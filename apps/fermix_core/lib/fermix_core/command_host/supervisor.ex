defmodule FermixCore.CommandHost.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-command `FermixCore.CommandHost` owners.

  Children are `:temporary` — a host crash is a single-command fault (one port),
  never a daemon-level fault, and a completed command must not be restarted.
  Wired as the first child of the `FermixCore.Application` tree (`:rest_for_one`)
  so every process that can run a command starts after it exists; being
  `:temporary`, its children add no restart intensity to that tree.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
