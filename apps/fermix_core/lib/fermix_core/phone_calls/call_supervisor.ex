defmodule FermixCore.PhoneCalls.CallSupervisor do
  @moduledoc """
  The dynamic supervisor of per-call workers (M94 §04), the
  `Harness.RunSupervisor` shape. `PhoneCalls.Manager` starts every child with
  a spec it builds itself, `restart: :temporary`, so a worker that dies is
  never restarted and its dial never replayed: the Manager, which monitors
  each one, settles its row by what the row proves.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
