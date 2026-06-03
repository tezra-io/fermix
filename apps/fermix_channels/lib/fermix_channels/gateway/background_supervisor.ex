defmodule FermixChannels.Gateway.BackgroundSupervisor do
  @moduledoc """
  Groups the background `WorkRegistry` and its task `WorkSupervisor` under a
  `:rest_for_one` strategy.

  `WorkRegistry`'s state (work_id → pid/ref, status) cannot be reconstructed after
  a crash, so a restarted-empty registry would leave orphan tasks that `/stop`
  can no longer see and `/tasks` cannot show. `:rest_for_one` with the registry
  first means a registry crash also restarts the task supervisor after it, tearing
  down those now-unreachable tasks (§17.4).
  """

  use Supervisor

  alias FermixChannels.Gateway.WorkRegistry
  alias FermixChannels.Gateway.WorkSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [
      WorkRegistry,
      {Task.Supervisor, name: WorkSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
