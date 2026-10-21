defmodule FermixCore.Capabilities.MCP.Remote.ConnectionTest do
  @moduledoc """
  The pinned connector over a real socket: an operator endpoint on this
  machine, which `Endpoint.operator/1` admits over plain `http` (M74 E4),
  against a loopback HTTP server. No DNS answer, no TLS chain and nothing off
  this machine.
  """

  # async: true — each case owns its server and its port, and the egress is
  # passed in.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Connection
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Net.Egress
  alias FermixTestSupport.LoopbackHttp

  @direct Egress.new([])
  @call_ms 10_000

  defp serve(handler) do
    server = start_supervised!({LoopbackHttp, handler})
    {:ok, endpoint} = Endpoint.operator("http://127.0.0.1:#{LoopbackHttp.port(server)}/mcp?x=1")
    {server, endpoint}
  end

  defp open!(endpoint) do
    {:ok, connection} = Connection.open(endpoint, egress: @direct)
    on_exit(fn -> Connection.close(connection) end)
    connection
  end

  test "speaks plain http to this machine, on the endpoint's request target" do
    {server, endpoint} =
      serve(fn _request -> {200, [{"content-type", "application/json"}], ~s({"ok":true})} end)

    connection = open!(endpoint)

    assert {:ok, connection, %{status: 200, body: {:json, ~s({"ok":true})}}} =
             Connection.request(connection, "POST", [{"x-k", "v"}], "{}", @call_ms)

    # The same socket serves the next request.
    assert {:ok, _connection, %{status: 200}} =
             Connection.request(connection, "POST", [], "{}", @call_ms)

    assert [first, _second] = LoopbackHttp.requests(server)
    assert first.method == "POST"
    assert first.path == "/mcp?x=1"
    assert {"x-k", "v"} in first.headers
    assert {"host", "127.0.0.1:#{LoopbackHttp.port(server)}"} in first.headers
  end

  # `localhost` is `::1` and `127.0.0.1` on most machines, and a server binds
  # one or the other: the validated answers are dialled in order until one
  # connects, with no second lookup.
  test "a name reaches a server bound to any one of its validated answers" do
    resolver = fn "localhost" -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]} end
    ok = fn _request -> {200, [{"content-type", "application/json"}], "{}"} end

    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      server = start_supervised!({LoopbackHttp, {ok, ip}}, id: {:loopback, ip})
      {:ok, endpoint} = Endpoint.operator("http://localhost:#{LoopbackHttp.port(server)}/mcp")

      assert {:ok, connection} = Connection.open(endpoint, egress: @direct, resolver: resolver)
      assert connection.peer == ip

      assert {:ok, connection, %{status: 200}} =
               Connection.request(connection, "POST", [], "{}", @call_ms)

      Connection.close(connection)
      assert [%{method: "POST"}] = LoopbackHttp.requests(server)
    end
  end

  test "a name with a metadata address among its answers is never dialled" do
    {_server, endpoint} = serve(fn _request -> flunk("a refused name was dialled") end)
    resolver = fn "localhost" -> {:ok, [{127, 0, 0, 1}, {169, 254, 169, 254}]} end
    {:ok, named} = Endpoint.operator("http://localhost:#{endpoint.port}/mcp")

    assert {:error,
            {:remote_security_blocked, {:resolved_to_link_local_address, {169, 254, 169, 254}}}} =
             Connection.open(named, egress: @direct, resolver: resolver)
  end

  test "a redirect is terminal and is never followed" do
    {server, endpoint} =
      serve(fn
        %{path: "/mcp?x=1"} -> {302, [{"location", "/elsewhere"}], ""}
        _followed -> {200, [], "followed"}
      end)

    connection = open!(endpoint)

    assert {:error, _connection, {:remote_security_blocked, {:redirect_refused, 302}}} =
             Connection.request(connection, "POST", [], "{}", @call_ms)

    assert [%{path: "/mcp?x=1"}] = LoopbackHttp.requests(server)
  end

  # The older SSE transport's stream never ends; reading it whole would wait
  # out the deadline and answer a timeout. `stop: :first_event` answers with
  # the first event.
  test "stop: :first_event answers an endless event stream with its first event" do
    {_server, endpoint} =
      serve(fn _request ->
        {:stream, 200, [{"content-type", "text/event-stream"}],
         "event: endpoint\ndata: /messages?session=1\n\n"}
      end)

    connection = open!(endpoint)

    assert {:ok, _connection, %{status: 200, body: {:sse, [event]}}} =
             Connection.request(connection, "GET", [], nil, @call_ms, stop: :first_event)

    assert event.event == "endpoint"
    assert event.data == "/messages?session=1"
  end
end
