defmodule FermixChannels.Companion.Supervisor do
  @moduledoc """
  The companion chat socket's subtree, started by `FermixChannels.Application`
  on every boot.

  The registry the channel adapter broadcasts through is always present, so a
  delivery to the companion timeline never depends on a client being connected,
  and so is `Companion.Approvals`, which keeps the approval cards still waiting
  for the owner for the clients of either transport that connect later.

  When the boot settles turns (`:settle?`, every boot but a test tree's),
  `Companion.Turns` runs right after the registry: the settlement owner both
  transports hand their turns to, the Mac's socket and the phone's channel
  alike, so it runs whether or not this boot serves `companion.sock` (a
  `:source` boot with the phone on serves no socket). It starts before
  `Approvals` so that nothing of the approvals' own restarts it and loses the
  endings of the turns it holds.

  When the boot also serves (a daemon run), the socket follows, in dependency
  order:

  1. the request coordinator for this transport, on the boot's shared epoch, so
     a companion request that a crash left unfinished is rerun at boot,
  2. `Companion.MediaGrants`, the managed media files a connection's
     `media_fetch` is granted (companion protocol 3), which starts with none:
     before the connections, so a restart that forgets every hold takes the
     connections that held them down with it, and its fresh directory never
     outlives the holds it forgot,
  3. the Always On watch (`FermixCore.Home.StatusWatch`, companion protocol
     6), which tells a version 6 connection when Always On changed: before the
     connections, so a restart that forgets who it tells takes them down
     with it, and they subscribe again,
  4. `Companion.Inbox`, the directory the owner's app hands the daemon a file
     in (companion protocol 7), emptied when it starts: before the
     connections, so a restart that empties it takes down the connections
     whose files it removed, and their apps send them again,
  5. a `DynamicSupervisor` for the connections, one `temporary` child each,
  6. the `Endpoint`, which binds `companion.sock` and accepts.

  A desktop's device-role engine after a move (`:tunnel`, M75 §6) serves the
  same socket for its app, but hands each connection to a `Desktop.Tunnel`
  that carries it to the primary through the desktop relay, and its media
  grants are made from the blobs the relay fetched (`Desktop.Relay.Media`)
  rather than from a phone store. Its connections are the primary's, whose
  inbox is on another computer, so it starts no inbox of its own.
  `:tunnel` is `[relay: server, staging: dir]`, or `nil` (every other engine).

  `:rest_for_one`: a registry restart would leave every connection unregistered
  and deaf, so it takes the later children down with it and clients reconnect.
  `Approvals` starts before the socket's children, which read it at every
  client's hello and at every approval's resolution.
  """

  use Supervisor

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Connection
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Inbox
  alias FermixChannels.Companion.MediaGrants
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Desktop.Relay.Media, as: RelayMedia
  alias FermixChannels.Desktop.Tunnel
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Home.StatusWatch

  @connection_supervisor FermixChannels.Companion.ConnectionSupervisor
  @request_coordinator FermixChannels.Companion.RequestCoordinator

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The registered name of this transport's request coordinator."
  @spec request_coordinator() :: atom()
  def request_coordinator, do: @request_coordinator

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Companion.registry())
    approvals = Keyword.get(opts, :approvals, Approvals)
    {settle?, serve?} = posture(opts)

    children =
      [{Registry, keys: :duplicate, name: registry}] ++
        settling(settle?) ++
        [approvals_child(approvals, registry)] ++
        serving(serve?, opts, registry, approvals)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # The socket hands every turn to Turns, so a boot that serves settles too.
  defp posture(opts) do
    case {Keyword.fetch!(opts, :settle?), Keyword.fetch!(opts, :serve?)} do
      {false, true} ->
        raise ArgumentError, "a companion tree that serves the socket must settle its turns"

      {settle?, serve?} when is_boolean(settle?) and is_boolean(serve?) ->
        {settle?, serve?}
    end
  end

  # A card and its end are announced to the connections of this tree's
  # registry, or to the phones, whichever transport raised it.
  defp approvals_child(approvals, registry) do
    {Approvals,
     name: approvals,
     announce: &Fanout.announce(&1, &2, companion_registry: registry, audience: &3)}
  end

  defp settling(true), do: [Turns]
  defp settling(false), do: []

  defp serving(true, opts, registry, approvals), do: socket_children(opts, registry, approvals)
  defp serving(false, _opts, _registry, _approvals), do: []

  # `:media_grants_opts` are `MediaGrants.start_link/1`'s: a test tree names
  # its own server and a temporary root, never the home's; `:status_watch_opts`
  # are `StatusWatch.start_link/1`'s, a test tree's own name and read;
  # `:inbox_opts` are `Inbox.start_link/1`'s, a test tree's own name, directory
  # and store.
  defp socket_children(opts, registry, approvals) do
    coordinator = Keyword.get(opts, :request_coordinator, @request_coordinator)
    connection_supervisor = Keyword.get(opts, :connection_supervisor, @connection_supervisor)
    store_opts = Keyword.get(opts, :store_opts, [])

    tunnel = Keyword.get(opts, :tunnel)

    media_grants_opts =
      opts
      |> Keyword.get(:media_grants_opts, [])
      |> Keyword.put_new(:name, MediaGrants)
      |> tunnel_blobs(tunnel)

    media_grants = Keyword.fetch!(media_grants_opts, :name)

    status_watch_opts =
      opts |> Keyword.get(:status_watch_opts, []) |> Keyword.put_new(:name, StatusWatch)

    status_watch = Keyword.fetch!(status_watch_opts, :name)

    inbox_opts = opts |> Keyword.get(:inbox_opts, []) |> Keyword.put_new(:name, Inbox)

    request_opts = [
      request_coordinator: coordinator,
      store_opts: store_opts,
      agent: Turns,
      settlement_owner: Turns,
      approvals: approvals
    ]

    [
      Supervisor.child_spec(
        {RequestCoordinator,
         name: coordinator,
         boot_epoch: Keyword.fetch!(opts, :boot_epoch),
         store_opts: [transport: "companion"] ++ store_opts,
         recover_request: &Connection.recover_request/3},
        id: coordinator
      ),
      Supervisor.child_spec({MediaGrants, media_grants_opts}, id: media_grants),
      Supervisor.child_spec({StatusWatch, status_watch_opts}, id: status_watch)
    ] ++
      inbox_child(tunnel, inbox_opts) ++
      [
        {DynamicSupervisor, name: connection_supervisor, strategy: :one_for_one},
        {Endpoint,
         Keyword.take(opts, [:socket_path, :max_clients]) ++
           [connection_supervisor: connection_supervisor] ++
           connections(
             tunnel,
             [media_grants: media_grants, status_watch: status_watch],
             registry: registry,
             request_opts: request_opts,
             approvals: approvals,
             inbox: Keyword.fetch!(inbox_opts, :name)
           )}
      ]
  end

  # Only an engine that runs its connections itself takes files in.
  defp inbox_child(nil, inbox_opts),
    do: [Supervisor.child_spec({Inbox, inbox_opts}, id: Keyword.fetch!(inbox_opts, :name))]

  defp inbox_child(_tunnel, _inbox_opts), do: []

  # `shared` (the media grants and the Always On watch) go to every
  # connection of either kind, `ordinary` (the registry, the request path,
  # the approvals and the inbox) to a `Companion.Connection` alone.
  defp connections(nil, shared, ordinary), do: [connection_opts: ordinary ++ shared]

  defp connections(tunnel, shared, _ordinary) do
    [
      connection_module: Tunnel,
      connection_opts:
        [relay: Keyword.fetch!(tunnel, :relay), staging: Keyword.fetch!(tunnel, :staging)] ++
          shared
    ]
  end

  # A desktop's grants are made from what its relay staged.
  defp tunnel_blobs(grants_opts, nil), do: grants_opts

  defp tunnel_blobs(grants_opts, tunnel) do
    staging = Keyword.fetch!(tunnel, :staging)
    Keyword.put_new(grants_opts, :blob, &RelayMedia.staged_blob(staging, &1))
  end
end
