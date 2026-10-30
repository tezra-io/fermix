defmodule FermixCore.Jobs.CueAdmission do
  @moduledoc """
  Admission and settle of cue runs (M60 §9.2, §9.4): plain functions that
  `Jobs.Scheduler` calls with its own state, and the settle the runner and the
  scheduler both use.

  ## Slots

  Cue runs and watcher follow-up runs (`trigger` `"cue"` and `"watcher"`,
  M60_WATCHER_CODING_RUNS.md §4.2) share at most three of the scheduler's run
  slots, counted from the `trigger` each `run_monitors` entry carries, so a
  cron run always keeps one: `free = min(max_active − active, 3 − active_cue)`.
  Manual runs still bypass the ceiling; a follow-up never takes that path. The
  scheduler admits only after a due scan, so a cron run that is due, or that
  the ceiling held back, takes a freed slot first.

  ## Follow-ups

  Each pass first hands every new waiting card to `offer` (`offer_follow_ups/2`,
  at most 10 a pass, each sent outside the scheduler's loop), then admits the
  oldest `starting` triggers into the free slots (`claim_follow_ups/4`): each
  is checked against the hold (`Cues.FollowUps.check/3`) and claimed with its
  job (`Repo.claim_follow_up_run/4`), which refuses it when the job still runs.
  A refused trigger spends no slot. Cue runs take the slots left.

  ## Lifecycle telemetry

  Every claim emits `claimed` and every settle `settled`, `retry` or
  `exhausted` through `Cues.Telemetry.lifecycle/3`, with the run's
  `session_id`, so each renders inside the run's trace. A failed scan, claim
  or settle is traced as `sweep_error` (reason `cue_claim` or `cue_settle`)
  before it is logged.

  ## Cap notices

  Each admission pass also reads the watchers whose oldest waiting delivery
  only the daily cap (or a source's half of it) holds, and sends each the
  `:cap_reached` watcher notice with the cap and how many items wait (C25),
  and the watchers with no task whose follow-up the cap skipped an item of,
  which get it with the cap and `follow_up: true` through their follow-up's
  delivery (M60_WATCHER_CODING_RUNS.md §4.4, §4.6). `Cues.Notices` sends it
  once per 24-hour window.
  """

  require Logger

  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Telemetry, as: CueTelemetry
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixCore.Memory.Repo.CuesRunsSql

  @max_cue_runs 3
  @cue_share_triggers ["cue", "watcher"]
  # Cards offered, and starting triggers read, per admission pass.
  @offers_per_pass 10
  @follow_up_scan 10

  @type claim :: %{job: map(), run: map(), delivery: map()}
  @type follow_up_claim :: %{job: map(), run: map(), trigger: map()}
  @type settled :: {map(), map(), CuesRunsSql.settlement()}

  @doc "The most run slots cue runs may hold at once."
  @spec max_cue_runs() :: pos_integer()
  def max_cue_runs, do: @max_cue_runs

  @doc "How many of the scheduler's monitored runs hold the cue share: cue and follow-up runs."
  @spec active_cue_runs(map()) :: non_neg_integer()
  def active_cue_runs(run_monitors) when is_map(run_monitors) do
    Enum.count(run_monitors, fn {_ref, info} -> Map.get(info, :trigger) in @cue_share_triggers end)
  end

  @doc """
  The cue runs that may start now: the open slots under `max_active`, capped
  by the cue share less the cue runs already active. Never negative.
  """
  @spec free_slots(non_neg_integer(), map(), pos_integer()) :: non_neg_integer()
  def free_slots(active, run_monitors, max_active)
      when is_integer(active) and active >= 0 and is_map(run_monitors) and
             is_integer(max_active) and max_active > 0 do
    open = max_active - active
    cue_room = @max_cue_runs - active_cue_runs(run_monitors)
    max(min(open, cue_room), 0)
  end

  @doc """
  Claims up to `free` cue runs at `now`, one per task, in the order of each
  task's oldest eligible delivery. `run_attrs_fun` builds a run's attributes
  from its job id (the scheduler's ids and session id). Returns the claims the
  caller must start; a candidate that is no longer due is skipped, and a fault
  is traced, logged and skipped, to be found by the next pass.

  `opts`: `:repo_opts` (the `Memory.Repo` call options) and `:cue_notice`, a
  function `(watcher_id, kind, data) -> term()` that sends one watcher notice,
  called with `:cap_reached` and `%{cap: n, waiting: n}` for each watcher only
  its cap holds, or `%{cap: n, follow_up: true}` for a watcher with no task
  whose follow-up the cap skipped.
  """
  @spec claim(non_neg_integer(), DateTime.t(), (String.t() -> map()), keyword()) :: [claim()]
  def claim(0, %DateTime{}, run_attrs_fun, opts)
      when is_function(run_attrs_fun, 1) and is_list(opts),
      do: []

  def claim(free, %DateTime{} = now, run_attrs_fun, opts)
      when is_integer(free) and free > 0 and is_function(run_attrs_fun, 1) and is_list(opts) do
    repo_opts = Keyword.fetch!(opts, :repo_opts)
    cue_notice = Keyword.fetch!(opts, :cue_notice)
    true = is_list(repo_opts) and is_function(cue_notice, 3)

    case Repo.cues_call(CuesRunsSql, {:admission_candidates, now, free}, repo_opts) do
      {:ok, %{candidates: candidates, capped: capped}} ->
        Enum.each(capped, &cap_notice(&1, cue_notice))
        Enum.flat_map(candidates, &claim_candidate(&1, now, run_attrs_fun, repo_opts))

      {:error, reason} ->
        trace_error(:cue_claim, %{}, reason)
        Logger.error("Cue admission candidate scan failed: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Settles a cue run through `Repo.settle_cue_run/3` and emits its lifecycle
  phase: `settled` (acked), `retry` (back to passed) or `exhausted`. The
  runner passes its outcome (`:ignored`, `:acted`, `{:failed, :provider}`,
  `{:failed, :other}`); the scheduler passes `:scheduler` for a reap or a
  monitored crash. `{:error, :run_not_active}` (the run settled already) is
  returned unlogged for the caller's own branch; any other error is logged.
  """
  @spec settle(map(), CuesRunsSql.settle_by(), keyword()) ::
          {:ok, settled()} | {:error, term()}
  def settle(%{id: run_id} = attrs, settle_by, repo_opts)
      when is_binary(run_id) and is_list(repo_opts) do
    case Repo.settle_cue_run(attrs, settle_by, repo_opts) do
      {:ok, {run, _job, settlement}} = settled ->
        emit_settle(run, settlement, settle_by)
        settled

      {:error, :run_not_active} = error ->
        error

      {:error, reason} = error ->
        trace_error(:cue_settle, %{job_id: Map.get(attrs, :job_id), run_id: run_id}, reason)
        Logger.error("Cue run #{run_id} settle failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Claims the waiting follow-up cards not yet offered (at most
  #{@offers_per_pass}, each stamped so it is offered once) and hands each to
  `offer`, a function `(trigger) -> term()` that sends it outside the caller's
  loop. `opts`: `:repo_opts` and `:offer`. A failed claim is traced and
  logged; the next pass reads them again.
  """
  @spec offer_follow_ups(DateTime.t(), keyword()) :: :ok
  def offer_follow_ups(%DateTime{} = now, opts) when is_list(opts) do
    repo_opts = Keyword.fetch!(opts, :repo_opts)
    offer = Keyword.fetch!(opts, :offer)
    true = is_function(offer, 1)

    case Repo.cues_call(CuesFollowUpSql, {:claim_offers, now, @offers_per_pass}, repo_opts) do
      {:ok, triggers} ->
        Enum.each(triggers, offer)

      {:error, reason} ->
        trace_error(:follow_up_offer, %{}, reason)
        Logger.error("Follow-up card claim failed: #{inspect(reason)}")
    end
  end

  @doc """
  Admits follow-up runs into `free` cue-share slots at `now`: the oldest
  `starting` triggers (at most #{@follow_up_scan} read), each checked against
  the hold and claimed with its job until the slots are spent. `run_attrs_fun`
  builds a run's attributes from its job id. Returns the claims the caller
  must start. `opts`: `:repo_opts`, `:notice` (`(watcher_id, kind, data) ->
  term()`, the hold's notices) and `:capability_registry`.
  """
  @spec claim_follow_ups(non_neg_integer(), DateTime.t(), (String.t() -> map()), keyword()) ::
          [follow_up_claim()]
  def claim_follow_ups(0, %DateTime{}, run_attrs_fun, opts)
      when is_function(run_attrs_fun, 1) and is_list(opts),
      do: []

  def claim_follow_ups(free, %DateTime{} = now, run_attrs_fun, opts)
      when is_integer(free) and free > 0 and is_function(run_attrs_fun, 1) and is_list(opts) do
    repo_opts = Keyword.fetch!(opts, :repo_opts)

    case Repo.cues_call(CuesFollowUpSql, {:starting_triggers, @follow_up_scan}, repo_opts) do
      {:ok, triggers} ->
        Enum.reduce_while(
          triggers,
          [],
          &admit_until_full(&1, &2, free, {now, run_attrs_fun, opts})
        )

      {:error, reason} ->
        trace_error(:follow_up_claim, %{}, reason)
        Logger.error("Follow-up admission scan failed: #{inspect(reason)}")
        []
    end
  end

  # --- private ------------------------------------------------------------------

  # A refused trigger spends no slot, so the scan goes on until `free` started.
  defp admit_until_full(_trigger, claims, free, _admission) when length(claims) >= free,
    do: {:halt, claims}

  defp admit_until_full(trigger, claims, _free, {now, run_attrs_fun, opts}),
    do: {:cont, claims ++ admit_trigger(trigger, now, run_attrs_fun, opts)}

  # A job gone since its trigger was written is refused by the claim itself.
  defp admit_trigger(trigger, now, run_attrs_fun, opts) do
    repo_opts = Keyword.fetch!(opts, :repo_opts)

    case JobsRegistry.get_job(trigger.job_id, repo_opts) do
      {:ok, job} ->
        if held_check(trigger, job, opts) == :ready,
          do: claim_trigger(trigger, now, run_attrs_fun, repo_opts),
          else: []

      {:error, :not_found} ->
        claim_trigger(trigger, now, run_attrs_fun, repo_opts)

      {:error, reason} ->
        trace_error(:follow_up_claim, %{job_id: trigger.job_id}, reason)
        Logger.error("Follow-up #{trigger.id}: its job could not be read: #{inspect(reason)}")
        []
    end
  end

  defp held_check(trigger, job, opts) do
    repo_opts = Keyword.fetch!(opts, :repo_opts)

    check_opts =
      [repo: Keyword.fetch!(repo_opts, :server)] ++
        Keyword.take(repo_opts, [:timeout, :on_timeout]) ++
        Keyword.take(opts, [:notice, :capability_registry, :cues_config])

    FollowUps.check(trigger, job, check_opts)
  end

  defp claim_trigger(trigger, now, run_attrs_fun, repo_opts) do
    case Repo.claim_follow_up_run(trigger.id, run_attrs_fun.(trigger.job_id), now, repo_opts) do
      {:ok, {:started, claim}} ->
        FollowUps.emit_started(claim.trigger, claim.run)
        [claim]

      {:ok, {:refused, refused}} ->
        FollowUps.emit_refused(refused, "not_runnable")
        []

      {:error, :nothing_due} ->
        []

      {:error, reason} ->
        trace_error(:follow_up_claim, %{job_id: trigger.job_id}, reason)
        Logger.error("Follow-up claim of trigger #{trigger.id} failed: #{inspect(reason)}")
        []
    end
  end

  defp cap_notice(%{watcher_id: watcher_id, daily_cap: cap, follow_up: true}, cue_notice),
    do: cue_notice.(watcher_id, :cap_reached, %{cap: cap, follow_up: true})

  defp cap_notice(%{watcher_id: watcher_id, daily_cap: cap, waiting: waiting}, cue_notice),
    do: cue_notice.(watcher_id, :cap_reached, %{cap: cap, waiting: waiting})

  defp claim_candidate(%{job_id: job_id}, now, run_attrs_fun, repo_opts) do
    case Repo.claim_cue_run(job_id, run_attrs_fun.(job_id), now, repo_opts) do
      {:ok, claim} ->
        emit_claimed(claim, now)
        [claim]

      # The row moved, or the job's earlier run still holds it, since the scan:
      # the next pass reads it again.
      {:error, reason} when reason in [:nothing_due, :already_running] ->
        Logger.debug("Cue claim of job #{job_id} skipped: #{inspect(reason)}")
        []

      {:error, reason} ->
        trace_error(:cue_claim, %{job_id: job_id}, reason)
        Logger.error("Cue claim of job #{job_id} failed: #{inspect(reason)}")
        []
    end
  end

  # Every claim or settle error is traced before it is logged (design §14),
  # as the sessionless `sweep_error` the filter dispatcher uses.
  defp trace_error(step, ids, reason) do
    metadata =
      ids
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(%{reason: step, result: {:error, reason}})

    CueTelemetry.lifecycle(:sweep_error, %{}, metadata)
  end

  defp emit_claimed(%{run: run, delivery: delivery}, now) do
    queue_ms = max(DateTime.diff(now, delivery.received_at, :millisecond), 0)

    CueTelemetry.lifecycle(:claimed, %{queue_ms: queue_ms}, %{
      session_id: run.session_id,
      job_id: run.job_id,
      run_id: run.id,
      delivery_id: delivery.id,
      watcher_id: delivery.watcher_id,
      source_ref: delivery.source_ref,
      state: "claimed",
      attempt: delivery.task_attempts
    })
  end

  defp emit_settle(_run, %{disposition: :untouched}, _settle_by), do: :ok

  defp emit_settle(run, settlement, settle_by) do
    CueTelemetry.lifecycle(settle_phase(settlement.disposition), %{}, %{
      session_id: run.session_id,
      job_id: run.job_id,
      run_id: run.id,
      delivery_id: settlement.delivery_id,
      watcher_id: settlement.watcher_id,
      source_ref: settlement.source_ref,
      state: settlement.state,
      outcome: settlement.outcome,
      attempt: settlement.task_attempts,
      reason: settle_reason(settle_by)
    })
  end

  defp settle_phase(:acked), do: :settled
  defp settle_phase(:retry), do: :retry
  defp settle_phase(:exhausted), do: :exhausted

  defp settle_reason(:ignored), do: "ignored"
  defp settle_reason(:acted), do: "acted"
  defp settle_reason({:failed, :provider}), do: "provider_failure"
  defp settle_reason({:failed, :other}), do: "run_failure"
  defp settle_reason(:scheduler), do: "reaped"
end
