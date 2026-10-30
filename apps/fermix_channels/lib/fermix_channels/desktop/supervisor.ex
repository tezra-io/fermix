defmodule FermixChannels.Desktop.Supervisor do
  @moduledoc """
  The primary's connected desktops (M75 §3): the registry of their peers by
  device id (`FermixChannels.Desktop.Peers`) and the supervisor each desktop
  session's `Desktop.Peer` runs under (`FermixChannels.Desktop.PeerSupervisor`).

  It runs inside the phone channel's subtree (`Mobile.Supervisor`), the
  carriers' sessions it serves, which only the primary role starts. The two go
  together: a peer is registered for as long as it runs.
  """

  use Supervisor

  @registry FermixChannels.Desktop.Peers
  @peer_supervisor FermixChannels.Desktop.PeerSupervisor

  @doc """
  Starts the registry and the peers' supervisor. `:registry` and
  `:peer_supervisor` name them (a test's own); `:name` names this supervisor.
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
       strategy: :one_for_one, name: Keyword.get(opts, :peer_supervisor, @peer_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
