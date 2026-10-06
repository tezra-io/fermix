defmodule FermixCore.Realtime.Supervisor do
  @moduledoc """
  Supervisor for the local Realtime voice runtime.
  """

  use Supervisor

  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSweep
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket
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

    # The call registry first: a Live session claims its call there from its
    # own `init/1`. The record sweep before the socket: its cutoff must
    # precede every call this boot starts.
    children = [
      {CallRegistry, name: Keyword.get(opts, :call_registry_name, CallRegistry)},
      {CallSweep, Keyword.take(opts, [:record_repo])},
      {SessionSupervisor, name: session_name},
      {Task.Supervisor, name: task_name},
      {LocalVoiceSocket,
       socket_path: socket_path,
       name: socket_name,
       task_supervisor: task_name,
       session_supervisor: session_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
