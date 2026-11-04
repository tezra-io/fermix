defmodule FermixChannels.Desktop.LoopbackHttpTest do
  # The bounded HTTP/1.1 both ends of the sign-in forward speak (M75 D17),
  # over real loopback sockets.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.LoopbackHttp

  @wait 10_000

  # A request written to a fresh connection, read by `read_request/3`.
  defp read(raw) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    writer =
      Task.async(fn ->
        {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
        :ok = :gen_tcp.send(conn, raw)
        conn
      end)

    {:ok, conn} = :gen_tcp.accept(listener, @wait)
    result = LoopbackHttp.read_request(conn, System.monotonic_time(:millisecond) + @wait)
    :gen_tcp.close(Task.await(writer))
    :gen_tcp.close(conn)
    :gen_tcp.close(listener)
    result
  end

  test "reads a request, its end-to-end headers and its body" do
    raw =
      "POST /callback?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1455\r\nConnection: keep-alive\r\n" <>
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 7\r\n\r\ncode=c1"

    assert {:ok, request} = read(raw)
    assert request.method == "POST"
    assert request.target == "/callback?x=1"
    assert request.body == "code=c1"

    assert request.headers == [
             ["Host", "127.0.0.1:1455"],
             ["Content-Type", "application/x-www-form-urlencoded"]
           ]
  end

  test "refuses what the wire cannot carry, each with its status" do
    big_body = "POST / HTTP/1.1\r\nContent-Length: 16385\r\n\r\n"
    chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    huge_head = "GET / HTTP/1.1\r\nX-Pad: " <> String.duplicate("a", 70_000)
    many = "GET / HTTP/1.1\r\n" <> Enum.map_join(1..65, fn n -> "X-#{n}: v\r\n" end) <> "\r\n"
    absolute = "GET http://evil.example/ HTTP/1.1\r\n\r\n"
    long_value = "GET / HTTP/1.1\r\nX-Long: " <> String.duplicate("a", 4_097) <> "\r\n\r\n"

    assert {:error, {413, :body_too_large}} = read(big_body)
    assert {:error, {411, :chunked_body}} = read(chunked)
    assert {:error, {431, :head_too_large}} = read(huge_head)
    assert {:error, {431, :too_many_headers}} = read(many)
    assert {:error, {400, :malformed_request}} = read(absolute)
    assert {:error, {400, :malformed_header}} = read(long_value)
  end

  test "replays a request and reads the whole answer until the listener closes" do
    me = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    Task.start(fn ->
      {:ok, conn} = :gen_tcp.accept(listener, @wait)

      {:ok, request} =
        LoopbackHttp.read_request(conn, System.monotonic_time(:millisecond) + @wait)

      send(me, {:replayed, request})

      :ok =
        LoopbackHttp.write_response(
          conn,
          200,
          [["Content-Type", "text/html"], ["Connection", "keep-alive"]],
          "<p>ok</p>"
        )

      :gen_tcp.close(conn)
    end)

    request = %{
      method: "GET",
      target: "/callback?code=c1",
      headers: [["Host", "127.0.0.1:#{port}"]],
      body: ""
    }

    assert {:ok, %{status: 200, headers: [["Content-Type", "text/html"]], body: "<p>ok</p>"}} =
             LoopbackHttp.replay(port, request, @wait)

    assert_receive {:replayed, %{target: "/callback?code=c1", headers: [["Host", _host]]}}
    :gen_tcp.close(listener)
  end

  test "a listener that is gone is a failed connect" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    request = %{method: "GET", target: "/", headers: [], body: ""}
    assert {:error, {:connect_failed, :econnrefused}} = LoopbackHttp.replay(port, request, @wait)
  end

  test "an answer past 256 KiB is refused" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    Task.start(fn ->
      {:ok, conn} = :gen_tcp.accept(listener, @wait)

      {:ok, _request} =
        LoopbackHttp.read_request(conn, System.monotonic_time(:millisecond) + @wait)

      _ = LoopbackHttp.write_response(conn, 200, [], String.duplicate("a", 262_145))
      :gen_tcp.close(conn)
    end)

    request = %{method: "GET", target: "/", headers: [], body: ""}
    assert {:error, :response_too_large} = LoopbackHttp.replay(port, request, @wait)
    :gen_tcp.close(listener)
  end
end
