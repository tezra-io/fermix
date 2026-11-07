defmodule FermixCore.Realtime.Supervisor do
  @moduledoc """
  Supervisor for the local Realtime voice runtime.
  """

  use Supervisor

  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSweep
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionGuard
  alias FermixCore.Realtime.SessionSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    session_name = Keyword.get(opts, :session_supervisor_name, SessionSupervisor)
    task_name = Keyword.get(opts, :task_supervisor_name, FermixCore.Realtime.TaskSupervisor)
    socket_name = Keyword.get(opts, :socket_name, LocalVoiceSocket)
    socket_path = Keyword.get(opts, :socket_path, Config.socket_path())
    guard_name = Keyword.get(opts, :session_guard_name, SessionGuard)

    # The call lease and registry first: every session takes the home's one
    # call from its own `init/1`, and a task-engine session claims its chat
    # context. The record sweep before the socket: its cutoff must precede
    # every call this boot starts. The guarded sessions before the socket whose
    # calls they are.
    children = [
      {CallLease, name: Keyword.get(opts, :call_lease_name, CallLease)},
      {CallRegistry, name: Keyword.get(opts, :call_registry_name, CallRegistry)},
      {CallSweep, Keyword.take(opts, [:record_repo])},
      guarded_sessions(guard_name, task_name, session_name),
      {LocalVoiceSocket,
       socket_path: socket_path,
       name: socket_name,
       task_supervisor: task_name,
       session_supervisor: session_name,
       session_guard: guard_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The guard and what it answers for, under `:rest_for_one` with the guard
  # first: a guard restart takes down the task supervisor (its start and
  # teardown tasks, and the connections' handlers) and the session supervisor
  # (every session) with it, so a guard that comes back has nothing it forgot.
  # A task supervisor restart ends every session too, so no teardown is lost
  # to it. The guard is this tree's cascade root, and never raises on what it
  # is sent (`SessionGuard`); nothing before it here does I/O.
  defp guarded_sessions(guard_name, task_name, session_name) do
    children = [
      {SessionGuard, name: guard_name, task_supervisor: task_name},
      {Task.Supervisor, name: task_name},
      {SessionSupervisor, name: session_name}
    ]

    %{
      id: :guarded_sessions,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
    }
  end
end
