defmodule FermixChannels.Mobile.RailTest do
  # M75 §4.2: the initiator-side session client, hermetic. Most sessions run
  # against the engine's own responder, `Mobile.Session` with real Noise, behind
  # the iroh bridge socket exactly as the helper hands it a stream (the test's
  # connect writes the helper's preamble). The rules only a misbehaving
  # responder can break, and the M75 modes whose responders come later, run
  # against a test that plays the responder itself.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Carrier
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Rail
  alias FermixTestSupport.SafeRm

  @device_id "5d0f2c7e-3b8a-4c1d-9e6f-0a7b8c9d1e2f"
  @peer_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @preamble "FXB1" <> <<1>> <> Base.decode16!(@peer_id, case: :lower)
  @route %{
    node_id: @peer_id,
    relays: [%{"url" => "https://relay.invalid/", "quic_port" => 7842}],
    relays_rev: "0123456789abcdef"
  }
  @rekey_frames 1_048_576

  setup do
    # Short: the bridge socket's path must fit a Unix socket address.
    root = Path.join(System.tmp_dir!(), "fx-rail-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    {:ok, identity} = Identity.ensure(root: root)
    revoked = start_supervised!({Agent, fn -> false end}, id: :revoked)

    %{
      root: root,
      gateway_public_key: identity.gateway_public_key,
      device: Noise.generate_keypair(),
      revoked: revoked
    }
  end

  # -- the engine's own responder ----------------------------------------------

  defp start_responder(ctx, opts \\ []) do
    suffix = System.unique_integer([:positive])
    registry = start_registry(:"rail_registry_#{suffix}", ctx.revoked)
    connections = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    socket_path = Path.join(ctx.root, "b.sock")

    start_supervised!(
      {Bridge,
       name: nil,
       socket_path: socket_path,
       connection_supervisor: connections,
       connection_opts: [session_opts: session_opts(ctx, registry, opts)]}
    )

    Map.merge(ctx, %{registry: registry, connections: connections, bridge_socket: socket_path})
  end

  defp start_registry(name, revoked) do
    start_supervised!(
      {DeviceRegistry,
       name: name,
       device_store: :rail_test_store,
       authorize_device: fn _store, @device_id ->
         if Agent.get(revoked, & &1),
           do: {:error, {:device_not_found, @device_id}},
           else: {:ok, %{device_id: @device_id}}
       end,
       delete_device: fn _store, @device_id -> Agent.update(revoked, fn _ -> true end) end,
       revoke_requests: fn _id -> :ok end,
       relays_changed: fn -> :ok end}
    )

    name
  end

  # A paired row for the test's device key and nothing else.
  defp session_opts(ctx, registry, opts) do
    device_public = ctx.device.public
    revoked = ctx.revoked

    [
      identity_root: ctx.root,
      device_store: :rail_test_store,
      device_registry: registry,
      iroh_helper: :rail_test_no_helper,
      find_device: fn _store, key ->
        if key == device_public and not Agent.get(revoked, & &1),
          do: {:ok, %{device_id: @device_id}},
          else: {:error, :not_found}
      end,
      update_device: fn _store, @device_id, _changes -> {:ok, %{device_id: @device_id}} end,
      profile_name: "Orbit",
      history_head: fn "main" -> {:ok, 0} end,
      read_frontier: fn "main" -> {:ok, 0} end,
      pending_approvals: fn _profile -> [] end,
      discover: fn -> {:ok, Keyword.get(opts, :candidates, [])} end
    ]
  end

  # The helper's side of the bridge: connect, then the 37-byte preamble.
  defp bridge_connect(path) do
    fn ->
      with {:ok, socket} <- :gen_tcp.connect({:local, path}, 0, [:binary, active: false]),
           :ok <- :gen_tcp.send(socket, @preamble),
           do: {:ok, socket}
    end
  end

  defp open(ctx, opts \\ []) do
    keys = [
      static_keypair: Keyword.get(opts, :static_keypair, ctx.device),
      remote_static: ctx.gateway_public_key,
      connect: bridge_connect(ctx.bridge_socket)
    ]

    Rail.open(@route, :ik, keys ++ Keyword.drop(opts, [:static_keypair]))
  end

  defp hello(rail) do
    payload = %{
      "device_id" => @device_id,
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    assert :ok = Rail.send_event(rail, "hello", payload)
    assert_receive {:rail, ^rail, {:event, %{"t" => "hello_ack"} = ack, <<>>}}
    ack
  end

  defp connection(ctx) do
    assert [{_id, pid, :worker, _modules}] = DynamicSupervisor.which_children(ctx.connections)
    pid
  end

  # Timers the session would set, sent here instead, to be fired by hand.
  defp captured_timers do
    test_pid = self()

    [
      schedule: fn message, delay_ms ->
        send(test_pid, {:scheduled, message, delay_ms})
        make_ref()
      end,
      cancel_timer: fn _ref -> false end
    ]
  end

  test "a paired device's session: IK, hello and its ack, ping and pong, then the owner's close",
       ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx)

    ack = hello(rail)
    assert %{"v" => 2, "seq" => 1, "profiles" => [%{"id" => "main"}]} = ack

    assert :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 2, "v" => 2}, <<>>}}

    responder = Process.monitor(connection(ctx))
    rail_down = Process.monitor(rail)
    assert :ok = Rail.close(rail)
    assert_receive {:DOWN, ^rail_down, :process, ^rail, :normal}
    assert_receive {:DOWN, ^responder, :process, _pid, :normal}
    refute_received {:rail, ^rail, {:closed, _reason}}
  end

  test "a long event arrives as an event_part run and reaches the owner as the one event", ctx do
    long = String.duplicate("a", 240) <> ".example"

    candidates =
      for n <- 1..16, do: %{address: "#{n}-#{long}", interface: "en0", scope: :lan}

    ctx = start_responder(ctx, candidates: candidates)
    assert {:ok, rail} = open(ctx)

    ack = hello(rail)
    assert %{"t" => "hello_ack", "seq" => 1, "v" => 2} = ack
    assert length(ack["candidates"]) == 16
    refute Map.has_key?(ack, "index") or Map.has_key?(ack, "count")

    # The run took a seq per frame; the next event follows its last.
    assert :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => pong_seq}, <<>>}}
    assert pong_seq > 2
  end

  test "the responder's close reaches the owner, and the session ends", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx)
    hello(rail)
    rail_down = Process.monitor(rail)

    assert :ok = DeviceRegistry.revoke(ctx.registry, @device_id)
    assert_receive {:rail, ^rail, {:closed, {:remote, 4003, "device revoked"}}}
    assert_receive {:DOWN, ^rail_down, :process, ^rail, :normal}
  end

  test "a key the responder does not hold fails the open with its close", ctx do
    ctx = start_responder(ctx)

    assert {:error, {:remote, 1002, "mobile protocol error"}} =
             open(ctx, static_keypair: Noise.generate_keypair())
  end

  test "a frame the codec refuses is refused at the call and costs no seq", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx)

    assert {:error, {:unknown_event, "surprise"}} = Rail.send_event(rail, "surprise", %{})
    assert {:error, _reason} = Rail.send_event(rail, "ping", %{}, "a raw tail ping never has")
    # hello still goes out as seq 1, which the responder holds it to.
    assert %{"seq" => 1} = hello(rail)
  end

  test "pings start with the owner's first event and keep the session alive", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx, captured_timers())

    assert_receive {:scheduled, {:rail_timer, :idle, _idle}, 150_000}
    refute_received {:scheduled, {:rail_timer, :ping, _token}, _delay}

    hello(rail)
    assert_receive {:scheduled, {:rail_timer, :ping, _token} = ping, 60_000}
    send(rail, ping)
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 2}, <<>>}}
    # The next ping is set, and every inbound frame set the idle bound afresh.
    assert_receive {:scheduled, {:rail_timer, :ping, _next}, 60_000}
    assert_receive {:scheduled, {:rail_timer, :idle, _again}, 150_000}

    # A stale timer's word changes nothing.
    send(rail, ping)
    send(rail, {:rail_timer, :idle, make_ref()})
    assert :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 3}, <<>>}}
  end

  test "no inbound frame for 150 s closes the session 1002, at either end", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx, captured_timers())
    hello(rail)
    responder = Process.monitor(connection(ctx))

    idle = last_scheduled(:idle)
    send(rail, idle)
    assert_receive {:rail, ^rail, {:closed, :idle}}
    assert_receive {:DOWN, ^responder, :process, _pid, :normal}
  end

  # M75: a desktop's session is meant to stay up; the 2^20-frame rekey (below)
  # still bounds every key it uses.
  test "a desktop's session has no one-hour lifetime", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx, captured_timers())
    assert %{"seq" => 1} = hello(rail)

    assert_received {:scheduled, {:rail_timer, :idle, _idle}, 150_000}
    refute_received {:scheduled, {:rail_timer, :lifetime, _token}, _delay}
  end

  test "each direction rekeys after exactly 2^20 frames, as the responder does", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx)
    hello(rail)

    # Both ends of both directions at the bound: the next frame each way rekeys.
    :sys.replace_state(rail, fn state -> %{state | noise: at_bound(state.noise)} end)

    :sys.replace_state(connection(ctx), fn state ->
      put_in(state.session.noise, at_bound(state.session.noise))
    end)

    assert :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 2}, <<>>}}
    assert %{send_frames: 1, receive_frames: 1} = :sys.get_state(rail).noise
  end

  test "an initiator that does not rekey at 2^20 is refused by the responder", ctx do
    ctx = start_responder(ctx)
    assert {:ok, rail} = open(ctx)
    hello(rail)

    # Only the responder reached the bound: its new key reads nothing the
    # session still sends under the old one.
    :sys.replace_state(connection(ctx), fn state ->
      put_in(state.session.noise, at_bound(state.session.noise))
    end)

    assert :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:closed, {:remote, 1002, "mobile protocol error"}}}
  end

  # -- a responder the test plays ----------------------------------------------

  defp manual_listener(ctx) do
    path = Path.join(ctx.root, "m.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:packet, 4}, {:active, false}, {:ifaddr, {:local, path}}])

    {listen, path}
  end

  defp open_manual(ctx, path, mode, extra \\ []) do
    keys = [
      static_keypair: ctx.device,
      remote_static: ctx.responder_keypair.public,
      connect: fn -> :gen_tcp.connect({:local, path}, 0, [:binary, active: false]) end
    ]

    Rail.open(@route, mode, keys ++ extra)
  end

  # Accepts the session's stream and answers its handshake for `mode`, for
  # `owner` (the test, when a task plays the responder's handshake).
  defp accept_handshake(listen, mode, ctx, psk \\ nil, owner \\ self()) do
    {:ok, socket} = :gen_tcp.accept(listen, 10_000)
    {:ok, frame} = :gen_tcp.recv(socket, 0, 10_000)
    {:message, first} = Carrier.decode(frame)
    assert {:ok, ^mode, _body} = Noise.parse_prelude(first, mode)
    keys = [static_keypair: ctx.responder_keypair] ++ if(psk, do: [psk: psk], else: [])
    {:ok, noise} = Noise.initialize(:responder, mode, keys)
    {:ok, <<>>, noise} = Noise.read_handshake(noise, first)
    {:ok, reply, noise} = Noise.write_handshake(noise, <<>>)
    :ok = :gen_tcp.send(socket, Carrier.message(reply))
    {:ok, initiator_key} = Noise.remote_static(noise)
    :ok = :gen_tcp.controlling_process(socket, owner)
    %{socket: socket, noise: noise, initiator_key: initiator_key}
  end

  # A task answers the handshake while the test opens the session; the socket
  # is the test's afterwards.
  defp handshake_task(listen, mode, ctx, psk \\ nil) do
    test_pid = self()
    Task.async(fn -> accept_handshake(listen, mode, ctx, psk, test_pid) end)
  end

  defp server_send(responder, type, payload, seq, bytes \\ <<>>) do
    {:ok, plaintext} = Protocol.encode_server_frame(type, payload, seq, bytes)
    {:ok, ciphertext, noise} = Noise.encrypt(responder.noise, plaintext)
    :ok = :gen_tcp.send(responder.socket, Carrier.message(ciphertext))
    %{responder | noise: noise}
  end

  defp read_frame(socket) do
    {:ok, frame} = :gen_tcp.recv(socket, 0, 10_000)
    Carrier.decode(frame)
  end

  describe "against a responder the test plays" do
    setup ctx, do: Map.put(ctx, :responder_keypair, Noise.generate_keypair())

    test "the M75 modes write their own preludes and keys", ctx do
      {listen, path} = manual_listener(ctx)
      psk = :crypto.strong_rand_bytes(32)

      for {mode, extra, responder_psk} <- [
            {:ikpsk2_enroll, [psk: psk], psk},
            {:ik_move, [], nil},
            {:ik, [], nil}
          ] do
        task = handshake_task(listen, mode, ctx, responder_psk)
        assert {:ok, rail} = open_manual(ctx, path, mode, extra)
        responder = Task.await(task)
        assert responder.initiator_key == ctx.device.public

        # The transport works both ways under the keys the handshake made.
        assert :ok = Rail.send_event(rail, "ping", %{})
        {:message, ciphertext} = read_frame(responder.socket)
        {:ok, plaintext, noise} = Noise.decrypt(responder.noise, ciphertext)
        assert {:ok, %{type: "ping", seq: 1}} = Protocol.decode_client_frame(plaintext)
        server_send(%{responder | noise: noise}, "pong", %{}, 1)
        assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 1}, <<>>}}
        assert :ok = Rail.close(rail)
      end
    end

    test "a server frame out of sequence or at another version closes 1002", ctx do
      {listen, path} = manual_listener(ctx)

      for {seq, version, why} <- [{2, 2, {:seq, 2, 1}}, {1, 3, {:version, 3}}] do
        task = handshake_task(listen, :ik, ctx)
        assert {:ok, rail} = open_manual(ctx, path, :ik)
        responder = Task.await(task)

        {:ok, plaintext} = Protocol.encode_server_frame("pong", %{}, seq, <<>>)
        plaintext = if version == 2, do: plaintext, else: at_version(plaintext, version)
        {:ok, ciphertext, _noise} = Noise.encrypt(responder.noise, plaintext)
        :ok = :gen_tcp.send(responder.socket, Carrier.message(ciphertext))

        assert_receive {:rail, ^rail, {:closed, {:protocol_error, reason}}}
        assert reason == why or match?({:unsupported_protocol_version, _, 3}, reason)
        assert {:close, 1002, "mobile protocol error"} = read_frame(responder.socket)
      end
    end

    test "an event_part run out of order, or broken by another event, closes 1002", ctx do
      {listen, path} = manual_listener(ctx)
      json = Jason.encode!(%{"t" => "pong"})
      half = div(byte_size(json), 2)
      <<first::binary-size(half), second::binary>> = json

      runs = [
        {[{"event_part", %{"index" => 1, "count" => 2}, second}], :event_part_out_of_order},
        {[{"event_part", %{"index" => 0, "count" => 2}, first}, {"pong", %{}, <<>>}],
         :event_inside_event_part_run},
        {[
           {"event_part", %{"index" => 0, "count" => 2}, first},
           {"event_part", %{"index" => 1, "count" => 3}, second}
         ], :event_part_out_of_order}
      ]

      for {frames, why} <- runs do
        task = handshake_task(listen, :ik, ctx)
        assert {:ok, rail} = open_manual(ctx, path, :ik)
        responder = Task.await(task)

        frames
        |> Enum.with_index(1)
        |> Enum.reduce(responder, fn {{type, payload, bytes}, seq}, responder ->
          server_send(responder, type, payload, seq, bytes)
        end)

        assert_receive {:rail, ^rail, {:closed, {:protocol_error, ^why}}}
        refute_received {:rail, ^rail, {:event, _header, _tail}}
      end
    end

    test "a whole run is the event it carries, at its first frame's seq", ctx do
      {listen, path} = manual_listener(ctx)
      task = handshake_task(listen, :ik, ctx)
      assert {:ok, rail} = open_manual(ctx, path, :ik)
      responder = Task.await(task)

      json = Jason.encode!(%{"t" => "pair_denied", "reason" => "denied"})
      <<first::binary-size(10), second::binary>> = json

      responder
      |> server_send("event_part", %{"index" => 0, "count" => 2}, 1, first)
      |> server_send("event_part", %{"index" => 1, "count" => 2}, 2, second)
      |> server_send("pong", %{}, 3)

      assert_receive {:rail, ^rail,
                      {:event, %{"t" => "pair_denied", "seq" => 1, "reason" => "denied"}, <<>>}}

      assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 3}, <<>>}}
    end

    test "an enrollment session closes 1000 after its hour", ctx do
      {listen, path} = manual_listener(ctx)
      psk = :crypto.strong_rand_bytes(32)
      task = handshake_task(listen, :ikpsk2_enroll, ctx, psk)

      assert {:ok, rail} =
               open_manual(ctx, path, :ikpsk2_enroll, [psk: psk] ++ captured_timers())

      _responder = Task.await(task)
      assert :ok = Rail.send_event(rail, "ping", %{})

      send(rail, last_scheduled(:lifetime))
      assert_receive {:rail, ^rail, {:closed, :lifetime}}
    end

    test "a move session has no one-hour lifetime; an enrollment session keeps it", ctx do
      {listen, path} = manual_listener(ctx)
      psk = :crypto.strong_rand_bytes(32)

      for {mode, extra, responder_psk, lifetime?} <- [
            {:ik_move, [], nil, false},
            {:ikpsk2_enroll, [psk: psk], psk, true}
          ] do
        task = handshake_task(listen, mode, ctx, responder_psk)
        assert {:ok, rail} = open_manual(ctx, path, mode, extra ++ captured_timers())
        _responder = Task.await(task)

        # A call the session answers only after it armed its timers.
        assert :ok = Rail.send_event(rail, "ping", %{})
        assert_received {:scheduled, {:rail_timer, :idle, _idle}, 150_000}

        if lifetime?,
          do: assert_received({:scheduled, {:rail_timer, :lifetime, _token}, 3_600_000}),
          else: refute_received({:scheduled, {:rail_timer, :lifetime, _token}, _delay})

        assert :ok = Rail.close(rail)
      end
    end

    test "an owner that exits takes the session down with a close 1000", ctx do
      {listen, path} = manual_listener(ctx)
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, rail} = open_manual(ctx, path, :ik)
          send(test_pid, {:opened, rail})
          receive do: (:exit -> :ok)
        end)

      responder = accept_handshake(listen, :ik, ctx)
      assert_receive {:opened, rail}
      rail_down = Process.monitor(rail)
      send(owner, :exit)
      assert {:close, 1000, "session closed"} = read_frame(responder.socket)
      assert_receive {:DOWN, ^rail_down, :process, ^rail, :normal}
    end

    test "a stream the responder ends with no close frame ends the session", ctx do
      {listen, path} = manual_listener(ctx)
      task = handshake_task(listen, :ik, ctx)
      assert {:ok, rail} = open_manual(ctx, path, :ik)
      responder = Task.await(task)

      :ok = :gen_tcp.close(responder.socket)
      assert_receive {:rail, ^rail, {:closed, :remote_ended}}
    end
  end

  test "an open outside the contract fails before anything starts", ctx do
    keys = [static_keypair: ctx.device, remote_static: ctx.gateway_public_key, helper: :none]

    assert {:error, :invalid_node_id} = Rail.open(%{@route | node_id: "79B5"}, :ik, keys)

    assert {:error, :invalid_static_keypair} =
             Rail.open(@route, :ik, Keyword.put(keys, :static_keypair, %{}))

    assert {:error, :invalid_remote_static} =
             Rail.open(@route, :ik, Keyword.put(keys, :remote_static, <<1>>))

    assert {:error, :psk_not_allowed} = Rail.open(@route, :ik, keys ++ [psk: <<0::256>>])
    assert {:error, :invalid_psk} = Rail.open(@route, :ikpsk2_enroll, keys)
    assert {:error, :no_helper} = Rail.open(@route, :ik, Keyword.delete(keys, :helper))
    assert_raise FunctionClauseError, fn -> Rail.open(@route, :ikpsk2, keys) end
  end

  test "a rail with no helper to dial through fails the open, not the opener", ctx do
    keys = [
      static_keypair: ctx.device,
      remote_static: ctx.gateway_public_key,
      helper: :rail_test_no_helper
    ]

    assert {:error, {:dial, :not_ready}} = Rail.open(@route, :ik, keys)
    assert Process.alive?(self())
  end

  defp at_bound(noise), do: %{noise | send_frames: @rekey_frames, receive_frames: @rekey_frames}

  # The same header with another `v`: a responder speaking another version.
  defp at_version(<<size::unsigned-big-32, json::binary-size(size), rest::binary>>, version) do
    header = json |> Jason.decode!() |> Map.put("v", version) |> Jason.encode!()
    <<byte_size(header)::unsigned-big-32, header::binary, rest::binary>>
  end

  defp last_scheduled(kind) do
    assert_receive {:scheduled, {:rail_timer, ^kind, _token} = message, _delay}
    drain_scheduled(kind, message)
  end

  defp drain_scheduled(kind, message) do
    receive do
      {:scheduled, {:rail_timer, ^kind, _token} = later, _delay} -> drain_scheduled(kind, later)
    after
      0 -> message
    end
  end
end
