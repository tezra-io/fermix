defmodule FermixChannels.Desktop.RelayIrohEndToEndTest do
  @moduledoc """
  The desktop relay over the real rail (M75 §6): the relay dials the
  primary's listening `fermix-iroh` helper through a dial-only one, runs `IK`
  with the desktop's key against the primary's real `Session`, says `hello`,
  and forwards a management call the primary's `manage` family answers.

  The primary is an Always On server (helper protocol 4): its endpoint binds
  the fixed port it is given, its session tells the desktop its address
  hints, and the relay dials the hint its link holds and names the path the
  helper reports.

  Answered by the primary's own `Fermix.CLI.Daemon`, a forwarded call costs
  the link and that answer, and no wait besides.

  Opt-in, because it needs the helper built from a `fermix-iroh` checkout
  (`cargo build --release --locked`):

      FERMIX_IROH_DIR=../fermix-iroh mix test --only iroh_end_to_end

  Run without `FERMIX_IROH_DIR` it fails, never passes empty. As in
  `Mobile.Iroh.EndToEndTest`, the dial reaches the listener only at its UDP
  address, here the server's hint, because no relay can be trusted locally
  by the released helper: the relay never resolves, so this is also the
  link with its relay unreachable and only the hint. The hint is the
  loopback one, given through the session's own seam: a tailnet address
  cannot reach a listener on this machine, and the interfaces stay the
  test's.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fermix.CLI.Daemon
  alias FermixChannels.Desktop.Manage
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.Relays.Source
  alias FermixChannels.Mobile.Noise
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixTestSupport.PrimaryHome
  alias FermixTestSupport.SafeRm

  @moduletag :iroh_end_to_end
  @moduletag timeout: 120_000

  @device_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @timeout_ms 15_000
  # Over loopback the link answers in a few milliseconds, so a median past
  # this is a wait outside the link and the primary's answer.
  @call_bound_ms 50
  @timed_calls 10
  # Never resolves, so nothing leaves the machine for a relay.
  @relay %{"url" => "https://relay.invalid/", "quic_port" => 7842}

  setup do
    dir = System.fetch_env!("FERMIX_IROH_DIR") |> Path.expand()
    helper = Path.join(dir, "target/release/fermix-iroh")
    assert File.regular?(helper), "#{helper} is not built"
    %{helper: helper}
  end

  test "a desktop's relay reaches its primary over iroh and forwards a management call", ctx do
    test = self()

    serve = fn frame, _device_id ->
      %{"request_id" => id, "method" => method} = Jason.decode!(frame)
      send(test, {:served, method})
      %{"request_id" => id, "result" => %{"answered_by" => "primary"}}
    end

    link = link!(ctx, %{manage: {Manage, serve: serve}})
    %{names: names, hint: hint} = link

    # The server's endpoint is on the port it was given, not one iroh picked.
    assert link.bound == link.port

    assert %{connected: true, epoch: 3, name: "fermix-vm"} = link.status
    assert [%{device_id: @device_id}] = Peer.connected(names.peers)

    # The dial went straight to the hint, and the session said it again.
    assert %{path: :direct} = Relay.status(names.relay)
    assert {:ok, %{primary: %{addrs: [^hint]}}} = DesktopLink.read(link.desktop_root)

    request = %{request_id: "r-1", protocol_version: 2, method: "cues.status", params: %{}}
    assert {:ok, %{"answered_by" => "primary"}} = Relay.forward(names.relay, request)
    assert_receive {:served, "cues.status"}, @timeout_ms
    refute_received {:relay_emit, _status, _failures, _class}
  end

  # The primary's own daemon answers each call, as `Desktop.Manage` has it do
  # in an engine. A call over the link on this machine takes a few
  # milliseconds; one that waits on the primary's daemon for anything but its
  # answer takes far longer, on every call.
  test "a forwarded call costs the link and the primary's answer, and no wait besides", ctx do
    tasks = start_supervised!({Task.Supervisor, []}, id: :daemon_tasks)
    daemon = start_primary_daemon!(tasks)
    serve = fn frame, device_id -> Daemon.serve_forwarded(frame, device_id, daemon) end
    %{names: names} = link!(ctx, %{manage: {Manage, serve: serve, task_supervisor: tasks}})

    took_ms =
      for call <- 1..@timed_calls do
        request = %{
          request_id: "t-#{call}",
          protocol_version: 2,
          method: "settings.get",
          params: %{"section" => "providers.openai"}
        }

        started = System.monotonic_time(:millisecond)
        assert {:ok, %{"engine" => "primary"}} = Relay.forward(names.relay, request)
        System.monotonic_time(:millisecond) - started
      end

    median = took_ms |> Enum.sort() |> Enum.at(div(@timed_calls, 2))

    assert median < @call_bound_ms,
           "forwarded calls took #{inspect(took_ms)} ms, past the #{@call_bound_ms} ms bound"
  end

  # -- the link ------------------------------------------------------------------------

  # A primary whose rail serves `families`, and a desktop's relay connected to
  # it over two real helpers, dialed at the server's loopback hint.
  defp link!(ctx, families) do
    test = self()
    primary_root = root!("fx-re-p")
    PrimaryHome.booted!(primary_root)
    :ok = Epoch.write(primary_root, 3)
    {:ok, identity} = Identity.ensure(root: primary_root)
    desktop = Noise.generate_keypair()
    names = names()

    start_supervised!(
      {DesktopSupervisor,
       name: nil, registry: names.peers, peer_supervisor: names.peer_supervisor}
    )

    registry = start_registry(names)
    port = free_udp_port()
    hint = "127.0.0.1:#{port}"

    {endpoint_id, bound} =
      start_listener(ctx, primary_root, names, registry, desktop, families, port)

    desktop_root = root!("fx-re-d")

    :ok =
      DesktopLink.write(desktop_root, %{
        device_id: @device_id,
        primary: %{
          name: "fermix-vm",
          gateway_pk: identity.gateway_public_key,
          node_id: endpoint_id,
          relays: [@relay],
          relays_rev: "0123456789abcdef",
          addrs: [hint]
        },
        epoch: 3
      })

    :ok = DesktopLink.write_key(desktop_root, desktop.private)
    dialer = start_dialer(ctx, desktop_root)

    start_supervised!(
      {Relay,
       name: names.relay,
       root: desktop_root,
       helper: dialer,
       schedule: fn message, delay ->
         send(test, {:scheduled, message, delay})
         make_ref()
       end,
       cancel_timer: fn _ref -> false end,
       emit: fn status, failures, class -> send(test, {:relay_emit, status, failures, class}) end}
    )

    status = await_connected(names.relay, 300)

    %{
      names: names,
      port: port,
      bound: bound,
      hint: hint,
      desktop_root: desktop_root,
      status: status
    }
  end

  # The primary's `Fermix.CLI.Daemon`, on a socket of the test's own: its
  # router answers `settings.get` from a reader that names the engine.
  defp start_primary_daemon!(tasks) do
    name = :"re2e_daemon_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Daemon,
       name: name,
       socket_path: Path.join(root!("fx-re-s"), "d.sock"),
       task_supervisor: tasks,
       forwarding: [],
       management_opts: [
         engine_role: %{role: :primary, primary: nil},
         settings_reader: fn section, _opts ->
           {:ok, %{"section" => section, "engine" => "primary"}}
         end
       ]},
      id: name
    )

    name
  end

  # -- the primary's rail ------------------------------------------------------------

  defp start_listener(ctx, root, names, registry, desktop, families, port) do
    revisions = Source.parse!(%{"revisions" => [%{"iroh" => "1.3.0", "relays" => [@relay]}]})
    desktop_public = desktop.public
    peer_supervisor = names.peer_supervisor

    session_opts = [
      identity_root: root,
      device_store: names.device_store,
      device_registry: registry,
      iroh_helper: names.iroh_helper,
      find_device: fn _store, key ->
        if key == desktop_public, do: {:ok, row()}, else: {:error, :not_found}
      end,
      update_device: fn _store, @device_id, _changes -> {:ok, row()} end,
      profile_name: "Orbit",
      history_head: fn "main" -> {:ok, 0} end,
      read_frontier: fn "main" -> {:ok, 0} end,
      pending_approvals: fn _profile -> [] end,
      discover: fn -> {:ok, []} end,
      desktop_peers: names.peers,
      desktop_peer_supervisor: peer_supervisor,
      start_desktop_peer: &Peer.start(peer_supervisor, Keyword.put(&1, :families, families)),
      iroh_hints: fn -> ["127.0.0.1:#{port}"] end
    ]

    opts = [
      root: root,
      names: names,
      switch: fn -> true end,
      session_opts: session_opts,
      helper_opts: [
        binary_path: ctx.helper,
        revisions: revisions,
        list_devices: fn _store -> {:ok, []} end,
        bind_port: port,
        interfaces: fn -> {:ok, []} end
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
    [_all, bound] = Regex.run(~r/bound UDP sockets: .*?(?:0\.0\.0\.0|127\.0\.0\.1):(\d+)/, log)
    {endpoint_id, String.to_integer(bound)}
  end

  # A UDP port nothing holds now, for the server's fixed one (never 4033,
  # which a Fermix running on this machine may hold).
  defp free_udp_port do
    {:ok, socket} = :gen_udp.open(0, ip: {0, 0, 0, 0})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  defp start_registry(names) do
    start_supervised!(
      {DeviceRegistry,
       name: names.device_registry,
       device_store: names.device_store,
       authorize_device: fn _store, @device_id -> {:ok, row()} end,
       delete_device: fn _store, @device_id -> :ok end,
       revoke_requests: fn _id -> :ok end,
       relays_changed: fn -> :ok end}
    )

    names.device_registry
  end

  defp row, do: %{device_id: @device_id, name: "Studio Mac", kind: :desktop}

  # -- the desktop's dial-only helper --------------------------------------------------

  defp start_dialer(ctx, root) do
    revisions = Source.parse!(%{"revisions" => [%{"iroh" => "1.3.0", "relays" => [@relay]}]})

    dialer =
      start_supervised!(
        {Helper,
         name: nil,
         mode: :dial,
         root: root,
         binary_path: ctx.helper,
         revisions: revisions,
         emit: fn _status, _failures, _class -> :ok end},
        id: :dialer
      )

    await_ready(dialer, 200)
    dialer
  end

  defp await_ready(helper, attempts) do
    case Helper.status(helper) do
      %{state: :ready} ->
        # sleep: lets the endpoint settle after `ready`, as the rail's own test does
        Process.sleep(200)

      %{state: state} = status when state in [:failed, :helper_missing] or attempts == 0 ->
        flunk("the rail did not become ready: #{inspect(status)}")

      _starting ->
        # sleep: polls the helper's status, which announces nothing
        Process.sleep(50)
        await_ready(helper, attempts - 1)
    end
  end

  defp await_connected(relay, attempts) do
    case Relay.status(relay) do
      %{connected: true} = status ->
        status

      status when attempts == 0 ->
        flunk("the relay did not connect: #{inspect(status)}")

      _connecting ->
        # sleep: polls the relay's status, which announces no first connection
        Process.sleep(50)
        await_connected(relay, attempts - 1)
    end
  end

  defp root!(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    root
  end

  defp names do
    suffix = System.unique_integer([:positive])

    %{
      device_store: :"re2e_store_#{suffix}",
      device_registry: :"re2e_registry_#{suffix}",
      iroh_helper: :"re2e_helper_#{suffix}",
      bridge: :"re2e_bridge_#{suffix}",
      bridge_connections: :"re2e_connections_#{suffix}",
      peers: :"re2e_peers_#{suffix}",
      peer_supervisor: :"re2e_peer_sup_#{suffix}",
      relay: :"re2e_relay_#{suffix}"
    }
  end
end
