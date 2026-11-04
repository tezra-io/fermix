defmodule FermixChannels.Test.DesktopRail do
  @moduledoc """
  A primary's responder and a desktop's home in one test VM (M75 §6).

  The primary is the engine's own: `Mobile.Session` with real Noise behind the
  real iroh bridge socket (`Iroh.Bridge`), a `DeviceRegistry`, and the
  desktop peers' supervisors (`Desktop.Supervisor`), each under the test's own
  names. The desktop's home holds `device/desktop.json` and its 0600 key, as
  the move worker leaves them. A relay reaches the primary through the
  bridge's socket (`bridge_connect/1`, the helper's side of a dialed stream),
  so everything past the dial is the code that runs in production; only the
  dial itself, and the trust store's rows, are stood in for.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2, on_exit: 1]

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Noise
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixTestSupport.PrimaryHome
  alias FermixTestSupport.SafeRm

  @device_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @node_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @preamble "FXB1" <> <<1>> <> Base.decode16!(@node_id, case: :lower)
  @relays [%{"url" => "https://relay.invalid/", "quic_port" => 7842}]
  @relays_rev "0123456789abcdef"

  def device_id, do: @device_id
  def node_id, do: @node_id
  def relays_rev, do: @relays_rev

  @doc "A short temporary root (a socket path under it must fit an address)."
  def root!(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    root
  end

  @doc """
  Starts the primary's responder. Options: `:epoch` (its primary epoch, 3),
  `:families` (the desktop peer's families, or a function of the primary's
  names, `%{tunnels, socket_dir, peers}`, answering them), `:revoked` (an Agent of whether
  the desktop's row is gone), `:hello_ack_builder`, `:media_descriptor` and
  `:media_store` (the session's media seams).
  """
  def primary!(opts \\ []) do
    root = root!("fx-dp")
    PrimaryHome.booted!(root)
    # The session reads the home's epoch when it loads the identity.
    :ok = Epoch.write(root, Keyword.get(opts, :epoch, 3))
    {:ok, identity} = Identity.ensure(root: root)
    desktop = Noise.generate_keypair()
    suffix = System.unique_integer([:positive])
    peers = :"desktop_rail_peers_#{suffix}"
    peer_supervisor = :"desktop_rail_peer_sup_#{suffix}"
    tunnels = :"desktop_rail_tunnels_#{suffix}"

    revoked =
      Keyword.get_lazy(opts, :revoked, fn ->
        start_supervised!({Agent, fn -> false end}, id: {:revoked, suffix})
      end)

    start_supervised!(
      {DesktopSupervisor,
       name: nil, registry: peers, peer_supervisor: peer_supervisor, tunnel_supervisor: tunnels},
      id: {:desktop, suffix}
    )

    registry = start_registry(:"desktop_rail_registry_#{suffix}", revoked)

    connections =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one},
        id: {:bridge_connections, suffix}
      )

    bridge_socket = Path.join(root, "b.sock")

    primary = %{
      root: root,
      gateway_public_key: identity.gateway_public_key,
      desktop: desktop,
      peers: peers,
      peer_supervisor: peer_supervisor,
      tunnels: tunnels,
      registry: registry,
      revoked: revoked,
      bridge_socket: bridge_socket,
      connections: connections
    }

    start_supervised!(
      {Bridge,
       name: nil,
       socket_path: bridge_socket,
       connection_supervisor: connections,
       connection_opts: [session_opts: session_opts(primary, opts)]},
      id: {:bridge, suffix}
    )

    primary
  end

  defp start_registry(name, revoked) do
    start_supervised!(
      {DeviceRegistry,
       name: name,
       device_store: :desktop_rail_store,
       authorize_device: fn _store, @device_id ->
         if Agent.get(revoked, & &1),
           do: {:error, {:device_not_found, @device_id}},
           else: {:ok, row()}
       end,
       delete_device: fn _store, @device_id -> Agent.update(revoked, fn _ -> true end) end,
       revoke_requests: fn _id -> :ok end,
       relays_changed: fn -> :ok end},
      id: {:registry, name}
    )

    name
  end

  def row, do: %{device_id: @device_id, name: "Studio Mac", kind: :desktop}

  defp session_opts(primary, opts) do
    desktop_public = primary.desktop.public
    revoked = primary.revoked
    peer_supervisor = primary.peer_supervisor

    families =
      case Keyword.get(opts, :families, %{}) do
        build when is_function(build, 1) ->
          build.(%{
            tunnels: primary.tunnels,
            socket_dir: Path.join(primary.root, "mobile"),
            peers: primary.peers
          })

        families ->
          families
      end

    [
      identity_root: primary.root,
      device_store: :desktop_rail_store,
      device_registry: primary.registry,
      iroh_helper: :desktop_rail_no_helper,
      primary_epoch: Keyword.get(opts, :epoch, 3),
      find_device: fn _store, key ->
        if key == desktop_public and not Agent.get(revoked, & &1),
          do: {:ok, row()},
          else: {:error, {:noise_identity_not_found, Base.encode64(key)}}
      end,
      update_device:
        Keyword.get(opts, :update_device, fn _store, @device_id, _changes -> {:ok, row()} end),
      profile_name: "Orbit",
      history_head: fn "main" -> {:ok, 0} end,
      read_frontier: fn "main" -> {:ok, 0} end,
      pending_approvals: fn _profile -> [] end,
      discover: fn -> {:ok, []} end,
      desktop_peers: primary.peers,
      desktop_peer_supervisor: peer_supervisor,
      start_desktop_peer: &Peer.start(peer_supervisor, Keyword.put(&1, :families, families))
    ] ++ Keyword.take(opts, [:hello_ack_builder, :media_descriptor, :media_store])
  end

  @doc """
  A desktop's home after the move: `device/desktop.json` naming the primary
  and the epoch it last saw (`:epoch`, 3), and the desktop's key at
  `:key_mode` (0600).
  """
  def desktop_home!(primary, opts \\ []) do
    root = root!("fx-dd")

    link = %{
      device_id: @device_id,
      primary: %{
        name: Keyword.get(opts, :name, "fermix-vm"),
        gateway_pk: primary.gateway_public_key,
        node_id: @node_id,
        relays: @relays,
        relays_rev: @relays_rev
      },
      epoch: Keyword.get(opts, :epoch, 3)
    }

    :ok = DesktopLink.write(root, link)
    :ok = DesktopLink.write_key(root, primary.desktop.private)
    :ok = File.chmod(DesktopLink.key_path(root), Keyword.get(opts, :key_mode, 0o600))
    root
  end

  @doc "The helper's side of the bridge: connect, then the 37-byte preamble."
  def bridge_connect(path) do
    fn ->
      with {:ok, socket} <- :gen_tcp.connect({:local, path}, 0, [:binary, active: false]),
           :ok <- :gen_tcp.send(socket, @preamble),
           do: {:ok, socket}
    end
  end

  @doc """
  Starts a relay for the desktop home `root` reaching `primary`, its timers
  sent to the test (`{:scheduled, message, delay_ms}`) and its telemetry too
  (`{:relay_emit, status, failures, class}`). `:connect` replaces the bridge.
  """
  def start_relay!(root, primary, opts \\ []) do
    test = self()
    name = :"desktop_rail_relay_#{System.unique_integer([:positive])}"

    relay_opts =
      [
        name: name,
        root: root,
        connect: Keyword.get(opts, :connect, bridge_connect(primary.bridge_socket)),
        schedule: fn message, delay ->
          send(test, {:scheduled, message, delay})
          make_ref()
        end,
        cancel_timer: fn _ref -> false end,
        emit: fn status, failures, class -> send(test, {:relay_emit, status, failures, class}) end,
        # The Always On provisioner's part, told to the test instead.
        primary_reached: fn epoch ->
          send(test, {:primary_reached, epoch})
          :ok
        end
      ]
      |> Keyword.merge(Keyword.drop(opts, [:connect]))

    start_supervised!({Relay, relay_opts}, id: name)
    name
  end

  @doc """
  Waits until the relay reports itself connected, within 10 s (the relay
  sends nothing when it connects the first time, so its status is polled).
  """
  def await_connected(relay, attempts \\ 1_000) do
    case Relay.status(relay) do
      %{connected: true} = status ->
        status

      status when attempts == 0 ->
        raise "the relay did not connect: #{inspect(status)}"

      _connecting ->
        # sleep: polls the relay's status, which announces no first connection
        Process.sleep(10)
        await_connected(relay, attempts - 1)
    end
  end
end
