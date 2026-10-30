defmodule FermixChannels.Desktop.RelayIrohEndToEndTest do
  @moduledoc """
  The desktop relay over the real rail (M75 §6): the relay dials the
  primary's listening `fermix-iroh` helper through a dial-only one, runs `IK`
  with the desktop's key against the primary's real `Session`, says `hello`,
  and forwards a management call the primary's `manage` family answers.

  Opt-in, because it needs the helper built from a `fermix-iroh` checkout
  (`cargo build --release --locked`):

      FERMIX_IROH_DIR=../fermix-iroh mix test --only iroh_end_to_end

  Run without `FERMIX_IROH_DIR` it fails, never passes empty. As in
  `Mobile.Iroh.EndToEndTest`, the dial names the listener's UDP address,
  because no relay can be trusted locally by the released helper.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    serve = fn frame, _device_id ->
      %{"request_id" => id, "method" => method} = Jason.decode!(frame)
      send(test, {:served, method})
      %{"request_id" => id, "result" => %{"answered_by" => "primary"}}
    end

    families = %{manage: {Manage, serve: serve}}
    {endpoint_id, port} = start_listener(ctx, primary_root, names, registry, desktop, families)

    desktop_root = root!("fx-re-d")

    :ok =
      DesktopLink.write(desktop_root, %{
        device_id: @device_id,
        primary: %{
          name: "fermix-vm",
          gateway_pk: identity.gateway_public_key,
          node_id: endpoint_id,
          relays: [@relay],
          relays_rev: "0123456789abcdef"
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
       addrs: ["127.0.0.1:#{port}"],
       schedule: fn message, delay ->
         send(test, {:scheduled, message, delay})
         make_ref()
       end,
       cancel_timer: fn _ref -> false end,
       emit: fn status, failures, class -> send(test, {:relay_emit, status, failures, class}) end}
    )

    assert %{connected: true, epoch: 3, name: "fermix-vm"} = await_connected(names.relay, 300)
    assert [%{device_id: @device_id}] = Peer.connected(names.peers)

    request = %{request_id: "r-1", protocol_version: 2, method: "cues.status", params: %{}}
    assert {:ok, %{"answered_by" => "primary"}} = Relay.forward(names.relay, request)
    assert_receive {:served, "cues.status"}, @timeout_ms
    refute_received {:relay_emit, _status, _failures, _class}
  end

  # -- the primary's rail ------------------------------------------------------------

  defp start_listener(ctx, root, names, registry, desktop, families) do
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
      pairing_pending: fn -> :none end,
      discover: fn -> {:ok, []} end,
      desktop_peers: names.peers,
      desktop_peer_supervisor: peer_supervisor,
      start_desktop_peer: &Peer.start(peer_supervisor, Keyword.put(&1, :families, families))
    ]

    opts = [
      root: root,
      names: names,
      switch: fn -> true end,
      session_opts: session_opts,
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

  defp row, do: %{device_id: @device_id, name: "Studio Mac", kind: :desktop, executor: true}

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
