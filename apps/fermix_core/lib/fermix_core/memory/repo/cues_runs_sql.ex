defmodule FermixCore.Memory.Repo.CuesRunsSql do
  @moduledoc """
  SQL for the run's side of the cue inbox (M60 §9.2–§9.4; PLAN §4.3): admission
  candidates, the delivery parts of the cue-run claim and settle, and the reads
  a cue run makes. Lane C owns it. What `list_cues` and `cue_history` read is
  `FermixCore.Memory.Repo.CuesDeliveriesSql`.

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`. One `handle/2` head per request tuple,
  every head contiguous and above the catch-all, which must stay last (private
  helpers go below it, or Elixir refuses the split clauses). Delivery moves go
  through `FermixCore.Memory.Repo.CuesSql.transition/6`.

  `eligible_delivery/3` and `settle_delivery/4` are not requests: the cue-run
  claim and settle are one transaction with the job and run rows, so
  `Memory.Repo` calls them with its own connection inside that transaction
  (PLAN §2.1, the exception).

  ## Eligibility (one rule for the candidates and the claim)

  A `passed` delivery is eligible when its `ready_at` has come and its
  `valid_until` has not; its task's job
  is enabled, `scheduled` and holds no active run; no older delivery of the
  same watcher and the same non-null subject is still `pending`, `filtering`,
  `passed` or `claimed`; and, when the watcher's `daily_cap` is above 0, the
  job's cue runs created in the last 24 hours, with the watcher's follow-ups
  started or proposed in them (M60_WATCHER_CODING_RUNS.md §4.4,
  `CuesFollowUpSql.counted_sql/0`), are under the cap and, for a watcher with
  more than one source, the runs caused by the delivery's source are under
  half of it.

  The watcher's own `enabled` is not part of the rule (design §8.8): a paused
  watcher stops routing and filtering, but the items it already passed still
  wake its task.
  """

  require Logger

  alias FermixCore.Memory.Repo.CuesDeliveriesSql
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixCore.Memory.Repo.CuesSql

  # Retry delays (design §9.4): a provider failure spends no attempt and backs
  # off 30 s, 2 min, then every 10 min; any other failure spends one and backs
  # off 30 s, then 2 min; the third is the last.
  @provider_backoff_s [30, 120]
  @provider_backoff_cap_s 600
  @other_backoff_s [30, 120]
  @max_task_attempts 3
  @cap_window_s 86_400
  # Capped watchers read per admission pass (each may become a notice).
  @capped_max 10

  @type conn :: term()
  @type settle_by :: :ignored | :acted | {:failed, :provider} | {:failed, :other} | :scheduler
  @type candidate :: %{job_id: String.t(), watcher_id: String.t(), delivery_id: pos_integer()}
  @type capped :: %{
          watcher_id: String.t(),
          daily_cap: pos_integer(),
          waiting: non_neg_integer()
        }
  @type delivery :: %{
          id: pos_integer(),
          cue_id: pos_integer(),
          watcher_id: String.t(),
          source_ref: String.t(),
          subject: String.t() | nil,
          received_at: DateTime.t(),
          ready_at: DateTime.t(),
          task_attempts: non_neg_integer(),
          state: String.t()
        }
  @type settlement :: %{
          delivery_id: pos_integer(),
          watcher_id: String.t() | nil,
          source_ref: String.t() | nil,
          disposition: :acked | :retry | :exhausted | :untouched,
          state: String.t() | nil,
          outcome: String.t() | nil,
          task_attempts: non_neg_integer() | nil,
          ready_at: DateTime.t() | nil
        }

  # The eligibility rule without the cap, as one FROM/WHERE. Its two `?` are
  # now: a delivery past its lifetime is never claimed, even before the
  # retention sweep expires it (design §7.4).
  @open_sql """
  FROM cue_deliveries d
  JOIN cue_watchers w ON w.id = d.watcher_id
  JOIN scheduled_jobs j ON j.id = w.task_job_id
  WHERE d.state = 'passed'
    AND d.ready_at <= ?
    AND d.valid_until > ?
    AND j.enabled = 1
    AND j.state = 'scheduled'
    AND NOT EXISTS (
      SELECT 1 FROM job_runs a WHERE a.job_id = j.id AND a.status IN ('queued', 'running'))
    AND (d.subject IS NULL OR NOT EXISTS (
      SELECT 1 FROM cue_deliveries o
      WHERE o.watcher_id = d.watcher_id AND o.subject = d.subject AND o.id < d.id
        AND o.state IN ('pending', 'filtering', 'passed', 'claimed')))
  """

  # The cap rule, true when the delivery has room. Its three `?` are the start
  # of the 24-hour cap window. `julianday` reads job_runs times, which are ISO
  # 8601 of varying width, as instants; trigger times are the fixed-width form.
  @cap_room_sql """
  (w.daily_cap = 0 OR (
      (SELECT COUNT(*) FROM job_runs r
       WHERE r.job_id = j.id AND r.trigger = 'cue'
         AND julianday(r.created_at) > julianday(?))
      + (SELECT COUNT(*) FROM cue_follow_up_triggers t
         WHERE t.watcher_id = w.id AND t.created_at > ?
           AND #{CuesFollowUpSql.counted_sql()}) < w.daily_cap
      AND ((SELECT COUNT(*) FROM cue_watcher_sources s WHERE s.watcher_id = w.id) < 2
        OR 2 * (SELECT COUNT(*) FROM job_runs r
                JOIN cue_deliveries x ON x.id = r.cue_delivery_id
                WHERE r.job_id = j.id AND r.trigger = 'cue'
                  AND julianday(r.created_at) > julianday(?)
                  AND x.source_ref = d.source_ref) < w.daily_cap)))
  """

  # The eligibility rule: its five `?` are now twice, then the cap window thrice.
  @eligible_sql @open_sql <> "  AND " <> @cap_room_sql

  # One row per task: the task's oldest eligible delivery, tasks in the order
  # of that delivery's id (cross-task fairness). A watcher has one task, so its
  # id is the same on every row of the group.
  @candidates_sql """
  SELECT j.id, w.id, MIN(d.id) AS first_delivery
  #{@eligible_sql}
  GROUP BY j.id
  ORDER BY first_delivery
  LIMIT ?
  """

  # Watchers whose oldest waiting delivery only the cap holds (C25): every
  # other part of the rule lets it run. One row per watcher with the cap and
  # how many of its deliveries are passed. The `?` are the cap window thrice,
  # now twice, then the row limit.
  @capped_sql """
  WITH open AS (
    SELECT d.id, d.watcher_id, w.daily_cap, #{@cap_room_sql} AS room
    #{@open_sql}
      AND w.daily_cap > 0
  )
  SELECT o.watcher_id, o.daily_cap,
         (SELECT COUNT(*) FROM cue_deliveries p
          WHERE p.watcher_id = o.watcher_id AND p.state = 'passed')
  FROM open o
  WHERE o.room = 0 AND o.id = (SELECT MIN(f.id) FROM open f WHERE f.watcher_id = o.watcher_id)
  ORDER BY o.id
  LIMIT ?
  """

  @eligible_delivery_sql """
  SELECT d.id, d.cue_id, d.watcher_id, d.source_ref, d.subject, d.received_at, d.ready_at,
         d.task_attempts
  #{@eligible_sql}
    AND j.id = ?
  ORDER BY d.id
  LIMIT 1
  """

  # What the settle needs about the delivery: its state and fence, its
  # attempts, its watcher's cap, and how many earlier runs held it (for the
  # provider backoff, which spends no attempt).
  @settle_facts_sql """
  SELECT d.state, d.claimed_run_id, d.task_attempts, d.watcher_id, d.source_ref,
         coalesce(w.daily_cap, 0),
         (SELECT COUNT(*) FROM job_runs r
          WHERE r.job_id = ? AND r.cue_delivery_id = d.id AND r.id <> ?)
  FROM cue_deliveries d
  LEFT JOIN cue_watchers w ON w.id = d.watcher_id
  WHERE d.id = ?
  """

  # --- admission (lane C1) ----------------------------------------------------

  @doc """
  Serves one request on `conn`; an unknown request is an error, never a raise.

  `{:admission_candidates, now, limit}` → `{:ok, %{candidates: [candidate],
  capped: [capped]}}`: at most `limit` tasks with an eligible delivery, one row
  each, ordered by that delivery's id; and at most 10 watchers whose oldest
  waiting delivery only the daily cap or the per-source half-cap holds (C25),
  each with its `daily_cap` and how many deliveries are `waiting`.
  """
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:admission_candidates, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    with {:ok, rows} <- CuesSql.query_all(conn, @candidates_sql, eligible_params(now) ++ [limit]),
         {:ok, capped} <- CuesSql.query_all(conn, @capped_sql, capped_params(now)) do
      {:ok, %{candidates: Enum.map(rows, &candidate/1), capped: Enum.map(capped, &capped/1)}}
    end
  end

  # --- cue run reads (lane C2) ---
  #
  # `{:cue_run_context, delivery_id}` → `{:ok, %{delivery, cue, watcher, gaps}}`
  # or `{:error, :not_found}`: what a cue run's prompt needs, with the watcher's
  # open, unreported gaps (at most `@run_gaps_max`, oldest first).
  # `{:mark_gaps_reported, gap_ids, now}` → `{:ok, n}`: stamps and closes them.
  # `{:delivery_outcomes, delivery_ids}` → `{:ok, %{id => %{state, outcome,
  # source_ref}}}`, for the job-run tools. Helpers are at the end of the module.
  @run_gaps_max 10
  @outcomes_max 100

  def handle(conn, {:cue_run_context, delivery_id}) when is_integer(delivery_id),
    do: cue_run_context(conn, delivery_id)

  def handle(conn, {:mark_gaps_reported, [_ | _] = gap_ids, %DateTime{} = now})
      when length(gap_ids) <= @run_gaps_max,
      do: mark_gaps_reported(conn, gap_ids, now)

  def handle(conn, {:delivery_outcomes, [_ | _] = delivery_ids})
      when length(delivery_ids) <= @outcomes_max,
      do: delivery_outcomes(conn, delivery_ids)

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- claim and settle parts, called by Memory.Repo inside its transaction -----

  @doc """
  The task's oldest eligible delivery by the rule above, read on the claim's
  own connection inside its `BEGIN IMMEDIATE`. `{:error, :nothing_due}` when
  there is none.
  """
  @spec eligible_delivery(conn(), String.t(), DateTime.t()) ::
          {:ok, delivery()} | {:error, :nothing_due | term()}
  def eligible_delivery(conn, job_id, %DateTime{} = now) when is_binary(job_id) do
    case CuesSql.query_all(conn, @eligible_delivery_sql, eligible_params(now) ++ [job_id]) do
      {:ok, [row]} -> {:ok, delivery(row)}
      {:ok, []} -> {:error, :nothing_due}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Moves the delivery `run` held, inside the run's settle transaction, with a
  compare-and-set on `claimed` and `claimed_run_id = run.id` (design §9.4):

  - `:ignored` / `:acted` → `acked` with that outcome;
  - any failure once the run's `tools_started_at` is set → `exhausted`,
    `failed_after_action`, never retried;
  - `{:failed, :provider}` → `passed`, attempts unchanged, ready after 30 s,
    2 min, then every 10 min (counted from the earlier runs that held it);
  - `{:failed, :other}` → `passed` with `task_attempts + 1`, ready after 30 s,
    then 2 min; the third → `exhausted`, `task_failed`;
  - `:scheduler` (a reap or a monitored crash) reads the run row: never
    started (`started_at` null) on a watcher with a daily cap → as a provider
    failure (the run counts toward the cap); otherwise as an other failure.

  A delivery that already left `claimed`, or that another run holds, is
  reported `:untouched` and logged: the run still settles, so its job is never
  wedged behind a row it no longer owns.
  """
  @spec settle_delivery(conn(), map(), settle_by(), DateTime.t()) ::
          {:ok, settlement()} | {:error, term()}
  def settle_delivery(conn, %{id: run_id, job_id: job_id} = run, settle_by, %DateTime{} = now)
      when is_binary(run_id) and is_binary(job_id) do
    delivery_id = Map.fetch!(run, :cue_delivery_id)

    case CuesSql.query_all(conn, @settle_facts_sql, [job_id, run_id, delivery_id]) do
      {:ok, [row]} -> settle_held(conn, run, settle_facts(delivery_id, row), settle_by, now)
      {:ok, []} -> {:ok, untouched(delivery_id, nil, "was not found")}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- private ------------------------------------------------------------------

  defp eligible_params(now) do
    window_start = window_start(now)
    [CuesSql.stamp(now), CuesSql.stamp(now), window_start, window_start, window_start]
  end

  defp capped_params(now) do
    window_start = window_start(now)

    [window_start, window_start, window_start, CuesSql.stamp(now), CuesSql.stamp(now)] ++
      [@capped_max]
  end

  defp window_start(now), do: CuesSql.stamp(DateTime.add(now, -@cap_window_s, :second))

  defp candidate([job_id, watcher_id, delivery_id]) do
    %{job_id: job_id, watcher_id: watcher_id, delivery_id: delivery_id}
  end

  defp capped([watcher_id, daily_cap, waiting]),
    do: %{watcher_id: watcher_id, daily_cap: daily_cap, waiting: waiting}

  defp delivery([id, cue_id, watcher_id, source_ref, subject, received_at, ready_at, attempts]) do
    %{
      id: id,
      cue_id: cue_id,
      watcher_id: watcher_id,
      source_ref: source_ref,
      subject: subject,
      received_at: CuesSql.parse_stamp(received_at),
      ready_at: CuesSql.parse_stamp(ready_at),
      task_attempts: attempts,
      state: "passed"
    }
  end

  defp settle_facts(delivery_id, [state, holder, attempts, watcher_id, source, cap, prior_runs]) do
    %{
      delivery_id: delivery_id,
      state: state,
      holder: holder,
      task_attempts: attempts,
      watcher_id: watcher_id,
      source_ref: source,
      daily_cap: cap,
      prior_runs: prior_runs
    }
  end

  defp settle_held(conn, %{id: run_id} = run, %{state: "claimed", holder: run_id} = facts, by, at) do
    move = settle_move(by, run, facts, at)
    {to, patch} = move_patch(move, at)
    fence = {:claimed_run_id, run_id}

    case CuesSql.transition(conn, facts.delivery_id, "claimed", fence, to, patch) do
      :ok -> {:ok, settlement(facts, move, to)}
      {:error, :stale} -> {:ok, untouched(facts.delivery_id, facts, "moved during the settle")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_held(_conn, _run, facts, _settle_by, _now) do
    {:ok, untouched(facts.delivery_id, facts, "was #{facts.state}, not held by this run")}
  end

  # The settle mapping (design §9.4). Success first: an outcome the runner
  # computed is final. Then the marker: once an allowed mandate call or a
  # proposal happened, nothing is retried.
  defp settle_move(:ignored, _run, _facts, _now), do: {:acked, "ignored"}
  defp settle_move(:acted, _run, _facts, _now), do: {:acked, "acted"}

  defp settle_move(_failure, %{tools_started_at: %DateTime{}}, facts, _now),
    do: {:exhausted, "failed_after_action", facts.task_attempts}

  defp settle_move({:failed, :provider}, _run, facts, now), do: unspent_retry(facts, now)
  defp settle_move({:failed, :other}, _run, facts, now), do: spent_retry(facts, now)

  defp settle_move(:scheduler, %{started_at: nil}, %{daily_cap: cap} = facts, now) when cap > 0,
    do: unspent_retry(facts, now)

  defp settle_move(:scheduler, _run, facts, now), do: spent_retry(facts, now)

  defp unspent_retry(facts, now) do
    unspent = max(facts.prior_runs - facts.task_attempts, 0)
    delay = Enum.at(@provider_backoff_s, unspent, @provider_backoff_cap_s)
    {:retry, facts.task_attempts, DateTime.add(now, delay, :second)}
  end

  defp spent_retry(facts, now) do
    attempts = facts.task_attempts + 1

    if attempts >= @max_task_attempts do
      {:exhausted, "task_failed", @max_task_attempts}
    else
      delay = Enum.at(@other_backoff_s, attempts - 1)
      {:retry, attempts, DateTime.add(now, delay, :second)}
    end
  end

  defp move_patch({:acked, outcome}, now), do: {"acked", %{outcome: outcome, settled_at: now}}

  defp move_patch({:retry, attempts, ready_at}, _now),
    do: {"passed", %{task_attempts: attempts, ready_at: ready_at, claimed_run_id: nil}}

  defp move_patch({:exhausted, outcome, attempts}, now),
    do: {"exhausted", %{outcome: outcome, task_attempts: attempts, settled_at: now}}

  defp settlement(facts, move, to) do
    base = %{
      delivery_id: facts.delivery_id,
      watcher_id: facts.watcher_id,
      source_ref: facts.source_ref,
      state: to,
      ready_at: nil
    }

    Map.merge(base, move_fields(move, facts))
  end

  defp move_fields({:acked, outcome}, facts),
    do: %{disposition: :acked, outcome: outcome, task_attempts: facts.task_attempts}

  defp move_fields({:retry, attempts, ready_at}, _facts),
    do: %{disposition: :retry, outcome: nil, task_attempts: attempts, ready_at: ready_at}

  defp move_fields({:exhausted, outcome, attempts}, _facts),
    do: %{disposition: :exhausted, outcome: outcome, task_attempts: attempts, ready_at: nil}

  defp untouched(delivery_id, facts, why) do
    Logger.warning(
      "Cue delivery #{delivery_id} #{why}; its run settled and left the delivery as it was."
    )

    %{
      delivery_id: delivery_id,
      watcher_id: facts && facts.watcher_id,
      source_ref: facts && facts.source_ref,
      disposition: :untouched,
      state: facts && facts.state,
      outcome: nil,
      task_attempts: facts && facts.task_attempts,
      ready_at: nil
    }
  end

  # --- cue run read helpers (lane C2) ---------------------------------------------

  @run_context_sql """
  SELECT d.id, d.cue_id, d.watcher_id, d.source_ref, d.received_at, d.state, d.decision_reason,
         d.hint, d.task_attempts, d.claimed_run_id,
         c.item_id, c.revision, c.type, c.subject, c.occurred_at, c.received_at, c.payload,
         c.snapshot,
         w.name, w.task_notes
  FROM cue_deliveries d
  JOIN cues c ON c.id = d.cue_id
  JOIN cue_watchers w ON w.id = d.watcher_id
  WHERE d.id = ?
  """

  @run_gaps_sql """
  SELECT id, source_ref, reason, count, range_from, range_to, first_at, last_at
  FROM cue_gaps
  WHERE watcher_id = ? AND reported_at IS NULL AND closed_at IS NULL
  ORDER BY first_at, id
  LIMIT ?
  """

  defp cue_run_context(conn, delivery_id) do
    case CuesSql.query_all(conn, @run_context_sql, [delivery_id]) do
      {:ok, [row]} -> with_gaps(conn, run_context_row(row))
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_gaps(_conn, {:error, reason}), do: {:error, reason}

  defp with_gaps(conn, {:ok, context}) do
    with {:ok, rows} <-
           CuesSql.query_all(conn, @run_gaps_sql, [context.watcher.id, @run_gaps_max]) do
      {:ok, Map.put(context, :gaps, Enum.map(rows, &run_gap_row/1))}
    end
  end

  defp run_context_row([
         id,
         cue_id,
         watcher_id,
         source_ref,
         received_at,
         state,
         reason,
         hint,
         attempts,
         holder,
         item_id,
         revision,
         type,
         subject,
         occurred_at,
         cue_received_at,
         payload,
         snapshot,
         watcher_name,
         task_notes
       ]) do
    with {:ok, summary} <- CuesDeliveriesSql.snapshot_text(snapshot, id) do
      {:ok,
       %{
         delivery: %{
           id: id,
           source_ref: source_ref,
           received_at: CuesSql.parse_stamp(received_at),
           state: state,
           decision_reason: reason,
           hint: hint,
           task_attempts: attempts,
           claimed_run_id: holder
         },
         cue: %{
           id: cue_id,
           item_id: item_id,
           revision: revision,
           type: type,
           subject: subject,
           occurred_at: CuesSql.parse_stamp(occurred_at),
           received_at: CuesSql.parse_stamp(cue_received_at),
           payload: payload,
           summary: summary
         },
         watcher: %{id: watcher_id, name: watcher_name, task_notes?: task_notes == 1}
       }}
    end
  end

  defp run_gap_row([id, ref, reason, count, from, to, first_at, last_at]) do
    %{
      id: id,
      source_ref: ref,
      reason: reason,
      count: count,
      range_from: from,
      range_to: to,
      first_at: CuesSql.parse_stamp(first_at),
      last_at: CuesSql.parse_stamp(last_at)
    }
  end

  defp mark_gaps_reported(conn, gap_ids, now) do
    at = CuesSql.stamp(now)
    marks = Enum.map_join(gap_ids, ", ", fn _id -> "?" end)

    with :ok <-
           CuesSql.execute(
             conn,
             "UPDATE cue_gaps SET reported_at = ?, closed_at = coalesce(closed_at, ?) " <>
               "WHERE reported_at IS NULL AND id IN (#{marks})",
             [at, at | gap_ids]
           ) do
      CuesSql.changes(conn)
    end
  end

  defp delivery_outcomes(conn, delivery_ids) do
    marks = Enum.map_join(delivery_ids, ", ", fn _id -> "?" end)

    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT id, state, outcome, source_ref FROM cue_deliveries WHERE id IN (#{marks})",
             delivery_ids
           ) do
      {:ok,
       Map.new(rows, fn [id, state, outcome, ref] ->
         {id, %{state: state, outcome: outcome, source_ref: ref}}
       end)}
    end
  end
end
