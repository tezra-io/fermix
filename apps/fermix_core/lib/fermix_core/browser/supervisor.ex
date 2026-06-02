defmodule FermixCore.Browser.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry, FermixCore.Browser.Registry)
    dynamic_name = Keyword.get(opts, :dynamic_supervisor, FermixCore.Browser.DynamicSupervisor)
    manager_name = Keyword.get(opts, :profile_manager, FermixCore.Browser.ProfileManager)

    children = [
      {Registry, keys: :unique, name: registry_name},
      {DynamicSupervisor, strategy: :one_for_one, name: dynamic_name},
      {FermixCore.Browser.ProfileManager,
       name: manager_name, dynamic_supervisor: dynamic_name, registry: registry_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
