defmodule FermixChannels.Companion.Supervisor do
  @moduledoc """
  The companion chat socket's subtree, started by `FermixChannels.Application`
  on every boot.

  The registry the channel adapter broadcasts through is always present, so a
  delivery to the companion timeline never depends on a client being connected.
  When the boot serves (a daemon run, never a test tree), the socket follows,
  in dependency order:

  1. the request coordinator for this transport, on the boot's shared epoch, so
     a companion request that a crash left unfinished is rerun at boot,
  2. a `DynamicSupervisor` for the connections, one `temporary` child each,
  3. the `Endpoint`, which binds `companion.sock` and accepts.

  `:rest_for_one`: a registry restart would leave every connection unregistered
  and deaf, so it takes the later children down with it and clients reconnect.
  """

  use Supervisor

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Connection
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Mobile.RequestCoordinator

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
    children = [{Registry, keys: :duplicate, name: registry}] ++ serving(opts, registry)
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp serving(opts, registry) do
    if Keyword.fetch!(opts, :serve?), do: socket_children(opts, registry), else: []
  end

  defp socket_children(opts, registry) do
    coordinator = Keyword.get(opts, :request_coordinator, @request_coordinator)
    connection_supervisor = Keyword.get(opts, :connection_supervisor, @connection_supervisor)
    store_opts = Keyword.get(opts, :store_opts, [])
    request_opts = [request_coordinator: coordinator, store_opts: store_opts]

    [
      Supervisor.child_spec(
        {RequestCoordinator,
         name: coordinator,
         boot_epoch: Keyword.fetch!(opts, :boot_epoch),
         store_opts: [transport: "companion"] ++ store_opts,
         recover_request: &Connection.recover_request/3},
        id: coordinator
      ),
      {DynamicSupervisor, name: connection_supervisor, strategy: :one_for_one},
      {Endpoint,
       Keyword.take(opts, [:socket_path, :max_clients]) ++
         [
           connection_supervisor: connection_supervisor,
           connection_opts: [registry: registry, request_opts: request_opts]
         ]}
    ]
  end
end
