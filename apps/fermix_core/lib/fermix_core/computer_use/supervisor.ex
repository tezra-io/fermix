defmodule FermixCore.ComputerUse.Supervisor do
  @moduledoc """
  Supervises the computer-use session infrastructure: a unique-key `Registry`
  (conversation_key → session pid), a `DynamicSupervisor` that owns the
  per-conversation `ComputerUse.Session` processes, and the global processes
  that must outlive those `:temporary` sessions to be worth anything — the
  `CaptureHealth` breaker, the `InputOwner` that holds the machine's one native
  input seat across conversations, and the `HelperActions` reading the tool's
  action enum is built from.

  Started from the application tree only when computer-use is enabled AND ready
  (`maybe_computer_use_supervisor/0`), so nothing here boots — and no OS-driver
  process is ever spawned — while the feature is off (the default).
  """

  use Supervisor

  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.ComputerUse.HelperActions
  alias FermixCore.ComputerUse.InputOwner
  alias FermixCore.ComputerUse.OperatorStop

  # The boot read spawns the installed helper, so it is gated on the compile-time
  # env (the scheduler precedent): a test that starts this tree must never reach
  # whatever helper the host has installed. `HelperActionsTest` drives the read
  # through its own seam.
  @compiled_env Mix.env()

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
      InputOwner,
      OperatorStop,
      {HelperActions, read_at_boot?: @compiled_env != :test},
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @session_supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
