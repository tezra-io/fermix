defmodule FermixCore.NativeHost.Supervisor do
  @moduledoc """
  The native host socket's subtree (M76 §4.4), started by
  `FermixCore.Application` only where it serves: a daemon whose
  `Native.Provider` is `:mac_app`, the Fermix app's own engine on a Mac. It
  holds, in dependency order:

  1. `Native.HostAvailability`, the record every caller reads,
  2. a `DynamicSupervisor` for the app's link, one `temporary` child,
  3. the `Server`, which binds `native_host.sock` and accepts.

  `:one_for_all`: the server is what knows an app is attached, and the record
  is what callers read it by, so none outlives the others. A restart takes the
  link with it, and the app reconnects to the fresh listener as the one host.
  """

  use Supervisor

  alias FermixCore.Native.HostAvailability
  alias FermixCore.NativeHost.Server

  @connection_supervisor FermixCore.NativeHost.ConnectionSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    host_availability = Keyword.get(opts, :host_availability, HostAvailability)
    connection_supervisor = Keyword.get(opts, :connection_supervisor, @connection_supervisor)

    children = [
      {HostAvailability, name: host_availability},
      {DynamicSupervisor, name: connection_supervisor, strategy: :one_for_one},
      {Server,
       Keyword.take(opts, [:socket_path, :link_opts]) ++
         [
           name: Keyword.get(opts, :server_name, Server),
           host_availability: host_availability,
           connection_supervisor: connection_supervisor
         ]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
