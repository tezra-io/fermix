defmodule FermixCore.Realtime.SupervisorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.Realtime.SessionSupervisor

  # Stands in for whichever engine module the caller names, so the supervisor's
  # engine dispatch is testable without a provider socket. It answers the
  # `SessionControl` messages the supervisor sends.
  defmodule EngineDouble do
    @moduledoc false
    use GenServer

    def child_spec(opts) when is_list(opts) do
      %{
        id: {__MODULE__, Keyword.get(opts, :session_scope, make_ref())},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        type: :worker
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:reload_runtime, _from, opts),
      do: {:reply, {:ok, %{tools: 0, applies: :next_call}}, opts}

    def handle_call(:opts, _from, opts), do: {:reply, opts, opts}
  end

  test "starts session supervisor and local voice socket" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-supervisor-#{System.unique_integer([:positive])}.sock"
      )

    name = :"rt_supervisor_#{System.unique_integer([:positive])}"
    socket_name = :"rt_socket_#{System.unique_integer([:positive])}"
    session_name = :"rt_sessions_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Realtime.Supervisor.start_link(
        name: name,
        socket_path: socket_path,
        socket_name: socket_name,
        session_supervisor_name: session_name
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    assert Process.whereis(socket_name)
    assert Process.whereis(session_name)
    assert LocalVoiceSocket.active_clients(socket_name) == {:ok, 0}
    assert SessionSupervisor.active_sessions(session_name) == 0
  end

  test "supervisor shutdown removes the realtime socket path" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-shutdown-#{System.unique_integer([:positive])}.sock"
      )

    name = :"rt_shutdown_supervisor_#{System.unique_integer([:positive])}"
    socket_name = :"rt_shutdown_socket_#{System.unique_integer([:positive])}"
    session_name = :"rt_shutdown_sessions_#{System.unique_integer([:positive])}"
    task_name = :"rt_shutdown_tasks_#{System.unique_integer([:positive])}"

    previous_trap_exit = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    {:ok, supervisor} =
      Realtime.Supervisor.start_link(
        name: name,
        socket_path: socket_path,
        socket_name: socket_name,
        session_supervisor_name: session_name,
        task_supervisor_name: task_name
      )

    assert File.exists?(socket_path)
    :ok = Supervisor.stop(supervisor, :shutdown, 1_000)

    refute File.exists?(socket_path)
  end

  test "session children are not restarted after normal shutdown" do
    session_name = :"rt_sessions_#{System.unique_integer([:positive])}"

    {:ok, supervisor} = SessionSupervisor.start_link(name: session_name)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    {:ok, session} =
      SessionSupervisor.start_session(session_name,
        engine_module: SessionServer,
        companion: self(),
        config: Config.normalize(enabled: true),
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert SessionSupervisor.active_sessions(session_name) == 1

    GenServer.stop(session, :normal, 1_000)

    wait_until(fn -> SessionSupervisor.active_sessions(session_name) == 0 end)
  end

  test "start_session starts the engine module the caller names" do
    session_name = :"rt_engine_#{System.unique_integer([:positive])}"
    {:ok, supervisor} = SessionSupervisor.start_link(name: session_name)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    assert {:ok, session} =
             SessionSupervisor.start_session(session_name,
               engine_module: EngineDouble,
               companion: self(),
               session_scope: "voice_live:1"
             )

    assert Keyword.get(GenServer.call(session, :opts), :session_scope) == "voice_live:1"
    assert SessionSupervisor.active_sessions(session_name) == 1
  end

  test "start_session refuses to guess an engine" do
    session_name = :"rt_no_engine_#{System.unique_integer([:positive])}"
    {:ok, supervisor} = SessionSupervisor.start_link(name: session_name)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    assert_raise KeyError, fn ->
      SessionSupervisor.start_session(session_name, companion: self())
    end
  end

  test "reload_sessions drives every engine through the session control seam" do
    session_name = :"rt_reload_#{System.unique_integer([:positive])}"
    {:ok, supervisor} = SessionSupervisor.start_link(name: session_name)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    for scope <- ["session:1", "voice_live:2"] do
      assert {:ok, _pid} =
               SessionSupervisor.start_session(session_name,
                 engine_module: EngineDouble,
                 companion: self(),
                 session_scope: scope
               )
    end

    assert {:ok, %{active: 2, reloaded: 2, failed: []}} =
             SessionSupervisor.reload_sessions(session_name)
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition did not become true")
end
