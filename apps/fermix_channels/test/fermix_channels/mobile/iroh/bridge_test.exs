defmodule FermixChannels.Mobile.Iroh.BridgeTest do
  # The bridge socket and its connections, over a real Unix socket, as the
  # helper sees them: the preamble, then iroh carrier frames, carrying a
  # phone's session.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Carrier
  alias FermixTestSupport.SafeRm

  @fixture_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @preamble "FXB1" <> <<1>> <> Base.decode16!(@fixture_id, case: :lower)

  setup do
    # A Unix socket path is at most 104 bytes on macOS: a short prefix.
    dir = SafeRm.make_tmp_dir!("b")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{socket_path: Path.join(dir, "b.sock")}
  end

  defp start_bridge(ctx, opts) do
    connections = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    bridge_opts =
      Keyword.merge(
        [
          name: nil,
          socket_path: ctx.socket_path,
          connection_supervisor: connections,
          connection_opts: [
            session_opts: Keyword.get(opts, :session_opts, paired_session(self())),
            idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 5_000),
            preamble_timeout_ms: Keyword.get(opts, :preamble_timeout_ms, 1_000)
          ]
        ],
        Keyword.take(opts, [:max_connections])
      )

    %{bridge: start_supervised!({Bridge, bridge_opts}), connections: connections}
  end

  # A paired phone's IK handshake with stubbed crypto: the session answers the
  # prelude with "response" and records the peer it was given.
  defp paired_session(test_pid) do
    [
      device_registry: :registry,
      device_store: :store,
      pair_manager: :pair,
      gateway_keypair: %{private: <<1::256>>, public: <<2::256>>},
      noise_initialize: fn :responder, :ik, [static_keypair: _keypair] -> {:ok, :noise0} end,
      noise_read: fn :noise0, <<"FXM1", 1, "handshake">> -> {:ok, <<>>, :noise1} end,
      noise_write: fn :noise1, <<>> -> {:ok, "response", :noise2} end,
      noise_remote_static: fn :noise2 -> {:ok, <<7::256>>} end,
      find_device: fn :store, <<7::256>> ->
        send(test_pid, :handshake_seen)
        {:ok, %{device_id: "paired-device"}}
      end
    ]
  end

  defp connect(ctx) do
    {:ok, socket} =
      :gen_tcp.connect({:local, ctx.socket_path}, 0, [:binary, active: false], 1_000)

    socket
  end

  defp framed(socket) do
    :ok = :inet.setopts(socket, packet: 4)
    socket
  end

  defp send_frame(socket, iodata), do: :ok = :gen_tcp.send(socket, iodata)
  defp recv_frame(socket), do: socket |> :gen_tcp.recv(0, 2_000) |> decode()
  defp decode({:ok, frame}), do: Carrier.decode(frame)
  defp decode(other), do: other

  test "the bridge socket is 0600 and removed when the bridge stops", ctx do
    %{bridge: pid} = start_bridge(ctx, [])
    assert %{mode: mode} = File.stat!(ctx.socket_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    :ok = stop_supervised(Bridge)
    refute Process.alive?(pid)
    refute File.exists?(ctx.socket_path)
  end

  test "a phone's stream carries its session: preamble, then whole Noise messages", ctx do
    start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)

    send_frame(socket, Carrier.message(<<"FXM1", 1, "handshake">>))
    assert {:message, "response"} = recv_frame(socket)
    assert_receive :handshake_seen
  end

  test "the session's pairing calls carry the iroh peer the preamble names", ctx do
    test_pid = self()

    session = [
      device_registry: :registry,
      gateway_keypair: %{private: <<1::256>>, public: <<2::256>>},
      pair_manager: :pair,
      current_pair: fn :pair, peer ->
        send(test_pid, {:peer, peer})
        :none
      end
    ]

    start_bridge(ctx, session_opts: session)
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)
    send_frame(socket, Carrier.message(<<"FXM1", 2, "pairing">>))

    assert_receive {:peer, {:iroh, @fixture_id}}
    assert {:close, 1002, "mobile protocol error"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a preamble the bridge does not know, or none in time, closes the connection", ctx do
    start_bridge(ctx, preamble_timeout_ms: 200)

    wrong = connect(ctx)
    send_frame(wrong, "FXB2" <> <<1>> <> <<0::256>>)
    assert {:error, :closed} = :gen_tcp.recv(wrong, 0, 1_000)

    silent = connect(ctx)
    assert {:error, :closed} = :gen_tcp.recv(silent, 0, 2_000)
  end

  test "an unknown frame type is a protocol error and closes with 1002", ctx do
    start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)

    send_frame(socket, <<9, "what">>)
    assert {:close, 1002, "mobile protocol error"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a zero-length frame is a protocol error and closes with 1002", ctx do
    start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)

    send_frame(socket, <<>>)
    assert {:close, 1002, "mobile protocol error"} = recv_frame(socket)
  end

  # M62 §10.4: an hourly renewal is a second stream, and so a second bridge
  # connection, from the same phone; each carries a session of its own.
  test "two bridge connections from one peer each carry a session", ctx do
    start_bridge(ctx, [])

    for _renewal <- 1..2 do
      socket = connect(ctx)
      send_frame(socket, @preamble)
      socket = framed(socket)
      send_frame(socket, Carrier.message(<<"FXM1", 1, "handshake">>))
      assert {:message, "response"} = recv_frame(socket)
      assert_receive :handshake_seen
    end
  end

  # The rail switched off, or the daemon stopping, ends a live session as any
  # other close does: a close frame first (M62 §3, the session's contract).
  test "a shutdown ends a live remote session with a close frame", ctx do
    %{connections: connections} = start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)
    send_frame(socket, Carrier.message(<<"FXM1", 1, "handshake">>))
    assert {:message, "response"} = recv_frame(socket)

    [{_id, connection, :worker, _modules}] = DynamicSupervisor.which_children(connections)
    :ok = DynamicSupervisor.terminate_child(connections, connection)

    assert {:close, 1000, "daemon shutting down"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a revocation ends a live remote session with 4003", ctx do
    %{connections: connections} = start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)
    send_frame(socket, Carrier.message(<<"FXM1", 1, "handshake">>))
    assert {:message, "response"} = recv_frame(socket)

    [{_id, connection, :worker, _modules}] = DynamicSupervisor.which_children(connections)
    send(connection, {:mobile_revoked, "paired-device"})

    assert {:close, 4003, "device revoked"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  # M62 §10.4: a revoked phone stays refused whatever iroh key or relay it
  # comes back with, because the daemon knows a phone by its Noise key alone.
  test "a revoked phone's Noise key is refused over a fresh iroh endpoint", ctx do
    test_pid = self()

    revoked =
      paired_session(test_pid)
      |> Keyword.put(:find_device, fn :store, <<7::256>> ->
        send(test_pid, :lookup)
        {:error, :not_found}
      end)

    start_bridge(ctx, session_opts: revoked)
    socket = connect(ctx)
    fresh = "FXB1" <> <<1>> <> :crypto.strong_rand_bytes(32)
    send_frame(socket, fresh)
    socket = framed(socket)

    send_frame(socket, Carrier.message(<<"FXM1", 1, "handshake">>))
    assert_receive :lookup
    assert {:close, 1002, "mobile protocol error"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a frame over 65,536 bytes is refused before it is read", ctx do
    start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)

    # The length alone: the bridge's packet bound refuses it before the bytes.
    send_frame(socket, <<65_537::32-big>>)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  test "a connection nothing is read from is closed at the session's idle bound", ctx do
    start_bridge(ctx, idle_timeout_ms: 200)
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)

    assert {:close, 1002, "no inbound frame"} = recv_frame(socket)
  end

  test "the phone's close frame ends the session", ctx do
    start_bridge(ctx, [])
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)

    send_frame(socket, Carrier.close(1000, "bye"))
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "connections past the bridge's bound are closed at accept", ctx do
    start_bridge(ctx, max_connections: 1)
    first = connect(ctx)
    send_frame(first, @preamble)
    Process.sleep(100)

    second = connect(ctx)
    assert {:error, :closed} = :gen_tcp.recv(second, 0, 1_000)
  end

  # The helper opens a bridge connection per stream as the streams arrive; a
  # burst must wait in the backlog, not be refused while the bridge is busy.
  test "a burst of connections waits in the backlog while the bridge is busy", ctx do
    %{bridge: bridge} = start_bridge(ctx, [])
    :ok = :sys.suspend(bridge)

    results =
      for _connection <- 1..20 do
        :gen_tcp.connect({:local, ctx.socket_path}, 0, [:binary, active: false], 1_000)
      end

    :ok = :sys.resume(bridge)
    assert Enum.all?(results, &match?({:ok, _socket}, &1)), inspect(results)
  end

  test "a stale socket file is replaced; a live bridge is never stolen", ctx do
    File.write!(ctx.socket_path, "stale")
    %{bridge: pid} = start_bridge(ctx, [])
    assert Process.alive?(pid)

    connections = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :second)

    assert :ignore =
             GenServer.start(Bridge,
               socket_path: ctx.socket_path,
               connection_supervisor: connections
             )
  end
end
