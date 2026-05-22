defmodule FermixCore.Auth.OAuthFlow do
  @moduledoc """
  Native OAuth Authorization Code + PKCE flow against ChatGPT
  (`auth.openai.com`).

  Mirrors the Codex CLI / RustyClaw contract:

    * `client_id` `app_EMoamEEZ73f0CkXaXp7hrann`
    * `redirect_uri` `http://localhost:1455/auth/callback`
    * scopes `openid profile email offline_access`
    * `codex_cli_simplified_flow=true` and `id_token_add_organizations=true`
      (required to mint tokens that work against the
      `chatgpt.com/backend-api/codex` Responses surface)

  Fermix runs its own authorization grant — separate from Codex CLI's — so
  the refresh chain is independent. This avoids the `refresh_token_reused`
  race that occurs when two tools share a refresh token.

  `start_loopback/1` opens the browser, listens on `127.0.0.1:1455`,
  captures the auth code, and exchanges it for tokens.
  """

  alias FermixCore.Auth.Browser

  require Logger

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @redirect_uri "http://localhost:1455/auth/callback"
  @redirect_port 1455
  @scopes "openid profile email offline_access"
  @default_timeout_ms 300_000

  @type pkce :: %{code_verifier: String.t(), code_challenge: String.t(), state: String.t()}

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @type loopback_opts :: [
          port: :inet.port_number(),
          opener: (String.t() -> :ok | {:error, term()}) | nil,
          timeout_ms: pos_integer(),
          req_options: keyword(),
          puts: (String.t() -> any())
        ]

  @spec start_loopback(loopback_opts()) :: {:ok, tokens()} | {:error, term()}
  def start_loopback(opts \\ []) when is_list(opts) do
    port = Keyword.get(opts, :port, @redirect_port)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    opener = Keyword.get(opts, :opener, &open_browser/1)
    req_options = Keyword.get(opts, :req_options, [])
    puts = Keyword.get(opts, :puts, &IO.puts/1)

    pkce = generate_pkce()
    url = authorize_url(pkce)

    case listen(port) do
      {:ok, listener} ->
        result =
          with :ok <- announce_and_open(puts, opener, url),
               {:ok, code} <- await_callback(listener, pkce.state, timeout_ms) do
            exchange_code(code, pkce.code_verifier, req_options)
          end

        :ok = :gen_tcp.close(listener)
        result

      {:error, _reason} = err ->
        err
    end
  end

  @spec generate_pkce() :: pkce()
  def generate_pkce do
    code_verifier = random_base64url(64)
    code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
    state = random_base64url(24)
    %{code_verifier: code_verifier, code_challenge: code_challenge, state: state}
  end

  @spec authorize_url(pkce()) :: String.t()
  def authorize_url(%{code_challenge: code_challenge, state: state}) do
    params = [
      {"response_type", "code"},
      {"client_id", @client_id},
      {"redirect_uri", @redirect_uri},
      {"scope", @scopes},
      {"code_challenge", code_challenge},
      {"code_challenge_method", "S256"},
      {"state", state},
      {"codex_cli_simplified_flow", "true"},
      {"id_token_add_organizations", "true"}
    ]

    @authorize_url <> "?" <> URI.encode_query(params)
  end

  @spec parse_callback_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_callback_path(path, expected_state)
      when is_binary(path) and is_binary(expected_state) do
    case String.split(path, "?", parts: 2) do
      [_path, query] -> parse_callback_query(query, expected_state)
      [_path] -> {:error, :missing_code}
    end
  end

  @spec exchange_code(String.t(), String.t(), keyword()) :: {:ok, tokens()} | {:error, term()}
  def exchange_code(code, code_verifier, req_options \\ [])
      when is_binary(code) and is_binary(code_verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => @client_id,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => code_verifier
      })

    request =
      Req.new(
        url: @token_url,
        method: :post,
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )

    case request |> Req.merge(req_options) |> Req.request() do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, "Token exchange failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_callback_query(query, expected_state) do
    params = URI.decode_query(query)

    cond do
      err = Map.get(params, "error") ->
        desc = Map.get(params, "error_description", "OAuth authorization failed")
        {:error, "OAuth error: #{err} (#{desc})"}

      Map.get(params, "state") != expected_state ->
        {:error, :state_mismatch}

      code = Map.get(params, "code") ->
        {:ok, code}

      true ->
        {:error, :missing_code}
    end
  end

  defp listen(port) do
    case :gen_tcp.listen(port, [
           :binary,
           {:packet, :raw},
           {:active, false},
           {:reuseaddr, true},
           {:ip, {127, 0, 0, 1}}
         ]) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:listen_failed, port, reason}}
    end
  end

  defp announce_and_open(puts, nil, url) do
    puts.("Open this URL in your browser to sign in:\n  #{url}")
    :ok
  end

  defp announce_and_open(puts, opener, url) when is_function(opener, 1) do
    puts.("Opening browser to ChatGPT login...")

    case opener.(url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("OAuthFlow: opener failed (#{inspect(reason)}); printing URL")
        puts.("Open this URL in your browser to sign in:\n  #{url}")
        {:error, {:opener_failed, reason, url}}
    end
  end

  defp await_callback(listener, expected_state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    accept_loop(listener, expected_state, deadline)
  end

  defp accept_loop(listener, expected_state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :callback_timeout}
    else
      case :gen_tcp.accept(listener, min(remaining, 5_000)) do
        {:ok, conn} ->
          handle_connection(conn, expected_state)
          |> after_connection(listener, expected_state, deadline)

        {:error, :timeout} ->
          accept_loop(listener, expected_state, deadline)

        {:error, reason} ->
          {:error, {:accept_failed, reason}}
      end
    end
  end

  defp after_connection({:ok, _code} = ok, _listener, _state, _deadline), do: ok

  defp after_connection({:retry, _reason}, listener, state, deadline),
    do: accept_loop(listener, state, deadline)

  defp after_connection({:error, _reason} = err, _listener, _state, _deadline), do: err

  defp handle_connection(conn, expected_state) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, request} ->
        result = parse_request_path(request) |> resolve_callback(expected_state)
        send_response(conn, result)
        :gen_tcp.close(conn)
        result

      {:error, reason} ->
        :gen_tcp.close(conn)
        {:error, {:recv_failed, reason}}
    end
  end

  defp resolve_callback({:ok, "/" <> _ = path}, expected_state) do
    if browser_preflight?(path) do
      {:retry, :preflight}
    else
      parse_callback_path(path, expected_state)
    end
  end

  defp resolve_callback({:error, _reason} = err, _expected_state), do: err

  # Browsers and OS preflight requests (favicon.ico, /, robots.txt) hit the
  # listener before the OAuth callback. Skip them and keep accepting.
  defp browser_preflight?(path) do
    path in ["/", "/favicon.ico", "/robots.txt"] or
      String.starts_with?(path, "/.well-known/")
  end

  defp parse_request_path(request) when is_binary(request) do
    with [first_line | _] <- String.split(request, ["\r\n", "\n"], parts: 2),
         [_method, path, _version | _] <- String.split(first_line, " ") do
      {:ok, path}
    else
      _ -> {:error, :malformed_request}
    end
  end

  defp send_response(conn, {:ok, _code}) do
    body = """
    <!doctype html><html><body style="font-family:system-ui;margin:40px">
    <h2>Fermix login complete</h2>
    <p>You can close this tab and return to the terminal.</p>
    </body></html>
    """

    :gen_tcp.send(conn, http_response(200, "OK", body))
  end

  defp send_response(conn, {:retry, _reason}) do
    :gen_tcp.send(conn, http_response(204, "No Content", ""))
  end

  defp send_response(conn, {:error, _reason}) do
    body = """
    <!doctype html><html><body style="font-family:system-ui;margin:40px">
    <h2>Fermix login failed</h2>
    <p>Return to the terminal — the error details are printed there.</p>
    </body></html>
    """

    :gen_tcp.send(conn, http_response(400, "Bad Request", body))
  end

  defp http_response(status, status_text, body) do
    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      status_text,
      "\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ]
  end

  defp open_browser(url), do: Browser.open(url)

  defp random_base64url(byte_len) do
    :crypto.strong_rand_bytes(byte_len) |> Base.url_encode64(padding: false)
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
       id_token: body["id_token"],
       expires_at: expires_at
     }}
  end

  defp parse_token_response(_body), do: {:error, :invalid_token_response}
end
