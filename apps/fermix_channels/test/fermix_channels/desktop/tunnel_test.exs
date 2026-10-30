defmodule FermixChannels.Desktop.TunnelTest do
  @moduledoc """
  The companion tunnel end to end (M75 §6): a client on the desktop's own
  `companion.sock`, the desktop's `Desktop.Tunnel` and relay, the rail's Noise
  session to the primary's real `Mobile.Session` behind the bridge socket,
  the primary's desktop peer and its companion family, and an ordinary
  `Companion.Connection` on the primary with the request path, coordinator
  and timeline on a throwaway repo.

  Both engines run in this VM under the test's own names; what is stood in
  for is the dial (the bridge socket in place of the iroh helper), the trust
  store's row, the gateway a request is ingested into and the settlement
  owner of its turn (as the companion connection's own tests stand them in),
  and the phone media store the primary streams a blob from.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Companion, as: CompanionChannel
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.MediaGrants
  alias FermixChannels.Companion.Output
  alias FermixChannels.Desktop.Companion
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay.Media
  alias FermixChannels.Desktop.Tunnel
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.ParentProcess

  @arrival_ms 10_000
  @unreachable "The server fermix-vm is unreachable. Fermix keeps your message until it is back."
  @blob String.duplicate("a voice note's bytes ", 5_000)
  @blob_ref :crypto.hash(:sha256, @blob) |> Base.encode16(case: :lower)

  defmodule GatewayStub do
    @moduledoc false
    def ingest([message], opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, message, opts})
      :ok
    end
  end

  defmodule TurnsStub do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:cancel, _profile, _client_msg_id}, _from, test_pid),
      do: {:reply, :ok, test_pid}

    @impl true
    def handle_cast({:settle_unless_handed_off, _key, _attempt, _settle}, test_pid),
      do: {:noreply, test_pid}
  end

  # The phone media store the primary's session streams a blob from.
  defmodule BlobStore do
    @moduledoc false
    use GenServer

    def start_link(path), do: GenServer.start_link(__MODULE__, path)

    @impl true
    def init(path), do: {:ok, path}

    @impl true
    def handle_call({:fetch, _ref}, _from, path),
      do: {:reply, {:ok, %{path: path, size_bytes: File.stat!(path).size}}, path}
  end

  setup do
    companion = primary_companion!()
    blob_store = start_blob_store!()

    primary =
      DesktopRail.primary!(
        families: fn names ->
          %{
            companion:
              {Companion,
               endpoint: companion.endpoint,
               supervisor: names.tunnels,
               socket_dir: names.socket_dir}
          }
        end,
        media_store: blob_store,
        media_descriptor: fn
          "main", @blob_ref ->
            {:ok,
             %{
               server_seq: 4,
               media: %{
                 ref: @blob_ref,
                 kind: "audio",
                 mime: "audio/ogg",
                 size_bytes: byte_size(@blob)
               }
             }}

          "main", _ref ->
            {:error, :not_found}
        end
      )

    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    %{
      companion: companion,
      primary: primary,
      root: root,
      relay: relay,
      socket: start_device_socket!(root, relay)
    }
  end

  test "a msg from the desktop's app runs on the primary, and the turn's stream comes back",
       ctx do
    client = hello(ctx.socket)

    send_line(client, message("mac-1", "hello from the desk"))

    assert %{"type" => "accepted", "client_msg_id" => "mac-1", "duplicate" => false} =
             recv(client)

    assert %{"type" => "row", "role" => "user", "text" => "hello from the desk"} = recv(client)
    assert_receive {:gateway_ingest, message, gateway_opts}, @arrival_ms
    assert message.channel == "companion"
    assert message.content == "hello from the desk"
    assert gateway_opts[:ingress_context] == %{transport: :companion}

    # The primary's turn speaks to every connection of its companion socket,
    # the tunneled one included.
    registry = ctx.companion.registry

    CompanionChannel.broadcast(
      "main",
      %{
        "t" => "turn_started",
        "profile_id" => "main",
        "turn_id" => "t-1",
        "in_reply_to" => "mac-1"
      },
      registry
    )

    stream(registry, "t-1", {:snapshot, "Hello"})
    stream(registry, "t-1", {:snapshot, "Hello there"})

    CompanionChannel.broadcast(
      "main",
      %{"t" => "text_done", "turn_id" => "t-1", "server_seq" => 2, "text" => "Hello there"},
      registry
    )

    assert %{"type" => "turn_started", "turn_id" => "t-1"} = recv(client)
    assert %{"type" => "text_delta", "turn_id" => "t-1", "text" => "Hello"} = recv(client)
    assert %{"type" => "text_delta", "turn_id" => "t-1", "text" => " there"} = recv(client)
    assert %{"type" => "text_done", "turn_id" => "t-1", "text" => "Hello there"} = recv(client)
  end

  test "history, an approval card and the hello's epoch are the primary's", ctx do
    client = connect(ctx.socket)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 3, "primary_epoch" => 2})

    assert %{"type" => "server_hello", "role" => "primary", "primary_epoch" => 3} = recv(client)

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "after_seq" => 0,
      "limit" => 50
    })

    assert %{"type" => "history_page", "messages" => []} = recv(client)

    card = Output.approval(%{kind: :sandbox, text: "Run it?", token: "DESK-T"})
    CompanionChannel.broadcast("main", card, ctx.companion.registry)
    assert %{"type" => "approval", "token" => "DESK-T", "text" => "Run it?"} = recv(client)
  end

  test "a client that has seen a later primary is refused by the primary, through the tunnel",
       ctx do
    client = connect(ctx.socket)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 3, "primary_epoch" => 9})
    assert %{"type" => "error", "reason" => "stale_primary"} = recv(client)
    assert closed?(client)
  end

  test "media is fetched from the primary and granted here, and released here", ctx do
    client = hello(ctx.socket)
    send_line(client, %{"type" => "media_fetch", "profile_id" => "main", "ref" => @blob_ref})

    assert %{
             "type" => "media_path",
             "ref" => @blob_ref,
             "path" => path,
             "kind" => "audio",
             "mime" => "audio/ogg",
             "sha256" => @blob_ref
           } = recv(client)

    assert path == Path.join([ctx.root, "companion", "media", @blob_ref <> ".ogg"])
    assert File.read!(path) == @blob
    # The staged copy went once the grant made its own.
    assert {:error, :media_gone} = Media.staged_blob(Media.staging_dir(ctx.root), @blob_ref)

    send_line(client, %{"type" => "media_release", "profile_id" => "main", "ref" => @blob_ref})
    send_line(client, %{"type" => "media_fetch", "profile_id" => "work", "ref" => @blob_ref})
    assert %{"type" => "error", "reason" => "unsupported_profile"} = recv(client)
  end

  test "a ref the primary has no row for is media_missing", ctx do
    missing = String.duplicate("b", 64)
    client = hello(ctx.socket)
    send_line(client, %{"type" => "media_fetch", "profile_id" => "main", "ref" => missing})
    assert %{"type" => "media_missing", "ref" => ^missing} = recv(client)
  end

  test "a client that connects while the primary is unreachable is told so by name, and closed",
       ctx do
    root = DesktopRail.desktop_home!(ctx.primary)

    relay =
      DesktopRail.start_relay!(root, ctx.primary, connect: fn -> {:error, :econnrefused} end)

    assert_receive {:relay_emit, :degraded, 1, :socket}, @arrival_ms
    socket = start_device_socket!(root, relay)

    client = connect(socket)

    assert %{"type" => "error", "reason" => "primary_unreachable", "message" => @unreachable} =
             recv(client)

    assert closed?(client)
  end

  test "a session that drops ends every open channel with the unreachable sentence", ctx do
    client = hello(ctx.socket)

    # The primary's end of the stream dies without a close: an outage.
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(ctx.primary.connections),
        is_pid(pid),
        do: Process.exit(pid, :kill)

    assert %{"type" => "error", "reason" => "primary_unreachable", "message" => @unreachable} =
             recv(client)

    assert closed?(client)
  end

  # A revoked desktop never reaches its primary again, so the app is told
  # that by its own reason and stops keeping messages for later.
  test "a primary that revokes this desktop ends every channel saying so", ctx do
    client = hello(ctx.socket)
    :ok = DeviceRegistry.revoke(ctx.primary.registry, DesktopRail.device_id())

    assert %{"type" => "error", "reason" => "desktop_revoked", "message" => message} =
             recv(client)

    assert message =~ "The server fermix-vm does not know this computer"
    assert closed?(client)

    # A client that connects afterwards hears the same, and nothing reaches the primary.
    late = connect(ctx.socket)

    assert %{"type" => "error", "reason" => "desktop_revoked", "message" => ^message} =
             recv(late)

    assert closed?(late)
    assert "desktop_revoked" in Tunnel.error_reasons()

    # The published golden is this refusal, word for word.
    golden =
      :fermix_core
      |> Application.app_dir("priv/companion/fixtures/server_events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["reason"] == "desktop_revoked"))

    assert golden == %{"type" => "error", "reason" => "desktop_revoked", "message" => message}
  end

  test "a process this engine started is refused before anything reaches the primary", ctx do
    root = DesktopRail.desktop_home!(ctx.primary)
    socket = start_device_socket!(root, ctx.relay, daemon_os_pid: ParentProcess.os_pid())

    client = connect(socket)

    assert %{"type" => "error", "reason" => "unattended_client", "message" => message} =
             recv(client)

    assert message =~ "Only the Fermix app chats with the server"
    assert closed?(client)
    assert [] = Peer.connected(ctx.primary.peers) |> Enum.flat_map(&channels(ctx, &1))
  end

  test "at most four channels: the desktop's socket takes four clients, and the primary four channels",
       ctx do
    clients = for _n <- 1..4, do: hello(ctx.socket)
    fifth = connect(ctx.socket)
    assert %{"type" => "error", "reason" => "max_clients_reached"} = recv(fifth)
    assert closed?(fifth)

    # The primary holds its own bound whatever a desktop sends: a fifth
    # channel is closed at once, and the four stay open.
    {:ok, peer, _value} = Peer.lookup(ctx.primary.peers, DesktopRail.device_id())
    assert map_size(companion_channels(peer)) == 4

    assert :ok =
             Peer.deliver(peer, %{
               type: "companion_open",
               payload: %{"channel" => 60},
               bytes: <<>>
             })

    assert channels = companion_channels(peer)
    assert map_size(channels) == 4
    refute Map.has_key?(channels, 60)
    assert Companion.max_channels() == 4

    send_line(hd(clients), message("mac-2", "still here"))
    assert %{"type" => "accepted", "client_msg_id" => "mac-2"} = recv(hd(clients))
  end

  test "the tunnel's own error reasons are documented in the companion protocol" do
    protocol = File.read!(Application.app_dir(:fermix_core, "priv/companion/PROTOCOL.md"))

    for reason <- Tunnel.error_reasons() do
      assert protocol =~ "`#{reason}`", "PROTOCOL.md does not document error #{reason}"
    end
  end

  # -- the primary's companion socket ---------------------------------------------

  defp primary_companion! do
    test_pid = self()
    unique = System.unique_integer([:positive])
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("desktop-tunnel")
    repo = :"desktop_tunnel_repo_#{unique}"
    registry = :"desktop_tunnel_registry_#{unique}"
    connections = :"desktop_tunnel_conns_#{unique}"
    endpoint = :"desktop_tunnel_endpoint_#{unique}"
    socket_path = Path.join(System.tmp_dir!(), "fx-dtc-#{unique}.sock")

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(dir)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    queue_owner = start_supervised!({Task, fn -> forward(test_pid) end}, id: :queue_owner)

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Registry, keys: :duplicate, name: registry})
    store_opts = [repo: repo, agent_id: "agent-d", owner_id: "owner-d"]

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil,
         boot_epoch: "boot-desktop",
         store_opts: [transport: "companion"] ++ store_opts,
         recover?: false}
      )

    turns = start_supervised!({TurnsStub, test_pid})

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    request_opts = [
      store_opts: store_opts,
      request_coordinator: coordinator,
      gateway: GatewayStub,
      agent_server: queue_owner,
      settlement_owner: turns,
      engine_role: %{role: :primary, primary: nil}
    ]

    start_supervised!(
      {Endpoint,
       name: endpoint,
       socket_path: socket_path,
       connection_supervisor: connections,
       connection_opts: [
         registry: registry,
         request_opts: request_opts,
         primary_epoch: fn -> {:ok, 3} end
       ]},
      id: endpoint
    )

    %{endpoint: endpoint, registry: registry}
  end

  defp start_blob_store! do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("desktop-blob")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    path = Path.join(dir, @blob_ref)
    File.write!(path, @blob)
    start_supervised!({BlobStore, path})
  end

  # -- the desktop's companion socket -----------------------------------------------

  defp start_device_socket!(root, relay, tunnel_opts \\ []) do
    unique = System.unique_integer([:positive])
    staging = Media.staging_dir(root)
    :ok = Media.prepare(staging)
    grants = :"desktop_tunnel_grants_#{unique}"
    connections = :"desktop_tunnel_device_conns_#{unique}"
    socket_path = Path.join(root, "c.sock")

    start_supervised!(
      {MediaGrants,
       name: grants,
       root: Path.join([root, "companion", "media"]),
       blob: &Media.staged_blob(staging, &1)},
      id: grants
    )

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    start_supervised!(
      {Endpoint,
       name: :"desktop_tunnel_device_endpoint_#{unique}",
       socket_path: socket_path,
       connection_supervisor: connections,
       connection_module: Tunnel,
       connection_opts: [relay: relay, staging: staging, media_grants: grants] ++ tunnel_opts},
      id: {:device_endpoint, unique}
    )

    socket_path
  end

  defp companion_channels(peer),
    do: :sys.get_state(peer).families.companion |> elem(1) |> Map.fetch!(:channels)

  defp channels(ctx, %{device_id: device_id}) do
    {:ok, peer, _value} = Peer.lookup(ctx.primary.peers, device_id)
    :sys.get_state(peer).families.companion |> elem(1) |> Map.fetch!(:channels) |> Map.keys()
  end

  # -- the client ---------------------------------------------------------------------

  defp stream(registry, turn_id, update) do
    Registry.dispatch(registry, "main", fn entries ->
      for {pid, _version} <- entries, do: send(pid, {:companion_stream, turn_id, update})
    end)
  end

  defp forward(test_pid) do
    receive do
      message -> send(test_pid, message)
    end

    forward(test_pid)
  end

  defp message(id, text),
    do: %{
      "type" => "msg",
      "client_msg_id" => id,
      "profile_id" => "main",
      "text" => text,
      "attach_ids" => []
    }

  defp hello(path) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 3})
    assert %{"type" => "server_hello", "role" => "primary"} = recv(client)
    client
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 128 * 1_024
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, @arrival_ms) == {:error, :closed}
end
