defmodule FermixCore.Jobs.RunnerSupervisor do
  @moduledoc """
  Dynamic supervisor for scheduled job run workers.
  """

  use DynamicSupervisor

  alias FermixCore.Jobs.Runner

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @spec start_run(keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(opts) when is_list(opts), do: start_run(__MODULE__, opts)

  @spec start_run(Supervisor.supervisor(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(supervisor, opts) when is_list(opts) do
    {runner_module, opts} = Keyword.pop(opts, :runner_module, Runner)
    DynamicSupervisor.start_child(supervisor, {runner_module, opts})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
