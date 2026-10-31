defmodule FermixChannels.Desktop.RelayTest do
  @moduledoc """
  The desktop relay against the primary's real responder (M75 §6): a real
  `Mobile.Session` with real Noise behind the real bridge socket, reached
  through the relay's own `Mobile.Rail`. Only the dial (the bridge socket in
  place of the iroh helper) and the trust store's row are stood in for; every
  timer the relay sets is delivered by hand.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Home.DesktopLink

  @unreachable "The server fermix-vm is unreachable. Fermix keeps your message until it is back."

  # A family of the primary, reporting each event the desktop sends it.
  defmodule CaptureFamily do
    @moduledoc false
    @behaviour FermixChannels.Desktop.Family

    @impl true
    def init(context), do: {:ok, Keyword.fetch!(context.options, :test)}

    @impl true
    def handle_event(type, fields, payload, test) do
      send(test, {:primary_got, type, fields, payload})
      {:ok, test}
    end

    @impl true
    def handle_info(_message, test), do: {:ok, test}

    @impl true
    def terminate(_reason, _test), do: :ok
  end

  test "hello carries the desktop's id, its relay revision and the highest epoch seen; a higher epoch is kept" do
    test = self()

    primary =
      DesktopRail.primary!(
        epoch: 5,
        update_device: fn _store, id, changes ->
          send(test, {:hello_seen, id, changes})
          {:ok, DesktopRail.row()}
        end
      )

    root = DesktopRail.desktop_home!(primary, epoch: 3)
    relay = DesktopRail.start_relay!(root, primary, clock: fn -> ~U[2026-10-27 09:00:00Z] end)

    device_id = DesktopRail.device_id()
    relays_rev = DesktopRail.relays_rev()
    assert_receive {:hello_seen, ^device_id, %{relay_list_rev: ^relays_rev}}, 10_000

    assert %{
             name: "fermix-vm",
             connected: true,
             status: :connected,
             epoch: 5,
             since: ~U[2026-10-27 09:00:00Z]
           } = status = DesktopRail.await_connected(relay)

    assert status.sentence == "Fermix is connected to the server fermix-vm."
    assert {:ok, %{epoch: 5}} = DesktopLink.read(root)
    refute_received {:relay_emit, _status, _failures, _class}
  end

  # M75 lean v1 §4.3: reaching the server one epoch above the one a replace's
  # old server held is how this desktop sees the move to the new one done, so
  # every session the relay opens says the primary's epoch.
  test "every session it opens tells the Always On provisioner the primary's epoch" do
    primary = DesktopRail.primary!(epoch: 6)
    root = DesktopRail.desktop_home!(primary, epoch: 5)
    relay = DesktopRail.start_relay!(root, primary)

    pid = GenServer.whereis(relay)

    DesktopRail.await_connected(relay)
    assert_receive {:primary_reached, 6}, 10_000

    :ok = drop_sessions(primary)
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, 1_000}, 10_000
    send(pid, timer)
    DesktopRail.await_connected(relay)
    assert_receive {:primary_reached, 6}, 10_000
  end

  # M75 lean v1 §4.3: once a replace's move is done the home lives on the new
  # server, reached at the same node id, and the provisioner names it here.
  test "the server's new name after a replace is kept and said from then on" do
    primary = DesktopRail.primary!(epoch: 6)
    root = DesktopRail.desktop_home!(primary, epoch: 5)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    assert :ok = Relay.rename(relay, "fermix-general-5d2e")
    assert {:ok, %{primary: %{name: "fermix-general-5d2e"}, epoch: 6}} = DesktopLink.read(root)

    assert %{name: "fermix-general-5d2e", sentence: sentence} = Relay.status(relay)
    assert sentence == "Fermix is connected to the server fermix-general-5d2e."

    :ok = drop_sessions(primary)
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000

    assert {:error, {:unreachable, unreachable}} = Relay.open_channel(relay)
    assert unreachable =~ "The server fermix-general-5d2e is unreachable."
    refute unreachable =~ "fermix-vm"
  end

  # A hello_ack that names no epoch never reaches the relay: the rail's codec
  # refuses it (the primary's own codec will not even send one), and the
  # relay names that refusal a stale primary too.
  test "a hello_ack with a lower epoch is a stale primary: closed, said, and the epoch kept" do
    primary = DesktopRail.primary!(epoch: 9, hello_ack_builder: fn _state -> {:ok, ack(4)} end)
    root = DesktopRail.desktop_home!(primary, epoch: 6)
    relay = DesktopRail.start_relay!(root, primary)

    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000
    assert_receive {:relay_emit, :degraded, 1, :stale_primary}

    assert %{connected: false, status: :stale, epoch: 6, sentence: sentence} =
             Relay.status(relay)

    assert sentence ==
             "The server fermix-vm answered as an older copy of Fermix (epoch 4; this " <>
               "computer has seen 6), so Fermix does not use it. Fermix tries again in 1 s."

    assert {:ok, %{epoch: 6}} = DesktopLink.read(root)
  end

  test "a primary that refuses the epoch this desktop has seen is a stale primary too" do
    primary = DesktopRail.primary!(epoch: 4)
    root = DesktopRail.desktop_home!(primary, epoch: 7)
    relay = DesktopRail.start_relay!(root, primary)

    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000
    assert_receive {:relay_emit, :degraded, 1, :stale_primary}

    assert %{connected: false, status: :stale, epoch: 7, sentence: sentence} =
             Relay.status(relay)

    assert sentence =~ "older copy of Fermix"
    assert {:ok, %{epoch: 7}} = DesktopLink.read(root)
  end

  test "it reconnects after 1 s doubling to 60 s, and starts over once a session was up" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    {:ok, reach} = Agent.start_link(fn -> :down end)
    real = DesktopRail.bridge_connect(primary.bridge_socket)

    connect = fn ->
      case Agent.get(reach, & &1) do
        :down -> {:error, :econnrefused}
        :up -> real.()
      end
    end

    relay = DesktopRail.start_relay!(root, primary, connect: connect)
    pid = GenServer.whereis(relay)

    assert_receive {:relay_emit, :degraded, 1, :socket}, 10_000

    for delay <- [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000] do
      assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, ^delay}, 10_000
      assert %{connected: false, status: :unreachable, sentence: sentence} = Relay.status(relay)
      assert sentence =~ "Fermix tries again in #{div(delay, 1_000)} s."
      send(pid, timer)
    end

    # The eighth failure waits the longest again; the ninth attempt reaches
    # the primary, and the relay says it recovered once.
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, 60_000}, 10_000
    Agent.update(reach, fn _ -> :up end)
    send(pid, timer)
    assert %{connected: true} = DesktopRail.await_connected(relay)
    assert_receive {:relay_emit, :recovered, 8, :none}
    refute_received {:relay_emit, :degraded, _failures, _class}

    # The primary closes the session as a stopping daemon does (`1000`): it is
    # renewed after the first step, quietly, and is no outage.
    :ok = drop_sessions(primary)
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000

    assert %{status: :renewing, sentence: "Fermix is reconnecting to the server fermix-vm."} =
             Relay.status(relay)

    refute_received {:relay_emit, :degraded, _failures, _class}
  end

  # How long the link has had no session, on the clock that stops while this
  # computer sleeps (M75 lean v1 §7: "Fermix cannot reach your server" after
  # ten minutes of it): from the start until the first session, none while a
  # session is up, and from the moment one ends.
  test "the time with no session counts from when it went down, and is none while one is up" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    {:ok, mono} = Agent.start_link(fn -> 1_000 end)
    relay = DesktopRail.start_relay!(root, primary, monotonic: fn -> Agent.get(mono, & &1) end)

    assert %{connected: true, down_ms: nil} = DesktopRail.await_connected(relay)

    :ok = drop_sessions(primary)
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000
    Agent.update(mono, &(&1 + 600_000))

    assert %{connected: false, down_ms: 600_000} = Relay.status(relay)
  end

  # The status word is what an app draws: the first dial is quiet, and a
  # redial during an outage is still the outage until a session is up.
  test "the first dial is renewing, and a redial during an outage stays unreachable" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    test = self()

    connect = fn ->
      send(test, {:dialing, self()})

      receive do
        :refuse -> {:error, :econnrefused}
      end
    end

    relay = DesktopRail.start_relay!(root, primary, connect: connect)
    pid = GenServer.whereis(relay)

    assert_receive {:dialing, first}, 10_000
    assert %{connected: false, status: :renewing} = Relay.status(relay)
    send(first, :refuse)

    assert_receive {:relay_emit, :degraded, 1, :socket}, 10_000
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, 1_000}, 10_000
    send(pid, timer)

    assert_receive {:dialing, second}, 10_000
    assert %{connected: false, status: :unreachable} = Relay.status(relay)
    send(second, :refuse)
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 2_000}, 10_000
  end

  test "a session the primary closes normally is renewed: in flight is told so, never unreachable" do
    # The primary takes the forwarded call and never answers it.
    primary = DesktopRail.primary!(families: %{manage: {CaptureFamily, test: self()}})
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    request = %{request_id: "r-1", protocol_version: 2, method: "cues.status", params: %{}}
    call = Task.async(fn -> Relay.forward(relay, request) end)
    assert_receive {:primary_got, "manage", %{"method" => "cues.status"}, _params}, 10_000

    :ok = drop_sessions(primary)

    assert Task.await(call, 10_000) ==
             {:error, :primary_unreachable,
              %{
                "primary" => "fermix-vm",
                "sentence" => "The link to the server fermix-vm was renewed. Try again."
              }}

    assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000
    refute_received {:relay_emit, :degraded, _failures, _class}
  end

  test "a primary that revokes this desktop is not tried again, and the relay says so" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    :ok = DeviceRegistry.revoke(primary.registry, DesktopRail.device_id())
    assert_receive {:relay_emit, :degraded, 1, :revoked}, 10_000
    refute_receive {:scheduled, {:relay_timer, :reconnect, _token}, _delay}, 200

    revoked =
      "The server fermix-vm does not know this computer: it was removed from the server's " <>
        "devices, or the server was restored from a snapshot taken before this computer " <>
        "joined it. Fermix stopped reaching it."

    assert %{connected: false, status: :revoked, sentence: ^revoked} = Relay.status(relay)

    request = %{request_id: "r-1", protocol_version: 2, method: "cues.status", params: %{}}

    assert Relay.forward(relay, request) ==
             {:error, :primary_unreachable, %{"primary" => "fermix-vm", "sentence" => revoked}}

    assert {:error, {:revoked, ^revoked}} = Relay.open_channel(relay)
  end

  test "a desktop the primary does not know at the handshake is not tried again" do
    primary = DesktopRail.primary!()
    Agent.update(primary.revoked, fn _ -> true end)
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)

    assert_receive {:relay_emit, :degraded, 1, :revoked}, 10_000
    refute_receive {:scheduled, {:relay_timer, :reconnect, _token}, _delay}, 200
    assert %{status: :revoked, sentence: sentence} = Relay.status(relay)
    assert sentence =~ "does not know this computer"
  end

  test "a forwarded call is answered within 8 s, or within the deadline its caller asks" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    pid = GenServer.whereis(relay)
    DesktopRail.await_connected(relay)
    request = %{request_id: "r-1", protocol_version: 2, method: "home.status", params: %{}}

    # The primary in this test serves no manage family, so nothing answers.
    plain = Task.async(fn -> Relay.forward(relay, request) end)
    assert_receive {:scheduled, {:relay_timer, {:call, _id}, _token} = timer, 8_000}, 10_000
    send(pid, timer)

    assert {:error, :primary_unreachable, %{"sentence" => sentence}} = Task.await(plain, 10_000)
    assert sentence == "The server fermix-vm did not answer in time. Try again."

    composed = Task.async(fn -> Relay.forward(relay, request, deadline_ms: 5_000) end)
    assert_receive {:scheduled, {:relay_timer, {:call, _id}, _token} = timer, 5_000}, 10_000
    send(pid, timer)
    assert {:error, :primary_unreachable, _details} = Task.await(composed, 10_000)
  end

  test "more than 32 payloads open at once end the session as a protocol error" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)
    {:ok, _peer, %{session: session}} = Peer.lookup(primary.peers, DesktopRail.device_id())

    for n <- 1..33 do
      frame = %{"t" => "manage_result", "call_id" => "m#{n}", "index" => 0, "last" => false}
      send(session, {:mobile_event, Map.put(frame, "bytes", "{")})
    end

    assert_receive {:relay_emit, :degraded, 1, :protocol}, 10_000
    assert %{connected: false, status: :unreachable, sentence: sentence} = Relay.status(relay)
    assert sentence =~ "it sent a message this computer could not read"
  end

  test "a desktop key readable by others is refused by name, and nothing is dialed" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary, key_mode: 0o644)
    test = self()

    relay =
      DesktopRail.start_relay!(root, primary,
        connect: fn ->
          send(test, :dialed)
          {:error, :econnrefused}
        end
      )

    assert %{connected: false, status: :unreachable, name: "fermix-vm", sentence: sentence} =
             Relay.status(relay)

    assert sentence ==
             "The desktop key file is mode 0644, readable by others; Fermix uses it only at 0600."

    request = %{request_id: "r-1", protocol_version: 2, method: "settings.sections", params: %{}}

    assert {:error, :primary_unreachable, %{"sentence" => ^sentence}} =
             Relay.forward(relay, request)

    refute_received :dialed
  end

  test "a forwarded call while the link is down answers primary_unreachable, naming the primary" do
    primary = DesktopRail.primary!()
    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary, connect: fn -> {:error, :econnrefused} end)
    assert_receive {:relay_emit, :degraded, 1, :socket}, 10_000

    request = %{
      request_id: "r-1",
      protocol_version: 2,
      method: "providers.models.list",
      params: %{}
    }

    assert Relay.forward(relay, request) ==
             {:error, :primary_unreachable,
              %{"primary" => "fermix-vm", "sentence" => @unreachable}}

    assert {:error, {:unreachable, @unreachable}} = Relay.open_channel(relay)
  end

  test "the primary's route with another relay revision is kept and acknowledged at the next hello" do
    test = self()
    new_relays = [%{"url" => "https://relay-two.invalid/", "quic_port" => 7843}]

    route = %{
      "kind" => "iroh",
      "node_id" => DesktopRail.node_id(),
      "relays" => new_relays,
      "relays_rev" => "fedcba9876543210"
    }

    primary =
      DesktopRail.primary!(
        hello_ack_builder: fn _state -> {:ok, Map.put(ack(3), "candidates", [route])} end,
        update_device: fn _store, _id, changes ->
          send(test, {:hello_seen, changes})
          {:ok, DesktopRail.row()}
        end
      )

    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)
    assert_receive {:hello_seen, %{relay_list_rev: "0123456789abcdef"}}

    assert {:ok, %{primary: %{relays: ^new_relays, relays_rev: "fedcba9876543210"}}} =
             DesktopLink.read(root)

    :ok = drop_sessions(primary)
    assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, 1_000}, 10_000
    send(GenServer.whereis(relay), timer)
    assert_receive {:hello_seen, %{relay_list_rev: "fedcba9876543210"}}, 10_000
  end

  test "the primary's media bound is taken up to this desktop's own 64 MiB, never past it" do
    huge = %{"commands" => [], "max_media_bytes" => 1_152_921_504_606_846_976}

    primary =
      DesktopRail.primary!(
        hello_ack_builder: fn _state -> {:ok, Map.put(ack(3), "caps", huge)} end
      )

    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)
    assert :sys.get_state(relay).max_media_bytes == 67_108_864
  end

  describe "the move's forwarded calls" do
    @unconfirmed "The server fermix-vm did not confirm in time whether the move started. " <>
                   "Its state shows once the server answers again, and starting it again " <>
                   "never starts a second move."

    test "wait 60 s for the primary's walk of the home; every other call keeps 8 s" do
      primary = DesktopRail.primary!()
      root = DesktopRail.desktop_home!(primary)
      relay = DesktopRail.start_relay!(root, primary)
      pid = GenServer.whereis(relay)
      DesktopRail.await_connected(relay)

      for {method, deadline} <- [
            {"home.move.readiness", 60_000},
            {"home.move.start", 60_000},
            {"home.snapshots.run", 8_000}
          ] do
        request = %{request_id: "r-1", protocol_version: 2, method: method, params: %{}}
        call = Task.async(fn -> Relay.forward(relay, request) end)

        assert_receive {:scheduled, {:relay_timer, {:call, _id}, _token} = timer, ^deadline},
                       10_000

        send(pid, timer)
        assert {:error, _code, _details} = Task.await(call, 10_000)
      end
    end

    test "a start whose answer is lost is unconfirmed, never a failure" do
      primary = DesktopRail.primary!(families: %{manage: {CaptureFamily, test: self()}})
      root = DesktopRail.desktop_home!(primary)
      relay = DesktopRail.start_relay!(root, primary)
      pid = GenServer.whereis(relay)
      DesktopRail.await_connected(relay)
      start = %{request_id: "r-1", protocol_version: 2, method: "home.move.start", params: %{}}
      unconfirmed = %{"method" => "home.move.start", "primary" => "fermix-vm"}

      # Its deadline passes while the primary walks the home.
      call = Task.async(fn -> Relay.forward(relay, start) end)
      assert_receive {:primary_got, "manage", %{"method" => "home.move.start"}, _params}, 10_000
      assert_receive {:scheduled, {:relay_timer, {:call, _id}, _token} = timer, 60_000}, 10_000
      send(pid, timer)

      assert Task.await(call, 10_000) ==
               {:error, :unconfirmed, Map.put(unconfirmed, "sentence", @unconfirmed)}

      # The primary restarts into the move before its answer leaves: the
      # session ends normally, and the start is still unconfirmed, while a
      # read in flight beside it is told the link was renewed.
      call = Task.async(fn -> Relay.forward(relay, start) end)
      assert_receive {:primary_got, "manage", %{"method" => "home.move.start"}, _params}, 10_000
      read = %{start | method: "cues.status", request_id: "r-2"}
      other = Task.async(fn -> Relay.forward(relay, read) end)
      assert_receive {:primary_got, "manage", %{"method" => "cues.status"}, _params}, 10_000
      :ok = drop_sessions(primary)

      assert Task.await(call, 10_000) ==
               {:error, :unconfirmed, Map.put(unconfirmed, "sentence", @unconfirmed)}

      assert {:error, :primary_unreachable, %{"sentence" => renewed}} = Task.await(other, 10_000)
      assert renewed =~ "was renewed"
    end
  end

  describe "a primary that ends every session normally" do
    test "is renewed quietly once, then redialed with the backoff, and the posture says so" do
      primary = DesktopRail.primary!()
      root = DesktopRail.desktop_home!(primary)
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-10-28 09:00:00Z] end)
      relay = DesktopRail.start_relay!(root, primary, clock: fn -> Agent.get(clock, & &1) end)
      pid = GenServer.whereis(relay)
      DesktopRail.await_connected(relay)

      # The first normal ending is a renewal: after 1 s, quietly.
      :ok = drop_sessions(primary)
      assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, 1_000}, 10_000
      refute_received {:relay_emit, :degraded, _failures, _class}
      send(pid, timer)
      DesktopRail.await_connected(relay)

      # The renewed session ends as soon as it opened: an outage now, with the
      # backoff and the posture, again and again.
      for delay <- [2_000, 4_000] do
        :ok = drop_sessions(primary)
        assert_receive {:relay_emit, :degraded, 1, :renewed_again}, 10_000
        assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, ^delay}, 10_000

        assert %{connected: false, status: :unreachable, sentence: sentence} =
                 Relay.status(relay)

        assert sentence ==
                 "The server fermix-vm ends this computer's session each time it opens. " <>
                   "Fermix tries again in #{div(delay, 1_000)} s."

        send(pid, timer)
        DesktopRail.await_connected(relay)
        assert_receive {:relay_emit, :recovered, 1, :none}, 10_000
      end

      # A session that stayed up a minute before its normal ending is renewed
      # quietly again.
      Agent.update(clock, &DateTime.add(&1, 60, :second))
      :ok = drop_sessions(primary)
      assert_receive {:scheduled, {:relay_timer, :reconnect, _token}, 1_000}, 10_000
      refute_received {:relay_emit, :degraded, _failures, _class}

      assert %{status: :renewing, sentence: "Fermix is reconnecting to the server fermix-vm."} =
               Relay.status(relay)
    end
  end

  # The primary's side of every bridge connection stops, as a stopping daemon's
  # does: each session hears `1000` and ends.
  defp drop_sessions(primary) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(primary.connections),
        is_pid(pid),
        do: :ok = DynamicSupervisor.terminate_child(primary.connections, pid)

    :ok
  end

  defp ack(epoch) do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "desktop-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520}
    }
    |> Map.put("primary_epoch", epoch)
  end
end
