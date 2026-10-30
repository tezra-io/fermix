defmodule FermixChannels.Mobile.DesktopSessionTest do
  @moduledoc """
  A desktop engine's session on the primary (M75 §3, §5.2, §5.3), through the
  real Noise `IK` handshake and codec: what its kind may send, its peer, and
  the frames the primary sends it.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.Chunks
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver

  @desktop_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @phone_id "2a9b8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d"
  @seen ~U[2026-10-21 08:00:00Z]

  # Reports every whole event, through the session, to the test.
  defmodule TunnelFamily do
    @moduledoc false
    @behaviour FermixChannels.Desktop.Family

    @impl true
    def init(context), do: {:ok, context}

    @impl true
    def handle_event(type, fields, payload, context) do
      send(context.session, {:driver_to_test, {:family_event, type, fields, payload}})
      {:ok, context}
    end

    @impl true
    def handle_info(_message, context), do: {:ok, context}

    @impl true
    def terminate(_reason, _context), do: :ok
  end

  setup do
    suffix = System.unique_integer([:positive])
    peers = Module.concat(__MODULE__, "Peers#{suffix}")
    peer_supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: peers, peer_supervisor: peer_supervisor}
    )

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, id -> {:ok, row(id)} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    %{
      gateway: Noise.generate_keypair(),
      desktop: Noise.generate_keypair(),
      phone: Noise.generate_keypair(),
      peers: peers,
      peer_supervisor: peer_supervisor,
      registry: registry
    }
  end

  test "a desktop's hello starts its peer, and a chunked line reaches its family whole", ctx do
    {driver, client} = ready_desktop!(ctx, %{companion: TunnelFamily})

    assert [%{device_id: @desktop_id, connected_since: @seen}] = Peer.connected(ctx.peers)

    line = :crypto.strong_rand_bytes(100_000)
    [{0, false, first}, {1, true, second}] = Chunks.split(line)
    client = Driver.client_send(driver, client, "companion_open", %{"channel" => 4}, 2)
    assert_receive {:family_event, "companion_open", %{"channel" => 4}, <<>>}

    line_fields = %{"channel" => 4, "index" => 0, "last" => false}
    client = Driver.client_send(driver, client, "companion_line", line_fields, 3, first)

    _client =
      Driver.client_send(
        driver,
        client,
        "companion_line",
        %{line_fields | "index" => 1, "last" => true},
        4,
        second
      )

    assert_receive {:family_event, "companion_line", %{"channel" => 4}, ^line}
  end

  test "a family this primary does not serve yet is unsupported_event, and the session stays open",
       ctx do
    {driver, client} = ready_desktop!(ctx, %{})

    client =
      Driver.client_send(driver, client, "manage", manage_fields(), 2, ~s({"section":"agent"}))

    {[{error, <<>>}], client} = Driver.client_receive(driver, client)
    assert %{"t" => "error", "code" => "unsupported_event", "seq" => 2} = error

    client = Driver.client_send(driver, client, "ping", %{}, 3)

    assert {[{%{"t" => "pong", "seq" => 3}, <<>>}], _client} =
             Driver.client_receive(driver, client)
  end

  test "a desktop may not send a phone's chat, nor a phone a desktop's events", ctx do
    {desktop, desktop_client} = ready_desktop!(ctx, %{companion: TunnelFamily})

    message = %{
      "client_msg_id" => "c-1",
      "profile_id" => "main",
      "text" => "hello",
      "attach_ids" => []
    }

    desktop_client = Driver.client_send(desktop, desktop_client, "msg", message, 2)
    {[{refusal, <<>>}], desktop_client} = Driver.client_receive(desktop, desktop_client)
    assert refusal["code"] == "unsupported_event"

    desktop_client = Driver.client_send(desktop, desktop_client, "unpair", %{}, 3)
    {[{refusal, <<>>}], _client} = Driver.client_receive(desktop, desktop_client)
    assert refusal["code"] == "unsupported_event"

    {phone, phone_client} = ready_phone!(ctx)
    phone_client = Driver.client_send(phone, phone_client, "companion_open", %{"channel" => 1}, 2)
    {[{refusal, <<>>}], phone_client} = Driver.client_receive(phone, phone_client)
    assert refusal["code"] == "unsupported_event"

    phone_client = Driver.client_send(phone, phone_client, "ping", %{}, 3)
    assert {[{%{"t" => "pong"}, <<>>}], _client} = Driver.client_receive(phone, phone_client)
    refute_received {:family_event, _type, _fields, _payload}
  end

  test "the primary's frames reach the desktop through its peer, cut and in order", ctx do
    {driver, client} = ready_desktop!(ctx, %{})
    payload = :crypto.strong_rand_bytes(130_000)
    event = %{"t" => "manage_result", "call_id" => "call-1"}

    assert :ok = Peer.send(@desktop_id, event, payload, registry: ctx.peers)

    {received, _client} =
      Enum.flat_map_reduce(1..3, client, fn _n, client ->
        Driver.client_receive(driver, client)
      end)

    assert Enum.map(received, fn {header, _bytes} -> {header["index"], header["seq"]} end) ==
             [{0, 2}, {1, 3}, {2, 4}]

    assert {:done, ^payload} =
             Enum.reduce_while(received, {:more, Chunks.new(4_194_304)}, fn
               {header, bytes}, {:more, acc} ->
                 case Chunks.add(acc, header["index"], header["last"], bytes) do
                   {:more, acc} -> {:cont, {:more, acc}}
                   done -> {:halt, done}
                 end
             end)
  end

  test "no phone event reaches a desktop: a broadcast skips it, and one sent to it is dropped",
       ctx do
    {driver, client} = ready_desktop!(ctx, %{})
    text_done = %{"t" => "text_done", "turn_id" => "t-1", "server_seq" => 9, "text" => "hi"}

    :ok = DeviceRegistry.broadcast(ctx.registry, "main", text_done)
    assert :ok = DeviceRegistry.send_device_event(ctx.registry, @desktop_id, text_done)

    # Nothing went out for either: the next frame is the pong, right after hello_ack.
    client = Driver.client_send(driver, client, "ping", %{}, 2)

    assert {[{%{"t" => "pong", "seq" => 2}, <<>>}], _client} =
             Driver.client_receive(driver, client)
  end

  test "a gap in a chunked payload closes the desktop's session as a protocol error", ctx do
    {driver, client} = ready_desktop!(ctx, %{companion: TunnelFamily})
    fields = %{"channel" => 2, "index" => 1, "last" => true}
    client = Driver.client_send(driver, client, "companion_line", fields, 2, "late")

    assert {{:chunk_gap, 0, 1}, {1002, "mobile protocol error"}, [], _client} =
             Driver.client_closed(driver, client)
  end

  test "a peer that stops closes its desktop's session", ctx do
    {driver, client} = ready_desktop!(ctx, %{})
    {:ok, peer, _value} = Peer.lookup(ctx.peers, @desktop_id)
    Process.exit(peer, :kill)

    assert {{:desktop_peer_down, :killed}, {1011, "desktop peer failed"}, [], _client} =
             Driver.client_closed(driver, client)
  end

  test "a peer that stops answering closes its desktop's session as the primary's failure",
       ctx do
    supervisor = ctx.peer_supervisor

    {driver, client} =
      ready!(ctx, ctx.desktop, @desktop_id,
        start_desktop_peer: &Peer.start(supervisor, Keyword.put(&1, :families, %{})),
        deliver_desktop_event: fn _peer, _event ->
          {:close, {:desktop_peer_unavailable, {:timeout, :deliver}}}
        end
      )

    client = Driver.client_send(driver, client, "companion_open", %{"channel" => 1}, 2)

    assert {{:desktop_peer_unavailable, {:timeout, :deliver}}, {1011, "desktop peer failed"}, [],
            _client} = Driver.client_closed(driver, client)
  end

  test "a desktop whose peer does not start is closed as the primary's failure, 1011", ctx do
    driver =
      Driver.start!(session_opts(ctx) ++ [start_desktop_peer: fn _opts -> {:error, :no_room} end])

    client = Driver.handshake!(driver, ik_client(ctx, ctx.desktop))
    client = Driver.client_send(driver, client, "hello", hello(@desktop_id), 1)

    assert {:no_room, {1011, "desktop peer failed"}, [], _client} =
             Driver.client_closed(driver, client)
  end

  # M75: a desktop's link is meant to stay up; the 2^20-frame rekey still bounds
  # its keys. A phone's session keeps its hour.
  test "a desktop's session has no one-hour lifetime; a phone's keeps it", ctx do
    test = self()

    timers = [
      schedule_session_timer: fn message, delay ->
        send(test, {:session_timer, message, delay})
        make_ref()
      end
    ]

    ready!(ctx, ctx.phone, @phone_id, timers)
    assert_received {:session_timer, {:mobile_session_expired, _token}, 3_600_000}

    supervisor = ctx.peer_supervisor
    start = &Peer.start(supervisor, Keyword.put(&1, :families, %{}))
    ready!(ctx, ctx.desktop, @desktop_id, [start_desktop_peer: start] ++ timers)
    refute_received {:session_timer, _message, _delay}
  end

  test "a key the primary holds no row for is told it is unknown (4003), not a protocol error",
       ctx do
    stranger = Noise.generate_keypair()

    driver =
      Driver.start!(
        session_opts(ctx) ++
          [
            find_device: fn :store, key ->
              {:error, {:noise_identity_not_found, Base.encode64(key)}}
            end
          ]
      )

    assert {:ok, first, client} = Noise.write_handshake(ik_client(ctx, stranger), <<>>)
    Driver.wire(driver, first)

    assert {:unknown_device, {4003, "device unknown"}, [], _client} =
             Driver.client_closed(driver, client)
  end

  defp ik_client(ctx, keypair) do
    {:ok, client} =
      Noise.initialize(:initiator, :ik,
        static_keypair: keypair,
        remote_static: ctx.gateway.public
      )

    client
  end

  defp hello(device_id) do
    %{
      "device_id" => device_id,
      "app_version" => "0.17.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }
  end

  defp session_opts(ctx) do
    keys = %{ctx.desktop.public => @desktop_id, ctx.phone.public => @phone_id}

    [
      peer: {127, 0, 0, 1},
      gateway_keypair: ctx.gateway,
      primary_epoch: 4,
      device_store: :store,
      device_registry: ctx.registry,
      desktop_peers: ctx.peers,
      desktop_peer_supervisor: ctx.peer_supervisor,
      find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
      update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
      wall_clock: fn -> @seen end,
      hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
      pending_approvals: fn "main" -> [] end
    ]
  end

  defp ready_desktop!(ctx, families) do
    supervisor = ctx.peer_supervisor

    ready!(ctx, ctx.desktop, @desktop_id,
      start_desktop_peer: fn opts ->
        Peer.start(supervisor, Keyword.put(opts, :families, families))
      end
    )
  end

  defp ready_phone!(ctx), do: ready!(ctx, ctx.phone, @phone_id, [])

  # A paired device's session through IK and hello, its hello_ack read.
  defp ready!(ctx, keypair, device_id, opts) do
    keys = %{ctx.desktop.public => @desktop_id, ctx.phone.public => @phone_id}

    driver =
      Driver.start!(
        [
          peer: {127, 0, 0, 1},
          gateway_keypair: ctx.gateway,
          primary_epoch: 4,
          device_store: :store,
          device_registry: ctx.registry,
          desktop_peers: ctx.peers,
          desktop_peer_supervisor: ctx.peer_supervisor,
          find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
          update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
          wall_clock: fn -> @seen end,
          hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
          pending_approvals: fn "main" -> [] end
        ] ++ opts
      )

    assert {:ok, client} =
             Noise.initialize(:initiator, :ik,
               static_keypair: keypair,
               remote_static: ctx.gateway.public
             )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => device_id,
      "app_version" => "0.17.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    client = Driver.client_send(driver, client, "hello", hello, 1)

    assert {[{%{"t" => "hello_ack", "seq" => 1}, <<>>}], client} =
             Driver.client_receive(driver, client)

    {driver, client}
  end

  defp row(@desktop_id),
    do: %{device_id: @desktop_id, name: "Studio Mac", kind: :desktop, executor: true}

  defp row(id), do: %{device_id: id, name: "Garden phone", kind: :phone}

  defp manage_fields do
    %{
      "call_id" => "call-1",
      "method" => "settings.get",
      "protocol_version" => 2,
      "index" => 0,
      "last" => true
    }
  end

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "desktop-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520},
      "primary_epoch" => 4
    }
  end
end
