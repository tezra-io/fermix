defmodule FermixCore.Capabilities.MCP.Remote.SessionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Session

  @credential "eden_pat_canary_do_not_leak"
  @session_id "sess-abc123"

  # A module double at the transport boundary — the same seam pattern the MCP
  # layer already uses for `:discoverer` and `:caller`. It records every
  # request so the wire contract (headers, method, ordering) is assertable
  # without a socket, a TLS chain, or a public DNS answer.
  defmodule FakeTransport do
    def open(endpoint, opts) do
      {:ok, %{agent: Keyword.fetch!(opts, :agent), endpoint: endpoint}}
    end

    def request(conn, method, headers, body, timeout_ms) do
      recorded = %{method: method, headers: headers, body: body, timeout_ms: timeout_ms}

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

    def close(conn) do
      if is_pid(conn[:agent]), do: Agent.update(conn.agent, &%{&1 | closes: &1.closes + 1})
      :ok
    end

    defp pop([next | rest]), do: {next, rest}
    defp pop([]), do: {{:error, :no_canned_response}, []}
  end

  defp start_agent(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{responses: responses, requests: [], closes: 0} end)
    agent
  end

  defp closes(agent), do: Agent.get(agent, & &1.closes)

  defp requests(agent), do: Agent.get(agent, & &1.requests)

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

  defp initialize_ok(version \\ "2025-06-18", headers \\ [{"mcp-session-id", @session_id}]) do
    json(200, rpc_result(1, %{"protocolVersion" => version, "capabilities" => %{}}), headers)
  end

  defp handshake(extra_responses \\ []) do
    agent = start_agent([initialize_ok(), accepted()] ++ extra_responses)
    {:ok, endpoint} = Endpoint.new("https://mcp.eden.so", "/mcp")
    {:ok, auth_ref} = AuthRef.new("eden")

    opts = [
      endpoint: endpoint,
      auth_ref: auth_ref,
      transport: FakeTransport,
      connect_opts: [agent: agent],
      resolver: fn "eden" -> @credential end
    ]

    {agent, opts}
  end

  defp start_session(extra_responses \\ []) do
    {agent, opts} = handshake(extra_responses)
    {:ok, session} = start_supervised({Session, opts})
    {agent, session}
  end

  describe "handshake" do
    test "a started session is an initialized session" do
      {agent, session} = start_session()

      assert Process.alive?(session)
      assert [initialize, initialized] = requests(agent)
      assert initialize.method == "POST"
      assert Jason.decode!(initialize.body)["method"] == "initialize"
      assert Jason.decode!(initialized.body)["method"] == "notifications/initialized"
    end

    test "advertises both response forms and the bearer on every request" do
      {agent, _session} = start_session()

      for request <- requests(agent) do
        assert {"accept", "application/json, text/event-stream"} in request.headers
        assert {"authorization", "Bearer " <> @credential} in request.headers
      end
    end

    # The negotiated version rides every request AFTER initialization; there is
    # nothing negotiated to send during initialize itself.
    test "sends the session id and protocol version only after initialize" do
      {agent, _session} = start_session()
      [initialize, initialized] = requests(agent)

      refute Enum.any?(initialize.headers, &(elem(&1, 0) == "mcp-session-id"))
      refute Enum.any?(initialize.headers, &(elem(&1, 0) == "mcp-protocol-version"))

      assert {"mcp-session-id", @session_id} in initialized.headers
      assert {"mcp-protocol-version", "2025-06-18"} in initialized.headers
    end

    test "pins 2025-06-18 and refuses any other negotiated version" do
      assert Session.protocol_version() == "2025-06-18"

      agent = start_agent([initialize_ok("2025-11-25")])
      {_agent, opts} = handshake()
      opts = Keyword.put(opts, :connect_opts, agent: agent)

      assert {:error, {:remote_protocol_error, {:unsupported_protocol_version, "2025-11-25"}}} =
               start_supervised({Session, opts})
               |> unwrap_start_error()
    end

    test "refuses a server that omits the protocol version" do
      agent = start_agent([json(200, rpc_result(1, %{"capabilities" => %{}}))])
      {_agent, opts} = handshake()
      opts = Keyword.put(opts, :connect_opts, agent: agent)

      assert {:error, {:remote_protocol_error, :missing_protocol_version}} =
               start_supervised({Session, opts}) |> unwrap_start_error()
    end

    test "refuses a session id that is not bounded visible ASCII" do
      agent = start_agent([initialize_ok("2025-06-18", [{"mcp-session-id", "bad id\n"}])])
      {_agent, opts} = handshake()
      opts = Keyword.put(opts, :connect_opts, agent: agent)

      assert {:error, {:remote_protocol_error, :session_id_charset}} =
               start_supervised({Session, opts}) |> unwrap_start_error()
    end

    test "refuses an over-long session id" do
      oversized = String.duplicate("a", 257)
      agent = start_agent([initialize_ok("2025-06-18", [{"mcp-session-id", oversized}])])
      {_agent, opts} = handshake()
      opts = Keyword.put(opts, :connect_opts, agent: agent)

      assert {:error, {:remote_protocol_error, :session_id_length}} =
               start_supervised({Session, opts}) |> unwrap_start_error()
    end

    test "refuses to start when the credential is absent" do
      {_agent, opts} = handshake()
      opts = Keyword.put(opts, :resolver, fn "eden" -> nil end)

      assert {:error, {:needs_secret, "eden"}} =
               start_supervised({Session, opts}) |> unwrap_start_error()
    end
  end

  describe "requests" do
    test "returns the JSON-RPC result" do
      {_agent, session} = start_session([json(200, rpc_result(2, %{"tools" => []}))])

      assert {:ok, %{"tools" => []}} = Session.request(session, "tools/list", %{}, 5_000)
    end

    test "reads a result delivered as an SSE stream" do
      body = "data: " <> Jason.encode!(rpc_result(2, %{"ok" => true})) <> "\n\n"

      sse =
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "text/event-stream"}],
           body:
             {:sse,
              [%{data: String.trim_leading(body, "data: ") |> String.trim(), event: nil, id: nil}]}
         }}

      {_agent, session} = start_session([sse])

      assert {:ok, %{"ok" => true}} = Session.request(session, "tools/list", %{}, 5_000)
    end

    test "surfaces a JSON-RPC error rather than wrapping it as success" do
      error = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "error" => %{"code" => -32_000, "message" => "nope"}
      }

      {_agent, session} = start_session([json(200, error)])

      assert {:error, {:remote_jsonrpc_error, -32_000, "nope"}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end

    test "refuses a response whose id does not match the request" do
      {_agent, session} = start_session([json(200, rpc_result(99, %{}))])

      assert {:error, {:invalid_remote_result, :id_mismatch}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end
  end

  describe "HTTP status classification" do
    test "401 becomes reauthorization, never a retry with the rejected credential" do
      {_agent, session} = start_session([json(401, %{})])

      assert {:error, {:reauthorization_required, "mcp.eden.so"}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end

    test "404 during an established session is session expiry" do
      {_agent, session} = start_session([json(404, %{})])

      assert {:error, :session_expired} = Session.request(session, "tools/list", %{}, 5_000)
    end

    test "429 honours an integer Retry-After" do
      {_agent, session} = start_session([json(429, %{}, [{"retry-after", "30"}])])

      assert {:error, {:rate_limited, 30_000}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end

    test "429 without Retry-After uses the fixed local backoff" do
      {_agent, session} = start_session([json(429, %{})])

      assert {:error, {:rate_limited, 60_000}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end

    # Server-controlled state must not be able to create an unbounded timer.
    test "429 with a Retry-After beyond the bound is a protocol error" do
      {_agent, session} = start_session([json(429, %{}, [{"retry-after", "36000"}])])

      assert {:error, {:remote_protocol_error, :invalid_retry_after}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end

    test "429 with a garbage Retry-After is a protocol error" do
      {_agent, session} = start_session([json(429, %{}, [{"retry-after", "soon"}])])

      assert {:error, {:remote_protocol_error, :invalid_retry_after}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end

    test "other non-2xx statuses classify without a body" do
      {_agent, session} = start_session([json(503, %{"secret" => "body"})])

      assert {:error, {:remote_http_error, 503}} =
               Session.request(session, "tools/list", %{}, 5_000)
    end
  end

  describe "teardown" do
    test "sends an authenticated DELETE on the same session" do
      {agent, session} = start_session([{:ok, %{status: 204, headers: [], body: {:empty, ""}}}])

      assert :ok = Session.teardown(session)

      assert %{method: "DELETE"} = List.last(requests(agent))
      delete = List.last(requests(agent))
      assert {"authorization", "Bearer " <> @credential} in delete.headers
      assert {"mcp-session-id", @session_id} in delete.headers
    end

    test "treats 405 as unsupported rather than a failure" do
      {_agent, session} = start_session([{:ok, %{status: 405, headers: [], body: {:empty, ""}}}])

      assert :ok = Session.teardown(session)
    end

    test "reports any other teardown failure before closing" do
      {_agent, session} = start_session([{:ok, %{status: 500, headers: [], body: {:empty, ""}}}])

      assert {:error, {:teardown_failed, 500}} = Session.teardown(session)
    end
  end

  describe "credential containment" do
    # The child spec is retained for the child's lifetime and is printed
    # verbatim in a `failed_to_start_child` report — the reference may appear
    # there, the bearer may not.
    test "the start spec carries only the opaque reference" do
      {_agent, opts} = handshake()
      spec = Session.child_spec(opts)

      refute inspect(spec, limit: :infinity) =~ @credential
      assert inspect(spec, limit: :infinity) =~ "plugin_secret"
    end
  end

  defp unwrap_start_error({:error, {reason, _child_spec}}), do: {:error, reason}
  defp unwrap_start_error({:error, reason}), do: {:error, reason}
  defp unwrap_start_error(other), do: other

  describe "keep-alive recovery" do
    # THE BUG THIS PINS: the session holds ONE connection for its whole life.
    # HTTP keep-alive is best-effort, so the peer closes an idle socket whenever
    # it likes — and before this, the first such close poisoned every later call
    # with `:closed` forever. A 17-case eval sweep reproduced it; a 3-case run
    # inside the keep-alive window did not.
    test "a send-phase close reconnects and delivers the request" do
      closed = {:error, {:not_sent, {:transport, :closed}}}
      {agent, session} = start_session([closed, json(200, rpc_result(2, %{"ok" => true}))])

      assert {:ok, %{"ok" => true}} = Session.request(session, "tools/list", %{}, 5_000)
      assert closes(agent) >= 1, "the dead connection must be closed before reopening"
    end

    # The other half, and the one that matters for correctness: a close AFTER
    # the request went out is ambiguous — the server may already have acted on
    # it. Resending would be the replayed write §7.8 forbids.
    test "a mid-response close is surfaced, never resent" do
      {agent, session} = start_session([{:error, {:transport, :closed}}])

      assert {:error, {:transport, :closed}} = Session.request(session, "tools/list", %{}, 5_000)

      # Two handshake requests only — the failed call was not repeated.
      assert length(requests(agent)) == 3
    end
  end
end
