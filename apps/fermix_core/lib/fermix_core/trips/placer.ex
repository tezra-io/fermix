defmodule FermixCore.Trips.Placer do
  @moduledoc """
  The trip placer (M89 D13 B): places the stops a trip keeps waiting
  (`Trips.Waiting`) once the home's place search can run again. Primary-only,
  in `FermixCore.Supervisor`'s tree.

  **What wakes it**, each a cast or a timer of its own, never a poll:

    * **boot**: the waits left from before a restart (`handle_continue/2`);
    * **a Mac that offers places**: `Computers.Registry` tells it when a
      computer's offers list Apple Maps on (`places_offered/2`);
    * **its one timer**: armed by a call that saved a wait
      (`waits_saved/1`, 5 min on) and by each run's answer (`Run`'s
      `next_ms`: Brave's reset while the key is spent, 5 min while waits are
      due, 6 h while no Mac that offers places is online, never later than
      the next wait put off comes due), the earlier of two wakes standing,
      every delay held between 1 min and 6 h. A run that met a fault (its
      store unreadable, a trip it could not read or write, a crash, its
      bound) is looked at again after 5 min, then 10, 20 and on, doubling
      to 6 h, and logged, until a run meets none. A wait ends after three
      tries that reached the place search or seven days, so the wakes end
      too.

  **One run at a time** (`Trips.Placer.Run`), each in a task of its own under
  `FermixCore.TaskSupervisor`: this process never waits on a run, a lookup or
  the store, so it answers every message at once (AGENTS: "A GenServer that
  blocks answers no call"). A trigger during a run runs once after it (at
  most one waits). The run links itself to this process, which traps exits:
  a run that raises is a message here, never a crash, and when this process
  ends (a restart under its tree, a kill), its run ends with it, so a new
  placer's run never overlaps an old one. Each run's session id is named
  here before it starts (`Trips.Telemetry.place_session_id/0`), so a run
  that raises, or one still running at 120 s (killed), is closed here with
  `run_error` under that session (`crashed` with the exception's kind, or
  `overran`) and its trace never waits for the sweep. It raises on nothing it
  is sent: an early child of a `:rest_for_one` tree must take down nothing
  after it ("Cascade roots"); an unexpected message is logged once each.

  `enabled: false` (`mix test`'s tree, `@compiled_env`) runs nothing and arms
  nothing. Seams: `:name`, `:enabled`, `:run` (2-arity, `Run.run/2`'s shape),
  `:run_opts` (a `:session_id` there names every run's session),
  `:task_supervisor`, `:timer` (2-arity, given the message and the delay,
  answering a reference, in place of `Process.send_after/3` to this process)
  and `:now_ms` (the monotonic clock the earlier wake is chosen by).
  """

  use GenServer

  require Logger

  alias FermixCore.Trips.Placer.Run
  alias FermixCore.Trips.Telemetry

  @soon_ms 5 * 60_000
  @min_wake_ms 60_000
  @max_wake_ms 6 * 3_600_000
  @max_run_ms 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The computer `device_id` says it offers Apple Maps: look the waiting stops
  up. A placer that does not run (a device, a test tree) hears nothing.
  """
  @spec places_offered(GenServer.server(), String.t()) :: :ok
  def places_offered(server \\ __MODULE__, device_id) when is_binary(device_id),
    do: GenServer.cast(server, {:trigger, :computer})

  @doc "A call saved a waiting stop: look again in 5 min unless sooner is armed."
  @spec waits_saved(GenServer.server()) :: :ok
  def waits_saved(server \\ __MODULE__), do: GenServer.cast(server, :saved)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      enabled?: Keyword.get(opts, :enabled, true),
      run: Keyword.get(opts, :run, &Run.run/2),
      run_opts: Keyword.get(opts, :run_opts, []),
      tasks: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      timer: Keyword.get(opts, :timer, &send_after/2),
      now_ms: Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end),
      running: nil,
      queued: nil,
      wake: nil,
      failures: 0
    }

    true = is_function(state.run, 2) and is_function(state.timer, 2)
    if state.enabled?, do: {:ok, state, {:continue, :boot}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:boot, state), do: {:noreply, trigger(state, :boot)}

  @impl true
  def handle_cast({:trigger, trigger}, state), do: {:noreply, trigger(state, trigger)}
  def handle_cast(:saved, %{enabled?: true} = state), do: {:noreply, arm(state, @soon_ms)}
  def handle_cast(:saved, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, result}, %{running: %{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finished() |> planned(result) |> start_queued()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref} = run} = state) do
    {code, kind} = if run.overran?, do: {"overran", "killed"}, else: {"crashed", kind(reason)}
    Logger.error("trips: a run placing waiting stops ended without answering: #{kind}")
    :ok = Telemetry.emit_place_error(run.meta, code, kind, elapsed(run.started_us))
    {:noreply, state |> finished() |> failed() |> start_queued()}
  end

  def handle_info({:overran, ref}, %{running: %{ref: ref, pid: pid} = run} = state) do
    Logger.error(
      "trips: a run placing waiting stops passed #{div(@max_run_ms, 1_000)} s, so it was stopped"
    )

    Process.exit(pid, :kill)
    {:noreply, %{state | running: %{run | overran?: true}}}
  end

  def handle_info({:wake, token}, %{wake: %{token: token}} = state),
    do: {:noreply, trigger(%{state | wake: nil}, :timer)}

  # A wake replaced, a run's guard after it ended, the exit of a run it
  # linked to (its result or its DOWN says how it ended): nothing to do.
  def handle_info({:wake, _token}, state), do: {:noreply, state}
  def handle_info({:overran, _ref}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.warning("trips: the placer was sent #{inspect(message, limit: 5)}, which it ignores")
    {:noreply, state}
  end

  # -- runs ----------------------------------------------------------------------

  defp trigger(%{enabled?: false} = state, _trigger), do: state
  defp trigger(%{running: nil} = state, trigger), do: start(state, trigger)
  defp trigger(state, trigger), do: %{state | queued: trigger}

  # A run answers when to look next, so a wake armed before it is let go. Its
  # session is named here, so this process can close it; the run links to
  # this process before it does anything, so it never outlives it.
  defp start(state, trigger) do
    placer = self()
    session_id = Keyword.get_lazy(state.run_opts, :session_id, &Telemetry.place_session_id/0)
    opts = Keyword.put(state.run_opts, :session_id, session_id)
    run = state.run

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        true = Process.link(placer)
        run.(trigger, opts)
      end)

    running = %{
      ref: task.ref,
      pid: task.pid,
      guard: state.timer.({:overran, task.ref}, @max_run_ms),
      meta: %{session_id: session_id, trigger: trigger},
      started_us: System.monotonic_time(:microsecond),
      overran?: false
    }

    %{cancel_wake(state) | running: running}
  end

  defp finished(%{running: %{guard: guard}} = state) do
    _cancelled = Process.cancel_timer(guard)
    %{state | running: nil}
  end

  defp start_queued(%{queued: nil} = state), do: state
  defp start_queued(%{queued: trigger} = state), do: start(%{state | queued: nil}, trigger)

  defp planned(state, %{next_ms: _ms, failed: true}), do: failed(state)
  defp planned(state, %{next_ms: nil}), do: %{state | failures: 0}

  defp planned(state, %{next_ms: ms}) when is_integer(ms) and ms >= 0,
    do: arm(%{state | failures: 0}, ms)

  defp planned(state, other) do
    Logger.error("trips: a run placing waiting stops answered #{inspect(other, limit: 5)}")
    failed(state)
  end

  # A fault backs off: 5 min after the first, doubling to the 6 h cap.
  defp failed(state) do
    failures = state.failures + 1
    delay = min(@soon_ms * Integer.pow(2, min(failures - 1, 7)), @max_wake_ms)
    arm(%{state | failures: failures}, delay)
  end

  # The kind of what ended a run, never its words: an exception's module or
  # an exit's word.
  defp kind({%{__exception__: true} = exception, _stack}), do: inspect(exception.__struct__)
  defp kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp kind({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp kind(_reason), do: "exit"

  # -- the one timer -------------------------------------------------------------

  # The earlier of two wakes stands; every delay within [1 min, 6 h].
  defp arm(state, delay_ms) do
    delay = delay_ms |> max(@min_wake_ms) |> min(@max_wake_ms)
    at = state.now_ms.() + delay

    case state.wake do
      %{at: earlier} when earlier <= at -> state
      _later_or_none -> put_wake(cancel_wake(state), delay, at)
    end
  end

  defp put_wake(state, delay, at) do
    token = make_ref()
    %{state | wake: %{token: token, ref: state.timer.({:wake, token}, delay), at: at}}
  end

  defp cancel_wake(%{wake: nil} = state), do: state

  defp cancel_wake(%{wake: %{ref: ref}} = state) do
    _cancelled = Process.cancel_timer(ref)
    %{state | wake: nil}
  end

  defp send_after(message, delay), do: Process.send_after(self(), message, delay)

  defp elapsed(started_us), do: max(System.monotonic_time(:microsecond) - started_us, 0)
end
