defmodule FermixCore.Temporal.Scheduler do
  @moduledoc """
  The single owner of reminder claims, delivery workers, and horizon
  reconciliation (M30 §6.3, §10).

  One process does four things and nothing else:

    * a **boot sweep** in `init/1`. Every row still `delivering` at start is
      stranded — no worker outlives the scheduler under `:rest_for_one` — so it
      returns to `pending`, fails at the attempt cap, or expires past its
      validity, before any timer arms.
    * a **nearest-due timer**. `event_changed/1` and every settled delivery
      re-query the earliest *claimable* `ready_at` — validity included, so a row
      the daemon slept past cannot set an alarm the due scan then refuses — and
      arm exactly one timer for it.
      The delay is clamped to 24 hours: not an OTP range fix (modern
      `Process.send_after/3` accepts far longer), but bounded-timer hygiene, so a
      birthday months away never rides one armed timer through host suspends and
      clock changes. A capped timer only re-queries; it can never deliver early.
    * a **due tick**. Capacity is read from the delivery supervisor first (an
      unregistered supervisor — the sub-millisecond boot window in which the
      scheduler is already up — is zero free slots), then at most that many rows
      are claimed atomically, and each claimed row's worker is started and
      `Process.monitor`ed in the same callback. The scheduler never performs
      network I/O.
    * a **60-second reconciliation**: one bounded validity-boundary page
      (expired/superseded marking and one-time completion), one bounded
      annual-horizon page, and the monitor invariant assert. Both pages use
      keyset cursors held in state and wrap around; `event_changed/1` invalidates
      the annual cursor so a newly earlier deadline is not starved behind it.

  Every fault path — a due-scan error, a full delivery pool, a worker that could
  not start — re-arms no sooner than the 5-second floor, so a stuck row can never
  hot-loop the scheduler. `now_fn` (the harness-worker clock seam) and
  `timer_enabled` keep tests hermetic; production has one code path with real
  time.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.DeliverySupervisor
  alias FermixCore.Temporal.DeliveryWorker
  alias FermixCore.Temporal.FollowupSupervisor
  alias FermixCore.Temporal.Planner
  alias FermixCore.Temporal.Telemetry, as: TemporalTelemetry

  @default_reconciliation_interval_ms 60_000

  # Per-tick bounds (§6.3). A larger backlog is picked up by the next tick or the
  # next reconciliation page; no single callback is ever unbounded.
  @due_limit 20
  @reconcile_limit 20

  # Fault/backpressure floor: a tick that could not drain — a repo error, a full
  # delivery pool, a worker that refused to start — re-arms no sooner than this.
  @error_backoff_ms 5_000

  # Armed-delay ceiling; see the moduledoc for why this is hygiene, not a range fix.
  @max_due_delay_ms 86_400_000

  # An annual event is re-materialized once its furthest materialized occurrence
  # is inside a year, i.e. once the current occurrence has passed. Re-running the
  # planner early is a harmless no-op (conflict-ignore inserts).
  @annual_horizon_days 366

  @crash_error "worker exited without settling its claim"
  @stranded_error "claim stranded without a monitored worker"
  @start_failed_error "delivery worker failed to start"

  @type state :: %{
          enabled?: boolean(),
          timer_enabled?: boolean(),
          repo: GenServer.server(),
          delivery_supervisor: Supervisor.supervisor(),
          delivery_worker_module: module(),
          delivery_opts: keyword(),
          followup_supervisor: Supervisor.supervisor(),
          now_fn: (-> DateTime.t()),
          due_limit: pos_integer(),
          reconcile_limit: pos_integer(),
          max_workers: pos_integer(),
          reconciliation_interval_ms: pos_integer(),
          due_timer: reference() | nil,
          reconciliation_timer: reference() | nil,
          monitors: %{reference() => String.t()},
          boundary_cursor: Repo.temporal_cursor() | nil,
          annual_cursor: Repo.temporal_cursor() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs one due tick synchronously and re-arms the due timer."
  @spec tick(GenServer.server(), keyword()) :: :ok
  def tick(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:tick, Keyword.get(opts, :now)})
  end

  @doc "Runs one bounded reconciliation pass synchronously (the 60-second safety net)."
  @spec reconcile(GenServer.server(), keyword()) :: :ok
  def reconcile(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:reconcile, Keyword.get(opts, :now)})
  end

  @impl true
  def init(opts) do
    state = build_state(opts)

    {:ok,
     state
     |> boot_sweep()
     |> schedule_due_timer()
     |> schedule_reconciliation_timer()}
  end

  @impl true
  def handle_call({:tick, now}, _from, state) do
    {:reply, :ok, run_due_and_rearm(state, now || state.now_fn.())}
  end

  def handle_call({:reconcile, now}, _from, state) do
    state = state |> run_reconciliation(now || state.now_fn.()) |> schedule_due_timer()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:event_changed, state) do
    {:noreply, schedule_due_timer(%{state | annual_cursor: nil})}
  end

  @impl true
  def handle_info(:due_tick, state) do
    {:noreply, run_due_and_rearm(state, state.now_fn.())}
  end

  def handle_info(:reconcile_tick, state) do
    now = state.now_fn.()

    state =
      state
      |> run_reconciliation(now)
      |> run_due_and_rearm(now)
      |> schedule_reconciliation_timer()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {reminder_id, monitors} = Map.pop(state.monitors, ref)
    state = %{state | monitors: monitors}
    {:noreply, worker_down(reminder_id, reason, state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- state ---------------------------------------------------------------

  defp build_state(opts) do
    %{
      enabled?: Keyword.get(opts, :scheduler_enabled, temporal_config(:scheduler_enabled, true)),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      repo: Keyword.get(opts, :repo, Repo),
      delivery_supervisor: Keyword.get(opts, :delivery_supervisor, DeliverySupervisor),
      delivery_worker_module: Keyword.get(opts, :delivery_worker_module, DeliveryWorker),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      followup_supervisor: Keyword.get(opts, :followup_supervisor, FollowupSupervisor),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      due_limit: @due_limit,
      reconcile_limit: @reconcile_limit,
      max_workers: DeliverySupervisor.max_children(),
      reconciliation_interval_ms:
        Keyword.get(opts, :reconciliation_interval_ms, @default_reconciliation_interval_ms),
      due_timer: nil,
      reconciliation_timer: nil,
      monitors: %{},
      boundary_cursor: nil,
      annual_cursor: nil
    }
  end

  defp temporal_config(key, default) do
    :fermix_core
    |> Application.get_env(:temporal, [])
    |> Keyword.get(key, default)
  end

  # --- boot sweep ----------------------------------------------------------

  defp boot_sweep(%{enabled?: false} = state), do: state

  defp boot_sweep(state) do
    case Repo.sweep_delivering_reminders(state.now_fn.(), server: state.repo) do
      {:ok, swept} -> log_and_trace_sweep(swept)
      # Reconciliation retries the invariant assert, so a failed sweep must not
      # stop the scheduler from booting and serving healthy rows.
      {:error, reason} -> fail_loudly("Reminder boot sweep failed", reason)
    end

    state
  end

  defp log_and_trace_sweep(swept) do
    emit_reminder_ids(:retry_scheduled, swept.pending, {:error, :stranded_claim})
    emit_reminder_ids(:failed, swept.failed, {:error, :stranded_claim})
    emit_reminder_ids(:expired, swept.expired, {:error, :stranded_claim})
    log_sweep(swept)
  end

  defp log_sweep(%{pending: [], failed: [], expired: []}), do: :ok

  defp log_sweep(%{pending: pending, failed: failed, expired: expired}) do
    Logger.warning(
      "Reminder boot sweep reset stranded claims: " <>
        "#{length(pending)} pending, #{length(failed)} failed, #{length(expired)} expired"
    )
  end

  # --- due ticks -----------------------------------------------------------

  defp run_due_and_rearm(state, now) do
    {outcome, state} = run_due(state, now)
    schedule_due_timer(state, outcome)
  end

  defp run_due(%{enabled?: false} = state, _now), do: {:ok, state}

  defp run_due(state, now) do
    case free_slots(state) do
      0 -> {:busy, state}
      slots -> claim_due(state, now, min(slots, state.due_limit))
    end
  end

  defp claim_due(state, now, limit) do
    case Repo.claim_due_reminders(now, limit, server: state.repo) do
      {:ok, rows} ->
        {:ok, Enum.reduce(rows, state, &start_delivery(&1, now, &2))}

      {:error, reason} ->
        fail_loudly("Reminder due scan failed", reason)
        {:error, state}
    end
  end

  # Capacity is OTP state, read before the transaction and never inside it. An
  # unregistered supervisor is zero slots: the tick claims nothing and re-arms at
  # the backpressure floor (§6.3), which is the same path a full pool takes.
  defp free_slots(state) do
    case supervisor_pid(state.delivery_supervisor) do
      nil ->
        Logger.warning(
          "Temporal delivery supervisor #{inspect(state.delivery_supervisor)} is not " <>
            "running; treating capacity as zero and re-arming at the backpressure floor"
        )

        0

      pid ->
        max(state.max_workers - DynamicSupervisor.count_children(pid).active, 0)
    end
  end

  defp supervisor_pid(supervisor) do
    case GenServer.whereis(supervisor) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid, else: nil
      _unregistered -> nil
    end
  end

  # The claim already consumed a logical attempt, so a worker that cannot start
  # must settle the row here rather than leave it `delivering` forever.
  defp start_delivery(row, now, state) do
    args = %{
      reminder: row,
      repo: state.repo,
      now_fn: state.now_fn,
      delivery_opts: state.delivery_opts,
      followup_supervisor: state.followup_supervisor
    }

    case DeliverySupervisor.start_delivery(
           state.delivery_supervisor,
           state.delivery_worker_module,
           args
         ) do
      {:ok, pid} when is_pid(pid) -> monitor_worker(pid, row, state)
      {:ok, pid, _info} when is_pid(pid) -> monitor_worker(pid, row, state)
      :ignore -> settle_stranded(row, :worker_ignored, @start_failed_error, now, state)
      {:error, reason} -> settle_stranded(row, reason, @start_failed_error, now, state)
    end
  end

  defp monitor_worker(pid, row, state) do
    TemporalTelemetry.emit(:claimed, TemporalTelemetry.reminder(row))
    put_in(state.monitors[Process.monitor(pid)], row.id)
  end

  # --- worker exits --------------------------------------------------------

  defp worker_down(nil, _reason, state), do: state

  defp worker_down(reminder_id, reason, state) do
    recover(reminder_id, reason, @crash_error, state)
  end

  # The Repo re-reads the row: a settled row is left alone and reported
  # `:settled` (a `:DOWN` after settlement changes nothing), while a still
  # `delivering` row returns to pending at the error floor with its attempt
  # consumed, or becomes failed at the cap — never attempt six.
  defp recover(reminder_id, exit_reason, error_text, state) do
    now = state.now_fn.()
    ready_at = DateTime.add(now, @error_backoff_ms, :millisecond)

    case Repo.recover_delivering_reminder(reminder_id, ready_at, error_text, now,
           server: state.repo
         ) do
      {:ok, {:settled, _row}} ->
        schedule_due_timer(state)

      {:ok, {outcome, row}} ->
        emit_settlement(outcome, row, {:error, exit_reason})
        log_recovery(reminder_id, exit_reason, outcome, state)

      {:error, reason} ->
        log_recovery_error(reminder_id, reason, state)
    end
  end

  # A worker must settle before exiting `:normal`, so an unsettled row after a
  # normal exit means the invariant broke — say so, then recover it anyway.
  defp log_recovery(reminder_id, :normal, outcome, state) do
    Logger.error(
      "scheduler_error: reminder #{reminder_id} was still delivering after a normal worker exit; recovered as #{outcome}"
    )

    emit_scheduler_error(:unsettled_normal_exit, reminder_id: reminder_id)
    schedule_due_timer(state)
  end

  defp log_recovery(reminder_id, exit_reason, outcome, state) do
    Logger.warning(
      "Reminder #{reminder_id} worker exited (#{inspect(exit_reason)}); recovered as #{outcome}"
    )

    schedule_due_timer(state)
  end

  defp log_recovery_error(reminder_id, reason, state) do
    Logger.error("Reminder #{reminder_id} claim recovery failed: #{inspect(reason)}")
    emit_scheduler_error(reason, reminder_id: reminder_id)
    state
  end

  defp settle_stranded(row, reason, error_text, now, state) do
    Logger.error("Reminder #{row.id} delivery worker start failed: #{inspect(reason)}")
    ready_at = DateTime.add(now, @error_backoff_ms, :millisecond)

    case Repo.recover_delivering_reminder(row.id, ready_at, error_text, now, server: state.repo) do
      {:ok, {:settled, _row}} -> state
      {:ok, {outcome, settled}} -> settled_stranded_state(outcome, settled, reason, state)
      {:error, error} -> log_recovery_error(row.id, error, state)
    end
  end

  defp settled_stranded_state(outcome, row, reason, state) do
    emit_settlement(outcome, row, {:error, reason})
    state
  end

  # --- reconciliation ------------------------------------------------------

  defp run_reconciliation(%{enabled?: false} = state, _now), do: state

  defp run_reconciliation(state, now) do
    state
    |> reconcile_boundaries(now)
    |> reconcile_annual_horizon(now)
    |> assert_monitor_invariant(now)
  end

  defp reconcile_boundaries(state, now) do
    case Repo.reconcile_temporal_boundaries(now, state.boundary_cursor, state.reconcile_limit,
           server: state.repo
         ) do
      {:ok, page} ->
        emit_boundaries(page)
        log_boundaries(page)
        %{state | boundary_cursor: page.cursor}

      {:error, reason} ->
        fail_loudly("Reminder validity reconciliation failed", reason)
        state
    end
  end

  defp emit_boundaries(page) do
    emit_reminder_ids(:expired, page.expired, :ok)
    emit_reminder_ids(:superseded, page.superseded, :ok)

    Enum.each(
      page.completed_events,
      &TemporalTelemetry.emit(:event_completed, event_id: &1, result: :ok)
    )
  end

  defp log_boundaries(%{expired: [], superseded: [], completed_events: []}), do: :ok

  defp log_boundaries(page) do
    Logger.info(
      "Reminder boundaries reconciled: #{length(page.expired)} expired, " <>
        "#{length(page.superseded)} superseded, #{length(page.completed_events)} events completed"
    )
  end

  defp reconcile_annual_horizon(state, now) do
    threshold = Date.add(DateTime.to_date(now), @annual_horizon_days)

    case Repo.annual_horizon_events(threshold, state.annual_cursor, state.reconcile_limit,
           server: state.repo
         ) do
      {:ok, page} ->
        Enum.each(page.events, &materialize_horizon(&1, now, state))
        %{state | annual_cursor: page.cursor}

      {:error, reason} ->
        fail_loudly("Reminder annual horizon scan failed", reason)
        state
    end
  end

  defp materialize_horizon(event, now, state) do
    with {:ok, rules} <- Defaults.decode_plan(event.reminder_plan),
         {:ok, plan} <- Planner.materialize(%{event | reminder_plan: rules}, now),
         :advances <- horizon_progress(event, plan),
         {:ok, _result} <- store_horizon(event, plan, now, state) do
      TemporalTelemetry.emit(:materialized,
        event_id: event.id,
        platform: event.delivery_platform,
        result: :ok
      )
    else
      :unchanged ->
        :ok

      {:error, :stale_event_revision} ->
        Logger.info("Reminder horizon for event #{event.id} skipped: an edit won the race")

      {:error, reason} ->
        Logger.error("Reminder horizon for event #{event.id} failed: #{inspect(reason)}")
        emit_scheduler_error(reason, event_id: event.id)
    end
  end

  # The horizon page selects on `materialized_through_on < today + @annual_horizon_days`,
  # but the planner materializes the next `Planner.annual_horizon/0` occurrences
  # by LOCAL CALENDAR — never by adding days — so a yearly event can only reach
  # `next_occurrence + 1 year`. On the occurrence day itself that lands one day
  # short of the threshold, the row stays in the page, and every pass recomputes
  # the identical plan.
  #
  # The threshold is not the bug: it is what walks an annual event forward as
  # *today* advances, and narrowing it would eventually stop re-materializing
  # them altogether. The bug is re-writing and re-announcing a plan that changed
  # nothing. A pass that cannot advance the horizon does nothing and says
  # nothing — `materialized` means something was materialized.
  #
  # Left in production this is self-limiting (it clears when the date rolls) and
  # harmless to the data (`insert_occurrences` is ON CONFLICT DO NOTHING), but it
  # cost one birthday 118 no-op transactions and 118 lifecycle events in two
  # hours, once per minute, per event, per year.
  defp horizon_progress(event, plan) do
    if plan.materialized_through_on == event.materialized_through_on and
         plan.next_occurrence_on == event.next_occurrence_on,
       do: :unchanged,
       else: :advances
  end

  defp store_horizon(event, plan, now, state) do
    occurrences = Enum.map(plan.occurrences, &Map.put(&1, :id, reminder_id()))

    Repo.materialize_temporal_occurrences(
      event.id,
      event.revision,
      %{plan | occurrences: occurrences},
      now,
      server: state.repo
    )
  end

  # Mid-lifetime this set is always exactly the monitored workers: the boot sweep
  # covers restarts and `:DOWN` covers crashes. Anything else means the invariant
  # broke, so it is traced loudly and reset — not because a second recovery path
  # is wanted, but so a wedged row cannot sit `delivering` forever.
  defp assert_monitor_invariant(state, now) do
    case Repo.list_temporal_reminders(%{status: ["delivering"]}, server: state.repo) do
      {:ok, rows} ->
        monitored = MapSet.new(Map.values(state.monitors))

        rows
        |> Enum.reject(&MapSet.member?(monitored, &1.id))
        |> Enum.reduce(state, &reset_stranded(&1, now, &2))

      {:error, reason} ->
        fail_loudly("Reminder monitor invariant scan failed", reason)
        state
    end
  end

  defp reset_stranded(row, now, state) do
    Logger.error("scheduler_error: reminder #{row.id} is delivering with no monitored worker")
    emit_scheduler_error(:unmonitored_claim, TemporalTelemetry.reminder(row))
    settle_stranded_row(row, now, state)
  end

  defp settle_stranded_row(row, now, state) do
    ready_at = DateTime.add(now, @error_backoff_ms, :millisecond)

    case Repo.recover_delivering_reminder(row.id, ready_at, @stranded_error, now,
           server: state.repo
         ) do
      {:ok, {:settled, _row}} ->
        state

      {:ok, {outcome, settled}} ->
        settled_stranded_state(outcome, settled, :unmonitored_claim, state)

      {:error, reason} ->
        log_recovery_error(row.id, reason, state)
    end
  end

  # --- timers --------------------------------------------------------------

  defp schedule_due_timer(state, outcome \\ :ok) do
    cancel_timer(state.due_timer)

    if state.enabled? and state.timer_enabled? do
      %{state | due_timer: next_due_timer(state, outcome)}
    else
      %{state | due_timer: nil}
    end
  end

  # The timer query asks for the earliest *claimable* row, validity included: a
  # row the due scan would refuse must never set the alarm, or the tick it wakes
  # claims nothing and re-arms at 0ms for as long as the row survives.
  defp next_due_timer(state, outcome) do
    now = state.now_fn.()

    case Repo.next_pending_reminder_ready_at(now, server: state.repo) do
      {:ok, %DateTime{} = ready_at} -> arm(due_delay_ms(ready_at, now, outcome))
      {:ok, nil} -> backoff_timer(outcome)
      {:error, reason} -> log_timer_error(reason)
    end
  end

  defp log_timer_error(reason) do
    fail_loudly("Reminder timer lookup failed", reason)
    arm(@error_backoff_ms)
  end

  defp backoff_timer(:ok), do: nil
  defp backoff_timer(_outcome), do: arm(@error_backoff_ms)

  # A clean tick fires at the next `ready_at` (0ms floor for a past-due row). A
  # tick that errored or hit backpressure floors at the backoff interval so a
  # stuck row cannot spin at 0ms. The 24-hour ceiling applies last; floor and
  # ceiling never overlap.
  defp due_delay_ms(ready_at, now, outcome) do
    delay = max(DateTime.diff(ready_at, now, :millisecond), 0)

    case outcome do
      :ok -> min(delay, @max_due_delay_ms)
      _backoff -> delay |> max(@error_backoff_ms) |> min(@max_due_delay_ms)
    end
  end

  defp schedule_reconciliation_timer(state) do
    cancel_timer(state.reconciliation_timer)

    if state.enabled? and state.timer_enabled? do
      timer = Process.send_after(self(), :reconcile_tick, state.reconciliation_interval_ms)
      %{state | reconciliation_timer: timer}
    else
      %{state | reconciliation_timer: nil}
    end
  end

  defp arm(delay_ms), do: Process.send_after(self(), :due_tick, delay_ms)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp reminder_id do
    "rem_" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  # --- lifecycle telemetry (§15.2) -----------------------------------------

  # Every fault the scheduler recovers from is logged AND traced: a fault the
  # trace cannot show is a fault nobody can diagnose.
  defp fail_loudly(message, reason) do
    Logger.error("#{message}: #{inspect(reason)}")
    emit_scheduler_error(reason)
  end

  defp emit_scheduler_error(reason, opts \\ []) do
    TemporalTelemetry.emit(:scheduler_error, Keyword.put(opts, :result, {:error, reason}))
  end

  defp emit_settlement(outcome, row, result) do
    TemporalTelemetry.emit(
      settlement_phase(outcome),
      Keyword.put(TemporalTelemetry.reminder(row), :result, result)
    )
  end

  defp settlement_phase(:pending), do: :retry_scheduled
  defp settlement_phase(:expired), do: :expired
  defp settlement_phase(:failed), do: :failed

  # The boot sweep and the boundary pages return row ids, not rows: the id is the
  # only correlation field available and the phase carries the rest of the story.
  defp emit_reminder_ids(phase, ids, result) do
    Enum.each(ids, &TemporalTelemetry.emit(phase, reminder_id: &1, result: result))
  end
end
