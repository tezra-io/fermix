defmodule FermixCore.OpenLoops.Scheduler do
  @moduledoc """
  The single owner of open-loop due scans, check-in claims and check-in runs
  (MILESTONE_78 §04 stage 2-3, §06, §11, §18), in the `Temporal.Scheduler`
  shape.

  One process does four things and nothing else:

    * a **boot sweep** in `init/1`: no check-in outlives the scheduler under
      `:rest_for_one`, so every claim still held at start is returned before
      any timer arms.
    * a **nearest-change timer**: `loop_changed/1` and every settled run
      re-query the earliest moment a live loop can next change
      (`Repo.next_open_loop_touch_at/2`), together with the waits this
      scheduler holds itself (the next active-hours start for a loop waiting
      on the owner's hours or the day's budget), and arm exactly one timer,
      clamped to 24 hours. The delay sits in state beside the reference
      (`due_delay_ms`). A capped timer only re-queries; it can never send early.
    * a **due tick**: the due scan moves arrived loops to due, to their
      hand-back, or to expiry (each expiry traced `settled` by `scheduler`);
      then every due loop is weighed for rung 2, the nearest date first so it
      wins the day's budget. An ineligible loop is silence while its rung 1
      window is open or it is imminent, and a traced skip (`active_hours`,
      `budget`) otherwise, once per loop, reason and local day. An eligible
      loop is claimed atomically and its `CheckIn` started under
      `CheckInSupervisor` and monitored. Capacity is read from the supervisor
      before claiming; a full or absent supervisor is a traced `max_children`
      skip, and a claim that could not start a run is released at once. One
      owner has at most one run in flight, so two loops can never both speak
      inside one day's budget; a loop held back that way is weighed again on
      the next pass. A run that dies still holding its claim re-arms its loop
      as an `error` (§11) and has its trace closed here.
    * a **60-second reconciliation**: the same pass again, so an hours window
      opening or a day's budget rolling over is never missed by more than a
      minute whatever the timer chose.

  Every fault path (a scan, claim or timer lookup that errored, a full
  supervisor, a run that could not start) re-arms at the 5-second floor. A full
  supervisor is the traced `max_children` skip; every other fault, a failed
  boot sweep or claim release included, is logged loudly and traced as one
  `[:fermix, :open_loop, :fault]` event at its stage. `now_fn` and
  `timer_enabled` keep tests hermetic; production has one code path with real
  time.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.CheckIn
  alias FermixCore.OpenLoops.CheckInSupervisor
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Lifecycle
  alias FermixCore.OpenLoops.Telemetry
  alias FermixCore.Timeouts

  @default_reconciliation_interval_ms 60_000

  # One page holds every live loop one owner may keep, so a page of waiting
  # due rows never hides a newly arrived one.
  @scan_limit Defaults.max_live_loops()

  # Armed-delay ceiling: bounded-timer hygiene, not an OTP range fix.
  @max_due_delay_ms 86_400_000

  @traced_skips [:active_hours, :budget]

  @type run :: %{
          loop: map(),
          claimed_at: DateTime.t(),
          active_hours: ActiveHours.hours(),
          correlation: Telemetry.run(),
          started: integer()
        }

  @type state :: %{
          timer_enabled?: boolean(),
          repo: GenServer.server(),
          repo_opts: keyword(),
          checkin_supervisor: Supervisor.supervisor(),
          checkin_module: module(),
          checkin_args: map(),
          now_fn: (-> DateTime.t()),
          max_children: pos_integer(),
          reconciliation_interval_ms: pos_integer(),
          due_timer: reference() | nil,
          due_delay_ms: non_neg_integer() | nil,
          reconciliation_timer: reference() | nil,
          waits: [DateTime.t()],
          runs: %{reference() => run()},
          skips: %{String.t() => {atom(), Date.t()}}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  A loop was noted, moved or settled: re-query the earliest change and re-arm.
  A cast, the `OpenLoops.Registry` `:scheduler` seam's signal.
  """
  @spec loop_changed(GenServer.server()) :: :ok
  def loop_changed(server \\ __MODULE__), do: GenServer.cast(server, :loop_changed)

  @doc "Runs one due tick synchronously and re-arms the timer."
  @spec tick(GenServer.server(), keyword()) :: :ok
  def tick(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:tick, Keyword.get(opts, :now)})
  end

  @doc "Runs one reconciliation pass synchronously (the 60-second safety net)."
  @spec reconcile(GenServer.server(), keyword()) :: :ok
  def reconcile(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:reconcile, Keyword.get(opts, :now)})
  end

  @impl true
  def init(opts) do
    state = build_state(opts)
    {:ok, state |> boot_sweep() |> schedule_due_timer() |> schedule_reconciliation_timer()}
  end

  @impl true
  def handle_call({:tick, now}, _from, state) do
    {:reply, :ok, run_due_and_rearm(state, now || state.now_fn.())}
  end

  def handle_call({:reconcile, now}, _from, state) do
    {:reply, :ok, run_due_and_rearm(state, now || state.now_fn.())}
  end

  @impl true
  def handle_cast(:loop_changed, state), do: {:noreply, schedule_due_timer(state)}

  @impl true
  def handle_info(:due_tick, state) do
    {:noreply, run_due_and_rearm(state, state.now_fn.())}
  end

  def handle_info(:reconcile_tick, state) do
    state = state |> run_due_and_rearm(state.now_fn.()) |> schedule_reconciliation_timer()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {run, runs} = Map.pop(state.runs, ref)
    {:noreply, run_down(run, reason, %{state | runs: runs})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- state -----------------------------------------------------------------

  defp build_state(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    %{
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      repo: repo,
      # A Repo that does not answer in time is an error each path logs and
      # retries, never an exit that would restart every later child.
      repo_opts:
        Repo.periodic_opts(repo, Keyword.get(opts, :repo_timeout_ms, Timeouts.repo_call())),
      checkin_supervisor: Keyword.get(opts, :checkin_supervisor, CheckInSupervisor),
      checkin_module: Keyword.get(opts, :checkin_module, CheckIn),
      # Merged into every run's args: the delivery, provider and store seams.
      checkin_args: Keyword.get(opts, :checkin_args, %{delivery_opts: []}),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      max_children: CheckInSupervisor.max_children(),
      reconciliation_interval_ms:
        Keyword.get(opts, :reconciliation_interval_ms, @default_reconciliation_interval_ms),
      due_timer: nil,
      due_delay_ms: nil,
      reconciliation_timer: nil,
      waits: [],
      runs: %{},
      skips: %{}
    }
  end

  # --- boot sweep --------------------------------------------------------------

  defp boot_sweep(state) do
    case Repo.sweep_open_loop_claims(state.repo_opts) do
      {:ok, []} ->
        :ok

      {:ok, ids} ->
        Logger.warning("Open-loop boot sweep returned #{length(ids)} stranded check-in claims")

      # The reconciliation pass retries everything a sweep would unblock, so a
      # failed sweep must not stop the scheduler from serving healthy loops.
      {:error, reason} ->
        report_fault("sweep", nil, "Open-loop boot sweep failed", reason)
    end

    state
  end

  # --- due ticks -----------------------------------------------------------------

  defp run_due_and_rearm(state, now) do
    {outcome, state} = run_due(state, now)
    schedule_due_timer(state, outcome)
  end

  defp run_due(state, now) do
    case Repo.scan_due_open_loops(now, @scan_limit, state.repo_opts) do
      {:ok, scan} ->
        trace_expired(scan)
        weigh_due(state, scan.due ++ scan.waiting, now)

      {:error, reason} ->
        report_fault("scan", nil, "Open-loop due scan failed", reason)
        {:error, state}
    end
  end

  defp trace_expired(%{expired: expired, expired_from: from}) do
    Enum.each(expired, fn row ->
      Telemetry.settled(row.id, Map.fetch!(from, row.id), "expired", nil, "scheduler", nil)
    end)
  end

  # The nearest date is weighed first, so it wins the day's budget (§18).
  defp weigh_due(state, rows, now) do
    pass = %{
      state: %{state | waits: []},
      now: now,
      outcome: :ok,
      free: nil,
      busy: MapSet.new(Map.values(state.runs), & &1.loop.owner_id),
      hours: %{},
      budgets: %{},
      seen: MapSet.new()
    }

    pass =
      rows
      |> Enum.sort_by(&{DateTime.to_unix(&1.matters_by_at, :microsecond), &1.id})
      |> Enum.reduce(pass, &weigh/2)

    skips = Map.take(pass.state.skips, MapSet.to_list(pass.seen))
    {pass.outcome, %{pass.state | skips: skips}}
  end

  # A loop whose owner already has a run in flight waits for that run: its
  # settlement re-arms the timer, and two runs can never share a day's budget.
  defp weigh(row, pass) do
    pass = %{pass | seen: MapSet.put(pass.seen, row.id)}

    if MapSet.member?(pass.busy, row.owner_id),
      do: pass,
      else: weigh_owner_free(row, pass)
  end

  defp weigh_owner_free(row, pass) do
    with {:ok, hours, pass} <- hours_for(row, pass),
         {:ok, spent?, pass} <- budget_for(row, pass) do
      decide(row, Lifecycle.rung2_eligible?(row, pass.now, hours, spent?), hours, pass)
    else
      {:error, reason, pass} ->
        fault(pass, "scan", row.id, "Open-loop #{row.id} rung 2 check failed", reason)
    end
  end

  defp decide(row, true, hours, pass), do: claim(row, hours, with_capacity(pass))

  # Silence, not a skip: the rung 1 window is still open, or the loop is
  # imminent and only ever raised in conversation. `next_wake` covers both.
  defp decide(_row, {:skip, reason}, _hours, pass) when reason not in @traced_skips, do: pass

  defp decide(row, {:skip, reason}, hours, pass) do
    pass
    |> trace_skip(row, reason)
    |> add_wait(ActiveHours.next_start(hours, pass.now, row.timezone))
  end

  defp hours_for(row, pass) do
    key = {row.agent_id, row.owner_id, row.timezone}

    case Map.fetch(pass.hours, key) do
      {:ok, hours} -> {:ok, hours, pass}
      :error -> resolve_hours(key, pass)
    end
  end

  defp resolve_hours({agent_id, owner_id, zone} = key, pass) do
    case ActiveHours.resolve(pass.state.repo_opts, agent_id, owner_id, zone, pass.now) do
      {:ok, hours} -> {:ok, hours, put_in(pass.hours[key], hours)}
      {:error, reason} -> {:error, {:active_hours, reason}, pass}
    end
  end

  # The budget is one rung 2 spend per owner (a check-in spends it just before
  # its send) since the start of the owner's local day, in the loop's own zone.
  defp budget_for(row, pass) do
    since = ActiveHours.day_start(pass.now, row.timezone)
    key = {row.owner_id, since}

    case Map.fetch(pass.budgets, key) do
      {:ok, spent?} -> {:ok, spent?, pass}
      :error -> read_budget(key, pass)
    end
  end

  defp read_budget({owner_id, since} = key, pass) do
    case Repo.open_loop_budget_spent_since(owner_id, since, pass.state.repo_opts) do
      {:ok, spent?} -> {:ok, spent?, put_in(pass.budgets[key], spent?)}
      {:error, reason} -> {:error, {:budget, reason}, pass}
    end
  end

  # Capacity is OTP state, read once per pass before the first claim and never
  # inside a transaction. An absent supervisor is zero free slots.
  defp with_capacity(%{free: nil} = pass), do: %{pass | free: free_slots(pass.state)}
  defp with_capacity(pass), do: pass

  defp free_slots(state) do
    case supervisor_pid(state.checkin_supervisor) do
      nil ->
        Logger.warning(
          "Open-loop check-in supervisor #{inspect(state.checkin_supervisor)} is not running; " <>
            "treating capacity as zero"
        )

        0

      pid ->
        max(state.max_children - DynamicSupervisor.count_children(pid).active, 0)
    end
  end

  defp supervisor_pid(supervisor) do
    case GenServer.whereis(supervisor) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid, else: nil
      _unregistered -> nil
    end
  end

  # --- claims and runs -------------------------------------------------------------

  defp claim(row, _hours, %{free: 0} = pass) do
    pass |> trace_skip(row, :max_children) |> busy()
  end

  defp claim(row, hours, pass) do
    case Repo.claim_open_loop_checkin(row.id, pass.now, pass.state.repo_opts) do
      {:ok, claimed} ->
        start_run(claimed, hours, pass)

      {:error, :not_claimable} ->
        pass

      # A timed-out claim may still land, ahead of anything sent next: release
      # the claim it would hold, exactly the instant it was stamped with.
      {:error, reason} ->
        release(row.id, pass.now, pass)
        fault(pass, "claim", row.id, "Open-loop #{row.id} claim failed", reason)
    end
  end

  defp start_run(claimed, hours, pass) do
    args =
      Map.merge(pass.state.checkin_args, %{
        loop: claimed,
        claimed_at: claimed.claimed_at,
        touch: claimed.touches + 1,
        rung: 2,
        active_hours: hours,
        repo: pass.state.repo,
        now_fn: pass.state.now_fn
      })

    case start_checkin(pass.state, args) do
      {:ok, pid} -> monitor_run(pid, claimed, hours, pass)
      {:error, :max_children} -> refused(claimed, pass)
      {:error, reason} -> start_failed(claimed, reason, pass)
    end
  end

  # A dead or shutting-down supervisor exits the call rather than returning:
  # the same refusal as a full one.
  defp start_checkin(state, args) do
    case CheckInSupervisor.start_checkin(state.checkin_supervisor, state.checkin_module, args) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, pid, _info} when is_pid(pid) -> {:ok, pid}
      :ignore -> {:error, :ignored}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :max_children}
  end

  defp monitor_run(pid, claimed, hours, pass) do
    run = %{
      loop: claimed,
      claimed_at: claimed.claimed_at,
      active_hours: hours,
      correlation: Telemetry.correlation(claimed.id, claimed.touches + 1),
      started: System.monotonic_time(:millisecond)
    }

    runs = Map.put(pass.state.runs, Process.monitor(pid), run)
    state = %{pass.state | runs: runs, skips: Map.delete(pass.state.skips, claimed.id)}

    %{
      pass
      | state: state,
        free: pass.free - 1,
        busy: MapSet.put(pass.busy, claimed.owner_id)
    }
  end

  defp refused(claimed, pass) do
    release(claimed.id, claimed.claimed_at, pass)
    pass |> trace_skip(claimed, :max_children) |> busy()
  end

  defp start_failed(claimed, reason, pass) do
    release(claimed.id, claimed.claimed_at, pass)

    fault(
      pass,
      "start_checkin",
      claimed.id,
      "Open-loop #{claimed.id} check-in failed to start",
      reason
    )
  end

  # Releasing a claim writes nothing but the claim: the loop stays due, as it
  # was. A claim already gone (it never landed) is nothing to release.
  defp release(id, claimed_at, pass) do
    opts = Keyword.put(pass.state.repo_opts, :now, pass.now)

    case Repo.finalize_open_loop_checkin(id, claimed_at, %{state: "due"}, opts) do
      {:ok, _row} ->
        :ok

      {:error, :closed_meanwhile} ->
        :ok

      {:error, reason} ->
        report_fault("release", id, "Open-loop #{id} claim release failed", reason)
    end
  end

  # --- run exits -------------------------------------------------------------------

  defp run_down(nil, _reason, state), do: state

  # A run settles its own claim before it exits, so the compare-and-set below
  # finds nothing to write in the normal case. A claim still held means the run
  # died before its outcome: the loop re-arms as an `error` (§11) and the run's
  # trace is closed here, since the run never closed it.
  defp run_down(run, reason, state) do
    now = state.now_fn.()
    changes = Lifecycle.after_outcome(run.loop, "error", now, run.active_hours)
    opts = Keyword.put(state.repo_opts, :now, now)

    case Repo.finalize_open_loop_checkin(run.loop.id, run.claimed_at, changes, opts) do
      {:error, :closed_meanwhile} ->
        :ok

      {:ok, row} ->
        recovered(run, row, reason)

      # The dead run's claim could not be returned: a failed release.
      {:error, error} ->
        report_fault("release", run.loop.id, "Open-loop #{run.loop.id} recovery failed", error)
    end

    schedule_due_timer(state)
  end

  defp recovered(run, row, :normal) do
    Logger.error(
      "Open-loop #{run.loop.id} check-in exited normally still holding its claim; " <>
        "recovered as #{row.state}"
    )

    trace_recovered_move(run, row)
  end

  defp recovered(run, row, reason) do
    Logger.warning(
      "Open-loop #{run.loop.id} check-in exited (#{inspect(reason)}); recovered as #{row.state}"
    )

    elapsed = System.monotonic_time(:millisecond) - run.started
    Telemetry.run_error(run.correlation, "error", elapsed, {:checkin_exit, reason})
    trace_recovered_move(run, row)
  end

  defp trace_recovered_move(run, %{state: "expired"}),
    do: Telemetry.settled(run.loop.id, "due", "expired", nil, "scheduler", nil)

  defp trace_recovered_move(_run, _row), do: :ok

  # --- skips, waits and faults -------------------------------------------------------

  # A standing reason is traced once per loop, reason and local day, not on
  # every tick and reconciliation it outlasts.
  defp trace_skip(pass, row, reason) do
    mark = {reason, row |> local_date(pass.now)}

    if Map.get(pass.state.skips, row.id) == mark do
      pass
    else
      Telemetry.skipped(Atom.to_string(reason), row.id)
      put_in(pass.state.skips[row.id], mark)
    end
  end

  defp local_date(row, now), do: now |> DateTime.shift_zone!(row.timezone) |> DateTime.to_date()

  defp add_wait(pass, at), do: put_in(pass.state.waits, [at | pass.state.waits])

  defp busy(%{outcome: :ok} = pass), do: %{pass | outcome: :busy}
  defp busy(pass), do: pass

  defp fault(pass, stage, open_loop_id, message, reason) do
    report_fault(stage, open_loop_id, message, reason)
    %{pass | outcome: :error}
  end

  # The log line keeps the reason as it is; the trace carries its class only.
  defp report_fault(stage, open_loop_id, message, reason) do
    Logger.error("#{message}: #{inspect(reason)}")
    Telemetry.fault(stage, open_loop_id, reason)
  end

  # --- timers ------------------------------------------------------------------------

  defp schedule_due_timer(state, outcome \\ :ok) do
    cancel_timer(state.due_timer)

    if state.timer_enabled? do
      {timer, delay_ms} = next_due_timer(state, outcome)
      %{state | due_timer: timer, due_delay_ms: delay_ms}
    else
      %{state | due_timer: nil, due_delay_ms: nil}
    end
  end

  # Returns the armed reference paired with the delay it was armed at; `{nil,
  # nil}` when nothing can change. A pass that faulted retries at the floor: a
  # stuck loop can neither spin nor wait out a far-off wake to be retried.
  defp next_due_timer(_state, outcome) when outcome != :ok, do: arm(Defaults.fault_floor_ms())

  defp next_due_timer(state, :ok) do
    now = state.now_fn.()

    case Repo.next_open_loop_touch_at(now, state.repo_opts) do
      {:ok, at} -> arm_for(earliest([at | state.waits]), now)
      {:error, reason} -> timer_lookup_failed(reason)
    end
  end

  defp timer_lookup_failed(reason) do
    report_fault("timer", nil, "Open-loop timer lookup failed", reason)
    arm(Defaults.fault_floor_ms())
  end

  defp earliest(instants) do
    instants |> Enum.reject(&is_nil/1) |> Enum.min(DateTime, fn -> nil end)
  end

  # The next change fires on time (0 ms for one already past), under the
  # 24-hour ceiling.
  defp arm_for(nil, _now), do: {nil, nil}

  defp arm_for(at, now),
    do: arm(at |> DateTime.diff(now, :millisecond) |> max(0) |> min(@max_due_delay_ms))

  defp schedule_reconciliation_timer(state) do
    cancel_timer(state.reconciliation_timer)

    if state.timer_enabled? do
      timer = Process.send_after(self(), :reconcile_tick, state.reconciliation_interval_ms)
      %{state | reconciliation_timer: timer}
    else
      %{state | reconciliation_timer: nil}
    end
  end

  defp arm(delay_ms), do: {Process.send_after(self(), :due_tick, delay_ms), delay_ms}

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
