defmodule FermixCore.Realtime.SupervisorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSweep
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.SessionGuard
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixTestSupport.CallLeases

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

  test "starts the call lease, call registry, session supervisor, guard and voice socket" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-supervisor-#{System.unique_integer([:positive])}.sock"
      )

    name = :"rt_supervisor_#{System.unique_integer([:positive])}"
    socket_name = :"rt_socket_#{System.unique_integer([:positive])}"
    session_name = :"rt_sessions_#{System.unique_integer([:positive])}"
    registry_name = :"rt_calls_#{System.unique_integer([:positive])}"
    lease_name = :"rt_lease_#{System.unique_integer([:positive])}"
    guard_name = :"rt_guard_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Realtime.Supervisor.start_link(
        name: name,
        socket_path: socket_path,
        socket_name: socket_name,
        session_supervisor_name: session_name,
        call_registry_name: registry_name,
        call_lease_name: lease_name,
        session_guard_name: guard_name
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    assert Process.whereis(socket_name)
    assert Process.whereis(session_name)
    assert LocalVoiceSocket.active_clients(socket_name) == {:ok, 0}
    assert SessionSupervisor.active_sessions(session_name) == 0
    assert CallRegistry.active(registry_name) == :none
    assert CallLease.holder(lease_name) == :none
    assert Process.whereis(guard_name)

    # The lease starts before the sessions that take it, and the guarded
    # sessions before the socket whose calls they are. Inside, the guard comes
    # first, so a guard restart ends its start tasks and every session too.
    ids = child_ids(pid)
    assert index_of(ids, lease_name) < index_of(ids, :guarded_sessions)
    assert index_of(ids, :guarded_sessions) < index_of(ids, LocalVoiceSocket)

    assert child_ids(guarded_sessions(pid)) ==
             [SessionGuard, FermixCore.Realtime.TaskSupervisor, SessionSupervisor]
  end

  # A guard restart would forget what it guards; instead it ends every
  # session it guarded, so none is left billing with the home's call held.
  test "a guard that dies ends every session it guarded, freeing the call" do
    tree = start_tree!("guard_down")
    owner = start_from_adapter(tree, &start_realtime(tree, &1))
    assert_receive {:started, ^owner, {:ok, session}}
    assert {:ok, %{endpoint: "desktop"}} = CallLease.holder(tree.lease)
    session_ref = Process.monitor(session)

    Process.exit(Process.whereis(tree.guard), :kill)

    assert_receive {:DOWN, ^session_ref, :process, ^session, _reason}
    assert CallLease.holder(tree.lease) == :none
    # Answered once the guarded sessions have restarted.
    assert child_ids(guarded_sessions(tree.supervisor)) == [
             SessionGuard,
             tree.tasks,
             SessionSupervisor
           ]

    assert %{bindings: bindings, starts: starts} = :sys.get_state(tree.guard)
    assert bindings == %{}
    assert starts == %{}
  end

  # A call never outlives what admitted it (`:rest_for_one` in start order): a
  # crash of the call lease or the call registry ends every session, the guard
  # tree and the socket, and the record sweep, restarted after the sessions are
  # gone, closes the records they left open. Stopped with `:shutdown`, as a
  # Registry fails: a kill races its partitions' names.
  for {label, crashed} <- [{"call lease", :lease}, {"call registry", :registry}] do
    @tag :capture_log
    test "a crashed #{label} ends the call in progress, closes its record and frees the lease" do
      tree = start_tree!("crash_#{unquote(crashed)}", records: true)
      :ok = await_child_done(tree.supervisor, CallSweep)
      owner = start_from_adapter(tree, &start_realtime(tree, &1))
      assert_receive {:started, ^owner, {:ok, session}}
      assert {:ok, %{endpoint: "desktop"}} = CallLease.holder(tree.lease)
      session_ref = Process.monitor(session)

      # The record the running call keeps, still open.
      uuid = "6d1e2f3a-4b5c-4d7e-8f9a-0b1c2d3e4f5a"
      opts = CallRecord.repo_opts(tree.repo)
      :ok = CallRecord.open(CallRecord.new(uuid, "openai_live"), DateTime.utc_now(), opts)

      :ok = Supervisor.stop(Map.fetch!(tree, unquote(crashed)), :shutdown)

      assert_receive {:DOWN, ^session_ref, :process, ^session, _reason}
      :ok = await_child_done(tree.supervisor, CallSweep)

      assert {:ok, %{end_reason: "daemon_restarted"}} =
               Repo.get_voice_call(uuid, server: tree.repo)

      next = start_from_adapter(tree, &start_realtime(tree, &1))
      assert_receive {:started, ^next, {:ok, next_session}}
      assert next_session != session
      assert {:ok, %{endpoint: "desktop"}} = CallLease.holder(tree.lease)
    end
  end

  # A start still running when its guard dies would finish onto the restarted
  # session supervisor and report to a guard that is gone: it dies with the
  # guard instead, and no session is made.
  @tag :capture_log
  test "a start in flight when its guard dies never makes a session" do
    tree = start_tree!("start_down")
    test_pid = self()

    held_start = fn opts ->
      send(test_pid, {:start_held, self()})

      receive do
        :finish_start -> start_realtime(tree, opts)
      after
        10_000 -> {:error, :start_never_finished}
      end
    end

    owner = start_from_adapter(tree, held_start)
    assert_receive {:start_held, start}
    start_ref = Process.monitor(start)

    Process.exit(Process.whereis(tree.guard), :kill)

    assert_receive {:DOWN, ^start_ref, :process, ^start, _reason}
    assert_receive {:started, ^owner, {:error, :session_guard_unavailable}}
    send(start, :finish_start)
    _restarted = child_ids(guarded_sessions(tree.supervisor))
    assert SessionSupervisor.active_sessions(tree.sessions) == 0
    assert CallLease.holder(tree.lease) == :none
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
    registry_name = :"rt_shutdown_calls_#{System.unique_integer([:positive])}"
    lease_name = :"rt_shutdown_lease_#{System.unique_integer([:positive])}"
    guard_name = :"rt_shutdown_guard_#{System.unique_integer([:positive])}"

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
        task_supervisor_name: task_name,
        call_registry_name: registry_name,
        call_lease_name: lease_name,
        session_guard_name: guard_name
      )

    assert File.exists?(socket_path)
    :ok = Supervisor.stop(supervisor, :shutdown, 1_000)

    refute File.exists?(socket_path)
  end

  test "the realtime tree closes the call records a restart left open" do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-realtime-sweep-#{unique}.sock")
    db_path = Path.join(System.tmp_dir!(), "fermix-realtime-sweep-#{unique}.db")
    repo = :"rt_sweep_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each(
        [socket_path, db_path, "#{db_path}-wal", "#{db_path}-shm"],
        &FermixTestSupport.SafeRm.rm/1
      )
    end)

    uuid = "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
    started_at = DateTime.add(DateTime.utc_now(), -60, :second)

    :ok =
      CallRecord.open(CallRecord.new(uuid, "openai_live"), started_at, CallRecord.repo_opts(repo))

    start_supervised!(
      {Realtime.Supervisor,
       name: :"rt_sweep_supervisor_#{unique}",
       socket_path: socket_path,
       socket_name: :"rt_sweep_socket_#{unique}",
       session_supervisor_name: :"rt_sweep_sessions_#{unique}",
       task_supervisor_name: :"rt_sweep_tasks_#{unique}",
       call_registry_name: :"rt_sweep_calls_#{unique}",
       call_lease_name: :"rt_sweep_lease_#{unique}",
       session_guard_name: :"rt_sweep_guard_#{unique}",
       record_repo: repo}
    )

    wait_until(fn ->
      match?({:ok, %{end_reason: "daemon_restarted"}}, Repo.get_voice_call(uuid, server: repo))
    end)
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
        endpoint: :desktop,
        call_lease: CallLeases.own!(),
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

  defp index_of(ids, id), do: Enum.find_index(ids, &(&1 == id))

  # A supervisor's children in start order.
  defp child_ids(supervisor),
    do: supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

  defp guarded_sessions(supervisor) do
    {:guarded_sessions, pid, :supervisor, _modules} =
      supervisor
      |> Supervisor.which_children()
      |> List.keyfind(:guarded_sessions, 0)

    pid
  end

  # A whole realtime tree under names of its own, stopped when the test ends;
  # with `records: true`, a record repo of its own for its sweep.
  defp start_tree!(label, opts \\ []) do
    unique = "#{label}_#{System.unique_integer([:positive])}"
    socket_path = Path.join(System.tmp_dir!(), "fermix-realtime-#{unique}.sock")

    tree = %{
      supervisor: :"rt_supervisor_#{unique}",
      sessions: :"rt_sessions_#{unique}",
      tasks: :"rt_tasks_#{unique}",
      lease: :"rt_lease_#{unique}",
      registry: :"rt_calls_#{unique}",
      guard: :"rt_guard_#{unique}",
      repo: record_repo(unique, Keyword.get(opts, :records, false))
    }

    {:ok, pid} =
      Realtime.Supervisor.start_link(
        [
          name: tree.supervisor,
          socket_path: socket_path,
          socket_name: :"rt_socket_#{unique}",
          session_supervisor_name: tree.sessions,
          task_supervisor_name: tree.tasks,
          call_registry_name: tree.registry,
          call_lease_name: tree.lease,
          session_guard_name: tree.guard
        ] ++ if(tree.repo, do: [record_repo: tree.repo], else: [])
      )

    # Linked to the test, its parent, so it shuts down as the test exits;
    # waited for before its socket path goes.
    on_exit(fn ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    tree
  end

  defp record_repo(_unique, false), do: nil

  defp record_repo(unique, true) do
    db_path = Path.join(System.tmp_dir!(), "fermix-realtime-#{unique}.db")
    repo = :"rt_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo
  end

  # A `:transient` child that finished shows `:undefined`; a running one is
  # awaited to its normal stop.
  defp await_child_done(supervisor, id) do
    {^id, pid, _type, _modules} = supervisor |> Supervisor.which_children() |> List.keyfind(id, 0)
    await_normal_exit(pid)
  end

  defp await_normal_exit(:undefined), do: :ok

  defp await_normal_exit(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    assert reason in [:normal, :noproc]
    :ok
  end

  # An adapter stand-in: has the tree's guard start a session for it, tells
  # the test what came back, then holds until its test ends.
  defp start_from_adapter(tree, starter) do
    test_pid = self()

    spawn(fn ->
      test_ref = Process.monitor(test_pid)

      result =
        SessionGuard.start_session(tree.guard, starter, [companion: self()], SessionControl)

      send(test_pid, {:started, self(), result})

      receive do
        {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> :ok
      after
        10_000 -> :ok
      end
    end)
  end

  # An OpenAI Realtime session under the tree's own supervisor and lease.
  defp start_realtime(tree, opts) do
    SessionSupervisor.start_session(
      tree.sessions,
      [
        engine_module: SessionServer,
        endpoint: :desktop,
        call_lease: tree.lease,
        config: Config.normalize(enabled: true),
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      ] ++ opts
    )
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
