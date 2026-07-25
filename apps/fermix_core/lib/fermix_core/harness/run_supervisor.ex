defmodule FermixCore.Harness.RunSupervisor do
  @moduledoc """
  Dynamic supervisor for local coding-harness run workers (design §6.4).

  Each `Harness.Run` is a `:temporary` child (its `child_spec/1` sets
  `restart: :temporary`), so a crashed run is never restarted here — the
  `Harness.Manager` monitors every run it starts and terminalizes an abnormal
  DOWN as `failed/:run_crashed`. The supervisor exists only to own the process
  group lifecycle, mirroring `Jobs.RunnerSupervisor`.
  """

  use DynamicSupervisor

  alias FermixCore.Harness.Run

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @doc "Starts a run under the default supervisor from its `%{row, plan, …}` args."
  @spec start_run(map()) :: DynamicSupervisor.on_start_child()
  def start_run(args) when is_map(args), do: start_run(__MODULE__, args)

  @doc "Starts a run under `supervisor` from its `%{row, plan, …}` args."
  @spec start_run(Supervisor.supervisor(), map()) :: DynamicSupervisor.on_start_child()
  def start_run(supervisor, args) when is_map(args) do
    DynamicSupervisor.start_child(supervisor, {Run, args})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
