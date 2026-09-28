defmodule FermixChannels.Mobile.WssLimitsTest do
  @moduledoc """
  The listener's transport bounds, over a real loopback TLS socket.

  Synchronous on purpose: the heap-cap case compares the VM's binary memory
  before and after an attack, which only means something while no other test
  allocates beside it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener

  @setup_timeout_ms 10_000
  @timeout_ms 5_000
  @chunk_bytes 60 * 1_024
  @attack_bytes 32 * 1_024 * 1_024

  defmodule Client do
    @moduledoc false

    use WebSockex

    @spec start_link({WebSockex.Conn.t(), pid()}) :: {:ok, pid()} | {:error, term()}
    def start_link({%WebSockex.Conn{} = conn, parent}) when is_pid(parent) do
      WebSockex.start_link(conn, __MODULE__, parent)
    end

    @impl true
    def handle_connect(_conn, parent) do
      send(parent, {:wss_connected, self()})
      {:ok, parent}
    end

    @impl true
    def handle_frame(frame, parent) do
      send(parent, {:wss_frame, self(), frame})
      {:ok, parent}
    end

    @impl true
    def handle_disconnect(%{reason: reason}, parent) do
      send(parent, {:wss_disconnected, self(), reason})
      {:ok, parent}
    end
  end

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-wss-limits")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    assert {:ok, _identity} = Identity.ensure(root: root)

    listener =
      start_supervised!(
        {Listener,
         name: Module.concat(__MODULE__, "Listener#{System.unique_integer([:positive])}"),
         root: root,
         bind: {127, 0, 0, 1},
         port: 0,
         router_opts: [discover: fn -> {:ok, []} end]}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = Listener.listener_info(listener)
    %{port: port}
  end

  # SEC-1: Bandit keeps every FIN=0 continuation frame until the final one,
  # with no bound on the total and before any authentication. The listener
  # caps an unauthenticated connection's heap, shared binaries included, so
  # the connection is killed and its memory released instead of the VM's.
  test "an unauthenticated fragmented message past the heap cap kills its connection", ctx do
    client = connect(ctx.port)
    :erlang.garbage_collect()
    before = :erlang.memory(:binary)

    log =
      capture_log(fn ->
        sent = stream_fragments(client, @attack_bytes)
        assert sent < @attack_bytes, "the listener accepted #{sent} bytes of one message"
        assert_receive {:wss_disconnected, ^client, _reason}, @timeout_ms
      end)

    assert log =~ "maximum heap size"
    :erlang.garbage_collect()
    grown = :erlang.memory(:binary) - before
    assert grown < div(@attack_bytes, 2), "binary memory grew by #{grown} bytes"
  end

  # SEC-10: Bandit counts the frame header against `max_frame_size`, so a
  # 65,535-byte cap refused the largest Noise message the protocol publishes.
  test "a maximal 65,535-byte frame reaches the socket handler", ctx do
    client = connect(ctx.port)
    garbage = :crypto.strong_rand_bytes(65_535 - 5)
    assert :ok = WebSockex.send_frame(client, {:binary, <<"FXM1", 1>> <> garbage})

    # Past the transport, the handler refuses the unreadable handshake with its
    # own protocol error, not the transport's 1009 "message too big".
    assert_receive {:wss_disconnected, ^client, {:remote, 1002, _message}}, @timeout_ms
  end

  test "one byte past the maximal Noise message is still refused as too big", ctx do
    client = connect(ctx.port)
    oversized = <<"FXM1", 1>> <> :crypto.strong_rand_bytes(65_536 - 5)
    assert :ok = WebSockex.send_frame(client, {:binary, oversized})

    assert_receive {:wss_disconnected, ^client, {:remote, 1009, _message}}, @timeout_ms
  end

  defp connect(port) do
    conn =
      WebSockex.Conn.new("wss://127.0.0.1:#{port}/ws",
        ssl_options: [verify: :verify_none],
        socket_connect_timeout: @setup_timeout_ms,
        socket_recv_timeout: @setup_timeout_ms
      )

    client = start_supervised!({Client, {conn, self()}}, restart: :temporary)
    assert_receive {:wss_connected, ^client}, @setup_timeout_ms
    client
  end

  # One message of FIN=0 frames that never finishes. Stops at the first send
  # the transport refuses and answers how many bytes it accepted.
  defp stream_fragments(client, total) do
    chunk = :binary.copy(<<0>>, @chunk_bytes)
    :ok = WebSockex.send_frame(client, {:fragment, :binary, chunk})
    stream_continuations(client, chunk, @chunk_bytes, total)
  end

  defp stream_continuations(_client, _chunk, sent, total) when sent >= total, do: sent

  defp stream_continuations(client, chunk, sent, total) do
    if Process.alive?(client) and send_continuation(client, chunk) == :ok,
      do: stream_continuations(client, chunk, sent + @chunk_bytes, total),
      else: sent
  end

  defp send_continuation(client, chunk) do
    WebSockex.send_frame(client, {:continuation, chunk})
  catch
    :exit, _reason -> :disconnected
  end
end
