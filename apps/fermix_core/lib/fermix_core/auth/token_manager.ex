defmodule FermixCore.Auth.TokenManager do
  @moduledoc """
  Manages OAuth tokens for the OpenAI provider.

  Reads from the Fermix-owned `~/.fermix/auth.json` store and refreshes
  before expiry. Codex CLI bootstrap was removed in M4.8 Stage 3 — the
  one-time `~/.codex` import lives in `FermixCore.Auth.CodexImport`,
  invoked explicitly by the setup wizard, and the resulting tokens
  land in `Auth.Store` under the `openai` provider scope.
  """

  use GenServer

  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store

  require Logger

  @refresh_skew_ms 90_000
  @retry_backoff_ms 30_000

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_token(server \\ __MODULE__) do
    GenServer.call(server, :get_token)
  end

  @spec refresh(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, 15_000)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    fermix_path = Keyword.get(opts, :fermix_auth_path, Store.path())
    req_options = Keyword.get(opts, :req_options, [])

    state = %{
      access_token: nil,
      refresh_token: nil,
      expires_at: nil,
      fermix_path: fermix_path,
      req_options: req_options,
      refresh_timer: nil
    }

    case Store.read(:openai, fermix_path) do
      {:ok, entry} ->
        state = apply_entry(state, entry)
        Logger.info("TokenManager: loaded tokens, expires #{inspect(state.expires_at)}")
        {:ok, schedule_refresh(state)}

      {:error, reason} ->
        Logger.warning("TokenManager: no tokens found — #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:get_token, _from, %{access_token: nil} = state) do
    {:reply, {:error, :no_token}, state}
  end

  def handle_call(:get_token, _from, state) do
    {:reply, {:ok, state.access_token}, state}
  end

  def handle_call(:refresh, _from, state) do
    case do_refresh(state) do
      {:ok, state} -> {:reply, {:ok, state.access_token}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    case do_refresh(state) do
      {:ok, state} ->
        Logger.info("TokenManager: refreshed successfully")
        {:noreply, state}

      {:error, reason, state} ->
        Logger.error("TokenManager: refresh failed — #{inspect(reason)}")
        timer = Process.send_after(self(), :refresh, @retry_backoff_ms)
        {:noreply, %{state | refresh_timer: timer}}
    end
  end

  # --- Internals ---

  defp do_refresh(%{refresh_token: nil} = state) do
    {:error, :no_refresh_token, state}
  end

  defp do_refresh(state) do
    case RefreshClient.refresh(state.refresh_token, state.req_options) do
      {:ok, tokens} ->
        state =
          state
          |> apply_tokens(tokens)
          |> schedule_refresh()

        persist(state)
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp apply_entry(state, %{tokens: tokens, expires_at: expires_at}) do
    %{
      state
      | access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: expires_at
    }
  end

  defp apply_tokens(state, tokens) do
    %{
      state
      | access_token: tokens.access_token,
        refresh_token: tokens.refresh_token || state.refresh_token,
        expires_at: tokens.expires_at
    }
  end

  defp schedule_refresh(state) do
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)

    case state.expires_at do
      nil ->
        %{state | refresh_timer: nil}

      expires_at ->
        ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
        delay = max(ms - @refresh_skew_ms, 1_000)
        timer = Process.send_after(self(), :refresh, delay)
        %{state | refresh_timer: timer}
    end
  end

  defp persist(state) do
    entry = %{
      auth_mode: "chatgpt",
      tokens: %{
        access_token: state.access_token,
        refresh_token: state.refresh_token
      },
      expires_at: state.expires_at,
      last_refresh: DateTime.utc_now()
    }

    case Store.write(:openai, entry, state.fermix_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("TokenManager: failed to persist — #{inspect(reason)}")
    end
  end
end
