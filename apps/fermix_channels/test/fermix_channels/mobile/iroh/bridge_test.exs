defmodule FermixChannels.Mobile.Iroh.BridgeTest do
  # The bridge socket and its connections, over a real Unix socket, as the
  # helper sees them: the preamble, then iroh carrier frames, carrying a
  # phone's session.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Carrier
  alias FermixTestSupport.SafeRm

  @fixture_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @preamble "FXB1" <> <<1>> <> Base.decode16!(@fixture_id, case: :lower)
  @paired <<"FXM1", 1, "handshake">>
  @pairing <<"FXM1", 2, "pairing">>

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

  # A bridge whose sessions can each get to one of the places a stream holds,
  # with stubbed crypto: in its handshake (the prelude, or IKpsk2's first
  # message), past it as a paired phone (IK, then "hello"), or past it as a
  # pairing phone waiting for the owner (IKpsk2, then "pair-request"). The
  # handshake deadline and the idle bound never fire, so only the bridge closes
  # a stream here. The bridge is traced (`trace/1`).
  defp start_held_bridge(ctx, opts) do
    registry = start_supervised!({DeviceRegistry, name: nil})
    opts = Keyword.merge([session_opts: held_session(registry), idle_timeout_ms: 600_000], opts)
    %{bridge: bridge} = started = start_bridge(ctx, opts)
    trace(bridge)
    started
  end

  # The bridge's own messages are the events these tests wait on: it sends each
  # connection it admits `:socket_handover`, casts `:make_room` to each it asks
  # for its place, and is cast `{:past_handshake, pid}` by each whose session
  # got past its handshake. One `:sys.get_state/1` after such a message was seen
  # reads the bridge after it.
  defp trace(bridge), do: 1 = :erlang.trace(bridge, true, [:send, :receive])

  defp admitted(bridge) do
    assert_receive {:trace, ^bridge, :send, :socket_handover, connection}
    connection
  end

  defp assert_made_room(bridge, connection),
    do: assert_receive({:trace, ^bridge, :send, {:"$gen_cast", :make_room}, ^connection})

  defp heard_past_handshake(bridge, connection) do
    assert_receive {:trace, ^bridge, :receive, {:"$gen_cast", {:past_handshake, ^connection}}}
    :sys.get_state(bridge)
  end

  defp held_session(registry) do
    [
      device_registry: registry,
      device_store: :store,
      pair_manager: :pair,
      gateway_keypair: %{private: <<1::256>>, public: <<2::256>>},
      primary_epoch: 1,
      schedule_handshake_deadline: fn _message, _delay_ms -> make_ref() end,
      cancel_handshake_deadline: fn _ref -> false end,
      current_pair: fn :pair, _peer ->
        {:ok, %{session_id: "pair-session", secret: <<3::256>>}}
      end,
      noise_initialize: fn :responder, pattern, _opts -> {:ok, {pattern, 0}} end,
      noise_read: fn {pattern, 0}, _wire -> {:ok, <<>>, {pattern, 1}} end,
      noise_write: fn {pattern, 1}, <<>> -> {:ok, "response", {pattern, 2}} end,
      noise_remote_static: fn {_pattern, 2} -> {:ok, <<7::256>>} end,
      noise_sas: fn {:ikpsk2, 2} -> "123456" end,
      find_device: fn :store, <<7::256>> -> {:ok, %{device_id: "paired-device"}} end,
      decrypt: fn {pattern, 2}, ciphertext -> {:ok, ciphertext, {pattern, 3}} end,
      decode_client: fn plaintext, _opts -> {:ok, client_event(plaintext)} end,
      update_device: fn :store, "paired-device", %{last_seen: %DateTime{}} ->
        {:ok, %{device_id: "paired-device"}}
      end,
      attach_socket: fn ^registry, "paired-device", _pid, _opts -> :ok end,
      hello_ack_builder: fn _state -> {:ok, %{"session_id" => "session"}} end,
      pending_approvals: fn _profile -> [] end,
      pairing_pending: fn -> :none end,
      encode_server: fn "hello_ack", _payload, 1 -> {:ok, "encoded"} end,
      encrypt: fn {:ik, 3}, "encoded" -> {:ok, "hello-ack", {:ik, 4}} end,
      verify_pair: fn :pair, "pair-session", _evidence -> {:ok, %{}} end,
      submit_pair: fn :pair, "pair-session", _attrs -> {:ok, %{}} end,
      record_pair_failure: fn :pair, "pair-session", _peer -> {:ok, 1} end
    ]
  end

  defp client_event("hello") do
    payload = %{
      "device_id" => "paired-device",
      "app_version" => "1.0",
      "last_server_seq" => 0,
      "protocol_v" => 2
    }

    %{version: 2, type: "hello", seq: 1, payload: payload, bytes: <<>>}
  end

  defp client_event("pair-request") do
    payload = %{
      "device_name" => "Phone",
      "model" => "Pixel",
      "app_version" => "1.0",
      "platform" => "android",
      "attestation" => %{"kind" => "android_key", "cert_lengths" => []}
    }

    %{version: 2, type: "pair_request", seq: 1, payload: payload, bytes: <<>>}
  end

  defp in_handshake(ctx) do
    socket = connect(ctx)
    send_frame(socket, @preamble)
    framed(socket)
  end

  defp ready(ctx) do
    socket = in_handshake(ctx)
    assert {:message, "response"} = handshake(socket, @paired)
    assert {:message, "hello-ack"} = send_and_recv(socket, "hello")
    socket
  end

  # A pairing request that waits for the owner gets no reply until the owner
  # decides; the bridge's state shows it got past its handshake.
  defp awaiting_owner(ctx) do
    socket = in_handshake(ctx)
    assert {:message, "response"} = handshake(socket, @pairing)
    send_frame(socket, Carrier.message("pair-request"))
    socket
  end

  defp handshake(socket, prelude), do: send_and_recv(socket, prelude)

  defp send_and_recv(socket, payload) do
    send_frame(socket, Carrier.message(payload))
    recv_frame(socket)
  end

  defp held(state), do: Enum.count(state.connections, fn {_pid, c} -> c.past_handshake? end)

  # The captured lines the bridge process itself logged that carry `words`.
  defp bridge_lines(log, bridge, words) do
    pid = "pid=" <> List.to_string(:erlang.pid_to_list(bridge))

    log
    |> String.split("\n")
    |> Enum.filter(&(String.contains?(&1, pid) and String.contains?(&1, words)))
  end

  # Closing every connection sends each the shutdown's close: a stream the
  # bridge had closed to make room would read its 1008 first.
  defp assert_untouched(sockets) do
    :ok = stop_supervised(DynamicSupervisor)

    for socket <- sockets do
      assert {:close, 1000, "daemon shutting down"} = recv_frame(socket)
    end
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

  # A peer refused before it is a paired phone's session keeps no iroh
  # connection, so opening stream after failing stream holds none of the
  # helper's connection places.
  test "a session refused in its handshake asks the helper to close its iroh peer", ctx do
    test_pid = self()

    refused =
      paired_session(test_pid)
      |> Keyword.put(:find_device, fn :store, <<7::256>> -> {:error, :not_found} end)
      |> Keyword.put(:close_iroh_peer, fn id ->
        send(test_pid, {:close_iroh_peer, id})
        :ok
      end)

    start_bridge(ctx, session_opts: refused)
    socket = connect(ctx)
    send_frame(socket, @preamble)
    socket = framed(socket)

    send_frame(socket, Carrier.message(<<"FXM1", 1, "handshake">>))
    assert {:close, 1002, "mobile protocol error"} = recv_frame(socket)
    assert_receive {:close_iroh_peer, @fixture_id}
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

  # A stranger who knows the node id can open streams that never say a word;
  # the phone's own stream must still find a place (M62 §7).
  test "a full bridge closes its oldest stream still in its handshake for a new one", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, [])

    [{oldest, oldest_connection}, {next, _next_connection} | _rest] =
      for _stream <- 1..Bridge.max_connections() do
        socket = in_handshake(ctx)
        {socket, admitted(bridge)}
      end

    log =
      capture_log(fn ->
        newcomer = in_handshake(ctx)
        assert_made_room(bridge, oldest_connection)
        _newcomer_connection = admitted(bridge)
        assert {:close, 1008, "mobile handshake deadline"} = recv_frame(oldest)
        assert {:error, :closed} = :gen_tcp.recv(oldest, 0, 1_000)
        assert {:message, "response"} = handshake(newcomer, @pairing)
      end)

    assert log =~ "bridge socket full: closed 1 remote stream still in the handshake"
    assert {:message, "response"} = handshake(next, @pairing)
    assert map_size(:sys.get_state(bridge).connections) == Bridge.max_connections()
  end

  # A phone whose IK handshake proved its paired key, and a pairing phone
  # waiting for the owner, keep their places whatever arrives; only streams in
  # a handshake make room, IKpsk2's first message included.
  test "a session past its handshake keeps its place in a full bridge", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, max_connections: 4)
    phone = ready(ctx)
    heard_past_handshake(bridge, admitted(bridge))
    pairing = awaiting_owner(ctx)
    heard_past_handshake(bridge, admitted(bridge))
    [first, second] = for _stream <- 1..2, do: {in_handshake(ctx), admitted(bridge)}

    third = in_handshake(ctx)
    third_connection = admitted(bridge)
    assert {:close, 1008, "mobile handshake deadline"} = recv_frame(elem(first, 0))
    assert {:message, "response"} = handshake(third, @paired)
    heard_past_handshake(bridge, third_connection)

    _fourth = in_handshake(ctx)
    fourth_connection = admitted(bridge)
    assert_made_room(bridge, elem(second, 1))
    assert {:close, 1008, "mobile handshake deadline"} = recv_frame(elem(second, 0))

    _fifth = in_handshake(ctx)
    _fifth_connection = admitted(bridge)
    assert_made_room(bridge, fourth_connection)

    assert held(:sys.get_state(bridge)) == 3
    assert_untouched([phone, pairing, third])
  end

  test "a full bridge whose every session is past its handshake turns a stream away", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, max_connections: 2)
    phone = ready(ctx)
    heard_past_handshake(bridge, admitted(bridge))
    pairing = awaiting_owner(ctx)
    heard_past_handshake(bridge, admitted(bridge))

    turned_away = connect(ctx)
    assert {:error, :closed} = :gen_tcp.recv(turned_away, 0, 2_000)
    refute_received {:trace, ^bridge, :send, {:"$gen_cast", :make_room}, _connection}
    assert map_size(:sys.get_state(bridge).connections) == 2
    assert_untouched([phone, pairing])
  end

  # The bridge chose a stream to make room before it read that the stream's
  # session had just got past its handshake: the session stays, and the bridge
  # serves one over its bound until a connection ends.
  test "a stream past its handshake by the time the bridge asks for its place stays", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, max_connections: 1)
    phone = in_handshake(ctx)
    phone_connection = admitted(bridge)

    :ok = :sys.suspend(bridge)
    assert {:message, "response"} = handshake(phone, @paired)

    assert_receive {:trace, ^bridge, :receive,
                    {:"$gen_cast", {:past_handshake, ^phone_connection}}}

    _newcomer = in_handshake(ctx)
    :ok = :sys.resume(bridge)

    assert_made_room(bridge, phone_connection)
    newcomer_connection = admitted(bridge)
    state = :sys.get_state(bridge)
    assert %{^phone_connection => %{past_handshake?: true}} = state.connections
    assert %{^newcomer_connection => %{past_handshake?: false}} = state.connections
    assert map_size(state.connections) == 2
    assert_untouched([phone])
  end

  # A stream that ended frees its place for the next one: nothing is closed
  # to make room.
  test "a stream that ends frees its place without closing another", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, max_connections: 2)
    {ending, ending_connection} = {in_handshake(ctx), admitted(bridge)}
    {staying, staying_connection} = {in_handshake(ctx), admitted(bridge)}

    :ok = :gen_tcp.close(ending)
    assert_receive {:trace, ^bridge, :receive, {:DOWN, _ref, :process, ^ending_connection, _}}
    assert map_size(:sys.get_state(bridge).connections) == 1

    _next = in_handshake(ctx)
    next_connection = admitted(bridge)
    refute_received {:trace, ^bridge, :send, {:"$gen_cast", :make_room}, _connection}
    assert {:message, "response"} = handshake(staying, @pairing)

    connections = :sys.get_state(bridge).connections
    assert Enum.sort(Map.keys(connections)) == Enum.sort([staying_connection, next_connection])
  end

  # The word can reach the bridge after the connection that sent it ended.
  test "a connection that ended before its word arrived takes no place", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, max_connections: 1)
    gone = spawn(fn -> :ok end)
    monitor = Process.monitor(gone)
    assert_receive {:DOWN, ^monitor, :process, ^gone, _reason}

    :ok = GenServer.cast(bridge, {:past_handshake, gone})
    assert_receive {:trace, ^bridge, :receive, {:DOWN, _ref, :process, ^gone, :noproc}}
    assert :sys.get_state(bridge).connections == %{}

    _stream = in_handshake(ctx)
    _connection = admitted(bridge)
    refute_received {:trace, ^bridge, :send, {:"$gen_cast", :make_room}, _connection}
  end

  # M62 §7: a flood is said at 1, 10, 100… streams, never once per stream.
  test "refused streams are warned about at each power of ten", ctx do
    %{bridge: bridge} = start_held_bridge(ctx, max_connections: 1)
    _phone = ready(ctx)
    heard_past_handshake(bridge, admitted(bridge))

    log =
      capture_log([format: "$metadata$message\n", metadata: [:pid]], fn ->
        for _stream <- 1..12 do
          turned_away = connect(ctx)
          assert {:error, :closed} = :gen_tcp.recv(turned_away, 0, 2_000)
        end
      end)

    # Other async modules log into the capture too: only this bridge's own
    # lines are read, and its state holds how many streams it refused.
    warnings = bridge_lines(log, bridge, "bridge socket full: refused")
    assert [one, ten] = warnings
    assert one =~ "refused 1 remote stream"
    assert ten =~ "refused 10 remote streams"
    assert :sys.get_state(bridge).refused == 12
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
