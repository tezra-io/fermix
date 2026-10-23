defmodule FermixCore.Cues.Source.Stream.SocketTest do
  # The real WebSocket transport against a WebSocket server on loopback, which
  # stands in for Jetstream: no outside network.
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Source.Stream.Socket
  alias FermixCore.Net.Egress

  @wait_ms 10_000

  defmodule Server do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state), do: {:push, {:text, "hello"}, state}

    @impl true
    def handle_in({text, opcode: :text}, state), do: {:push, {:text, "echo " <> text}, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{request_path: "/refuse"} = conn, _opts),
      do: Plug.Conn.send_resp(conn, 401, "")

    def call(conn, _opts),
      do: conn |> Plug.Conn.upgrade_adapter(:websocket, {Server, %{}, []}) |> Plug.Conn.halt()
  end

  setup do
    server = start_supervised!({Bandit, plug: Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{base: "ws://127.0.0.1:#{port}"}
  end

  defp start(url, owner \\ self()),
    do: Socket.start(url, owner, handshake_timeout: @wait_ms, egress: %Egress{})

  test "reports the connection, text frames and pongs, and stops when closed", ctx do
    assert {:ok, socket} = start(ctx.base <> "/stream")
    monitor = Process.monitor(socket)

    assert_receive {:cue_stream, ^socket, :connected}, @wait_ms
    assert_receive {:cue_stream, ^socket, {:frame, {:text, "hello"}}}, @wait_ms

    :ok = Socket.ping(socket)
    assert_receive {:cue_stream, ^socket, :pong}, @wait_ms

    :ok = Socket.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}, @wait_ms
  end

  test "a refused handshake ends the socket with the status in its exit reason", ctx do
    assert {:ok, socket} = start(ctx.base <> "/refuse")
    monitor = Process.monitor(socket)

    assert_receive {:DOWN, ^monitor, :process, ^socket,
                    {:error, %WebSockex.RequestError{code: 401}}},
                   @wait_ms

    refute_received {:cue_stream, ^socket, :connected}
  end

  test "closes when its owner is gone", ctx do
    test = self()

    owner =
      spawn(fn ->
        {:ok, socket} = start(ctx.base <> "/stream", self())
        send(test, {:socket, socket})

        receive do
          {:cue_stream, ^socket, :connected} -> send(test, :connected)
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:socket, socket}, @wait_ms
    monitor = Process.monitor(socket)
    assert_receive :connected, @wait_ms

    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}, @wait_ms
  end

  test "a route the proxy would carry is refused before any dial" do
    egress = %Egress{proxy: %{host: "proxy.example.test", port: 3128}, bypass: []}

    assert Socket.start("wss://jetstream.example.test", self(),
             handshake_timeout: @wait_ms,
             egress: egress
           ) == {:error, :proxy_unsupported_transport}
  end
end
