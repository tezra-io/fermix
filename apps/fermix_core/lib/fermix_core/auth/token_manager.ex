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

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Auth.TokenSupervisor

  require Logger

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

  @spec status(GenServer.server() | String.t()) :: {:ok, map()} | {:error, term()}
  def status(server \\ __MODULE__)
  def status(auth_profile) when is_binary(auth_profile), do: TokenSupervisor.status(auth_profile)

  def status(server) do
    GenServer.call(server, :status)
  end

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
      invalidated: false
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
  def handle_call(:get_token, _from, %{invalidated: true} = state) do
    {:reply, {:error, permanent_reason(state.auth_profile)}, state}
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
        invalidated?: state.invalidated
      }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:refresh, _from, %{invalidated: true} = state) do
    {:reply, {:error, permanent_reason(state.auth_profile)}, state}
  end

  def handle_call(:refresh, _from, state) do
    case do_refresh(state) do
      {:ok, state} -> {:reply, {:ok, state.access_token}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reload, _from, state) do
    case Store.read(state.auth_profile, state.fermix_path) do
      {:ok, entry} ->
        state =
          state
          |> Map.put(:invalidated, false)
          |> apply_entry(entry)

        Logger.info("TokenManager: reloaded tokens, expires #{inspect(state.expires_at)}")
        {:reply, {:ok, state.access_token}, state}

      {:error, reason} ->
        Logger.warning("TokenManager: reload failed — #{Redaction.format(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # --- Internals ---

  defp do_refresh(%{refresh_token: nil} = state) do
    {:error, :no_refresh_token, state}
  end

  defp do_refresh(state) do
    entry = entry_from_state(state)

    case refresh_entry(state.auth_profile, entry, state.fermix_path, state.req_options) do
      {:ok, entry} ->
        {:ok, apply_entry(state, entry)}

      {:error, {:permanent, status, body}} ->
        Logger.error(
          "TokenManager: refresh permanently failed (HTTP #{status}: #{Redaction.format(body)}). " <>
            "Recover with `fermix auth login`, then restart the daemon."
        )

        reason = permanent_reason(state.auth_profile)
        mark_reauthorization_required(state.auth_profile, entry, state.fermix_path)
        {:error, reason, %{state | invalidated: true}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp apply_entry(state, %{tokens: tokens, expires_at: expires_at} = entry) do
    %{
      state
      | access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: expires_at,
        # Keep the whole entry — refresh dispatch keys on :provider
        # (anthropic/google), which a tokens-only merge silently dropped.
        entry: Map.merge(state.entry || %{}, entry)
    }
  end

  defp entry_from_state(state) do
    base =
      state.entry ||
        %{
          auth_mode: "chatgpt",
          tokens: %{access_token: state.access_token, refresh_token: state.refresh_token},
          expires_at: state.expires_at,
          last_refresh: nil
        }

    base
    |> Map.put(:tokens, %{
      access_token: state.access_token,
      refresh_token: state.refresh_token
    })
    |> Map.put(:expires_at, state.expires_at)
    |> Map.put(:last_refresh, Map.get(base, :last_refresh))
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
    _ = Store.write(auth_profile, %{entry | status: "reauthorization_required"}, path)
    :ok
  end
end
