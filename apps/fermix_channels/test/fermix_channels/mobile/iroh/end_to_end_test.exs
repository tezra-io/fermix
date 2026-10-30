defmodule FermixChannels.Mobile.Iroh.EndToEndTest do
  @moduledoc """
  M62 stage 4's proof with the real helper: a paired phone's session carried
  over iroh, end to end, through the real `fermix-iroh`, the bridge socket, a
  `BridgeConnection` and the real `Session` with real Noise.

  The phone is the helper repository's dev-only `test_peer`, a pipe between
  stdin/stdout and one iroh stream, dialed directly at the helper's UDP socket
  (no relay can be trusted locally by the released helper, whose TLS roots are
  compiled in); this test speaks the mobile protocol through it.

  M75's rail (§4.2) runs the same way: `Mobile.Rail` dials the listening
  helper through a second, dial-only helper (helper protocol 3), at the
  listener's UDP address, and carries a desktop's session to the same
  `Session`.

  Opt-in, because it needs both binaries built from a `fermix-iroh` checkout
  (`cargo build --release --locked`, then `--example test_peer`):

      FERMIX_IROH_DIR=../fermix-iroh mix test --only iroh_end_to_end

  Run without `FERMIX_IROH_DIR` it fails, never passes empty.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh
  alias FermixChannels.Mobile.Iroh.Carrier
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.Relays.Source
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Rail
  alias FermixTestSupport.PrimaryHome
  alias FermixTestSupport.SafeRm

  @moduletag :iroh_end_to_end
  @moduletag timeout: 120_000

  @device_id "5d0f2c7e-3b8a-4c1d-9e6f-0a7b8c9d1e2f"
  @timeout_ms 15_000
  # Never resolves, so nothing leaves the machine for a relay.
  @relay %{"url" => "https://relay.invalid/", "quic_port" => 7842}

  setup do
    dir = System.fetch_env!("FERMIX_IROH_DIR") |> Path.expand()
    helper = Path.join(dir, "target/release/fermix-iroh")
    peer = Path.join(dir, "target/release/examples/test_peer")

    for binary <- [helper, peer],
        do: assert(File.regular?(binary), "#{binary} is not built")

    # Short: the bridge socket's path must fit a Unix socket address.
    root = Path.join(System.tmp_dir!(), "fx-e2e-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    PrimaryHome.booted!(root)
    {:ok, identity} = Identity.ensure(root: root)
    revoked = start_supervised!({Agent, fn -> false end})

    %{
      root: root,
      helper: helper,
      peer: peer,
      gateway_public_key: identity.gateway_public_key,
      device: Noise.generate_keypair(),
      revoked: revoked
    }
  end

  test "a paired phone's session over iroh: hello, renewal, revocation, close", ctx do
    names = names()
    registry = start_registry(names, ctx.revoked)
    {endpoint_id, port} = start_rail(ctx, names, registry)

    # A session: Noise IK, hello, ping, then the phone ends it.
    first = open_peer(ctx, endpoint_id, port)
    {noise, ack} = hello(first, ctx)
    assert %{"t" => "hello_ack"} = ack
    assert %{"kind" => "iroh", "node_id" => ^endpoint_id} = List.last(ack["candidates"])
    {pong, _noise} = round_trip(first, "ping", %{}, 2, noise)
    assert %{"t" => "pong", "seq" => 2} = pong
    close_peer(first)

    # An hourly renewal is a new stream with a new iroh key, and no pairing.
    second = open_peer(ctx, endpoint_id, port)
    {_noise, %{"t" => "hello_ack"}} = hello(second, ctx)

    # Revocation ends the live session at once.
    assert :ok = DeviceRegistry.revoke(registry, @device_id)
    assert {:close, 4003, "device revoked"} = read_frame(second)
    assert_peer_exits(second)

    # The same Noise key stays refused over yet another iroh key.
    third = open_peer(ctx, endpoint_id, port)
    {:ok, noise} = initiator(ctx)
    {:ok, first_wire, _noise} = Noise.write_handshake(noise, <<>>)
    write_frame(third, Carrier.message(first_wire))
    assert {:close, 1002, "mobile protocol error"} = read_frame(third)
    assert_peer_exits(third)

    # That refusal sent the helper protocol 2's close for the third peer; the
    # helper took it and still carries the next peer's session to its own.
    fourth = open_peer(ctx, endpoint_id, port)
    write_frame(fourth, Carrier.message("not a prelude"))
    assert {:close, 1002, _reason} = read_frame(fourth)
    assert_peer_exits(fourth)
    assert %{state: :ready} = Helper.status(names.iroh_helper)
  end

  test "the rail: a desktop's session dialed through a dial-only helper", ctx do
    names = names()
    registry = start_registry(names, ctx.revoked)
    {endpoint_id, port} = start_rail(ctx, names, registry)
    {dialer, dial_root} = start_dialer(ctx)

    route = %{
      node_id: endpoint_id,
      relays: [@relay],
      relays_rev: "0123456789abcdef",
      addrs: ["127.0.0.1:#{port}"]
    }

    keys = [helper: dialer, static_keypair: ctx.device, remote_static: ctx.gateway_public_key]
    assert {:ok, rail} = Rail.open(route, :ik, keys)

    hello = %{
      "device_id" => @device_id,
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    assert :ok = Rail.send_event(rail, "hello", hello)
    assert_receive {:rail, ^rail, {:event, %{"t" => "hello_ack", "seq" => 1}, <<>>}}, @timeout_ms
    assert :ok = Rail.send_event(rail, "ping", %{})
    assert_receive {:rail, ^rail, {:event, %{"t" => "pong", "seq" => 2}, <<>>}}, @timeout_ms

    # The dialed stream ended with the session, and the helper said so; the
    # dial's socket is gone.
    rail_down = Process.monitor(rail)
    assert :ok = Rail.close(rail)
    assert_receive {:DOWN, ^rail_down, :process, ^rail, :normal}
    assert_dials_drained(dialer)
    assert [] = Path.wildcard(Path.join([dial_root, "mobile", "dial-*.sock"]))

    # A second session on a fresh dial; then the device is revoked under it.
    assert {:ok, rail} = Rail.open(route, :ik, keys)
    assert :ok = Rail.send_event(rail, "hello", hello)
    assert_receive {:rail, ^rail, {:event, %{"t" => "hello_ack"}, <<>>}}, @timeout_ms
    assert :ok = DeviceRegistry.revoke(registry, @device_id)
    assert_receive {:rail, ^rail, {:closed, {:remote, 4003, "device revoked"}}}, @timeout_ms
    assert_dials_drained(dialer)

    # The revoked key is refused in the handshake of the next session.
    assert {:error, {:remote, 1002, "mobile protocol error"}} = Rail.open(route, :ik, keys)
    assert %{state: :ready} = Helper.status(names.iroh_helper)
    assert %{state: :ready} = Helper.status(dialer)
  end

  # The dial-only helper, in a home of its own (a desktop's), and that home.
  defp start_dialer(ctx) do
    dial_root = Path.join(System.tmp_dir!(), "fx-e2e-d-#{System.unique_integer([:positive])}")
    SafeRm.mark!(dial_root)
    on_exit(fn -> SafeRm.rm_rf!(dial_root) end)
    revisions = Source.parse!(%{"revisions" => [%{"iroh" => "1.3.0", "relays" => [@relay]}]})

    dialer =
      start_supervised!(
        {Helper,
         name: nil,
         mode: :dial,
         root: dial_root,
         binary_path: ctx.helper,
         revisions: revisions,
         emit: fn _status, _failures, _class -> :ok end},
        id: :dialer
      )

    await_ready(dialer, 200)
    {dialer, dial_root}
  end

  # The helper forgets a dial once it says the stream ended.
  defp assert_dials_drained(dialer, attempts \\ 100) do
    case :sys.get_state(dialer).dials do
      dials when dials == %{} ->
        :ok

      _open when attempts > 0 ->
        Process.sleep(50)
        assert_dials_drained(dialer, attempts - 1)

      open ->
        flunk("dials still open: #{inspect(open)}")
    end
  end

  # -- the rail ----------------------------------------------------------------

  defp start_rail(ctx, names, registry) do
    revisions = Source.parse!(%{"revisions" => [%{"iroh" => "1.3.0", "relays" => [@relay]}]})

    opts = [
      root: ctx.root,
      names: names,
      switch: fn -> true end,
      session_opts: session_opts(ctx, names, registry),
      helper_opts: [
        binary_path: ctx.helper,
        revisions: revisions,
        list_devices: fn _store -> {:ok, []} end
      ]
    ]

    Logger.put_module_level(Helper, :info)
    on_exit(fn -> Logger.delete_module_level(Helper) end)

    {_result, log} =
      with_log([level: :info], fn ->
        start_supervised!({Iroh, opts})
        await_ready(names.iroh_helper, 200)
      end)

    %{endpoint_id: endpoint_id} = Helper.status(names.iroh_helper)
    [_all, port] = Regex.run(~r/bound UDP sockets: .*?(?:0\.0\.0\.0|127\.0\.0\.1):(\d+)/, log)
    {endpoint_id, String.to_integer(port)}
  end

  defp await_ready(helper, attempts) do
    case Helper.status(helper) do
      %{state: :ready} ->
        Process.sleep(200)

      %{state: state} = status when state in [:failed, :helper_missing] or attempts == 0 ->
        flunk("the rail did not become ready: #{inspect(status)}")

      _starting ->
        Process.sleep(50)
        await_ready(helper, attempts - 1)
    end
  end

  defp session_opts(ctx, names, registry) do
    device_public = ctx.device.public
    revoked = ctx.revoked

    [
      identity_root: ctx.root,
      device_store: names.device_store,
      device_registry: registry,
      iroh_helper: names.iroh_helper,
      find_device: fn _store, key ->
        if key == device_public and not Agent.get(revoked, & &1),
          do: {:ok, %{device_id: @device_id}},
          else: {:error, :not_found}
      end,
      update_device: fn _store, @device_id, _changes -> {:ok, %{device_id: @device_id}} end,
      profile_name: "Orbit",
      primary_epoch: 1,
      history_head: fn "main" -> {:ok, 0} end,
      read_frontier: fn "main" -> {:ok, 0} end,
      pending_approvals: fn _profile -> [] end,
      pairing_pending: fn -> :none end,
      discover: fn -> {:ok, []} end
    ]
  end

  defp start_registry(names, revoked) do
    start_supervised!(
      {DeviceRegistry,
       name: names.device_registry,
       device_store: names.device_store,
       authorize_device: fn _store, @device_id ->
         if Agent.get(revoked, & &1),
           do: {:error, {:device_not_found, @device_id}},
           else: {:ok, %{device_id: @device_id}}
       end,
       delete_device: fn _store, @device_id -> Agent.update(revoked, fn _ -> true end) end,
       revoke_requests: fn _id -> :ok end,
       relays_changed: fn -> Helper.relays_acknowledged(names.iroh_helper) end}
    )
  end

  defp names do
    suffix = System.unique_integer([:positive])

    %{
      device_store: :"e2e_store_#{suffix}",
      device_registry: :"e2e_registry_#{suffix}",
      iroh_helper: :"e2e_helper_#{suffix}",
      bridge: :"e2e_bridge_#{suffix}",
      bridge_connections: :"e2e_connections_#{suffix}"
    }
  end

  # -- the phone -----------------------------------------------------------------

  defp open_peer(ctx, endpoint_id, port) do
    Port.open({:spawn_executable, ctx.peer}, [
      :binary,
      :exit_status,
      args: [endpoint_id, "127.0.0.1:#{port}"]
    ])
    |> then(&%{port: &1, buffer: :ets.new(:buffer, [:set, :private])})
    |> tap(&:ets.insert(&1.buffer, {:bytes, <<>>}))
  end

  defp close_peer(peer) do
    Port.close(peer.port)
  end

  defp assert_peer_exits(peer) do
    port = peer.port
    assert_receive {^port, {:exit_status, 0}}, @timeout_ms
  end

  defp initiator(ctx) do
    Noise.initialize(:initiator, :ik,
      static_keypair: ctx.device,
      remote_static: ctx.gateway_public_key
    )
  end

  defp hello(peer, ctx) do
    {:ok, noise} = initiator(ctx)
    {:ok, first_wire, noise} = Noise.write_handshake(noise, <<>>)
    write_frame(peer, Carrier.message(first_wire))
    assert {:message, second_wire} = read_frame(peer)
    {:ok, <<>>, noise} = Noise.read_handshake(noise, second_wire)

    hello = %{
      "device_id" => @device_id,
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    {ack, noise} = round_trip(peer, "hello", hello, 1, noise)
    {noise, ack}
  end

  defp round_trip(peer, type, payload, seq, noise) do
    header =
      payload
      |> Map.merge(%{"v" => Protocol.protocol_version(), "t" => type, "seq" => seq})
      |> Jason.encode!()

    {:ok, ciphertext, noise} =
      Noise.encrypt(noise, <<byte_size(header)::unsigned-big-32, header::binary>>)

    write_frame(peer, Carrier.message(ciphertext))
    assert {:message, response} = read_frame(peer)
    {:ok, plaintext, noise} = Noise.decrypt(noise, response)
    <<size::unsigned-big-32, json::binary-size(size), _bytes::binary>> = plaintext
    {Jason.decode!(json), noise}
  end

  defp write_frame(peer, iodata) do
    frame = IO.iodata_to_binary(iodata)
    true = Port.command(peer.port, <<byte_size(frame)::unsigned-big-32, frame::binary>>)
  end

  # The peer's stdout is a byte stream; frames are cut from it here.
  defp read_frame(peer) do
    [{:bytes, buffered}] = :ets.lookup(peer.buffer, :bytes)

    case buffered do
      <<size::unsigned-big-32, frame::binary-size(size), rest::binary>> ->
        :ets.insert(peer.buffer, {:bytes, rest})
        Carrier.decode(frame)

      _partial ->
        :ets.insert(peer.buffer, {:bytes, buffered <> receive_bytes(peer)})
        read_frame(peer)
    end
  end

  defp receive_bytes(%{port: port}) do
    receive do
      {^port, {:data, bytes}} -> bytes
      {^port, {:exit_status, status}} -> flunk("the peer exited with #{status}")
    after
      @timeout_ms -> flunk("no bytes from the peer")
    end
  end
end
