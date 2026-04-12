defmodule FermixCore.Auth.TokenManager do
  @moduledoc """
  Manages OAuth tokens for LLM providers.

  Reads initial tokens from `~/.fermix/auth.json` (preferred) or `~/.codex/auth.json`.
  When bootstrapping from codex, immediately refreshes to fork an independent token chain
  so the two processes never collide on the same refresh token.
  """

  use GenServer

  require Logger

  @refresh_skew_ms 90_000
  @retry_backoff_ms 30_000
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @token_url "https://auth.openai.com/oauth/token"
  @max_attempts 3
  @retry_base_ms 350

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
    fermix_path = Keyword.get(opts, :fermix_auth_path, default_fermix_path())
    codex_path = Keyword.get(opts, :codex_auth_path, default_codex_path())
    req_options = Keyword.get(opts, :req_options, [])

    state = %{
      access_token: nil,
      refresh_token: nil,
      expires_at: nil,
      fermix_path: fermix_path,
      codex_path: codex_path,
      req_options: req_options,
      refresh_timer: nil
    }

    case load_tokens(fermix_path, codex_path) do
      {:ok, tokens, :fermix} ->
        state = apply_tokens(state, tokens)
        Logger.info("TokenManager: loaded tokens, expires #{inspect(state.expires_at)}")
        {:ok, schedule_refresh(state)}

      {:ok, tokens, :codex} ->
        state = apply_tokens(state, tokens)
        Logger.info("TokenManager: bootstrapping from codex, forking token chain")
        send(self(), :fork_refresh)
        {:ok, state}

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
  # Temporary: remove codex bootstrap + fork once M3 onboarding persists tokens directly
  def handle_info(:fork_refresh, state) do
    case do_refresh(state) do
      {:ok, state} ->
        Logger.info("TokenManager: forked own token chain from codex")
        {:noreply, state}

      {:error, reason, state} ->
        Logger.error("TokenManager: fork refresh failed — #{inspect(reason)}")
        timer = Process.send_after(self(), :fork_refresh, @retry_backoff_ms)
        {:noreply, %{state | refresh_timer: timer}}
    end
  end

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
    case call_refresh(state.refresh_token, state.req_options) do
      {:ok, tokens} ->
        state =
          state
          |> apply_tokens(tokens)
          |> schedule_refresh()

        persist_tokens(state)
        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp call_refresh(refresh_token, req_options, attempt \\ 1) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id
      })

    result =
      Req.new(
        url: @token_url,
        method: :post,
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )
      |> Req.merge(req_options)
      |> Req.request()

    case result do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: status}} when attempt < @max_attempts ->
        Logger.warning("TokenManager: refresh attempt #{attempt}/#{@max_attempts} got #{status}")
        Process.sleep(@retry_base_ms * attempt)
        call_refresh(refresh_token, req_options, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, "Refresh failed (#{status}): #{inspect(body)}"}

      {:error, _reason} when attempt < @max_attempts ->
        Logger.warning("TokenManager: refresh attempt #{attempt}/#{@max_attempts} failed")
        Process.sleep(@retry_base_ms * attempt)
        call_refresh(refresh_token, req_options, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_token_response(%{"access_token" => access} = body) when is_binary(access) do
    expires_at =
      case body["expires_in"] do
        secs when is_integer(secs) and secs > 0 ->
          DateTime.add(DateTime.utc_now(), secs, :second)

        _ ->
          nil
      end

    {:ok,
     %{
       access_token: access,
       refresh_token: body["refresh_token"],
       expires_at: expires_at
     }}
  end

  defp parse_token_response(_body), do: {:error, :invalid_token_response}

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

  # --- Token Loading ---

  defp load_tokens(fermix_path, codex_path) do
    case read_fermix_auth(fermix_path) do
      {:ok, tokens} -> {:ok, tokens, :fermix}
      {:error, _} -> load_from_codex(codex_path)
    end
  end

  defp load_from_codex(codex_path) do
    case read_codex_auth(codex_path) do
      {:ok, tokens} -> {:ok, tokens, :codex}
      {:error, _} = err -> err
    end
  end

  defp read_fermix_auth(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         %{"tokens" => %{"access_token" => at}} when is_binary(at) and at != "" <- data do
      tokens = data["tokens"]

      {:ok,
       %{
         access_token: at,
         refresh_token: tokens["refresh_token"],
         expires_at: parse_iso8601(data["expires_at"])
       }}
    else
      _ -> {:error, :no_fermix_auth}
    end
  end

  defp read_codex_auth(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         %{"tokens" => %{"access_token" => at}} when is_binary(at) and at != "" <- data do
      tokens = data["tokens"]

      {:ok,
       %{
         access_token: at,
         refresh_token: tokens["refresh_token"],
         expires_at: decode_jwt_exp(at)
       }}
    else
      _ -> {:error, :no_codex_auth}
    end
  end

  defp decode_jwt_exp(token) when is_binary(token) do
    with [_, payload | _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         exp when is_integer(exp) <- claims["exp"] do
      DateTime.from_unix!(exp)
    else
      _ -> nil
    end
  end

  defp parse_iso8601(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(_), do: nil

  # --- Persistence ---

  defp persist_tokens(state) do
    data =
      Jason.encode!(
        %{
          "auth_mode" => "chatgpt",
          "tokens" => %{
            "access_token" => state.access_token,
            "refresh_token" => state.refresh_token
          },
          "expires_at" => state.expires_at && DateTime.to_iso8601(state.expires_at),
          "last_refresh" => DateTime.to_iso8601(DateTime.utc_now())
        },
        pretty: true
      )

    dir = Path.dirname(state.fermix_path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(state.fermix_path, data) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("TokenManager: failed to persist — #{inspect(reason)}")
    end
  end

  defp default_fermix_path, do: Path.join(System.user_home!(), ".fermix/auth.json")
  defp default_codex_path, do: Path.join(System.user_home!(), ".codex/auth.json")
end
