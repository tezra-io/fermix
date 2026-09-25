defmodule FermixCore.Auth.TokenManager do
  @moduledoc """
  Manages OAuth tokens for local auth profiles.

  Reads from the Fermix-owned `~/.fermix/auth.json` store and refreshes
  before expiry. Codex CLI bootstrap was removed in M4.8 Stage 3 — the
  one-time `~/.codex` import lives in `FermixCore.Auth.CodexImport`,
  invoked explicitly by the setup wizard, and the resulting tokens
  land in `Auth.Store` under the `openai_codex` provider scope.
  """

  use GenServer

  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Auth.TokenFile
  alias FermixCore.Auth.TokenSupervisor

  require Logger

  # One proactive refresh per token, this long before expiry. A single re-armed
  # timer — not polling. Tokens with less than this margin left (or none) skip
  # the proactive refresh and fall back to the lazy on-use / reactive-401 path.
  @default_proactive_refresh_margin_ms 5 * 60 * 1000

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_token(GenServer.server() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_token(server \\ __MODULE__)

  def get_token(auth_profile) when is_binary(auth_profile),
    do: TokenSupervisor.get_token(auth_profile)

  def get_token(server) do
    GenServer.call(server, :get_token, 15_000)
  end

  @spec refresh(GenServer.server() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh(server \\ __MODULE__)

  def refresh(auth_profile) when is_binary(auth_profile),
    do: TokenSupervisor.refresh(auth_profile)

  def refresh(server) do
    GenServer.call(server, :refresh, 15_000)
  end

  @spec reload(GenServer.server() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def reload(server \\ __MODULE__)
  def reload(auth_profile) when is_binary(auth_profile), do: TokenSupervisor.reload(auth_profile)

  def reload(server) do
    GenServer.call(server, :reload, 5_000)
  end

  @doc """
  Drops the tokens this manager holds and refuses to serve them again.

  A sign-out that only deletes the stored entry leaves the running daemon
  holding the access and refresh tokens in memory, so Fermix keeps making calls
  as the account the operator just removed until the token expires. The manager
  is left invalidated rather than stopped: it is a supervised child, and a
  `reload/1` after a fresh sign-in is what brings it back.
  """
  @spec forget(GenServer.server() | String.t()) :: :ok
  def forget(server \\ __MODULE__)
  def forget(auth_profile) when is_binary(auth_profile), do: TokenSupervisor.forget(auth_profile)
  def forget(server), do: GenServer.call(server, :forget)

  @spec status(GenServer.server() | String.t()) :: {:ok, map()} | {:error, term()}
  def status(server \\ __MODULE__)
  def status(auth_profile) when is_binary(auth_profile), do: TokenSupervisor.status(auth_profile)

  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Project this profile's access token to `path` and keep it there (M8 §9.3).

  Writes the current token immediately, then rewrites it from the same seam
  that accepts any new grant, so a refreshed token reaches the plugin child
  without the child ever holding a refresh token. A grant that must not be
  served is refused here and leaves no file behind: a child started without the
  credential it exists to use would 401 every call, so the caller drops its
  spec instead.
  """
  @spec enable_token_file(GenServer.server() | String.t(), Path.t()) :: :ok | {:error, term()}
  def enable_token_file(auth_profile, path) when is_binary(auth_profile) and is_binary(path),
    do: TokenSupervisor.enable_token_file(auth_profile, path)

  def enable_token_file(server, path) when is_binary(path),
    do: GenServer.call(server, {:enable_token_file, path})

  @doc """
  Delete this profile's token projection and stop rewriting it.

  Called when no child is reading it any more: the plugin was disabled, its
  runtime gate was switched off, it stopped being ready, or it was uninstalled.
  """
  @spec disable_token_file(GenServer.server() | String.t()) :: :ok | {:error, term()}
  def disable_token_file(auth_profile) when is_binary(auth_profile),
    do: TokenSupervisor.disable_token_file(auth_profile)

  def disable_token_file(server), do: GenServer.call(server, :disable_token_file)

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    fermix_path = Keyword.get(opts, :fermix_auth_path, Store.path())
    req_options = Keyword.get(opts, :req_options, [])
    auth_profile = Keyword.get(opts, :auth_profile, :openai_codex)

    state = %{
      auth_profile: auth_profile,
      access_token: nil,
      refresh_token: nil,
      expires_at: nil,
      entry: nil,
      fermix_path: fermix_path,
      req_options: req_options,
      # nil while this manager serves tokens. Once a grant is invalidated it is
      # the reason every caller is answered with, until a reload brings a fresh
      # sign-in in: the generic one for a dead grant or a forget, the typed
      # `{:oauth_client_rejected, detail}` when the provider refused the client.
      refusal: nil,
      refresh_timer: nil,
      # The plugin-child token projection (M8 §9.3): nil until a local `mcp`
      # child that authenticates as this profile is materialized. `generation`
      # counts writes of the current file and resets when it is disabled.
      token_file: nil,
      token_file_generation: 0,
      refresh_margin_ms:
        Keyword.get(opts, :proactive_refresh_margin_ms, @default_proactive_refresh_margin_ms)
    }

    case Store.read(auth_profile, fermix_path) do
      {:ok, entry} ->
        state = apply_entry(state, entry)
        Logger.info("TokenManager: loaded tokens, expires #{inspect(state.expires_at)}")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("TokenManager: no tokens found — #{Redaction.format(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:get_token, _from, %{refusal: reason} = state) when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(:get_token, _from, %{access_token: nil} = state) do
    {:reply, {:error, :no_token}, state}
  end

  def handle_call(:get_token, _from, state) do
    if TokenExpiry.refresh_due?(state.expires_at) do
      case do_refresh(state) do
        {:ok, state} -> {:reply, {:ok, state.access_token}, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:ok, state.access_token}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status =
      %{
        auth_profile: state.auth_profile,
        loaded?: not is_nil(state.access_token),
        expires_at: state.expires_at,
        invalidated?: not is_nil(state.refusal)
      }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:refresh, _from, %{refusal: reason} = state) when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(:refresh, _from, state) do
    case do_refresh(state) do
      {:ok, state} -> {:reply, {:ok, state.access_token}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:forget, _from, state) do
    Logger.info("TokenManager: forgot tokens for #{inspect(state.auth_profile)}")
    {:reply, :ok, drop_tokens(state)}
  end

  def handle_call({:enable_token_file, path}, _from, state) do
    case sync_token_file(%{state | token_file: path}) do
      {:ok, synced} -> reply_enabled(synced)
      {:error, reason, _synced} -> {:reply, {:error, reason}, %{state | token_file: nil}}
    end
  end

  def handle_call(:disable_token_file, _from, %{token_file: nil} = state),
    do: {:reply, :ok, state}

  def handle_call(:disable_token_file, _from, state) do
    case TokenFile.delete(state.token_file) do
      :ok -> {:reply, :ok, %{state | token_file: nil, token_file_generation: 0}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reload, _from, state) do
    case Store.read(state.auth_profile, state.fermix_path) do
      {:ok, entry} ->
        state =
          state
          |> Map.put(:refusal, nil)
          |> apply_entry(entry)

        Logger.info("TokenManager: reloaded tokens, expires #{inspect(state.expires_at)}")
        {:reply, {:ok, state.access_token}, state}

      {:error, reason} ->
        Logger.warning("TokenManager: reload failed — #{Redaction.format(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:proactive_refresh, %{refusal: reason} = state) when not is_nil(reason),
    do: {:noreply, state}

  def handle_info(:proactive_refresh, %{refresh_token: nil} = state), do: {:noreply, state}

  def handle_info(:proactive_refresh, state) do
    # Best-effort keep-warm. On success `do_refresh` → `apply_entry` re-arms the
    # next timer; on a transient failure we don't re-arm — the token is still
    # valid and the lazy on-use / reactive-401 refresh stays the safety net.
    case do_refresh(state) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  # --- Internals ---

  # A single one-shot timer per token, re-armed whenever the token changes.
  defp schedule_proactive_refresh(state) do
    if is_reference(state.refresh_timer), do: Process.cancel_timer(state.refresh_timer)
    %{state | refresh_timer: arm_refresh(state.expires_at, state.refresh_margin_ms)}
  end

  defp arm_refresh(nil, _margin_ms), do: nil

  defp arm_refresh(%DateTime{} = expires_at, margin_ms) do
    delay = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) - margin_ms
    if delay > 0, do: Process.send_after(self(), :proactive_refresh, delay), else: nil
  end

  defp do_refresh(%{refresh_token: nil} = state) do
    {:error, :no_refresh_token, state}
  end

  # One refresher of this profile at a time, across processes and VMs: the
  # entry is read, refreshed and its outcome written under the profile lock
  # (`Store.with_profile_lock/3`), so a CLI VM or the Codex image backend never
  # presents the refresh token this refresh is consuming, and a logout never
  # lands inside it. The manager's own state and the token-file projection
  # change only after the lock is released.
  defp do_refresh(state) do
    locked =
      Store.with_profile_lock(state.auth_profile, state.fermix_path, fn ->
        refresh_stored(state)
      end)

    case locked do
      {:ok, entry} ->
        {:ok, apply_entry(state, entry)}

      {:refused, refusal} ->
        refuse(state, refusal)

      {:refused, refusal, write_error} ->
        {:error, _refusal, refused} = refuse(state, refusal)
        {:error, write_error, refused}

      {:signed_out, reason} ->
        signed_out(state, reason)

      # Transient, the lock included (another refresher held it past the wait,
      # and `Store` has logged it): the state is kept for the next trigger.
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Runs under the profile lock, which is not reentrant: nothing here takes it
  # again or calls a TokenManager.
  defp refresh_stored(state) do
    case latest_entry(state) do
      {:ok, entry} -> refresh_outcome(state, entry)
      {:error, reason} -> stored_entry_error(reason)
    end
  end

  # A manager's tokens only ever come from disk (`init/1`, `:reload`), so an
  # entry that is gone was signed out since it loaded them.
  defp stored_entry_error({:provider_missing, _provider} = reason), do: {:signed_out, reason}
  defp stored_entry_error(:no_auth_file), do: {:signed_out, :no_auth_file}
  defp stored_entry_error(reason), do: {:error, reason}

  defp refresh_outcome(state, entry) do
    case refresh_entry(state.auth_profile, entry, state.fermix_path, state.req_options) do
      {:ok, refreshed} ->
        {:ok, refreshed}

      # The grant cannot renew under this client, so it is quarantined under its
      # true cause. A sign-in with the same client, or a restart, cannot fix it.
      {:error, {:oauth_client_rejected, detail} = reason} ->
        Logger.error(
          "TokenManager: #{state.auth_profile} cannot renew " <>
            "(#{ClientRejection.vendor_words(detail)}). #{ClientRejection.sentence(detail)}"
        )

        mark_client_rejected(state.auth_profile, entry, state.fermix_path)
        {:refused, reason}

      {:error, {:permanent, status, body}} ->
        Logger.error(
          "TokenManager: refresh permanently failed (HTTP #{status}: #{Redaction.format(body)}). " <>
            "Recover with `fermix auth login`, then restart the daemon."
        )

        permanently_refused(state, entry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The provider has rejected the grant, so the manager refuses it whether or
  # not its status reached the store. A status write that failed (logged by
  # mark_reauthorization_required/3) is this caller's answer.
  defp permanently_refused(state, entry) do
    refusal = permanent_reason(state.auth_profile)

    case mark_reauthorization_required(state.auth_profile, entry, state.fermix_path) do
      :ok -> {:refused, refusal}
      {:error, reason} -> {:refused, refusal, reason}
    end
  end

  # The stored entry is gone: a logout ran since this manager loaded it, for example a
  # CLI logout whose `auth_forget` notice has not yet reached, or was refused by, this
  # daemon. Refreshing the in-memory copy would write the account back, so the manager
  # drops its tokens as `forget/1` does, and sends and writes nothing.
  defp signed_out(state, reason) do
    Logger.warning(
      "TokenManager: #{state.auth_profile} has no stored sign-in " <>
        "(#{Redaction.format(reason)}); dropping its tokens instead of refreshing them"
    )

    dropped = drop_tokens(state)
    {:error, dropped.refusal, dropped}
  end

  # Signed out: nothing is held or served again until a reload brings a fresh
  # sign-in in, and a plugin child's projection is deleted with the tokens.
  defp drop_tokens(state) do
    if is_reference(state.refresh_timer), do: Process.cancel_timer(state.refresh_timer)

    refresh_token_file(%{
      state
      | access_token: nil,
        refresh_token: nil,
        expires_at: nil,
        entry: nil,
        refresh_timer: nil,
        refusal: permanent_reason(state.auth_profile)
    })
  end

  defp apply_entry(state, %{tokens: tokens, expires_at: expires_at} = entry) do
    %{
      state
      | access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: expires_at,
        # Keep the whole entry — refresh dispatch keys on :provider
        # (anthropic/google), which a tokens-only merge silently dropped.
        entry: Map.merge(state.entry || %{}, entry),
        # A grant a sign-in quarantined is unexpired and otherwise servable, so
        # the refusal has to come off the entry itself. `Store` owns which
        # statuses those are; a grant that clears one clears the refusal here,
        # which is what a sign-in's reload does.
        refusal: Store.quarantine_reason(entry)
    }
    |> schedule_proactive_refresh()
    |> refresh_token_file()
  end

  # --- the plugin-child token projection (M8 §9.3) ---

  # The one place a grant becomes refused, so the projection is deleted with it:
  # a child must never keep calling with a credential the daemon has stopped
  # serving.
  defp refuse(state, reason), do: {:error, reason, refresh_token_file(%{state | refusal: reason})}

  # Write-through on every accepted grant. A failed projection is loud but not
  # fatal to the manager: serving tokens in-process is its primary job, and a
  # crash here would take the daemon's own provider calls down with it.
  defp refresh_token_file(%{token_file: nil} = state), do: state

  defp refresh_token_file(state) do
    case sync_token_file(state) do
      {:ok, synced} ->
        synced

      {:error, reason, synced} ->
        Logger.error(
          "TokenManager: could not project the #{synced.auth_profile} token for its plugin " <>
            "child — #{Redaction.format(reason)}"
        )

        synced
    end
  end

  # "Make the file match the grant": write the current token, or delete the file
  # when there is no servable token to project.
  defp sync_token_file(%{token_file: nil} = state), do: {:ok, state}

  defp sync_token_file(%{refusal: refusal, access_token: token} = state)
       when not is_nil(refusal) or is_nil(token) do
    case TokenFile.delete(state.token_file) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp sync_token_file(state) do
    generation = state.token_file_generation + 1

    case TokenFile.write(state.token_file, projection(state, generation)) do
      :ok -> {:ok, %{state | token_file_generation: generation}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp projection(state, generation) do
    %{
      access_token: state.access_token,
      expires_at: state.expires_at,
      region: state.entry && Map.get(state.entry, :region),
      auth_profile: to_string(state.auth_profile),
      generation: generation
    }
  end

  # `sync_token_file/1` deleting rather than writing means "the file matches the
  # grant", which is not the same as "the child has a credential to read". The
  # caller needs the second answer, and it drops the child's spec on anything
  # but `:ok` — so the registration comes back off too.
  defp reply_enabled(%{refusal: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, %{state | token_file: nil}}

  defp reply_enabled(%{access_token: nil} = state),
    do: {:reply, {:error, :no_token}, %{state | token_file: nil}}

  defp reply_enabled(state), do: {:reply, :ok, state}

  # Refresh from the newest persisted entry, not the in-memory copy. Another
  # refresher (a CLI/doctor probe, or a prior refresh) may have rotated the
  # refresh token in the store; Codex invalidates the whole session if a
  # rotated (consumed) refresh token is reused, so always start from disk. A
  # failed read is the answer: there is no in-memory fallback to refresh from.
  defp latest_entry(state) do
    with {:ok, entry} <- Store.read(state.auth_profile, state.fermix_path) do
      {:ok, Map.merge(state.entry || %{}, entry)}
    end
  end

  defp refresh_entry(:openai_codex, entry, path, req_options) do
    CodexToken.refresh_entry(entry, path, req_options)
  end

  defp refresh_entry("openai_codex", entry, path, req_options) do
    CodexToken.refresh_entry(entry, path, req_options)
  end

  defp refresh_entry(
         auth_profile,
         %{provider: "anthropic", tokens: %{refresh_token: refresh_token}} = entry,
         path,
         req_options
       )
       when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, tokens} <-
           RefreshClient.refresh(OAuthProvider.anthropic(), refresh_token, req_options),
         refreshed <- apply_tokens(entry, tokens),
         :ok <- Store.write(auth_profile, refreshed, path) do
      {:ok, refreshed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_entry(
         auth_profile,
         %{provider: "xai", tokens: %{refresh_token: refresh_token}} = entry,
         path,
         req_options
       )
       when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, tokens} <- RefreshClient.refresh(OAuthProvider.xai(), refresh_token, req_options),
         refreshed <- apply_tokens(entry, tokens),
         :ok <- Store.write(auth_profile, refreshed, path) do
      {:ok, refreshed}
    else
      # 403 is tier/entitlement denial, not a stale token — surface it
      # without tripping the central permanent-failure quarantine (§6.5).
      {:error, {:permanent, 403, _body}} -> {:error, :xai_oauth_tier_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  # Plugin OAuth profiles (google/github/notion/…): the provider registry
  # rebuilds the definition from the [fermix_core.oauth.<provider>] client
  # config; scopes come from the stored grant.
  defp refresh_entry(
         auth_profile,
         %{provider: provider, tokens: %{refresh_token: refresh_token}} = entry,
         path,
         req_options
       )
       when is_binary(provider) and is_binary(refresh_token) and refresh_token != "" do
    scopes = Map.get(entry, :granted_scopes, [])

    with {:ok, oauth_provider} <- OAuthProviders.definition_from_env(provider, scopes),
         {:ok, tokens} <- RefreshClient.refresh(oauth_provider, refresh_token, req_options),
         refreshed <- apply_tokens(entry, tokens),
         :ok <- Store.write(auth_profile, refreshed, path) do
      {:ok, refreshed}
    else
      {:error, {:unsupported_oauth_provider, _provider}} -> {:error, :unsupported_provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_entry(_auth_profile, _entry, _path, _req_options),
    do: {:error, :unsupported_provider}

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

  defp permanent_reason(:openai_codex), do: :auth_invalidated
  defp permanent_reason("openai_codex"), do: :auth_invalidated
  defp permanent_reason(_auth_profile), do: :reauthorization_required

  defp mark_reauthorization_required(:openai_codex, _entry, _path), do: :ok
  defp mark_reauthorization_required("openai_codex", _entry, _path), do: :ok

  defp mark_reauthorization_required(auth_profile, entry, path) do
    case Store.write(auth_profile, %{entry | status: "reauthorization_required"}, path) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "TokenManager: could not record reauthorization_required for #{auth_profile}: " <>
            Redaction.format(reason)
        )

        error
    end
  end

  # A successful sign-in or refresh rewrites the status to "ready", which is
  # what lifts this quarantine.
  defp mark_client_rejected(auth_profile, entry, path) do
    case Store.write(auth_profile, %{entry | status: "client_rejected"}, path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "TokenManager: could not record the refused sign-in client for #{auth_profile}: " <>
            Redaction.format(reason)
        )
    end
  end
end
