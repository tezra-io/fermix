defmodule FermixCore.Capabilities.MCP.Remote.OperatorSessionTest do
  @moduledoc """
  The one remote session, driven by an operator endpoint (M74 E4): the headers
  an `[mcp.servers.*]` http server declares, read from `MCP.Secrets`; its
  protocol window; what a refusal means in each `auth` mode; and the older
  HTTP+SSE transport told apart and refused. The transport is a recording
  double and the secret store is the stub.
  """

  # The secret store is global, so this case runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Session
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets
  alias FermixTestSupport.SecretWriterStub

  @key "lin_api_canary_9f2c41"
  @workspace "ws-canary-77ab"
  @session_id "sess-op-1"

  # The session tests' double, with the six-argument request the older
  # transport check makes. Each request is recorded with the options it was
  # made with.
  defmodule FakeTransport do
    def open(endpoint, opts),
      do: {:ok, %{agent: Keyword.fetch!(opts, :agent), endpoint: endpoint}}

    def request(conn, method, headers, body, _timeout_ms, opts \\ []) do
      recorded = %{method: method, headers: headers, body: body, opts: opts}

      conn.agent
      |> Agent.get_and_update(fn state ->
        {next, rest} = pop(state.responses)
        {next, %{state | responses: rest, requests: state.requests ++ [recorded]}}
      end)
      |> case do
        {:ok, response} -> {:ok, conn, response}
        {:error, reason} -> {:error, conn, reason}
      end
    end

    def close(_conn), do: :ok

    defp pop([next | rest]), do: {next, rest}
    defp pop([]), do: {{:error, :no_canned_response}, []}
  end

  setup do
    writer = Application.get_env(:fermix_core, :secret_writer)
    profile = Application.get_env(:fermix_core, :profile)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    on_exit(fn ->
      SecretWriterStub.reset()
      Application.put_env(:fermix_core, :secret_writer, writer)
      restore(:profile, profile)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp server(auth, headers),
    do: %{name: "linear", transport: :http, auth: auth, header_secrets: headers}

  defp agent(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{responses: responses, requests: []} end)
    agent
  end

  defp requests(agent), do: Agent.get(agent, & &1.requests)

  defp opts(agent, server, url \\ "https://mcp.linear.app/mcp") do
    {:ok, endpoint} = Endpoint.operator(url)
    {:ok, auth_ref} = AuthRef.operator(server)

    [
      endpoint: endpoint,
      auth_ref: auth_ref,
      transport: FakeTransport,
      connect_opts: [agent: agent]
    ]
  end

  defp start(agent, server) do
    case start_supervised({Session, opts(agent, server)}) do
      {:ok, session} -> {:ok, session}
      {:error, {reason, _child_spec}} -> {:error, reason}
    end
  end

  defp json(status, body, headers \\ []) do
    {:ok,
     %{
       status: status,
       headers: [{"content-type", "application/json"}] ++ headers,
       body: {:json, Jason.encode!(body)}
     }}
  end

  defp accepted, do: {:ok, %{status: 202, headers: [], body: {:empty, ""}}}
  defp rpc_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp initialize_ok(version, headers \\ []) do
    json(200, rpc_result(1, %{"protocolVersion" => version, "capabilities" => %{}}), headers)
  end

  defp status(code, headers \\ []),
    do: {:ok, %{status: code, headers: headers, body: {:empty, ""}}}

  defp body_method(request), do: Jason.decode!(request.body)["method"]

  defp header(request, name) do
    Enum.find_value(request.headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  describe "headers" do
    test "Authorization goes as Bearer, another header as stored, on every request" do
      :ok = Secrets.put("linear", {:header, "Authorization"}, "Bearer " <> @key)
      :ok = Secrets.put("linear", {:header, "X-Workspace"}, @workspace)
      agent = agent([initialize_ok("2025-11-25"), accepted(), json(200, rpc_result(2, %{}))])

      {:ok, session} = start(agent, server(:header, ["Authorization", "X-Workspace"]))
      {:ok, _result} = Session.request(session, "tools/list", %{}, 5_000)

      assert [_initialize, _initialized, _list] = requests(agent)

      for request <- requests(agent) do
        assert {"authorization", "Bearer " <> @key} in request.headers
        assert {"X-Workspace", @workspace} in request.headers
      end
    end

    test "a server that sends no key sends no Authorization" do
      agent = agent([initialize_ok("2025-11-25"), accepted()])
      {:ok, _session} = start(agent, server(:none, []))

      for request <- requests(agent), do: refute(header(request, "authorization"))
    end

    test "a declared value that cannot be read refuses the start and names only the header" do
      agent = agent([])

      assert {:error, {:header_unavailable, "Authorization"}} =
               start(agent, server(:header, ["Authorization"]))

      assert requests(agent) == []

      assert RuntimeStatus.classify({:header_unavailable, "Authorization"}) ==
               {:invalid_remote_config, :header_unavailable, nil}
    end

    test "a header the rail writes itself cannot be declared" do
      for header <- ["Host", "content-type", "Mcp-Session-Id", "MCP-Protocol-Version"] do
        assert {:error, {:invalid_remote_config, :reserved_header}} =
                 AuthRef.operator(server(:none, [header])),
               header
      end
    end

    test "no value is in the reference, the session's printed state or its crash report" do
      :ok = Secrets.put("linear", {:header, "Authorization"}, @key)
      :ok = Secrets.put("linear", {:header, "X-Workspace"}, @workspace)
      server = server(:header, ["Authorization", "X-Workspace"])
      agent = agent([initialize_ok("2025-11-25"), accepted()])
      {:ok, session} = start(agent, server)

      {:ok, auth_ref} = AuthRef.operator(server)
      printed = inspect([auth_ref, :sys.get_status(session)], limit: :infinity)

      refute printed =~ @key
      refute printed =~ @workspace
      assert printed =~ "mcp.linear.app"
    end
  end

  describe "the protocol window" do
    test "offers 2025-11-25 and accepts 2025-06-18 or 2025-11-25" do
      for version <- ["2025-06-18", "2025-11-25"] do
        agent = agent([initialize_ok(version), accepted(), json(200, rpc_result(2, %{}))])
        {:ok, session} = start(agent, server(:none, []))
        {:ok, _result} = Session.request(session, "tools/list", %{}, 5_000)

        [initialize, initialized, list] = requests(agent)
        assert Jason.decode!(initialize.body)["params"]["protocolVersion"] == "2025-11-25"
        assert header(initialized, "mcp-protocol-version") == version
        assert header(list, "mcp-protocol-version") == version
        stop_supervised!(Session)
      end
    end

    test "refuses any other negotiated version" do
      for version <- ["2024-11-05", "2026-07-28"] do
        agent = agent([initialize_ok(version)])

        assert {:error, {:remote_protocol_error, {:unsupported_protocol_version, ^version}}} =
                 start(agent, server(:none, []))
      end
    end

    # The version rides every request after initialize; a server that issues no
    # session id is no exception (it used to be keyed on the id).
    test "the protocol header rides every request after initialize, with or without a session id" do
      for session_headers <- [[], [{"mcp-session-id", @session_id}]] do
        agent =
          agent([
            initialize_ok("2025-11-25", session_headers),
            accepted(),
            json(200, rpc_result(2, %{})),
            json(200, rpc_result(3, %{}))
          ])

        {:ok, session} = start(agent, server(:none, []))
        {:ok, _result} = Session.request(session, "tools/list", %{}, 5_000)
        {:ok, _result} = Session.request(session, "tools/call", %{"name" => "x"}, 5_000)

        [initialize | after_initialize] = requests(agent)
        refute header(initialize, "mcp-protocol-version")

        for request <- after_initialize do
          assert header(request, "mcp-protocol-version") == "2025-11-25", body_method(request)
        end

        stop_supervised!(Session)
      end
    end
  end

  describe "refusals by auth mode" do
    test "with header, a 401 or a 403 refuses the key" do
      :ok = Secrets.put("linear", {:header, "Authorization"}, @key)

      for code <- [401, 403] do
        agent = agent([status(code)])

        assert {:error, {:reauthorization_required, :key_refused} = reason} =
                 start(agent, server(:header, ["Authorization"]))

        assert RuntimeStatus.classify(reason) == {:reauthorization_required, :key_refused, nil}
      end
    end

    test "with auto, a 401 carrying WWW-Authenticate asks for a sign-in" do
      challenge = ~s(Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth")
      agent = agent([status(401, [{"www-authenticate", challenge}])])

      assert {:error, {:reauthorization_required, :sign_in_required} = reason} =
               start(agent, server(:auto, []))

      assert RuntimeStatus.classify(reason) == {:reauthorization_required, :sign_in_required, nil}
      assert [initialize] = requests(agent)
      refute header(initialize, "authorization")
    end

    test "a 401 with no challenge, or under none, is the plain refusal" do
      for auth <- [:auto, :none] do
        agent = agent([status(401)])

        assert {:error, {:reauthorization_required, "mcp.linear.app"} = reason} =
                 start(agent, server(auth, []))

        assert RuntimeStatus.classify(reason) == {:reauthorization_required, nil, nil}
      end
    end
  end

  describe "the older HTTP+SSE transport (D7)" do
    test "initialize refused, then an event stream opening with endpoint, is refused by name" do
      for code <- [400, 404, 405] do
        endpoint_event = %{event: "endpoint", data: "/messages?sessionId=1", id: nil}

        sse =
          {:ok,
           %{
             status: 200,
             headers: [{"content-type", "text/event-stream"}],
             body: {:sse, [endpoint_event]}
           }}

        agent = agent([status(code), sse])

        assert {:error, {:remote_protocol_error, :legacy_sse_transport} = reason} =
                 start(agent, server(:none, []))

        assert RuntimeStatus.classify(reason) ==
                 {:remote_protocol_error, :legacy_sse_transport, nil}

        assert [post, get] = requests(agent)
        assert post.method == "POST"
        assert get.method == "GET"
        assert header(get, "accept") == "text/event-stream"
        assert get.opts == [stop: :first_event]
      end
    end

    test "any other answer to the check keeps the initialize failure" do
      other_event = %{event: "message", data: "{}", id: nil}

      for answer <- [
            status(405),
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "text/event-stream"}],
               body: {:sse, [other_event]}
             }},
            {:error, {:transport, :closed}}
          ] do
        agent = agent([status(404), answer])
        assert {:error, {:remote_http_error, 404}} = start(agent, server(:none, []))
      end
    end

    test "an initialize refused otherwise is not checked" do
      agent = agent([status(500)])
      assert {:error, {:remote_http_error, 500}} = start(agent, server(:none, []))
      assert [%{method: "POST"}] = requests(agent)
    end
  end
end
