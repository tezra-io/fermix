defmodule FermixCore.Jobs.Scheduler do
  @moduledoc """
  Scheduler for durable scheduled jobs.

  Owns due-job discovery, atomic claim, run record creation, and dispatch to
  supervised scheduled-job runners.
  """

  use GenServer
  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Schedule
  alias FermixCore.Memory.Repo

  @default_reconciliation_interval_ms 60_000
  @default_due_limit 20
  @default_run_freshness_window_seconds 3600

  # Wake-time burst smoothing: each newly started run is told to wait this much
  # per run already active before its first network call, capped, so a batch of
  # jobs due at the same minute doesn't slam the HTTP pool simultaneously.
  @runner_stagger_ms 250
  @max_startup_stagger_ms 5_000

  # A due tick that could not fully drain its work — a DB fault on any path, a
  # timer-lookup failure, or admission backpressure — re-arms the next tick no
  # sooner than this, so a persistently past-due-but-unclaimable job can never
  # spin the scheduler at 0ms (Rule #2). One constant, no escalation ladder.
  @due_error_backoff_ms 5_000

  # Armed-delay ceiling. `Process.send_after/3` takes a bounded delay (it raises
  # ArgumentError past the OTP timer range), and a schedule is unbounded: "every
  # 3650 days" or a distant cron match name a wakeup months or years out. Cap the
  # armed delay at a day so the scheduler never depends on that range and never
  # sleeps on one months-long timer across suspends and clock changes. Firing
  # early is free: the due tick scans, finds nothing due, and re-arms with a
  # fresh (smaller) delay.
  @max_due_delay_ms 86_400_000

  # Crash-recovery scan bound: the most active job_runs rows one reconciliation
  # pass inspects. Anything beyond this is picked up by the next pass, so a large
  # backlog can never make a single tick unbounded.
  @reconcile_run_limit 50

  # Error text for a run reaped by reconciliation. It names the cause in the run
  # row itself, so an operator reading the run sees why it ended with no process
  # behind it rather than a bare terminal status.
  @reap_error "reaped: no live runner (daemon or scheduler restart)"

  # Concurrent scheduled-run ceiling. When this many runs are already active the
  # tick claims nothing; due jobs stay "scheduled" and later ticks (armed at the
  # backoff floor above) or reconciliation claim them as slots free. The bounded
  # queue is the DB due scan itself — no separate queue structure.
  @max_active_runs 4

  @type state :: %{
          enabled?: boolean(),
          timer_enabled?: boolean(),
          repo: GenServer.server(),
          capability_registry: GenServer.server(),
          skill_registry: GenServer.server(),
          runner_supervisor: Supervisor.supervisor(),
          runner_module: module(),
          adapter: module() | nil,
          adapter_opts: keyword(),
          delivery_adapter: module() | nil,
          delivery_opts: keyword(),
          delivery_channels: map() | keyword(),
          delivery_timeout_ms: non_neg_integer() | nil,
          output_base_dir: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          inactivity_timeout_ms: pos_integer() | nil,
          runner_notify: pid() | nil,
          runner_delay_ms: non_neg_integer(),
          reconciliation_interval_ms: pos_integer(),
          run_freshness_window_seconds: pos_integer() | nil,
          due_limit: pos_integer(),
          max_active_runs: pos_integer(),
          due_timer: reference() | nil,
          reconciliation_timer: reference() | nil,
          run_monitors: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec tick(GenServer.server(), keyword()) :: :ok
  def tick(server \\ __MODULE__, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    GenServer.call(server, {:tick, now})
  end

  @spec job_changed(GenServer.server()) :: :ok
  def job_changed(server \\ __MODULE__) do
    GenServer.cast(server, :job_changed)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @doc """
  Claim and start an out-of-band ("run now") execution of a scheduled job.

  Reuses the same atomic claim, runner dispatch, and monitoring as the timed
  path; only the trigger is `"manual"` and the schedule's `next_run_at` is left
  untouched (the natural cadence continues). Returns the created run on success.
  """
  @spec run_now(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_now(server \\ __MODULE__, job_id, opts \\ []) when is_binary(job_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    GenServer.call(server, {:run_now, job_id, now})
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?: Keyword.get(opts, :scheduler_enabled, jobs_config(:scheduler_enabled, true)),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      repo: Keyword.get(opts, :repo, Repo),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      runner_supervisor: Keyword.get(opts, :runner_supervisor, RunnerSupervisor),
      runner_module: Keyword.get(opts, :runner_module, Runner),
      adapter: Keyword.get(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      delivery_adapter: Keyword.get(opts, :delivery_adapter),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      delivery_channels:
        Keyword.get(opts, :delivery_channels, jobs_config(:delivery_channels, %{})),
      delivery_timeout_ms:
        Keyword.get(opts, :delivery_timeout_ms, jobs_config(:delivery_timeout_ms, 60_000)),
      output_base_dir: Keyword.get(opts, :output_base_dir),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      inactivity_timeout_ms: Keyword.get(opts, :inactivity_timeout_ms),
      runner_notify: Keyword.get(opts, :runner_notify),
      runner_delay_ms: Keyword.get(opts, :runner_delay_ms, 0),
      reconciliation_interval_ms:
        Keyword.get(
          opts,
          :reconciliation_interval_ms,
          jobs_config(:reconciliation_interval_ms, @default_reconciliation_interval_ms)
        ),
      run_freshness_window_seconds:
        Keyword.get(
          opts,
          :run_freshness_window_seconds,
          jobs_config(:run_freshness_window_seconds, @default_run_freshness_window_seconds)
        ),
      due_limit: Keyword.get(opts, :due_limit, @default_due_limit),
      max_active_runs: Keyword.get(opts, :max_active_runs, @max_active_runs),
      due_timer: nil,
      reconciliation_timer: nil,
      run_monitors: %{}
    }

    state =
      state
      |> reconcile_active_runs()
      |> schedule_due_timer()
      |> schedule_reconciliation_timer()

    {:ok, state}
  end

  @impl true
  def handle_call({:tick, %DateTime{} = now}, _from, state) do
    {:reply, :ok, run_due_and_rearm(state, now)}
  end

  def handle_call({:run_now, job_id, %DateTime{} = now}, _from, state) do
    {reply, state} = manual_run(job_id, now, state)
    {:reply, reply, schedule_due_timer(state)}
  end

  @impl true
  def handle_cast(:job_changed, state) do
    {:noreply, schedule_due_timer(state)}
  end

  @impl true
  def handle_info(:due_tick, state) do
    {:noreply, run_due_and_rearm(state, DateTime.utc_now())}
  end

  # Reconcile before scanning: a run freed here puts its job back to "scheduled",
  # so the same tick can claim it instead of waiting a further interval.
  def handle_info(:reconcile_tick, state) do
    state =
      state
      |> reconcile_active_runs()
      |> run_due_and_rearm(DateTime.utc_now())
      |> schedule_reconciliation_timer()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.run_monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | run_monitors: monitors}}

      {_run_info, monitors} when reason in [:normal, :shutdown] ->
        {:noreply, %{state | run_monitors: monitors}}

      {%{job_id: job_id, run_id: run_id}, monitors} ->
        state = %{state | run_monitors: monitors}
        {:noreply, mark_run_crashed(run_id, job_id, reason, state)}
    end
  end

  # Crash recovery beyond the in-process monitor above. A daemon restart (or a
  # scheduler-subtree restart) drops every monitor while job_runs rows stay
  # "queued"/"running", and `ensure_no_active_job_run` then refuses every future
  # claim for those jobs — wedged forever, with no timer that ever reclaims them.
  # Liveness is the signal, never age: the runner supervisor is the authority on
  # which runs still exist. Runs it still holds are adopted; the rest are failed
  # through the same path a monitored crash takes.
  defp reconcile_active_runs(%{enabled?: false} = state), do: state

  defp reconcile_active_runs(state) do
    case Repo.active_job_runs(server: state.repo, limit: @reconcile_run_limit) do
      {:ok, runs} ->
        live = live_runner_pids(state)
        Enum.reduce(runs, state, &reconcile_active_run(&1, live, &2))

      {:error, reason} ->
        Logger.error("Scheduled job run reconciliation scan failed: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_active_run(run, live, state) do
    case Map.fetch(live, run.id) do
      {:ok, pid} -> adopt_live_run(run, pid, state)
      :error -> reap_orphaned_run(run, state)
    end
  end

  # The run's process is alive but unmonitored: the scheduler restarted alone
  # (:rest_for_one starts the runner supervisor first, so runners survive it).
  # Monitor it now so its eventual exit is still marked. Monitoring an already
  # dead pid delivers :DOWN immediately, which the handler above treats as a
  # crash — the same outcome as reaping it here.
  defp adopt_live_run(run, pid, state) do
    if monitored_run?(state.run_monitors, run.id) do
      state
    else
      Logger.info("Scheduled job run #{run.id} adopted from a surviving runner")
      ref = Process.monitor(pid)
      put_in(state.run_monitors[ref], %{job_id: run.job_id, run_id: run.id})
    end
  end

  defp monitored_run?(run_monitors, run_id) do
    Enum.any?(run_monitors, fn {_ref, %{run_id: id}} -> id == run_id end)
  end

  defp reap_orphaned_run(run, state) do
    Logger.warning("Scheduled job #{run.job_id} run #{run.id} #{@reap_error}")
    mark_run_failed(run.id, run.job_id, @reap_error, state)
  end

  # Run ids of every process the runner supervisor still holds. The id is read
  # from the process-dictionary key the runner publishes in its own init
  # (`Runner.run_id/1`, a `Process.info/2` read), never by calling the runner: a
  # runner spends its whole run inside `handle_continue/2`, so a GenServer.call
  # would block the scheduler for the length of the run and time out into "not
  # alive" — reaping runs that are healthily executing.
  defp live_runner_pids(state) do
    state.runner_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce(%{}, &put_live_runner/2)
  end

  defp put_live_runner({_id, pid, _type, _modules}, live) when is_pid(pid) do
    case Runner.run_id(pid) do
      nil -> live
      run_id -> Map.put(live, run_id, pid)
    end
  end

  # A child mid-restart has no pid to ask; the next pass sees it settled.
  defp put_live_runner({_id, _no_pid, _type, _modules}, live), do: live

  # One due tick, run then re-armed. The tick outcome — `:ok` (drained),
  # `:busy` (admission backpressure), or `:error` (a fault on any path) — decides
  # whether the next timer floors at the backoff interval so a stuck past-due job
  # never hot-loops the scheduler.
  defp run_due_and_rearm(state, now) do
    {outcome, state} = run_due_jobs(state, now)
    schedule_due_timer(state, outcome)
  end

  defp run_due_jobs(%{enabled?: false} = state, _now), do: {:ok, state}

  defp run_due_jobs(state, now) do
    case Repo.due_scheduled_jobs(now, server: state.repo, limit: state.due_limit) do
      {:ok, jobs} ->
        Enum.reduce(jobs, {:ok, state}, &reduce_due_job(&1, now, &2))

      {:error, reason} ->
        Logger.error("Scheduled job due scan failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp reduce_due_job(job, now, {outcome, state}) do
    {job_outcome, state} = claim_and_start(job, now, state)
    {merge_outcome(outcome, job_outcome), state}
  end

  # Most-severe wins: a fault dominates admission backpressure dominates a clean
  # drain, so the tick re-arms conservatively.
  defp merge_outcome(:error, _other), do: :error
  defp merge_outcome(_prev, :error), do: :error
  defp merge_outcome(:busy, _other), do: :busy
  defp merge_outcome(_prev, :busy), do: :busy
  defp merge_outcome(:ok, :ok), do: :ok

  defp claim_and_start(job, now, state) do
    cond do
      expired?(job, now) -> expire_job(job.id, now, state)
      stale?(job, now, state.run_freshness_window_seconds) -> skip_stale_job(job, now, state)
      at_capacity?(state) -> {:busy, state}
      true -> claim_and_start_due_job(job, now, state)
    end
  end

  # Aggregate admission: the tick claims nothing while the run ceiling is full.
  # The blocked due job stays "scheduled" and a later tick (armed at the backoff
  # floor) or reconciliation claims it once a slot frees.
  defp at_capacity?(state), do: active_run_count(state) >= state.max_active_runs

  defp active_run_count(state) do
    DynamicSupervisor.count_children(state.runner_supervisor).active
  end

  # When the daemon is down across a recurring job's fire time, its next_run_at
  # is left far in the past. Firing it now would run the job with a wall-clock
  # far from the one it was scheduled for, so a due time older than the freshness
  # window is skipped and the schedule advances to the next future occurrence.
  # A one-off `once` job has no next occurrence to advance to — dropping it would
  # silently lose a one-time request — so it runs late instead, never stale.
  defp stale?(_job, _now, nil), do: false
  defp stale?(%{schedule_kind: "once"}, _now, _window), do: false

  defp stale?(%{next_run_at: %DateTime{} = next_run_at}, now, window) when is_integer(window) do
    DateTime.diff(now, next_run_at, :second) > window
  end

  defp stale?(_job, _now, _window), do: false

  defp skip_stale_job(job, now, state) do
    case advance_schedule(job, now) do
      {:ok, next_run_at} ->
        advance_stale_job(job, next_run_at, now, state)

      {:error, reason} ->
        Logger.error(
          "Scheduled job #{job.id} stale-skip schedule recompute failed; disabling: #{inspect(reason)}"
        )

        disable_job(job, schedule_error_message(reason), now, state)
    end
  end

  defp advance_schedule(job, now) do
    case Schedule.parse(job.schedule_expr, timezone: job.timezone, now: now) do
      {:ok, %{next_run_at: %DateTime{} = next_run_at}} -> {:ok, next_run_at}
      {:ok, _parsed} -> {:error, :no_future_run}
      {:error, reason} -> {:error, reason}
    end
  end

  # Re-fetch and guard on the live state (mirrors expiry) so an edit/pause that
  # lands between the due scan and here is not clobbered. Only next_run_at moves;
  # last_status/last_run_at stay untouched because no run actually happened.
  defp advance_stale_job(job, next_run_at, now, state) do
    case Repo.get_scheduled_job(job.id, server: state.repo) do
      {:ok, %{enabled?: true, state: "scheduled"} = current} ->
        Logger.info(
          "Scheduled job #{job.id} skipped a stale run due at " <>
            "#{DateTime.to_iso8601(job.next_run_at)}; next run at #{DateTime.to_iso8601(next_run_at)}"
        )

        outcome_state(store_advanced_run_at(current, next_run_at, now, state.repo), state)

      {:ok, _job} ->
        {:ok, state}

      {:error, :not_found} ->
        {:ok, state}

      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} stale-skip lookup failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp store_advanced_run_at(job, next_run_at, now, repo) do
    job
    |> Map.merge(%{next_run_at: next_run_at, updated_at: now})
    |> Repo.upsert_scheduled_job(server: repo)
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} stale-skip advance failed: #{inspect(reason)}")
        :error
    end
  end

  defp claim_and_start_due_job(job, now, state) do
    case claim_job_patch(job, now) do
      {:ok, job_patch} ->
        claim_patched_job(job, job_patch, now, state)

      # The claim patch fails only when the schedule expression/timezone no
      # longer parses. Retrying would re-fail forever, so the job is terminal:
      # disable it (edit then resume) rather than spin the due scan on it.
      {:error, reason} ->
        Logger.error(
          "Scheduled job #{job.id} schedule unparseable at claim; disabling: #{inspect(reason)}"
        )

        disable_job(job, schedule_error_message(reason), now, state)
    end
  end

  defp claim_patched_job(job, job_patch, now, state) do
    run_attrs = run_attrs(job, now)

    case Repo.claim_due_job(job.id, job_patch, run_attrs, now, server: state.repo) do
      {:ok, {claimed_job, run}} ->
        {:ok, start_or_mark_failed(claimed_job, run, state)}

      {:error, :already_running} ->
        {:ok, state}

      {:error, :not_due} ->
        {:ok, state}

      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} claim failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  # Out-of-band manual run: claim immediately regardless of the schedule, but
  # keep next_run_at so the timed cadence is undisturbed, and tag the run
  # `trigger: "manual"`. The runner dispatch and monitoring are the same as the
  # timed path — no second execution path.
  defp manual_run(job_id, now, state) do
    case Repo.get_scheduled_job(job_id, server: state.repo) do
      {:ok, job} -> manual_run_job(job, now, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # Classify the already-fetched job for a precise error. The state is the
  # authoritative signal: a job mid-run carries state "running" (the claim sets
  # it atomically), so "already running" is reported distinctly from a paused,
  # disabled, or completed job. The in-transaction `ensure_no_active_job_run`
  # guard (shared with the due path) remains the atomic race-stop underneath.
  defp manual_run_job(job, now, state) do
    cond do
      expired?(job, now) -> {{:error, :expired}, state}
      not job.enabled? -> {{:error, :not_runnable}, state}
      job.state == "running" -> {{:error, :already_running}, state}
      job.state != "scheduled" -> {{:error, :not_runnable}, state}
      true -> claim_manual_run(job, now, state)
    end
  end

  defp claim_manual_run(job, now, state) do
    run_attrs = job |> run_attrs(now) |> Map.put(:trigger, "manual")
    job_patch = %{state: "running", updated_at: now}

    case Repo.claim_job_now(job.id, job_patch, run_attrs, server: state.repo) do
      {:ok, {claimed_job, run}} ->
        {{:ok, run}, start_or_mark_failed(claimed_job, run, state)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp expired?(%{expires_at: nil}, _now), do: false

  defp expired?(%{expires_at: %DateTime{} = expires_at}, now) do
    DateTime.compare(now, expires_at) != :lt
  end

  defp expire_job(job_id, now, state) do
    case Repo.get_scheduled_job(job_id, server: state.repo) do
      {:ok, %{enabled?: true, state: "scheduled"} = job} ->
        outcome_state(expire_scheduled_job(job, now, state.repo), state)

      {:ok, _job} ->
        {:ok, state}

      {:error, :not_found} ->
        {:ok, state}

      {:error, reason} ->
        Logger.error("Scheduled job #{job_id} expiry lookup failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp expire_scheduled_job(job, now, repo) do
    if expired?(job, now) do
      job
      |> Map.merge(%{
        enabled?: false,
        state: "completed",
        next_run_at: nil,
        last_status: "expired",
        last_error: nil,
        updated_at: now
      })
      |> Repo.upsert_scheduled_job(server: repo)
      |> case do
        {:ok, updated_job} ->
          _ = mark_source_expired(updated_job, now, repo)
          :ok

        {:error, reason} ->
          Logger.error("Scheduled job #{job.id} expiry update failed: #{inspect(reason)}")
          :error
      end
    else
      :ok
    end
  end

  # Terminal state for a job whose schedule no longer parses (claim time or the
  # stale-skip recompute). Re-fetch and guard on the live row (mirrors expiry) so
  # an edit/pause landing between the due scan and here is not clobbered. The
  # `state = 'scheduled'` due-scan filter then keeps a disabled job off every
  # future tick; `resume` re-parses and fails loudly if the schedule is still
  # broken.
  defp disable_job(job, error, now, state) do
    case Repo.get_scheduled_job(job.id, server: state.repo) do
      {:ok, %{enabled?: true, state: "scheduled"} = current} ->
        current
        |> Map.merge(%{state: "disabled", enabled?: false, last_error: error, updated_at: now})
        |> Repo.upsert_scheduled_job(server: state.repo)
        |> case do
          {:ok, _updated} ->
            {:ok, state}

          {:error, reason} ->
            Logger.error("Scheduled job #{job.id} disable update failed: #{inspect(reason)}")
            {:error, state}
        end

      {:ok, _job} ->
        {:ok, state}

      {:error, :not_found} ->
        {:ok, state}

      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} disable lookup failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp schedule_error_message(:no_future_run), do: "schedule has no future occurrence"
  defp schedule_error_message(reason), do: "schedule no longer parses: #{inspect(reason)}"

  defp outcome_state(:ok, state), do: {:ok, state}
  defp outcome_state(:error, state), do: {:error, state}

  defp start_or_mark_failed(job, run, state) do
    case start_runner(job, run, state) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        put_in(state.run_monitors[ref], %{job_id: job.id, run_id: run.id})

      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} runner start failed: #{inspect(reason)}")
        mark_run_crashed(run.id, job.id, reason, state)
    end
  end

  defp claim_job_patch(%{schedule_kind: "once"} = _job, now) do
    {:ok, %{state: "running", next_run_at: nil, updated_at: now}}
  end

  defp claim_job_patch(job, now) do
    with {:ok, parsed} <- Schedule.parse(job.schedule_expr, timezone: job.timezone, now: now) do
      {:ok, %{state: "running", next_run_at: parsed.next_run_at, updated_at: now}}
    end
  end

  defp run_attrs(job, now) do
    %{
      id: "run_#{random_id()}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{timestamp_id(now)}",
      trigger: "schedule",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }
  end

  # Per-run startup delay = how many runs are already active × the stagger step,
  # capped. Read at start time, so a batch fired back-to-back spreads out (run 1
  # waits 0, run 2 one step, …) without the scheduler ever blocking — the runner
  # does the waiting before its first network call.
  defp startup_stagger_ms(state) do
    min(active_run_count(state) * @runner_stagger_ms, @max_startup_stagger_ms)
  end

  defp start_runner(job, run, state) do
    case RunnerSupervisor.start_run(state.runner_supervisor,
           runner_module: state.runner_module,
           repo: state.repo,
           capability_registry: state.capability_registry,
           skill_registry: state.skill_registry,
           job: job,
           run: run,
           adapter: state.adapter,
           adapter_opts: state.adapter_opts,
           delivery_adapter: state.delivery_adapter,
           delivery_opts: state.delivery_opts,
           delivery_channels: state.delivery_channels,
           delivery_timeout_ms: state.delivery_timeout_ms,
           output_base_dir: state.output_base_dir,
           timeout_ms: state.timeout_ms,
           inactivity_timeout_ms: state.inactivity_timeout_ms,
           notify: state.runner_notify,
           start_delay_ms: startup_stagger_ms(state)
         ) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, pid, _info} when is_pid(pid) -> {:ok, pid}
      :ignore -> {:error, :runner_ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_run_crashed(run_id, job_id, reason, state) do
    mark_run_failed(run_id, job_id, "runner crashed: #{inspect(reason)}", state)
  end

  # Shared terminal write for a run that ended without finalizing itself, whether
  # the scheduler watched it die (monitor) or found it abandoned (reconciliation).
  # The caller supplies the operator-facing cause; everything after is identical.
  defp mark_run_failed(run_id, job_id, error, state) when is_binary(error) do
    now = DateTime.utc_now()

    case mark_run_error(run_id, error, now, state.repo) do
      {:active_run_marked, _run} ->
        mark_job_error(job_id, error, now, state.repo)

      {:pending_delivery_marked, run} ->
        mark_job_completed_after_delivery_crash(job_id, run, now, state.repo)

      :ok ->
        :ok
    end

    state
  end

  defp mark_run_error(run_id, error, now, repo) do
    case Repo.get_job_run(run_id, server: repo) do
      {:ok, %{status: status} = run} when status in ["queued", "running"] ->
        mark_active_run_crashed(run, run_id, error, now, repo)

      {:ok, %{status: "ok", delivery_status: "pending"} = run} ->
        mark_pending_delivery_failed(run, run_id, error, now, repo)

      {:ok, _finished_run} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job run #{run_id} crash update failed: #{inspect(reason)}")
    end
  end

  defp mark_active_run_crashed(run, run_id, error, now, repo) do
    run
    |> Map.merge(%{
      status: "error",
      completed_at: now,
      error: error,
      updated_at: now
    })
    |> update_reaped_run(run_id, repo, :active_run_marked, "crash update")
  end

  defp mark_pending_delivery_failed(run, run_id, error, now, repo) do
    run
    |> Map.merge(%{
      delivery_status: "failed",
      delivery_error: error,
      updated_at: now
    })
    |> update_reaped_run(run_id, repo, :pending_delivery_marked, "pending delivery update")
  end

  defp update_reaped_run(run, run_id, repo, success_tag, log_context) do
    case Repo.upsert_job_run(run, server: repo) do
      {:ok, updated_run} ->
        {success_tag, updated_run}

      {:error, reason} ->
        Logger.error("Scheduled job run #{run_id} #{log_context} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_job_completed_after_delivery_crash(job_id, run, now, repo) do
    run_at = run.completed_at || now

    case Repo.get_scheduled_job(job_id, server: repo) do
      {:ok, job} ->
        job
        |> Map.merge(completed_job_state(job))
        |> Map.merge(%{
          last_run_at: run_at,
          last_status: "ok",
          last_error: nil,
          updated_at: now
        })
        |> Repo.upsert_scheduled_job(server: repo)
        |> case do
          {:ok, updated_job} ->
            mark_source_ok(updated_job, run_at, now, repo)

          {:error, reason} ->
            Logger.error(
              "Scheduled job #{job_id} delivery crash update failed: #{inspect(reason)}"
            )
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job #{job_id} delivery crash lookup failed: #{inspect(reason)}")
    end
  end

  defp completed_job_state(%{schedule_kind: "once"}) do
    %{enabled?: false, state: "completed", next_run_at: nil}
  end

  defp completed_job_state(%{state: "running"}), do: %{state: "scheduled"}
  defp completed_job_state(_job), do: %{}

  defp mark_job_error(job_id, error, now, repo) do
    case Repo.get_scheduled_job(job_id, server: repo) do
      {:ok, job} ->
        job
        |> Map.merge(failed_job_state(job))
        |> Map.merge(%{
          last_run_at: now,
          last_status: "error",
          last_error: error,
          updated_at: now
        })
        |> Repo.upsert_scheduled_job(server: repo)
        |> case do
          {:ok, updated_job} ->
            mark_source_error(updated_job, now, repo)

          {:error, reason} ->
            Logger.error("Scheduled job #{job_id} crash update failed: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job #{job_id} crash lookup failed: #{inspect(reason)}")
    end
  end

  defp failed_job_state(%{schedule_kind: "once"}) do
    %{enabled?: false, state: "completed", next_run_at: nil}
  end

  defp failed_job_state(%{state: "running"}), do: %{state: "scheduled"}
  defp failed_job_state(_job), do: %{}

  defp mark_source_error(job, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{last_run_at: now, last_status: "error", updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Scheduled job source #{job.memory_source_id} crash update failed: #{inspect(reason)}"
        )
    end
  end

  defp mark_source_ok(job, run_at, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{last_run_at: run_at, last_status: "ok", updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Scheduled job source #{job.memory_source_id} delivery crash update failed: #{inspect(reason)}"
        )
    end
  end

  defp mark_source_expired(job, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{status: "expired", last_status: "expired", updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Scheduled job source #{job.memory_source_id} expiry update failed: #{inspect(reason)}"
        )
    end
  end

  defp schedule_due_timer(state, outcome \\ :ok) do
    cancel_timer(state.due_timer)

    if state.enabled? and state.timer_enabled? do
      %{state | due_timer: next_due_timer(state, outcome)}
    else
      %{state | due_timer: nil}
    end
  end

  defp next_due_timer(state, outcome) do
    case Repo.next_scheduled_job(server: state.repo) do
      {:ok, job} when is_map(job) ->
        arm_due_timer(next_wakeup_at(job), outcome)

      {:ok, _none} ->
        backoff_timer(outcome)

      # The timer lookup itself failing is a fault: re-arm at the backoff floor
      # so the scheduler retries rather than going dark until reconciliation.
      {:error, reason} ->
        Logger.error("Scheduled job timer lookup failed: #{inspect(reason)}")
        Process.send_after(self(), :due_tick, @due_error_backoff_ms)
    end
  end

  defp arm_due_timer(%DateTime{} = wakeup_at, outcome) do
    Process.send_after(self(), :due_tick, due_delay_ms(wakeup_at, outcome))
  end

  defp arm_due_timer(nil, outcome), do: backoff_timer(outcome)

  defp backoff_timer(:ok), do: nil
  defp backoff_timer(_outcome), do: Process.send_after(self(), :due_tick, @due_error_backoff_ms)

  defp next_wakeup_at(%{next_run_at: nil, expires_at: nil}), do: nil
  defp next_wakeup_at(%{next_run_at: nil, expires_at: expires_at}), do: expires_at
  defp next_wakeup_at(%{next_run_at: next_run_at, expires_at: nil}), do: next_run_at

  defp next_wakeup_at(%{
         next_run_at: %DateTime{} = next_run_at,
         expires_at: %DateTime{} = expires_at
       }) do
    if DateTime.compare(expires_at, next_run_at) == :lt do
      expires_at
    else
      next_run_at
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

  # A clean tick fires at the next wakeup (0ms floor for a past-due job). A tick
  # that errored or hit admission backpressure re-arms no sooner than the backoff
  # floor, so a persistently past-due-but-unclaimable job cannot spin at 0ms.
  # The floor applies first, then the ceiling: the two never overlap (5s vs 24h),
  # so the order is only there to make the intent readable.
  defp due_delay_ms(next_run_at, outcome) do
    delay = max(DateTime.diff(next_run_at, DateTime.utc_now(), :millisecond), 0)

    case outcome do
      :ok -> min(delay, @max_due_delay_ms)
      _backoff -> delay |> max(@due_error_backoff_ms) |> min(@max_due_delay_ms)
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp random_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp timestamp_id(now) do
    Enum.map_join(
      [
        now.year,
        pad(now.month),
        pad(now.day),
        "_",
        pad(now.hour),
        pad(now.minute),
        pad(now.second)
      ],
      &to_string/1
    )
  end

  defp pad(value) when is_integer(value) and value < 10, do: "0#{value}"
  defp pad(value), do: value

  defp jobs_config(key, default) do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(key, default)
  end
end
