defmodule FermixCore.Cues.Filters do
  @moduledoc """
  The one filter dispatcher for every `llm` watcher (M60 §8.3, PLAN §4.2).

  Woken by `wake/0` after deliveries commit, by a timer when a backoff or a
  cue's retry falls due, and by a 60 s sweep that finds whatever a lost
  wake-up left behind, it claims through `CuesFilterSql`: each eligible
  watcher's oldest due `pending` delivery, the longest-waiting watcher first,
  at most four calls in flight across watchers and never two for one watcher
  (the claim query skips a watcher with a delivery in `filtering`, and this
  process passes the watchers it still holds a call for, so a call that has
  written its result but not yet reported back cannot be doubled).

  Each claim runs as one task under `FermixCore.Cues.FilterSupervisor`
  (`Task.Supervisor.async_nolink/2`, monitored). The task opens the call's
  run (`Cues.Filter.Telemetry`), asks `Cues.Filter.Llm.decide/2`, writes the
  result itself through the Repo (fenced on its `filter_call_id`), emits the
  filter-scoped lifecycle phase, sends any notice and closes the run. When it
  reports back, this process frees the slot, wakes the scheduler on a pass and
  claims again.

  A task that exits abnormally is a content failure for its cue; one shut down
  with its supervisor is `aborted` (the delivery goes back unchanged, as the
  boot sweep does); one still running at the 60 s deadline is killed and
  counted as a provider failure (a timeout). Each of these is written here,
  with the same fence, so a task that had already written its result loses
  nothing and is not counted twice.

  `init` runs the boot sweep (`{:reset, now}`) and arms the first sweep after
  1 s. Nothing is dispatched before that first sweep fires: `FilterSupervisor`
  starts after this process (its `rest_for_one` group), so a wake that lands
  earlier starts no call and the first sweep makes the pass it asked for. A
  boot sweep that fails is traced and tried again before the first claim,
  never skipped. Rows are the truth; the in-flight map is a cache of them.
  The first sweep also wakes the scheduler once, since its own admission
  request at init comes before the cue tree runs.

  Every sweep first reclaims the `filtering` rows no task holds (a claim that
  landed after its Repo call timed out, a settle that rolled back): a row
  whose call is not in flight here and started more than the call deadline
  plus 30 s ago goes back to `pending`, attempts unchanged, and its call is
  finished `aborted` (`{:reclaim_orphans, ...}`).

  Notices go through `Cues.Notices.watcher/4`: `:filter_held` when a watcher's
  third provider failure in a row holds it, `:filter_recovered` when a held
  watcher's call succeeds, `:filter_failed` when a cue is exhausted, and
  `:filter_budget_reached` when a watcher's filter budget holds its deliveries
  back. `Cues.Notices` sends each once per episode.
  """

  use GenServer

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Filter.Llm
  alias FermixCore.Cues.Filter.Telemetry, as: FilterTelemetry
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Timeouts

  @max_in_flight 4
  @first_sweep_ms 1_000
  @sweep_ms 60_000
  @call_timeout_ms 60_000
  # How far past the call deadline a `filtering` row no task holds must be
  # before the sweep reclaims it.
  @orphan_margin_ms 30_000
  @task_supervisor FermixCore.Cues.FilterSupervisor
  @shutdown_reasons [:shutdown]

  @doc """
  Starts the dispatcher. Opts: `:name` (default `__MODULE__`), `:repo`
  (default `Memory.Repo`), `:clock` (a zero-arity function returning the UTC
  now), `:timers?` (default true; false turns off the sweep, the due timer and
  the call deadline, for tests, and the dispatcher dispatches from its first
  wake, its task supervisor being the test's), `:schedule` (a function
  `(message, ms) -> term()` that arms the sweep timers, default
  `Process.send_after/3` to this process), `:task_supervisor` (default
  `FermixCore.Cues.FilterSupervisor`), `:notices` (default `Cues.Notices`) and
  `:notice_opts` (appended to every notice call's opts), `:llm` (opts for
  `Cues.Filter.Llm.decide/2`'s seams) and `:wake_scheduler` (default
  `Cues.wake_scheduler/0`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Asks the dispatcher to claim what is due now. A cast: it never blocks."
  @spec wake(GenServer.server()) :: :ok
  def wake(server \\ __MODULE__), do: GenServer.cast(server, :wake)

  @doc "The most filter calls in flight at once, across every watcher."
  @spec max_in_flight() :: pos_integer()
  def max_in_flight, do: @max_in_flight

  @impl true
  def init(opts) do
    timers? = Keyword.get(opts, :timers?, true)

    state = %{
      repo: Keyword.get(opts, :repo, Repo),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      timers?: timers?,
      schedule: Keyword.get(opts, :schedule, &send_after_self/2),
      # Whether the first sweep has fired; until then a wake starts nothing.
      ready?: not timers?,
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      notices: Keyword.get(opts, :notices, Notices),
      notice_opts: Keyword.get(opts, :notice_opts, []),
      llm_opts: Keyword.get(opts, :llm, []),
      wake_scheduler: Keyword.get(opts, :wake_scheduler, &Cues.wake_scheduler/0),
      in_flight: %{},
      due_timer: nil,
      reset_pending?: true
    }

    if state.timers?, do: state.schedule.(:sweep, @first_sweep_ms)
    {:ok, boot_reset(state)}
  end

  # Before the first sweep the task supervisor may not be up yet: that sweep
  # makes the pass an early wake asked for.
  @impl true
  def handle_cast(:wake, %{ready?: false} = state), do: {:noreply, state}
  def handle_cast(:wake, state), do: {:noreply, dispatch(state)}

  @impl true
  def handle_info(:sweep, state) do
    state.schedule.(:sweep, @sweep_ms)
    {:noreply, state |> first_sweep() |> reclaim_orphans() |> dispatch()}
  end

  def handle_info(:due, state), do: {:noreply, dispatch(%{state | due_timer: nil})}

  def handle_info({:deadline, ref}, state) when is_reference(ref) do
    {:noreply, ref |> expire(state) |> dispatch()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, ref |> crashed(reason, state) |> dispatch()}
  end

  def handle_info({ref, reply}, state) when is_reference(ref) do
    {:noreply, ref |> reported(reply, state) |> dispatch()}
  end

  # --- boot -------------------------------------------------------------------------

  # The boot sweep must run before this process's first claim: until it has,
  # a delivery a stopped call left in `filtering` holds its watcher. A failure
  # (the Repo busy or timing out at boot) is traced and leaves the sweep
  # pending, and every dispatch tries it again first, so a slow Repo cannot
  # take the cue tree down and nothing is claimed past an unswept row.
  defp boot_reset(state) do
    case Repo.cues_call(CuesFilterSql, {:reset, state.clock.()}, repo_opts(state)) do
      {:ok, %{reset: 0}} ->
        %{state | reset_pending?: false}

      {:ok, %{reset: count}} ->
        Logger.info("Cue filters: #{count} filter call(s) cut off by a stop are due again.")
        %{state | reset_pending?: false}

      {:error, reason} ->
        trace_error(:filter_reset, reason)
        state
    end
  end

  # The first sweep marks the filtering group started: the task supervisor is
  # up, and the cue tree is running. The scheduler's own admission request at
  # its init comes before the cue tree exists and is skipped, so it is woken
  # once here and passed deliveries waiting since before a boot or a restart
  # start now, not at its next tick.
  defp first_sweep(%{ready?: true} = state), do: state

  defp first_sweep(state) do
    state.wake_scheduler.()
    %{state | ready?: true}
  end

  # A `filtering` row whose call no task holds (a claim that landed after its
  # Repo call timed out, a settle that rolled back) would hold its watcher
  # until a restart (TLA cue_inbox CUE-1). The sweep puts it back once its
  # call is older than the call deadline and its margin; a call this process
  # still holds is never touched, however old. A failure is traced, logged
  # and tried again by the next sweep.
  defp reclaim_orphans(%{reset_pending?: true} = state), do: state

  defp reclaim_orphans(state) do
    now = state.clock.()
    cutoff = DateTime.add(now, -(@call_timeout_ms + @orphan_margin_ms), :millisecond)
    held = state.in_flight |> Map.values() |> Enum.map(& &1.run.call_id)
    request = {:reclaim_orphans, held, cutoff, now}

    case Repo.cues_call(CuesFilterSql, request, repo_opts(state)) do
      {:ok, %{reclaimed: []}} ->
        state

      {:ok, %{reclaimed: reclaimed}} ->
        Logger.warning(
          "Cue filters: #{length(reclaimed)} filter call(s) no task held are due again."
        )

        state

      {:error, reason} ->
        trace_error(:filter_reclaim, reason)
        state
    end
  end

  # --- dispatch ---------------------------------------------------------------------

  defp dispatch(%{reset_pending?: true} = state) do
    case boot_reset(state) do
      %{reset_pending?: true} = still_pending -> still_pending
      swept -> dispatch(swept)
    end
  end

  defp dispatch(state) do
    case @max_in_flight - map_size(state.in_flight) do
      free when free > 0 -> claim(state, free)
      _full -> state
    end
  end

  defp claim(state, free) do
    now = state.clock.()
    busy = state.in_flight |> Map.values() |> Enum.map(& &1.run.watcher_id)

    case Repo.cues_call(CuesFilterSql, {:claim, now, free, busy}, repo_opts(state)) do
      {:ok, %{claims: claims, over_budget: over, next_at: next_at}} ->
        Enum.each(over, &notify(state, &1.watcher_id, :filter_budget_reached, budget_data(&1)))
        state = Enum.reduce(claims, state, &start_call/2)
        arm_due(state, next_at, now)

      {:error, reason} ->
        trace_error(:filter_claim, reason)
        state
    end
  end

  defp start_call(claim, state) do
    context = task_context(state)
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> run_call(claim, context) end)

    deadline =
      if state.timers?, do: Process.send_after(self(), {:deadline, task.ref}, @call_timeout_ms)

    entry = %{run: run_of(claim), pid: task.pid, deadline: deadline, started_ms: monotonic_ms()}
    %{state | in_flight: Map.put(state.in_flight, task.ref, entry)}
  end

  defp arm_due(%{timers?: false} = state, _next_at, _now), do: state
  defp arm_due(state, nil, _now), do: state

  defp arm_due(state, %DateTime{} = next_at, now) do
    if state.due_timer, do: Process.cancel_timer(state.due_timer)
    delay = max(DateTime.diff(next_at, now, :millisecond), 0)
    %{state | due_timer: Process.send_after(self(), :due, delay)}
  end

  # --- one call, inside its task ------------------------------------------------------

  defp run_call(claim, context) do
    run = run_of(claim)
    started = monotonic_ms()
    FilterTelemetry.run_start(run)

    result = Llm.decide(claim, Keyword.put(context.llm_opts, :session_id, claim.session_id))
    reply = settle(context, run, result)
    finish(context, run, result, reply, monotonic_ms() - started)
    {:settled, match?({:ok, %{passed?: true}}, reply)}
  end

  defp run_of(claim) do
    %{
      session_id: claim.session_id,
      call_id: claim.call_id,
      watcher_id: claim.watcher.id,
      delivery_id: claim.delivery.id,
      cue_id: claim.cue.id,
      source_ref: claim.cue.source_ref,
      attempt: claim.delivery.filter_attempts,
      provider: claim.watcher.filter_provider,
      model: claim.watcher.filter_model
    }
  end

  defp task_context(state) do
    Map.take(state, [:repo, :clock, :notices, :notice_opts, :llm_opts, :wake_scheduler])
  end

  defp settle(context, run, result) do
    request = {:settle, run.call_id, result, context.clock.()}
    Repo.cues_call(CuesFilterSql, request, repo_opts(context))
  end

  # --- the end of a call: written by its task, or here when the task cannot -----------

  defp reported(ref, reply, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {entry, in_flight} ->
        Process.demonitor(ref, [:flush])
        cancel(entry.deadline)
        if match?({:settled, true}, reply), do: state.wake_scheduler.()
        %{state | in_flight: in_flight}
    end
  end

  defp crashed(ref, reason, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {entry, in_flight} ->
        cancel(entry.deadline)
        end_here(state, entry, down_result(entry.run, reason))
        %{state | in_flight: in_flight}
    end
  end

  defp expire(ref, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {entry, in_flight} ->
        Process.exit(entry.pid, :kill)
        Process.demonitor(ref, [:flush])
        message = "The filter model gave no answer within #{div(@call_timeout_ms, 1000)} seconds."
        end_here(state, entry, {:provider_failure, %{kind: :timeout, message: message}})
        %{state | in_flight: in_flight}
    end
  end

  defp end_here(state, entry, result) do
    context = task_context(state)
    reply = settle(context, entry.run, result)
    finish(context, entry.run, result, reply, monotonic_ms() - entry.started_ms)
  end

  defp down_result(_run, reason) when reason in @shutdown_reasons,
    do:
      {:aborted, %{kind: :shutdown, message: "The filter call was stopped with its supervisor."}}

  defp down_result(_run, {:shutdown, _detail}),
    do:
      {:aborted, %{kind: :shutdown, message: "The filter call was stopped with its supervisor."}}

  defp down_result(run, reason) do
    Logger.warning("Cue filter call #{run.call_id} crashed: #{inspect(reason)}")
    {:content_failure, %{kind: :crashed, message: "The filter call stopped unexpectedly."}}
  end

  defp finish(context, run, result, {:ok, outcome}, duration_ms) do
    emit_phase(run, result, outcome)
    send_notices(context, run, result, outcome)
    close(run, result, duration_ms)
  end

  # A stale settle here can follow a deadline kill of a task that had already
  # written its pass and not yet reported it: the scheduler is woken anyway (a
  # wake is cheap and idempotent), so that pass does not wait for its 60 s
  # reconcile.
  defp finish(context, run, _result, {:error, :stale}, duration_ms) do
    context.wake_scheduler.()
    FilterTelemetry.run_error(run, :stale, :stale, duration_ms)
  end

  defp finish(_context, run, _result, {:error, reason}, duration_ms) do
    Logger.error("Cue filter call #{run.call_id} could not write its result: #{inspect(reason)}")
    FilterTelemetry.run_error(run, :settle_failed, error_kind(reason), duration_ms)
  end

  defp close(run, {:pass, _reason, _hint}, duration_ms),
    do: FilterTelemetry.run_complete(run, :pass, duration_ms)

  defp close(run, {:drop, _reason}, duration_ms),
    do: FilterTelemetry.run_complete(run, :drop, duration_ms)

  defp close(run, {status, %{kind: kind}}, duration_ms),
    do: FilterTelemetry.run_error(run, status, kind, duration_ms)

  # --- lifecycle and notices ----------------------------------------------------------

  defp emit_phase(run, result, outcome) do
    {phase, extra} = phase(result, outcome)

    metadata =
      Map.merge(
        %{
          session_id: run.session_id,
          filter_call_id: run.call_id,
          watcher_id: run.watcher_id,
          delivery_id: run.delivery_id,
          cue_id: run.cue_id,
          source_ref: run.source_ref,
          job_id: outcome.task_job_id,
          attempt: outcome.attempt
        },
        extra
      )

    Telemetry.lifecycle(phase, %{}, Map.reject(metadata, fn {_key, value} -> is_nil(value) end))
  end

  defp phase({:pass, reason, _hint}, _outcome), do: {:passed, %{decision: :pass, content: reason}}
  defp phase({:drop, reason}, _outcome), do: {:dropped, %{decision: :drop, content: reason}}

  defp phase({status, %{kind: kind}}, %{result: result}) do
    phase =
      case result do
        :held -> :filter_held
        :exhausted -> :filter_failed
        _retry_or_aborted -> :filter_retry
      end

    {phase, %{reason: status, kind: kind, result: {:error, kind}}}
  end

  defp send_notices(context, run, result, outcome) do
    message = failure_message(result)
    base = %{watcher_name: outcome.watcher_name, waiting: outcome.waiting}

    if outcome.held_now?,
      do: notify(context, run.watcher_id, :filter_held, Map.put(base, :error, message))

    if outcome.recovered?, do: notify(context, run.watcher_id, :filter_recovered, base)

    if outcome.exhausted? do
      data = Map.merge(base, %{delivery_id: run.delivery_id, cue_id: run.cue_id, error: message})
      notify(context, run.watcher_id, :filter_failed, data)
    end

    :ok
  end

  defp failure_message({_status, %{message: message}}), do: message
  defp failure_message(_decision), do: nil

  defp budget_data(over) do
    %{watcher_name: over.watcher_name, waiting: over.waiting, budget: over.budget}
  end

  defp notify(context, watcher_id, kind, data) do
    opts = [repo: context.repo, now: context.clock.()] ++ context.notice_opts

    case context.notices.watcher(watcher_id, kind, data, opts) do
      {:error, reason} ->
        Logger.warning("Cue filter notice #{kind} for #{watcher_id} failed: #{inspect(reason)}")

      _sent_or_already ->
        :ok
    end
  end

  # --- helpers ------------------------------------------------------------------------

  defp trace_error(step, reason) do
    Telemetry.lifecycle(:sweep_error, %{}, %{reason: step, result: {:error, reason}})
    Logger.error("Cue filters: #{step} failed: #{inspect(reason)}")
  end

  defp error_kind(reason) when is_atom(reason), do: reason

  defp error_kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp error_kind(_reason), do: :unclassified

  defp cancel(nil), do: :ok

  defp cancel(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp repo_opts(%{repo: repo}), do: Repo.periodic_opts(repo, Timeouts.repo_call())

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp send_after_self(message, ms), do: Process.send_after(self(), message, ms)
end
