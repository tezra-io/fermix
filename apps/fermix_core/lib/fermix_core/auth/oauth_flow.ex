defmodule FermixCore.Auth.OAuthFlow do
  @moduledoc """
  Native OAuth Authorization Code + PKCE loopback flows, for the provider an
  `Auth.OAuthProvider` describes: xAI, the plugins' providers, and Sign in with
  ChatGPT (`await_authorization/2`, whose caller exchanges the code itself).

  The exchange spends the authorization code, so a sign-in passes `:redeem`: a
  function given the exchange (a zero-arity function) that takes the profile
  lock before running it and writes the grant before releasing the lock
  (`Auth.Store.with_profile_lock/3`). A busy profile then refuses after the
  browser step with the code unspent. The flow returns what `:redeem` returns;
  without it, the tokens. Every request the flow makes sets
  `RefreshClient.request_bounds/0`, since it runs under that lock.

  The wait is one attempt with two inputs. A monitored acceptor process
  answers the browser and sends the attempt the first request that settles it;
  with `:paste_message`, the waiting process also takes `{tag, url}` messages
  carrying the address the browser ended on, parsed by the same rules. A
  provider with `hardened_callback?` accepts only `GET` with the exact `Host`
  and path, and a request whose `state` is wrong is answered 400 without
  ending the attempt. `await_authorization/2` stops there and returns the
  callback; `start_loopback/2` goes on to the exchange.
  """

  alias FermixCore.Auth.Browser
  alias FermixCore.Auth.CallbackPage
  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.JwtClaims
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Net.Egress

  require Logger

  @default_timeout_ms 300_000
  # A loopback catcher reads the request line with a non-buffering raw recv, so
  # the request can arrive split across reads — accumulate up to a full line,
  # bounded by a per-read wait and a byte cap.
  @per_recv_timeout_ms 5_000
  @max_request_bytes 64_000

  @type pkce :: %{code_verifier: String.t(), code_challenge: String.t(), state: String.t()}

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil,
          scope: String.t() | nil,
          expires_at: DateTime.t() | nil,
          earliest_refresh_at: term()
        }

  @typedoc """
  Runs the code exchange it is given and returns the flow's result. A sign-in's
  takes the profile lock first and stores the grant before releasing it.
  """
  @type redeem :: ((-> {:ok, map()} | {:error, term()}) -> {:ok, term()} | {:error, term()})

  @type loopback_opts :: [
          port: :inet.port_number(),
          opener: (String.t() -> :ok | {:error, term()}) | nil,
          timeout_ms: pos_integer(),
          port_fallbacks: non_neg_integer(),
          req_options: keyword(),
          puts: (String.t() -> any()),
          redeem: redeem(),
          paste_message: atom()
        ]

  @typedoc """
  A settled callback: the code, the client the provider issued (`nil` for a
  `:static` client), the callback's own `scope`, and what the exchange must
  repeat.
  """
  @type authorization :: %{
          code: String.t(),
          client_id: String.t() | nil,
          scope: String.t() | nil,
          redirect_uri: String.t(),
          code_verifier: String.t()
        }

  # Every OAuth `error` code is a short identifier; anything else in that field
  # is not repeated.
  @vendor_code ~r/\A[a-z0-9_.]{1,64}\z/
  @issued_client_id ~r/\A[a-zA-Z0-9_-]{1,200}\z/

  @spec start_loopback(OAuthProvider.t(), loopback_opts()) :: {:ok, term()} | {:error, term()}
  def start_loopback(%OAuthProvider{} = provider, opts) when is_list(opts) do
    redeem = Keyword.get(opts, :redeem, &exchange_only/1)

    with {:ok, authorization} <- await_authorization(provider, opts) do
      redeem.(provider_exchange(provider, authorization, opts))
    end
  end

  @doc """
  Binds the callback listener, opens (or prints) the authorize url, and waits
  for the attempt's callback: from the browser, or pasted as a
  `{paste_message, url}` message to the calling process. An opener that fails
  only prints the url; the wait goes on. Spends nothing: the caller exchanges
  the code.
  """
  @spec await_authorization(OAuthProvider.t(), loopback_opts()) ::
          {:ok, authorization()} | {:error, term()}
  def await_authorization(%OAuthProvider{} = provider, opts) when is_list(opts) do
    port = Keyword.get(opts, :port, provider.redirect_port)

    with {:ok, listener} <- listen_for(provider, port, opts) do
      result = authorize_on(listener, provider, opts)
      :ok = :gen_tcp.close(listener)
      result
    end
  end

  defp authorize_on(listener, provider, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    opener = Keyword.get(opts, :opener, &open_browser/1)
    puts = Keyword.get(opts, :puts, &IO.puts/1)
    pkce = generate_pkce()
    {:ok, actual_port} = :inet.port(listener)
    redirect_uri = redirect_uri(provider, actual_port)
    spec = callback_spec(provider, pkce.state, actual_port)

    with :ok <-
           announce_and_open_optional(puts, opener, authorize_url(provider, pkce, redirect_uri)),
         {:ok, callback} <- await_callback(listener, spec, timeout_ms, opts) do
      {:ok, Map.merge(callback, %{redirect_uri: redirect_uri, code_verifier: pkce.code_verifier})}
    end
  end

  # The flow without a sign-in around it: the exchange alone, for a caller
  # that stores nothing.
  defp exchange_only(exchange), do: exchange.()

  # The exchange `:redeem` is handed: nothing is spent until it is called.
  defp provider_exchange(provider, authorization, opts),
    do: fn -> exchange_with_userinfo(provider, authorization, opts) end

  defp exchange_with_userinfo(provider, authorization, opts) do
    req_options = Keyword.get(opts, :req_options, [])
    userinfo_req_options = Keyword.get(opts, :userinfo_req_options, [])
    %{code: code, code_verifier: verifier, redirect_uri: redirect_uri} = authorization

    with {:ok, tokens} <- exchange_code(provider, code, verifier, redirect_uri, req_options) do
      userinfo = fetch_userinfo_best_effort(provider, tokens.access_token, userinfo_req_options)
      {:ok, Map.put(tokens, :userinfo, userinfo)}
    end
  end

  @spec generate_pkce() :: pkce()
  def generate_pkce do
    code_verifier = random_base64url(64)
    code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
    state = random_base64url(24)
    %{code_verifier: code_verifier, code_challenge: code_challenge, state: state}
  end

  @spec authorize_url(OAuthProvider.t(), pkce(), String.t()) :: String.t()
  def authorize_url(
        %OAuthProvider{} = provider,
        %{code_challenge: code_challenge, state: state},
        redirect_uri
      ) do
    params =
      %{
        "response_type" => "code",
        "client_id" => provider.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => Enum.join(provider.scopes, " "),
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256",
        "state" => state
      }
      |> Map.merge(provider.extra_authorize_params)

    provider.authorize_url <> "?" <> URI.encode_query(params)
  end

  @spec parse_callback_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_callback_path(path, expected_state)
      when is_binary(path) and is_binary(expected_state) do
    case String.split(path, "?", parts: 2) do
      [_path, query] -> parse_callback_query(query, expected_state)
      [_path] -> {:error, :missing_code}
    end
  end

  @spec exchange_code(OAuthProvider.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, tokens()} | {:error, term()}
  def exchange_code(%OAuthProvider{} = provider, code, code_verifier, redirect_uri, req_options)
      when is_binary(code) and is_binary(code_verifier) and is_binary(redirect_uri) and
             is_list(req_options) do
    # `extra_token_params` is merged UNDER the exchange's own fields, so a
    # provider definition can add what its endpoint requires (Tesla's regional
    # `audience`) but can never rewrite the grant, the code, or the redirect.
    body =
      provider.extra_token_params
      |> Map.merge(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => code_verifier
      })
      |> Map.merge(OAuthProvider.body_credentials(provider))
      |> maybe_echo_code_challenge(provider, code_verifier)
      |> URI.encode_query()

    request =
      Req.new(
        [
          url: provider.token_url,
          method: :post,
          body: body,
          headers: OAuthProvider.token_request_headers(provider)
        ] ++ RefreshClient.request_bounds()
      )

    case request |> Req.merge(req_options) |> Egress.attach(:direct) |> Req.request() do
      {:ok, %{status: status, body: body}} ->
        exchange_response(provider, status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A refused client is recognised whatever the status (GitHub and Slack refuse
  # with a 200); every other response keeps its own handling.
  defp exchange_response(provider, status, body) do
    case ClientRejection.classify(provider, status, body) do
      nil -> token_exchange_response(status, body)
      rejection -> {:error, rejection}
    end
  end

  defp token_exchange_response(200, body), do: parse_token_response(body)

  defp token_exchange_response(status, body),
    do: {:error, "Token exchange failed (#{status}): #{Redaction.format(body)}"}

  @spec fetch_userinfo(OAuthProvider.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_userinfo(%OAuthProvider{userinfo_url: nil}, _access_token, _req_options),
    do: {:ok, nil}

  def fetch_userinfo(%OAuthProvider{} = provider, access_token, req_options)
      when is_binary(access_token) and is_list(req_options) do
    request =
      Req.new(
        [
          method: :get,
          url: provider.userinfo_url,
          headers: [{"authorization", "Bearer #{access_token}"}]
        ] ++ RefreshClient.request_bounds()
      )

    case request |> Req.merge(req_options) |> Egress.attach(:direct) |> Req.request() do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:userinfo_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_userinfo_best_effort(provider, access_token, req_options) do
    case fetch_userinfo(provider, access_token, req_options) do
      {:ok, userinfo} ->
        userinfo

      {:error, reason} ->
        Logger.warning("OAuthFlow: userinfo fetch failed: #{Redaction.format(reason)}")
        nil
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

  # Providers with exact-match registered redirect URIs (fixed_port?) get one
  # bind attempt — falling back to another port would redirect to an
  # unregistered URI, so a taken port fails loud instead.
  defp listen_for(%OAuthProvider{fixed_port?: true} = provider, port, _opts) do
    case listen(port) do
      {:ok, listener} ->
        {:ok, listener}

      {:error, {:listen_failed, ^port, :eaddrinuse}} ->
        Logger.error(
          "OAuthFlow: redirect port #{port} is in use and #{provider.id} requires the exact " <>
            "registered redirect URI — free the port and retry."
        )

        {:error, {:port_in_use, port}}

      {:error, _reason} = err ->
        err
    end
  end

  defp listen_for(%OAuthProvider{} = _provider, port, opts) do
    listen_with_fallback(port, Keyword.get(opts, :port_fallbacks, 5))
  end

  defp listen_with_fallback(0, _fallbacks), do: listen(0)

  defp listen_with_fallback(port, fallbacks)
       when is_integer(port) and port > 0 and is_integer(fallbacks) and fallbacks >= 0 do
    port
    |> candidate_ports(fallbacks)
    |> do_listen_with_fallback(nil)
  end

  defp candidate_ports(port, fallbacks) do
    0..fallbacks
    |> Enum.map(&(&1 + port))
    |> Enum.filter(&(&1 <= 65_535))
  end

  defp do_listen_with_fallback([], {:error, _reason} = err), do: err
  defp do_listen_with_fallback([], nil), do: {:error, {:listen_failed, nil, :no_candidate_port}}

  defp do_listen_with_fallback([port | rest], _last_error) do
    case listen(port) do
      {:ok, listener} ->
        {:ok, listener}

      {:error, {:listen_failed, _port, :eaddrinuse}} = err ->
        do_listen_with_fallback(rest, err)

      {:error, _reason} = err ->
        err
    end
  end

  # A provider that registered a public redirect URI (Tesla accepts no loopback
  # one) sends that URI in authorize and in the exchange; the bounce page it
  # names forwards the callback to the loopback listener, which stays local.
  defp redirect_uri(%OAuthProvider{public_redirect_uri: uri}, _port) when is_binary(uri), do: uri

  defp redirect_uri(%OAuthProvider{} = provider, port) do
    "http://#{provider.redirect_host}:#{port}#{provider.redirect_path}"
  end

  defp announce_and_open_optional(puts, nil, url) do
    puts.("Open this URL in your browser to sign in:\n  #{url}")
    :ok
  end

  defp announce_and_open_optional(puts, opener, url) when is_function(opener, 1) do
    puts.("Starting the browser sign-in...")

    case opener.(url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("OAuthFlow: opener failed (#{opener_failure(reason)}); printing URL")
        puts.("Open this URL in your browser to sign in:\n  #{url}")
        :ok
    end
  end

  # An opener's output can echo the url it was given, and the url is never
  # logged: an OS opener's failure is named by its exit status alone.
  defp opener_failure({:opener_failed, status, _output}), do: "exit #{status}"
  defp opener_failure(reason), do: Redaction.format(reason)

  # What one attempt accepts as its callback. The `state` it sent; for a
  # hardened listener also the exact `Host` and path; and where the client id
  # comes from (`OAuthProvider.client_registration`).
  defp callback_spec(%OAuthProvider{} = provider, state, port) do
    %{
      state: state,
      hardened?: provider.hardened_callback?,
      host: "#{provider.redirect_host}:#{port}",
      path: provider.redirect_path,
      registration: provider.client_registration,
      client_id: provider.client_id
    }
  end

  # The acceptor answers the browser in its own process and sends the first
  # request that settles the attempt, so this process can also take a pasted
  # address. The listener is this process's: closing it ends the acceptor's
  # accept, and the acceptor is killed and its last message flushed before this
  # returns, so nothing of the attempt is left behind.
  defp await_callback(listener, spec, timeout_ms, opts) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    reply_to = {self(), make_ref()}
    {pid, monitor} = spawn_monitor(fn -> accept_loop(listener, spec, deadline, reply_to) end)

    wait = %{
      ref: elem(reply_to, 1),
      monitor: monitor,
      spec: spec,
      deadline: deadline,
      paste: Keyword.get(opts, :paste_message),
      puts: Keyword.get(opts, :puts, &IO.puts/1)
    }

    case wait_for_callback(wait) do
      {:acceptor_down, reason} ->
        {:error, {:accept_failed, reason}}

      result ->
        stop_acceptor(pid, wait)
        result
    end
  end

  defp wait_for_callback(%{ref: ref, monitor: monitor, paste: paste} = wait) do
    remaining = max(wait.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, result} ->
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:acceptor_down, reason}

      {^paste, url} when not is_nil(paste) and is_binary(url) ->
        pasted_callback(url, wait)
    after
      remaining -> {:error, :callback_timeout}
    end
  end

  # A pasted address goes through the listener's own rules. One that does not
  # settle this attempt (another attempt's state, the wrong address) is refused
  # and the wait goes on, as a stray browser request's would.
  defp pasted_callback(url, wait) do
    case resolve_request(pasted_request(url), wait.spec) do
      {:ok, _callback} = settled ->
        settled

      {:error, _reason} = settled ->
        settled

      refused ->
        Logger.info("OAuthFlow: refused a pasted callback address (#{refusal_kind(refused)})")

        wait.puts.(
          "That address is not from this sign-in. Paste the address the browser ended on."
        )

        wait_for_callback(wait)
    end
  end

  defp pasted_request(url) do
    uri = url |> String.trim() |> URI.parse()

    request = %{
      method: "GET",
      target: (uri.path || "") <> if(uri.query, do: "?" <> uri.query, else: ""),
      host: "#{uri.host}:#{uri.port}"
    }

    if uri.scheme == "http", do: {:ok, request}, else: {:error, :malformed_request}
  end

  defp refusal_kind({:retry, reason}), do: inspect(reason)
  defp refusal_kind({:reject, _status, reason}), do: inspect(reason)

  defp stop_acceptor(pid, %{ref: ref, monitor: monitor}) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    receive do
      {^ref, _late} -> :ok
    after
      0 -> :ok
    end
  end

  # The deadline is the waiter's too. Saying so before exiting makes a timeout
  # read as one whichever process reaches the deadline first: a process's
  # message always arrives before its `:DOWN`, which alone would read as a
  # failed accept.
  defp accept_loop(listener, spec, deadline, reply_to) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      reply(reply_to, {:error, :callback_timeout})
    else
      case :gen_tcp.accept(listener, min(remaining, 5_000)) do
        {:ok, conn} ->
          conn
          |> handle_connection(spec, deadline)
          |> after_connection(listener, spec, deadline, reply_to)

        {:error, :timeout} ->
          accept_loop(listener, spec, deadline, reply_to)

        {:error, reason} ->
          reply(reply_to, {:error, {:accept_failed, reason}})
      end
    end
  end

  defp after_connection({:retry, _reason}, listener, spec, deadline, reply_to),
    do: accept_loop(listener, spec, deadline, reply_to)

  defp after_connection({:reject, _status, _reason}, listener, spec, deadline, reply_to),
    do: accept_loop(listener, spec, deadline, reply_to)

  defp after_connection(settled, _listener, _spec, _deadline, reply_to),
    do: reply(reply_to, settled)

  defp reply({pid, ref}, result) do
    send(pid, {ref, result})
    :ok
  end

  defp handle_connection(conn, spec, deadline) do
    result =
      case read_request(conn, "", deadline, request_end(spec)) do
        {:ok, request} -> request |> parse_request() |> resolve_request(spec)
        {:retry, _reason} = retry -> retry
      end

    send_response(conn, result)
    :gen_tcp.close(conn)
    result
  end

  # A static listener reads the request line; a hardened one reads every
  # header, since it checks `Host`.
  defp request_end(%{hardened?: true}), do: ["\r\n\r\n", "\n\n"]
  defp request_end(%{hardened?: false}), do: ["\n"]

  # The listener fields more than the OAuth callback: browser/OS preconnect
  # probes, TLS handshakes, empty connect-then-close, and the callback itself
  # can arrive split across reads (raw recv returns on first data, not at a line
  # boundary). Accumulate until the request (line or headers) is terminated;
  # treat anything unreadable as junk to skip (retry), bounded by the byte cap
  # and the deadline.
  defp read_request(conn, acc, deadline, ends) do
    cond do
      String.contains?(acc, ends) ->
        {:ok, acc}

      byte_size(acc) > @max_request_bytes ->
        {:retry, :request_too_large}

      true ->
        read_more(conn, acc, deadline, ends)
    end
  end

  defp read_more(conn, acc, deadline, ends) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:retry, :deadline}
    else
      case :gen_tcp.recv(conn, 0, min(remaining, @per_recv_timeout_ms)) do
        {:ok, chunk} -> read_request(conn, acc <> chunk, deadline, ends)
        {:error, reason} -> {:retry, {:recv, reason}}
      end
    end
  end

  defp parse_request(raw) when is_binary(raw) do
    [head | _body] = String.split(raw, ["\r\n\r\n", "\n\n"], parts: 2)
    [request_line | header_lines] = String.split(head, ["\r\n", "\n"])

    case String.split(request_line, " ") do
      [method, target, _version | _] ->
        {:ok, %{method: method, target: target, host: host_header(header_lines)}}

      _malformed ->
        {:error, :malformed_request}
    end
  end

  # Exactly one `Host` header, or none to compare.
  defp host_header(lines) do
    hosts =
      for line <- lines,
          [name, value] <- [String.split(line, ":", parts: 2)],
          String.downcase(String.trim(name)) == "host",
          do: String.trim(value)

    case hosts do
      [host] -> host
      _none_or_many -> nil
    end
  end

  defp resolve_request({:error, :malformed_request}, %{hardened?: false}),
    do: {:retry, :malformed}

  defp resolve_request({:error, :malformed_request}, %{hardened?: true}),
    do: {:reject, 400, :malformed}

  defp resolve_request({:ok, request}, %{hardened?: false} = spec),
    do: resolve_static(request.target, spec)

  defp resolve_request({:ok, request}, %{hardened?: true} = spec) do
    cond do
      request.method != "GET" -> {:reject, 405, :method_not_allowed}
      request.host != spec.host -> {:reject, 400, :wrong_host}
      true -> resolve_target(request.target, spec)
    end
  end

  defp resolve_static("/" <> _ = path, spec) do
    if browser_preflight?(path) do
      {:retry, :preflight}
    else
      # A genuine callback (valid code+state, an error param, or a state
      # mismatch) is terminal — only its parse result ends the wait.
      case parse_callback_path(path, spec.state) do
        {:ok, code} -> {:ok, %{code: code, client_id: nil, scope: nil}}
        {:error, _reason} = error -> error
      end
    end
  end

  # A parseable but non-callback request (path not starting with "/", e.g. an
  # absolute-form proxy probe) is junk: skip it and keep accepting until the
  # real callback or the deadline.
  defp resolve_static(_other_path, _spec), do: {:retry, :non_callback}

  # Browsers and OS preflight requests (favicon.ico, /, robots.txt) hit the
  # listener before the OAuth callback. Skip them and keep accepting.
  defp browser_preflight?(path) do
    path in ["/", "/favicon.ico", "/robots.txt"] or
      String.starts_with?(path, "/.well-known/")
  end

  defp resolve_target(target, %{path: path} = spec) do
    case String.split(target, "?", parts: 2) do
      [^path, query] -> resolve_query(query, spec)
      [^path] -> {:reject, 400, :state_mismatch}
      _other -> {:reject, 404, :not_callback}
    end
  end

  # Only a request carrying this attempt's `state`, once, settles it. Anything
  # else is answered 400 and the attempt keeps waiting, so a stray or forged
  # request cannot end the sign-in.
  defp resolve_query(query, spec) do
    with {:ok, params} <- decode_query(query),
         [state] <- values(params, "state"),
         true <- same_secret?(state, spec.state) do
      settle_callback(params, spec)
    else
      _not_this_attempt -> {:reject, 400, :state_mismatch}
    end
  end

  # A malformed percent-escape is a forged or broken request, not this
  # attempt's callback.
  defp decode_query(query) do
    {:ok, query |> URI.query_decoder() |> Enum.to_list()}
  rescue
    _malformed in ArgumentError -> {:error, :malformed_query}
  end

  defp values(params, key), do: for({^key, value} <- params, do: value)

  defp same_secret?(given, expected),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)

  defp settle_callback(params, spec) do
    case {values(params, "error"), values(params, "code")} do
      {["access_denied"], _code} -> {:error, :access_denied}
      {[error], _code} -> {:error, {:authorization_error, vendor_code(error)}}
      {[], [code]} when code != "" -> settle_client(params, code, spec)
      {[], []} -> {:error, :missing_code}
      _duplicated -> {:error, :invalid_callback}
    end
  end

  defp settle_client(params, code, spec) do
    with {:ok, client_id} <- issued_client(values(params, "client_id"), spec) do
      {:ok, %{code: code, client_id: client_id, scope: List.first(values(params, "scope"))}}
    end
  end

  # A first registration must come back naming the client it issued; a
  # re-authorization may leave it out, but never names another.
  defp issued_client(_given, %{registration: :static}), do: {:ok, nil}

  defp issued_client([client_id], %{registration: :register}) do
    if issued_client_id?(client_id),
      do: {:ok, client_id},
      else: {:error, :registration_incomplete}
  end

  defp issued_client([], %{registration: :register}), do: {:error, :registration_incomplete}
  defp issued_client([], %{registration: :issued, client_id: expected}), do: {:ok, expected}

  defp issued_client([expected], %{registration: :issued, client_id: expected}),
    do: {:ok, expected}

  defp issued_client([_other], %{registration: :issued}), do: {:error, :client_mismatch}
  defp issued_client(_duplicated, _spec), do: {:error, :invalid_callback}

  defp issued_client_id?(client_id),
    do: client_id != "dynamic_agent_client" and Regex.match?(@issued_client_id, client_id)

  defp vendor_code(error), do: if(Regex.match?(@vendor_code, error), do: error, else: "unknown")

  # The browser is answered before the code is exchanged and the account
  # verified, so the page cannot know the outcome (`CallbackPage`).
  defp send_response(conn, {:ok, _callback}) do
    :gen_tcp.send(conn, http_response(200, "OK", CallbackPage.render(:received)))
  end

  defp send_response(conn, {:retry, _reason}) do
    :gen_tcp.send(conn, http_response(204, "No Content", ""))
  end

  defp send_response(conn, {:reject, status, _reason}) do
    body = CallbackPage.render(:not_this_sign_in)
    :gen_tcp.send(conn, http_response(status, status_text(status), body))
  end

  defp send_response(conn, {:error, _reason}) do
    :gen_tcp.send(conn, http_response(400, "Bad Request", CallbackPage.render(:failed)))
  end

  defp status_text(400), do: "Bad Request"
  defp status_text(404), do: "Not Found"
  defp status_text(405), do: "Method Not Allowed"

  # The callback page is never cached and never leaks its address (the code
  # and state are in it) as a referrer. It runs nothing and loads nothing: its
  # only allowances are its own inline style and the inline image of its mark.
  @page_csp "default-src 'none'; style-src 'unsafe-inline'; img-src data:; " <>
              "base-uri 'none'; form-action 'none'"

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
      "Cache-Control: no-store\r\n",
      "Referrer-Policy: no-referrer\r\n",
      "Content-Security-Policy: #{@page_csp}\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ]
  end

  defp open_browser(url), do: Browser.open(url)

  defp random_base64url(byte_len) do
    :crypto.strong_rand_bytes(byte_len) |> Base.url_encode64(padding: false)
  end

  # Some token endpoints (xAI) re-validate PKCE and require the challenge
  # echoed alongside the verifier at exchange time (design doc §6.4).
  defp maybe_echo_code_challenge(params, %OAuthProvider{echo_code_challenge?: true}, verifier) do
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    params
    |> Map.put("code_challenge", challenge)
    |> Map.put("code_challenge_method", "S256")
  end

  defp maybe_echo_code_challenge(params, _provider, _verifier), do: params

  defp parse_token_response(%{"access_token" => access} = body) when is_binary(access) do
    expires_at =
      case body["expires_in"] do
        secs when is_integer(secs) and secs > 0 ->
          DateTime.add(DateTime.utc_now(), secs, :second)

        # xAI omits expires_in; its access tokens are JWTs — derive the
        # expiry from the exp claim so TokenManager can schedule refresh
        # (design doc §6.4).
        _ ->
          JwtClaims.expires_at(access)
      end

    {:ok,
     %{
       access_token: access,
       refresh_token: body["refresh_token"],
       id_token: body["id_token"],
       scope: body["scope"],
       expires_at: expires_at,
       # As the provider sent it: ChatGPT's is Unix seconds or ISO-8601, and
       # its reader (`Auth.ChatGPT.Registration`) decides which.
       earliest_refresh_at: body["earliest_refresh_at"]
     }}
  end

  defp parse_token_response(_body), do: {:error, :invalid_token_response}
end
