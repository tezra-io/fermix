defmodule FermixCore.Auth.TokenSupervisor do
  @moduledoc """
  Starts one token manager per OAuth auth profile.
  """

  use Supervisor

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Auth.TokenManager

  require Logger

  @registry FermixCore.Auth.TokenRegistry
  @dynamic_supervisor FermixCore.Auth.TokenDynamicSupervisor
  @stop_wait_attempts 10
  @stop_wait_ms 10
  @codex_profile Store.profile(:openai_codex)

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec get_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_token(auth_profile) when is_binary(auth_profile) do
    call_or_read(auth_profile, :get_token)
  end

  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh(auth_profile) when is_binary(auth_profile) do
    call_or_read(auth_profile, :refresh)
  end

  @spec reload(String.t()) :: {:ok, String.t()} | {:error, term()}
  def reload(auth_profile) when is_binary(auth_profile) do
    call_or_read(auth_profile, :reload)
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(auth_profile) when is_binary(auth_profile) do
    case ensure_child(auth_profile) do
      {:ok, server} -> TokenManager.status(server)
      {:error, :not_started} -> direct_status(auth_profile)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ask this profile's manager to project its access token to `path` (M8 §9.3).

  Only the daemon can do this: the projection has to be rewritten on every
  refresh, and a tree-less CLI VM has no manager to do the rewriting. Such a VM
  refuses with `:token_file_needs_daemon` rather than writing a token file it
  could never keep fresh — `Auth.TokenFile.needs_daemon_sentence/0` is the
  sentence for it. No `fermix` CLI verb reaches here today: the verbs mutate
  config and the plugin store on disk and ask the running daemon to re-apply,
  and plugin children are only ever materialized inside the daemon's MCP tree.
  """
  @spec enable_token_file(String.t(), Path.t()) :: :ok | {:error, term()}
  def enable_token_file(auth_profile, path) when is_binary(auth_profile) and is_binary(path) do
    case ensure_child(auth_profile) do
      {:ok, server} -> TokenManager.enable_token_file(server, path)
      {:error, :not_started} -> {:error, :token_file_needs_daemon}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete one profile's token projection, when a manager is holding it.

  Never starts a manager, for the same reason `forget/1` does not: a profile
  with no live holder is already writing nothing, and a projection left on disk
  by a previous daemon is collected by the plugin store's boot sweep before any
  child spawns.
  """
  @spec disable_token_file(String.t()) :: :ok | {:error, term()}
  def disable_token_file(auth_profile) when is_binary(auth_profile) do
    case running_manager(auth_profile) do
      {:ok, server} -> TokenManager.disable_token_file(server)
      :none -> :ok
    end
  end

  @doc """
  Delete every profile's token projection except the ones in `kept`.

  The reconciliation half of `enable_token_file/2`: the daemon re-derives which
  plugin children it wants on every reload, and every other live manager must
  stop keeping an access token on disk. It asks the running managers rather than
  the plugin registry, because the registry no longer lists a plugin that was
  just uninstalled or dropped from `dev_local` — and those are precisely the
  cases whose file has to go. A manager holding no projection answers a cheap
  no-op, so profiles that never had one cost nothing.
  """
  @spec release_token_files_except(Enumerable.t()) :: :ok
  def release_token_files_except(kept) do
    keep = MapSet.new(kept)

    live_profiles()
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> Enum.each(&disable_token_file/1)
  end

  defp live_profiles do
    case Process.whereis(@registry) do
      nil -> []
      _pid -> Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    end
  end

  @doc """
  Drops one profile's tokens from the manager serving it, when one is running.

  Never starts a manager: a profile with no live holder is already in the state
  the caller asked for, and starting one to forget it would read the entry that
  was just deleted.
  """
  @spec forget(String.t()) :: :ok
  def forget(auth_profile) when is_binary(auth_profile) do
    case running_manager(auth_profile) do
      {:ok, server} -> TokenManager.forget(server)
      :none -> :ok
    end
  end

  @doc """
  Lets go of a profile a tree-less CLI VM has just signed out of
  (`fermix auth logout`, `fermix plugins auth logout`): the daemon's side of
  its `auth_forget` request.

  The CLI deleted the stored entry; this VM may still hold the tokens. The
  manager serving the profile drops them, and deletes its plugin child's token
  file, through `forget/1`. A child of this supervisor is then stopped, so its
  next use starts a fresh manager from auth.json and serves a sign-in made
  after the logout instead of refusing it. The Codex profile's manager is the
  top-level `TokenManager`, which this supervisor does not own: it is only told
  to forget, and a restart (or a reload after the next sign-in) brings it back.
  Never starts a manager, and a manager that stopped between its lookup and
  the call held nothing, so that is `:ok` too.

  A `get_token` call queued on a child at the moment it is stopped exits in its
  caller instead of answering `{:error, :auth_invalidated}`: a window of one
  message, which a plugin logout's stop (`Plugins.Auth.logout/1`) already has.
  """
  @spec forget_signed_out(String.t()) :: :ok
  def forget_signed_out(@codex_profile) do
    case Process.whereis(TokenManager) do
      nil -> :ok
      pid -> forget_live(fn -> TokenManager.forget(pid) end)
    end
  end

  def forget_signed_out(auth_profile) when is_binary(auth_profile) and auth_profile != "" do
    :ok = forget_live(fn -> forget(auth_profile) end)
    stop_profile(auth_profile)
  end

  # `:noproc` is the lookup's "no manager", observed a moment later. Every
  # other exit (a wedged manager's timeout) still reaches the caller.
  defp forget_live(forget) do
    forget.()
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp running_manager(auth_profile) do
    with pid when is_pid(pid) <- Process.whereis(@registry),
         [{_pid, _value}] <- Registry.lookup(@registry, auth_profile) do
      {:ok, via(auth_profile)}
    else
      _absent -> :none
    end
  end

  @spec stop_profile(String.t()) :: :ok
  def stop_profile(auth_profile) when is_binary(auth_profile) do
    if Process.whereis(@registry) && Process.whereis(@dynamic_supervisor) do
      case Registry.lookup(@registry, auth_profile) do
        [{pid, _value}] ->
          DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
          wait_until_unregistered(auth_profile, @stop_wait_attempts)
          :ok

        [] ->
          :ok
      end
    else
      :ok
    end
  end

  defp wait_until_unregistered(_auth_profile, 0), do: :ok

  defp wait_until_unregistered(auth_profile, attempts_left) do
    case Registry.lookup(@registry, auth_profile) do
      [] ->
        :ok

      [{_pid, _value}] ->
        Process.sleep(@stop_wait_ms)
        wait_until_unregistered(auth_profile, attempts_left - 1)
    end
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp call_or_read(auth_profile, :refresh) do
    case ensure_child(auth_profile) do
      {:ok, server} -> TokenManager.refresh(server)
      {:error, :not_started} -> direct_refresh(auth_profile)
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_or_read(auth_profile, call) do
    case ensure_child(auth_profile) do
      {:ok, server} -> apply(TokenManager, call, [server])
      {:error, :not_started} -> direct_read(auth_profile)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_child(auth_profile) do
    if Process.whereis(__MODULE__) do
      server = via(auth_profile)

      case Registry.lookup(@registry, auth_profile) do
        [{_pid, _value}] ->
          {:ok, server}

        [] ->
          start_child(auth_profile, server)
      end
    else
      {:error, :not_started}
    end
  end

  defp start_child(auth_profile, server) do
    child = %{
      id: {:token_manager, auth_profile},
      start: {TokenManager, :start_link, [[name: server, auth_profile: auth_profile]]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(@dynamic_supervisor, child) do
      {:ok, _pid} -> {:ok, server}
      {:error, {:already_started, _pid}} -> {:ok, server}
      {:error, reason} -> {:error, reason}
    end
  end

  defp via(auth_profile), do: {:via, Registry, {@registry, auth_profile}}

  defp direct_read(auth_profile) do
    case Store.read(auth_profile) do
      {:ok, entry} when is_map(entry) ->
        direct_read_entry(auth_profile, entry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The tree-less world reads the same quarantine the supervised manager applies
  # in memory, so a CLI VM cannot hand out a credential the daemon refuses.
  defp direct_read_entry(auth_profile, entry) do
    case Store.quarantine_reason(entry) do
      nil -> serve_entry(auth_profile, entry)
      reason -> {:error, reason}
    end
  end

  defp serve_entry(
         auth_profile,
         %{tokens: %{access_token: token}, expires_at: expires_at}
       )
       when is_binary(token) and token != "" do
    if TokenExpiry.refresh_due?(expires_at) do
      direct_refresh(auth_profile)
    else
      {:ok, token}
    end
  end

  defp serve_entry(_auth_profile, _entry), do: {:error, :no_token}

  defp direct_status(auth_profile) do
    case Store.read(auth_profile) do
      {:ok, entry} ->
        {:ok, %{auth_profile: auth_profile, loaded?: true, expires_at: entry.expires_at}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp direct_refresh(auth_profile), do: direct_refresh(auth_profile, [])

  # A tree-less VM refreshes with no manager, so it takes the profile lock the
  # daemon's manager takes (`Store.with_profile_lock/3`) and reads the entry
  # under it: it never presents a refresh token another refresher is consuming,
  # and its status write after a 4xx can never land over that refresher's
  # rotation. Public for tests, which inject `req_options`.
  @doc false
  @spec direct_refresh(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def direct_refresh(auth_profile, req_options)
      when is_binary(auth_profile) and is_list(req_options) do
    Store.with_profile_lock(auth_profile, Store.path(), fn ->
      with {:ok, entry} <- Store.read(auth_profile),
           {:ok, refreshed} <- refresh_entry(auth_profile, entry, req_options) do
        {:ok, refreshed.tokens.access_token}
      end
    end)
  end

  # Public for tests: the direct (process-less) refresh dispatch is a real
  # production path and needs `req_options` injection to be hermetic.
  @doc false
  @spec refresh_entry(String.t(), Store.entry(), keyword()) ::
          {:ok, Store.entry()} | {:error, term()}
  def refresh_entry("openai_codex", entry, req_options),
    do: CodexToken.refresh_entry(entry, Store.path(), req_options)

  def refresh_entry(
        auth_profile,
        %{provider: "anthropic", tokens: %{refresh_token: refresh_token}} = entry,
        req_options
      )
      when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, tokens} <-
           RefreshClient.refresh(OAuthProvider.anthropic(), refresh_token, req_options),
         refreshed <- apply_tokens(entry, tokens),
         :ok <- Store.write(auth_profile, refreshed) do
      {:ok, refreshed}
    else
      {:error, {:permanent, _status, _body}} ->
        mark_reauthorization_required(auth_profile, entry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh_entry(
        auth_profile,
        %{provider: "xai", tokens: %{refresh_token: refresh_token}} = entry,
        req_options
      )
      when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, tokens} <- RefreshClient.refresh(OAuthProvider.xai(), refresh_token, req_options),
         refreshed <- apply_tokens(entry, tokens),
         :ok <- Store.write(auth_profile, refreshed) do
      {:ok, refreshed}
    else
      # 403 is tier/entitlement denial, not a stale token — keep tokens,
      # no quarantine (design doc §6.5).
      {:error, {:permanent, 403, _body}} ->
        {:error, :xai_oauth_tier_denied}

      {:error, {:permanent, _status, _body}} ->
        mark_reauthorization_required(auth_profile, entry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Plugin OAuth profiles (google/github/notion/…): the provider registry
  # rebuilds the definition from the [fermix_core.oauth.<provider>] client
  # config; scopes come from the stored grant.
  def refresh_entry(
        auth_profile,
        %{provider: provider, tokens: %{refresh_token: refresh_token}} = entry,
        req_options
      )
      when is_binary(provider) and is_binary(refresh_token) and refresh_token != "" do
    scopes = Map.get(entry, :granted_scopes, [])

    with {:ok, oauth_provider} <- OAuthProviders.definition_from_env(provider, scopes),
         {:ok, tokens} <- RefreshClient.refresh(oauth_provider, refresh_token, req_options),
         refreshed <- apply_tokens(entry, tokens),
         :ok <- Store.write(auth_profile, refreshed) do
      {:ok, refreshed}
    else
      {:error, {:unsupported_oauth_provider, _provider}} ->
        {:error, :unsupported_provider}

      {:error, {:oauth_client_rejected, _detail} = reason} ->
        mark_client_rejected(auth_profile, entry, reason)

      {:error, {:permanent, _status, _body}} ->
        mark_reauthorization_required(auth_profile, entry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh_entry(_auth_profile, _entry, _req_options), do: {:error, :unsupported_provider}

  defp apply_tokens(entry, tokens) do
    %{
      entry
      | tokens: %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token || entry.tokens.refresh_token
        },
        expires_at: tokens.expires_at,
        last_refresh: DateTime.utc_now(),
        status: "ready"
    }
  end

  defp mark_reauthorization_required(auth_profile, entry) do
    case Store.write(auth_profile, %{entry | status: "reauthorization_required"}) do
      :ok ->
        {:error, :reauthorization_required}

      {:error, reason} = error ->
        Logger.error(
          "TokenSupervisor: could not record reauthorization_required for #{auth_profile}: " <>
            Redaction.format(reason)
        )

        error
    end
  end

  # The grant cannot renew under the refused client, so it is quarantined under
  # its true cause, exactly as the supervised manager does; a successful sign-in
  # or refresh rewrites the status to "ready". The caller words the refusal.
  defp mark_client_rejected(auth_profile, entry, reason) do
    case Store.write(auth_profile, %{entry | status: "client_rejected"}) do
      :ok ->
        {:error, reason}

      {:error, write_reason} ->
        Logger.error(
          "TokenSupervisor: could not record the refused sign-in client for #{auth_profile}: " <>
            Redaction.format(write_reason)
        )

        {:error, reason}
    end
  end
end
