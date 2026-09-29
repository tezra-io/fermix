defmodule FermixChannels.BrowserHost.Supervisor do
  @moduledoc """
  The browser host socket's subtree, started by `FermixChannels.Application`
  on every boot. When the boot serves (a daemon run, never a test tree) it
  holds, in dependency order:

  1. a `DynamicSupervisor` for the host's connection, one `temporary` child,
  2. the `Endpoint`, which binds `browser_host.sock` and accepts.

  `:one_for_all`: the endpoint is what knows a host is attached, so neither
  outlives the other. An endpoint that restarts takes the connection with it,
  and the app reconnects to the fresh listener as the one host.
  """

  use Supervisor

  alias FermixChannels.BrowserHost.Endpoint

  @connection_supervisor FermixChannels.BrowserHost.ConnectionSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = if Keyword.fetch!(opts, :serve?), do: socket_children(opts), else: []
    Supervisor.init(children, strategy: :one_for_all)
  end

  defp socket_children(opts) do
    connection_supervisor = Keyword.get(opts, :connection_supervisor, @connection_supervisor)

    [
      {DynamicSupervisor, name: connection_supervisor, strategy: :one_for_one},
      {Endpoint,
       Keyword.take(opts, [:socket_path, :host_availability, :connection_opts]) ++
         [connection_supervisor: connection_supervisor]}
    ]
  end
end
