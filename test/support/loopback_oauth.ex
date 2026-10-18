defmodule FermixTestSupport.LoopbackOAuth do
  @moduledoc """
  An OAuth 2.1 authorization server and the MCP server it protects, on one
  loopback port (`LoopbackHttp`), for the sign-in of an MCP server the owner
  added (M74 E5). It checks what a sign-in must send and refuses what it must
  not:

    * `POST /mcp` wants `Authorization: Bearer` with a token it issued, and
      answers `401` with a `Bearer` challenge otherwise (naming
      `resource_metadata` unless `challenge: :bare`, and `scope` when
      `challenge_scope` is set). `protected: false` serves anyone. A
      `tools/call` whose token lacks `required_scope` is answered `403
      insufficient_scope`.
    * `/.well-known/oauth-protected-resource/mcp` is the resource metadata
      (`resource`, `authorization_servers`, `scopes_supported`); the root
      well-known URI is a `404`.
    * `/.well-known/oauth-authorization-server` is the metadata
      (`client_id_metadata_document_supported` with `cimd: true`,
      `registration_endpoint` with `registration: true`,
      `authorization_response_iss_parameter_supported` with `iss_supported`,
      `userinfo_endpoint` with a `userinfo` document to answer). Its token
      answers carry `id_token` when one is set.
    * `POST /register` registers a client and answers its id.
    * `GET /authorize` refuses a request without `S256` PKCE, without the
      `resource` it protects, with an unknown client, or with a redirect that
      is not loopback, and otherwise redirects to the callback with a code,
      the state and `iss` (`iss: :correct | :wrong | :absent`).
    * `POST /token` exchanges a code only with its verifier, its client
      (authenticated as its registration says), its redirect and its
      resource, and refreshes only with the resource; `refuse_refresh: true`
      refuses every refresh with `invalid_grant`.

  Everything it was asked, and every grant it issued, is kept in its agent
  for the test to read (`state/1`). `browse/1` is the browser: it follows the
  authorize url to the loopback callback.
  """

  alias FermixTestSupport.LoopbackHttp

  @tools [
    %{"name" => "echo", "description" => "Echoes.", "inputSchema" => %{"type" => "object"}},
    %{"name" => "admin", "description" => "Administers.", "inputSchema" => %{"type" => "object"}}
  ]

  @defaults %{
    protected: true,
    challenge: :resource_metadata,
    challenge_scope: nil,
    scopes_supported: ["mcp:read"],
    cimd: false,
    registration: true,
    iss: :correct,
    iss_supported: false,
    token_ttl: 3_600,
    id_token: nil,
    userinfo: nil,
    refuse_refresh: false,
    required_scope: nil,
    owner_clients: %{},
    issuer: nil,
    resource: nil
  }

  @doc """
  Starts one under the test's supervisor. `config` overrides `@defaults`.
  Answers `%{agent, base, url}`: `url` is the MCP endpoint.
  """
  @spec start(map()) :: map()
  def start(config \\ %{}) do
    agent =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Agent, fn -> initial(config) end}, id: make_ref())
      )

    http =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({LoopbackHttp, &handle(agent, &1)}, id: make_ref())
      )

    base = "http://127.0.0.1:#{LoopbackHttp.port(http)}"
    Agent.update(agent, &Map.put(&1, :base, base))
    %{agent: agent, base: base, url: base <> "/mcp", http: http}
  end

  @doc "Changes its configuration."
  @spec configure(map(), map()) :: :ok
  def configure(%{agent: agent}, changes), do: Agent.update(agent, &Map.merge(&1, changes))

  @doc "Everything it holds."
  @spec state(map()) :: map()
  def state(%{agent: agent}), do: Agent.get(agent, & &1)

  @doc "Forgets every access token it issued, as a server that revoked them would."
  @spec revoke_access(map()) :: :ok
  def revoke_access(%{agent: agent}), do: Agent.update(agent, &%{&1 | access: %{}})

  @doc "The requests its MCP endpoint was sent, in order."
  @spec mcp_requests(map()) :: [map()]
  def mcp_requests(%{http: http}), do: Enum.filter(LoopbackHttp.requests(http), &String.starts_with?(&1.path, "/mcp"))

  @doc """
  The browser: GETs the authorize url and follows its redirect to the
  loopback callback, answering what the callback answered, or the
  authorization server's own refusal.
  """
  @spec browse(String.t()) :: {:ok, String.t()} | {:refused, String.t()}
  def browse(url) do
    case get(url) do
      {302, headers, _body} -> {:ok, url_body(get(header(headers, "location")))}
      {_status, _headers, body} -> {:refused, body}
    end
  end

  defp url_body({_status, _headers, body}), do: body

  # --- the server ---------------------------------------------------------------

  defp initial(config) do
    @defaults
    |> Map.merge(config)
    |> Map.merge(%{
      base: nil,
      registered: %{},
      codes: %{},
      access: %{},
      refresh: %{},
      authorize_requests: [],
      token_requests: [],
      registrations: 0,
      refreshes: 0,
      next: 0
    })
  end

  defp handle(agent, %{method: "POST", path: "/mcp"} = request), do: mcp(agent, request)
  defp handle(_agent, %{method: "DELETE", path: "/mcp"}), do: {204, [], ""}

  defp handle(agent, %{method: "GET", path: "/.well-known/oauth-protected-resource/mcp"}) do
    s = Agent.get(agent, & &1)

    json(200, %{
      "resource" => s.resource || s.base <> "/mcp",
      "authorization_servers" => [s.issuer || s.base],
      "scopes_supported" => s.scopes_supported
    })
  end

  defp handle(agent, %{method: "GET", path: "/.well-known/oauth-authorization-server"}),
    do: json(200, metadata(Agent.get(agent, & &1)))

  defp handle(agent, %{method: "POST", path: "/register", body: body}), do: register(agent, JSON.decode!(body))

  defp handle(agent, %{method: "GET", path: "/authorize?" <> query}), do: authorize(agent, URI.decode_query(query))

  defp handle(agent, %{method: "POST", path: "/token"} = request), do: token(agent, request)

  defp handle(agent, %{method: "GET", path: "/userinfo"} = request) do
    s = Agent.get(agent, & &1)

    if is_map_key(s.access, bearer(request.headers)),
      do: json(200, s.userinfo),
      else: json(401, %{"error" => "invalid_token"})
  end

  defp handle(_agent, _request), do: json(404, %{"error" => "not_found"})

  defp metadata(s) do
    %{
      "issuer" => s.base,
      "authorization_endpoint" => s.base <> "/authorize",
      "token_endpoint" => s.base <> "/token",
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none", "client_secret_basic"],
      "client_id_metadata_document_supported" => s.cimd,
      "authorization_response_iss_parameter_supported" => s.iss_supported
    }
    |> then(&if(s.registration, do: Map.put(&1, "registration_endpoint", s.base <> "/register"), else: &1))
    |> then(&if(s.userinfo, do: Map.put(&1, "userinfo_endpoint", s.base <> "/userinfo"), else: &1))
  end

  # --- the MCP endpoint ---------------------------------------------------------

  defp mcp(agent, request) do
    s = Agent.get(agent, & &1)
    token = bearer(request.headers)

    cond do
      not s.protected -> rpc(JSON.decode!(request.body), nil, s)
      is_map_key(s.access, token) -> rpc(JSON.decode!(request.body), s.access[token], s)
      true -> {401, [{"www-authenticate", challenge(s)}], ""}
    end
  end

  defp challenge(s) do
    params =
      [
        if(s.challenge == :resource_metadata,
          do: ~s(resource_metadata="#{s.base}/.well-known/oauth-protected-resource/mcp")
        ),
        if(s.challenge_scope, do: ~s(scope="#{s.challenge_scope}"))
      ]
      |> Enum.reject(&is_nil/1)

    String.trim("Bearer " <> Enum.join(params, ", "))
  end

  defp rpc(%{"method" => "initialize", "id" => id}, _grant, _s),
    do: result(id, %{"protocolVersion" => "2025-11-25", "capabilities" => %{"tools" => %{}}})

  defp rpc(%{"method" => "notifications/initialized"}, _grant, _s), do: {202, [], ""}
  defp rpc(%{"method" => "tools/list", "id" => id}, _grant, _s), do: result(id, %{"tools" => @tools})

  defp rpc(%{"method" => "tools/call", "id" => id}, grant, s) do
    if is_binary(s.required_scope) and not granted?(grant, s.required_scope) do
      challenge = ~s(Bearer error="insufficient_scope", scope="#{s.required_scope}")
      {403, [{"www-authenticate", challenge}], ""}
    else
      result(id, %{"content" => [%{"type" => "text", "text" => "done"}]})
    end
  end

  defp granted?(%{scopes: scopes}, scope), do: scope in scopes
  defp granted?(nil, _scope), do: false

  defp result(id, result), do: json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  # --- registration and authorization ------------------------------------------

  defp register(agent, metadata) do
    Agent.get_and_update(agent, fn s ->
      id = "dcr-client-#{s.registrations + 1}"
      s = %{s | registered: Map.put(s.registered, id, metadata), registrations: s.registrations + 1}
      {json(201, Map.put(metadata, "client_id", id)), s}
    end)
  end

  defp authorize(agent, params) do
    Agent.get_and_update(agent, fn s ->
      s = %{s | authorize_requests: s.authorize_requests ++ [params]}

      case authorize_refusal(s, params) do
        nil -> issue_code(s, params)
        refusal -> {json(400, %{"error" => refusal}), s}
      end
    end)
  end

  # Every check an authorization request must pass, with the error it fails.
  defp authorize_refusal(s, params) do
    [
      {params["response_type"] == "code", "unsupported_response_type"},
      {s256_challenge?(params), "invalid_request: pkce"},
      {params["resource"] == (s.resource || s.base <> "/mcp"), "invalid_target"},
      {known_client?(s, params["client_id"]), "invalid_client"},
      {loopback_redirect?(params["redirect_uri"]), "invalid_redirect"},
      {is_binary(params["state"]), "invalid_request: state"}
    ]
    |> Enum.find_value(fn {passed?, error} -> if not passed?, do: error end)
  end

  defp s256_challenge?(params),
    do: params["code_challenge_method"] == "S256" and byte_size(params["code_challenge"] || "") == 43

  defp loopback_redirect?(uri) when is_binary(uri),
    do: Regex.match?(~r{\Ahttp://127\.0\.0\.1:\d+/callback\z}, uri)

  defp loopback_redirect?(_uri), do: false

  defp known_client?(s, id) do
    is_map_key(s.registered, id) or is_map_key(s.owner_clients, id) or
      (s.cimd and id == "https://fermix.ai/oauth/mcp-client.json")
  end

  defp issue_code(s, params) do
    code = "code-#{s.next}"

    grant = %{
      client_id: params["client_id"],
      redirect_uri: params["redirect_uri"],
      challenge: params["code_challenge"],
      resource: params["resource"],
      scopes: String.split(params["scope"] || "", " ", trim: true)
    }

    location = params["redirect_uri"] <> "?" <> URI.encode_query(callback(s, code, params["state"]))
    {{302, [{"location", location}], ""}, %{s | codes: Map.put(s.codes, code, grant), next: s.next + 1}}
  end

  defp callback(%{iss: :correct, base: base}, code, state), do: %{"code" => code, "state" => state, "iss" => base}
  defp callback(%{iss: :wrong}, code, state), do: %{"code" => code, "state" => state, "iss" => "https://elsewhere.example"}
  defp callback(%{iss: :absent}, code, state), do: %{"code" => code, "state" => state}

  # --- the token endpoint -------------------------------------------------------

  defp token(agent, %{body: body, headers: headers}) do
    form = URI.decode_query(body)
    client = client_of(form, headers)

    Agent.get_and_update(agent, fn s ->
      s = %{s | token_requests: s.token_requests ++ [Map.put(form, "authenticated_as", client)]}
      grant_type(form["grant_type"], form, client, s)
    end)
  end

  # Basic first (RFC 6749 §2.3.1), else the form's client_id.
  defp client_of(form, headers) do
    case header(headers, "authorization") do
      "Basic " <> encoded ->
        [id, secret] = encoded |> Base.decode64!() |> String.split(":", parts: 2)
        {:basic, URI.decode_www_form(id), URI.decode_www_form(secret)}

      nil ->
        {:form, form["client_id"], form["client_secret"]}
    end
  end

  defp grant_type("authorization_code", form, client, s) do
    with {:ok, grant} <- Map.fetch(s.codes, form["code"]),
         true <- client_matches?(s, client, grant.client_id),
         true <- form["redirect_uri"] == grant.redirect_uri,
         true <- pkce?(form["code_verifier"], grant.challenge),
         true <- form["resource"] == grant.resource do
      s = %{s | codes: Map.delete(s.codes, form["code"])}
      issue_tokens(s, grant)
    else
      _refused -> {json(400, %{"error" => "invalid_grant"}), s}
    end
  end

  defp grant_type("refresh_token", form, client, s) do
    with false <- s.refuse_refresh,
         {:ok, grant} <- Map.fetch(s.refresh, form["refresh_token"]),
         true <- client_matches?(s, client, grant.client_id),
         true <- form["resource"] == grant.resource do
      s = %{s | refresh: Map.delete(s.refresh, form["refresh_token"]), refreshes: s.refreshes + 1}
      issue_tokens(s, grant)
    else
      _refused -> {json(400, %{"error" => "invalid_grant"}), s}
    end
  end

  defp grant_type(_other, _form, _client, s), do: {json(400, %{"error" => "unsupported_grant_type"}), s}

  defp client_matches?(s, {kind, id, secret}, expected) do
    id == expected and
      case Map.fetch(s.owner_clients, id) do
        {:ok, nil} -> kind == :form and is_nil(secret)
        {:ok, owner_secret} -> kind == :basic and secret == owner_secret
        :error -> kind == :form and is_nil(secret)
      end
  end

  defp pkce?(verifier, challenge) when is_binary(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge

  defp pkce?(_verifier, _challenge), do: false

  defp issue_tokens(s, grant) do
    n = s.next
    access = "access-#{n}"
    refresh = "refresh-#{n}"

    answer =
      %{
        "access_token" => access,
        "token_type" => "Bearer",
        "expires_in" => s.token_ttl,
        "refresh_token" => refresh,
        "scope" => Enum.join(grant.scopes, " ")
      }
      |> then(&if(s.id_token, do: Map.put(&1, "id_token", s.id_token), else: &1))

    s = %{
      s
      | access: Map.put(s.access, access, grant),
        refresh: Map.put(s.refresh, refresh, grant),
        next: n + 1
    }

    {json(200, answer), s}
  end

  # --- plumbing -----------------------------------------------------------------

  defp json(status, body), do: {status, [{"content-type", "application/json"}], JSON.encode!(body)}

  defp bearer(headers) do
    case header(headers, "authorization") do
      "Bearer " <> token -> token
      _other -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  # One GET on its own connection, read to the end of its body: a keep-alive
  # server never closes, so the body is read by its length.
  defp get(url) do
    uri = URI.parse(url)
    {:ok, conn} = :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false])
    target = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
    request = "GET #{target} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(conn, request)
    response = read_response(conn, "")
    :gen_tcp.close(conn)
    response
  end

  defp read_response(conn, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] -> read_body(conn, parse_head(head), body)
      [_partial] -> read_response(conn, acc <> recv(conn))
    end
  end

  defp read_body(conn, {status, headers}, body) do
    case header(headers, "content-length") do
      nil -> {status, headers, body <> read_to_close(conn)}
      length -> {status, headers, read_length(conn, body, String.to_integer(length))}
    end
  end

  defp read_length(_conn, body, length) when byte_size(body) >= length, do: body
  defp read_length(conn, body, length), do: read_length(conn, body <> recv(conn), length)

  defp read_to_close(conn) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, chunk} -> chunk <> read_to_close(conn)
      {:error, _closed} -> ""
    end
  end

  defp recv(conn) do
    {:ok, chunk} = :gen_tcp.recv(conn, 0, 5_000)
    chunk
  end

  defp parse_head(head) do
    [status_line | lines] = String.split(head, "\r\n")
    [_version, status | _reason] = String.split(status_line, " ")

    headers =
      for line <- lines, [name, value] <- [String.split(line, ":", parts: 2)],
          do: {String.downcase(name), String.trim(value)}

    {String.to_integer(status), headers}
  end
end
