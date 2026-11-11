defmodule FermixCore.ComputerUse.Supervisor do
  @moduledoc """
  Supervises the computer-use session infrastructure: a unique-key `Registry`
  (conversation_key → session pid), a `DynamicSupervisor` that owns the
  per-conversation `ComputerUse.Session` processes, and the global processes
  that must outlive those `:temporary` sessions to be worth anything — the
  `CaptureHealth` breaker, the `InputOwner` that holds the machine's one native
  input seat across conversations, and the `HelperActions` reading the tool's
  action enum is built from (and, on a linked computer, its offer to its
  server, M97 §6.4).

  Started from the application tree when computer-use is enabled AND ready, on
  a primary that may drive a computer's screen (`ComputerUse.drives_computers?/1`)
  and on a linked computer whose screen its server may drive
  (`ComputerUse.driven?/1`); otherwise nothing here boots — and no OS-driver
  process is ever spawned. A session or a seat spawns a helper only when asked.
  """

  use Supervisor

  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.ComputerUse.HelperActions
  alias FermixCore.ComputerUse.InputOwner
  alias FermixCore.ComputerUse.OperatorStop

  # The boot read spawns the installed helper, so it is gated on the compile-time
  # env (the scheduler precedent): a test that starts this tree must never reach
  # whatever helper the host has installed. `HelperActionsTest` drives the read
  # through its own seam. It runs only where this machine's own screen is used:
  # here, or by its server; a server that drives only its computers' screens
  # reads theirs from their offers (`ComputerUse.Reach`).
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
      {HelperActions, read_at_boot?: @compiled_env != :test and own_screen?()},
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @session_supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp own_screen?, do: ComputerUse.ready?() or ComputerUse.driven?()
end
