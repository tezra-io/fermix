defmodule FermixCore.Realtime.SessionGuardTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.SessionGuard
  alias FermixTestSupport.CallLeases

  # Answers the one `SessionControl` verb a teardown sends, telling the test,
  # blocks in it while the test holds it closed, and then ends itself, as every
  # engine session does on `call_stop`. Given a lease, it takes the home's call
  # in `init/1` as an engine session does.
  defmodule StoppableSession do
    use GenServer

    alias FermixCore.Realtime.CallLease

    # Unlinked, as a session under its supervisor is to its adapter. It ends
    # with the test that started it, from whichever process started it.
    def start(observer, opts \\ []), do: GenServer.start(__MODULE__, {observer, opts})

    @impl true
    def init({observer, opts}) do
      Process.monitor(observer)

      case take_lease(opts[:lease]) do
        :ok -> {:ok, %{observer: observer, block?: opts[:block?] == true}}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, observer, _reason}, %{observer: observer} = state),
      do: {:stop, :normal, state}

    defp take_lease(nil), do: :ok
    defp take_lease(lease), do: CallLease.acquire(lease, :desktop, "openai_realtime")

    @impl true
    def handle_call(:call_stop, _from, state) do
      send(state.observer, {:call_stop, self()})
      if state.block?, do: wait_for_release(state.observer)
      {:stop, :normal, :ok, state}
    end

    defp wait_for_release(observer) do
      receive do
        :release_stop -> :ok
      after
        10_000 -> send(observer, {:stop_never_released, self()})
      end
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    tasks = start_supervised!({Task.Supervisor, name: :"guard_tasks_#{unique}"})
    guard = :"session_guard_#{unique}"
    start_supervised!({SessionGuard, name: guard, task_supervisor: tasks})
    %{guard: guard}
  end

  test "a session is torn down when the adapter that owns it crashes", %{guard: guard} do
    {:ok, session} = StoppableSession.start(self())
    session_ref = Process.monitor(session)
    owner = own_session(guard, session)

    Process.exit(owner, :kill)

    assert_receive {:call_stop, ^session}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
  end

  test "a session is torn down when its adapter exits normally without releasing it", %{
    guard: guard
  } do
    {:ok, session} = StoppableSession.start(self())
    session_ref = Process.monitor(session)
    owner = own_session(guard, session)

    send(owner, :exit)

    assert_receive {:call_stop, ^session}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
  end

  # The adapter tore its session down itself: the guard forgets it, and the
  # adapter's later exit stops nothing.
  test "a released session is left alone when its adapter exits", %{guard: guard} do
    {:ok, session} = StoppableSession.start(self())
    owner = own_session(guard, session)

    send(owner, {:release, self()})
    assert_receive {:released, :ok}
    assert :sys.get_state(guard).bindings == %{}

    owner_ref = Process.monitor(owner)
    send(owner, :exit)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    # The guard has handled the owner's exit by the time it answers this.
    assert :sys.get_state(guard).bindings == %{}
    refute_received {:call_stop, ^session}
    assert Process.alive?(session)
  end

  # A slow settle must never hold up the guard: it answers the next adapter
  # while a teardown is still waiting on its session.
  test "a teardown runs off the guard's own loop", %{guard: guard} do
    {:ok, slow} = StoppableSession.start(self(), block?: true)
    owner = own_session(guard, slow)

    Process.exit(owner, :kill)
    assert_receive {:call_stop, ^slow}

    {:ok, other} = StoppableSession.start(self())
    second_owner = own_session(guard, other)
    assert %{^second_owner => _binding} = :sys.get_state(guard).bindings

    send(slow, :release_stop)
    refute_received {:stop_never_released, ^slow}
  end

  test "an adapter starts one session at a time", %{guard: guard} do
    {:ok, first} = StoppableSession.start(self())
    owner = own_session(guard, first)
    test_pid = self()

    send(owner, {:start, fn _opts -> send(test_pid, :started_twice) end, self()})
    assert_receive {:started, {:error, {:already_bound, ^first}}}
    refute_received :started_twice
  end

  # A refusal from the engine (the lease, a missing key) reaches the adapter
  # as it was given, and the guard keeps nothing of the start.
  test "a start that fails answers its own reason", %{guard: guard} do
    refusal = {:error, {:call_in_progress, "accessory:desk-robot"}}

    assert start_from_adapter(guard, fn _opts -> refusal end) == refusal
    assert %{bindings: bindings, starts: starts} = :sys.get_state(guard)
    assert bindings == %{}
    assert starts == %{}
  end

  @tag :capture_log
  test "a start that crashes is a typed failure, and the guard lives on", %{guard: guard} do
    assert {:error, {:session_start_failed, _reason}} =
             start_from_adapter(guard, fn _opts -> raise "engine init blew up" end)

    assert %{bindings: bindings, starts: starts} = :sys.get_state(guard)
    assert bindings == %{}
    assert starts == %{}
  end

  # A start runs off the guard's loop: while one is still in an engine's
  # `init/1`, another adapter's crash is torn down.
  test "a slow start holds up no teardown", %{guard: guard} do
    {:ok, slow} = StoppableSession.start(self())
    slow_owner = start_in_adapter(guard, held_starter(slow))
    assert_receive {:start_held, start}

    {:ok, other} = StoppableSession.start(self())
    other_owner = own_session(guard, other)
    Process.exit(other_owner, :kill)
    assert_receive {:call_stop, ^other}

    send(start, :finish_start)
    assert_receive {:started, ^slow_owner, {:ok, ^slow}}
  end

  # The adapter waits a bounded time. A start past it is refused, and the
  # session it still makes is torn down the moment it arrives, its call freed.
  test "a start past its bound is refused, and its late session is torn down", %{guard: guard} do
    lease = CallLeases.own!()
    {:ok, late} = StoppableSession.start(self(), lease: lease)
    late_ref = Process.monitor(late)
    owner = start_in_adapter(guard, held_starter(late))
    assert_receive {:start_held, start}

    # The bound's expiry, delivered by hand.
    [start_ref] = guard |> :sys.get_state() |> Map.fetch!(:starts) |> Map.keys()
    send(guard, {:start_timeout, start_ref})
    assert_receive {:started, ^owner, {:error, :session_start_timeout}}
    assert :sys.get_state(guard).bindings == %{}

    send(start, :finish_start)
    assert_receive {:call_stop, ^late}
    assert_receive {:DOWN, ^late_ref, :process, ^late, :normal}
    assert CallLease.holder(lease) == :none
    assert :sys.get_state(guard).starts == %{}
  end

  # A start's bound firing after its session was bound is stale: the binding
  # stays, and no one gets a second answer.
  test "a late start timeout after a bind changes nothing", %{guard: guard} do
    {:ok, session} = StoppableSession.start(self())
    owner = start_in_adapter(guard, held_starter(session))
    assert_receive {:start_held, start}
    [start_ref] = guard |> :sys.get_state() |> Map.fetch!(:starts) |> Map.keys()
    send(start, :finish_start)
    assert_receive {:started, ^owner, {:ok, ^session}}
    bound = :sys.get_state(guard)

    send(guard, {:start_timeout, start_ref})

    assert :sys.get_state(guard) == bound
    assert {:messages, []} = Process.info(owner, :messages)
  end

  @tag :capture_log
  test "a starter that answers neither ok nor error is a typed bad return", %{guard: guard} do
    assert start_from_adapter(guard, fn _opts -> :ok end) ==
             {:error, {:session_start_failed, {:bad_return, :ok}}}
  end

  # The guard is the first child of its `:rest_for_one` tree: nothing it is
  # sent may crash it, since its restart ends every session.
  @tag :capture_log
  test "a message the guard does not know changes nothing", %{guard: guard} do
    before = guarding_one(guard)
    send(guard, :not_a_guard_message)
    assert :sys.get_state(guard) == before
  end

  @tag :capture_log
  test "a call the guard does not know is refused, and changes nothing", %{guard: guard} do
    before = guarding_one(guard)
    assert GenServer.call(guard, :not_a_guard_call) == {:error, :unknown_call}
    assert :sys.get_state(guard) == before
  end

  @tag :capture_log
  test "a cast the guard does not know changes nothing", %{guard: guard} do
    before = guarding_one(guard)
    GenServer.cast(guard, :not_a_guard_cast)
    assert :sys.get_state(guard) == before
  end

  test "a guard that is not running is a typed refusal, not an exit" do
    missing = :"session_guard_missing_#{System.unique_integer([:positive])}"
    test_pid = self()
    starter = fn _opts -> send(test_pid, :started_unguarded) end

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        SessionGuard.start_session(missing, starter, [], SessionControl)
      end)

    assert result == {:error, :session_guard_unavailable}
    assert log =~ "session guard"
    refute_received :started_unguarded
  end

  # The guard's state while it guards one adapter's session.
  defp guarding_one(guard) do
    {:ok, session} = StoppableSession.start(self())
    _owner = own_session(guard, session)
    :sys.get_state(guard)
  end

  # An adapter stand-in: has the guard start `session` for it from its own
  # process, then does what the test tells it.
  defp own_session(guard, session) do
    owner = start_in_adapter(guard, fn _opts -> {:ok, session} end)
    assert_receive {:started, ^owner, {:ok, ^session}}
    owner
  end

  defp start_in_adapter(guard, starter) do
    test_pid = self()

    spawn(fn ->
      send(test_pid, {:started, self(), start(guard, starter)})
      adapter_loop(guard, test_pid)
    end)
  end

  defp start_from_adapter(guard, starter) do
    owner = start_in_adapter(guard, starter)
    assert_receive {:started, ^owner, result}
    result
  end

  defp start(guard, starter), do: SessionGuard.start_session(guard, starter, [], SessionControl)

  # A start that stands still once its session exists, until the test lets it
  # hand the session over; bounded, so it never outlives its test for long.
  defp held_starter(session) do
    test_pid = self()

    fn _opts ->
      send(test_pid, {:start_held, self()})

      receive do
        :finish_start -> {:ok, session}
      after
        10_000 -> {:ok, session}
      end
    end
  end

  defp adapter_loop(guard, test_pid) do
    receive do
      {:release, ^test_pid} ->
        send(test_pid, {:released, SessionGuard.release(guard)})
        adapter_loop(guard, test_pid)

      {:start, starter, ^test_pid} ->
        send(test_pid, {:started, start(guard, starter)})
        adapter_loop(guard, test_pid)

      :exit ->
        :ok
    after
      10_000 -> :ok
    end
  end
end
