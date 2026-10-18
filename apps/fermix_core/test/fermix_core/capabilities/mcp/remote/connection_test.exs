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
