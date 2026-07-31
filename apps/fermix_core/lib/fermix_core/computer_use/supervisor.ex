defmodule FermixCore.ComputerUse.Supervisor do
  @moduledoc """
  Supervises the computer-use session infrastructure: a unique-key `Registry`
  (conversation_key → session pid), a `DynamicSupervisor` that owns the
  per-conversation `ComputerUse.Session` processes, and the global
  `CaptureHealth` breaker (which must outlive those `:temporary` sessions to be
  worth anything).

  Started from the application tree only when computer-use is enabled AND ready
  (`maybe_computer_use_supervisor/0`), so nothing here boots — and no OS-driver
  process is ever spawned — while the feature is off (the default).
  """

  use Supervisor

  alias FermixCore.ComputerUse.CaptureHealth

  @registry FermixCore.ComputerUse.SessionRegistry
  @session_supervisor FermixCore.ComputerUse.SessionSupervisor

  @spec registry() :: atom()
  def registry, do: @registry

  @spec session_supervisor() :: atom()
  def session_supervisor, do: @session_supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      CaptureHealth,
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @session_supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
