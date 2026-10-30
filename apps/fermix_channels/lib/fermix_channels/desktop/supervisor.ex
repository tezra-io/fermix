defmodule FermixChannels.Desktop.Supervisor do
  @moduledoc """
  The primary's connected desktops (M75 §3): the registry of their peers by
  device id (`FermixChannels.Desktop.Peers`), the supervisor each desktop
  session's `Desktop.Peer` runs under (`FermixChannels.Desktop.PeerSupervisor`),
  and the one the companion connections of their tunnels run under
  (`FermixChannels.Desktop.TunnelSupervisor`, M75 §6), apart from the local
  socket's so neither counts against the other's clients.

  It runs inside the phone channel's subtree (`Mobile.Supervisor`), the
  carriers' sessions it serves, which only the primary role starts. The two go
  together: a peer is registered for as long as it runs.
  """

  use Supervisor

  @registry FermixChannels.Desktop.Peers
  @peer_supervisor FermixChannels.Desktop.PeerSupervisor
  @tunnel_supervisor FermixChannels.Desktop.TunnelSupervisor

  @doc """
  Starts the registry, the peers' supervisor and the supervisor of the
  companion connections each desktop's tunnel runs (`Desktop.Companion`).
  `:registry`, `:peer_supervisor` and `:tunnel_supervisor` name them (a
  test's own); `:name` names this supervisor. A tree that does not run under
  this supervisor's own name and names no tunnel supervisor gets an unnamed
  one, so a test tree never takes the engine's name.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: Keyword.get(opts, :registry, @registry)},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Keyword.get(opts, :peer_supervisor, @peer_supervisor)},
      Supervisor.child_spec({DynamicSupervisor, tunnel_supervisor_opts(opts)}, id: :tunnels)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp tunnel_supervisor_opts(opts) do
    default = if Keyword.get(opts, :name, __MODULE__) == __MODULE__, do: @tunnel_supervisor

    case Keyword.get(opts, :tunnel_supervisor, default) do
      nil -> [strategy: :one_for_one]
      name -> [strategy: :one_for_one, name: name]
    end
  end
end
