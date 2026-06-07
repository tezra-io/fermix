defmodule FermixCore.Auth.TokenSupervisor do
  @moduledoc """
  Starts one token manager per OAuth auth profile.
  """

  use Supervisor

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Auth.TokenManager

  @registry FermixCore.Auth.TokenRegistry
  @dynamic_supervisor FermixCore.Auth.TokenDynamicSupervisor
  @stop_wait_attempts 10
  @stop_wait_ms 10

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

  defp direct_read_entry(
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

  defp direct_read_entry(_auth_profile, _entry), do: {:error, :no_token}

  defp direct_status(auth_profile) do
    case Store.read(auth_profile) do
      {:ok, entry} ->
        {:ok, %{auth_profile: auth_profile, loaded?: true, expires_at: entry.expires_at}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp direct_refresh(auth_profile) do
    with {:ok, entry} <- Store.read(auth_profile),
         {:ok, refreshed} <- refresh_entry(auth_profile, entry, []) do
      {:ok, refreshed.tokens.access_token}
    end
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

  def refresh_entry(
        auth_profile,
        %{provider: "google", tokens: %{refresh_token: refresh_token}} = entry,
        req_options
      )
      when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, provider} <- google_provider(entry),
         {:ok, tokens} <- RefreshClient.refresh(provider, refresh_token, req_options),
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

  def refresh_entry(_auth_profile, _entry, _req_options), do: {:error, :unsupported_provider}

  defp google_provider(entry) do
    case google_client_config() do
      {:ok, config} ->
        {:ok,
         OAuthProvider.google(
           client_id: Keyword.fetch!(config, :client_id),
           client_secret: Keyword.fetch!(config, :client_secret),
           redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
           redirect_port: Keyword.get(config, :redirect_port, 1455),
           scopes: Map.get(entry, :granted_scopes, [])
         )}

      {:error, _reason} = err ->
        err
    end
  end

  defp google_client_config do
    config =
      case Application.get_env(:fermix_core, :oauth, %{}) do
        %{"google" => value} -> value
        oauth when is_list(oauth) -> Keyword.get(oauth, :google, [])
        _other -> []
      end

    client_id = Keyword.get(config, :client_id)
    client_secret = Keyword.get(config, :client_secret)

    if present?(client_id) and present?(client_secret) do
      {:ok, config}
    else
      {:error, :needs_client_config}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

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
    _ = Store.write(auth_profile, %{entry | status: "reauthorization_required"})
    {:error, :reauthorization_required}
  end
end
