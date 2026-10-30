defmodule FermixCore.Memory.Repo.CuesFilterSql do
  @moduledoc """
  SQL for the filter dispatcher's claims, settles and boot reset (PLAN §4.2,
  design §7.3 and §8.3).

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`. One `handle/2` head per request tuple,
  above the catch-all, which stays last. Every delivery move goes through the
  fenced `CuesSql.transition/6` and every write request runs in one
  `CuesSql.with_immediate_transaction/2`.

  ## Requests

  - `{:claim, now, free_slots, exclude}`: up to `free_slots` claims, one per
    eligible watcher (enabled, `filter = 'llm'`, no delivery in `filtering`,
    `filter_retry_at` null or past, under its filter budget: fewer calls started
    in the last 24 hours than `filter_budget` when that is above 0, and not in
    `exclude`, the watchers whose call the dispatcher still holds). Watchers go
    in the order of their oldest due `pending` delivery (`ready_at <= now`,
    `valid_until > now`: one past its lifetime is retention's, design §7.4);
    each claim moves that delivery `pending → filtering` with a new
    `filter_call_id` and inserts its `cue_filter_calls` row. Returns
    `%{claims: [claim], over_budget: [..], next_at: DateTime | nil}`, where
    `next_at` is the earliest later time a backoff or a cue retry falls due.
  - `{:settle, call_id, result, now}`: writes one call's result, fenced on
    `state = 'filtering' AND filter_call_id = call_id`. A stale fence is
    `{:error, :stale}`: the result is refused and the delivery left as it is,
    but a call still open is closed `aborted` (error `stale: …`) in the same
    commit, so no row stays open for retention to skip. A pass whose watcher
    was paused while the call ran is withheld: the delivery goes back to
    `pending`, attempts unchanged, and the call is recorded as its pass. See
    `settle_outcome/0`.
  - `{:reset, now}`: the boot sweep. Every `filtering` delivery back to
    `pending` with its attempts unchanged and its fence cleared; every open
    call `aborted`.
  - `{:reclaim_orphans, in_flight, cutoff, now}`: the dispatcher's periodic
    recovery of calls no task holds (a claim that landed after its Repo call
    timed out, a settle that rolled back). Every `filtering` delivery whose
    `filter_call_id` is not in `in_flight` (the call ids the dispatcher still
    holds) and whose call started before `cutoff` (or whose call row is gone)
    goes back to `pending`, fenced on that `filter_call_id`, attempts
    unchanged; its call is finished `aborted`. Returns
    `%{reclaimed: [delivery_id], aborted: n}`.
  - `{:held_watchers}`: `llm` watchers held by provider failures, with the
    count of deliveries waiting.

  ## Live calls (M60_CUE_INTAKE_AT_SCALE.md §3.2)

  A stream item is judged before it is stored (`Cues.LiveFilters`), so its
  call has no delivery. Its ledger row is written once, when the call ends,
  with `delivery_id` null, so the filter budget, the hold and the cost record
  count it as they count a stored call.

  - `{:live_context, watcher_ids, now}`: what a live call needs beyond the
    watcher's row, per watcher: its active `instructions`, its 20 most recent
    `examples`, and `used`, the calls started in the last 24 hours (stored and
    live) that its `filter_budget` counts.
  - `{:settle_live, watcher_id, call, result, now}`: a live drop or failure,
    written by `record_live/5`. A pass is written with its cue and delivery by
    `CuesSql`'s `{:pass_live, …}`, which calls `record_live/5` in its own
    transaction.

  ## Backoffs (design §8.3)

  A provider failure is the watcher's: the delivery goes back to `pending`
  unchanged and the watcher's next call waits 30 s, then 2 min, then 10 min;
  from the third failure in a row it is held. A content failure is the cue's:
  it spends an attempt and is retried after 30 s, then 2 min; the third ends
  it `exhausted` with outcome `filter_failed`. A pass or a drop clears the
  watcher's failures. An `aborted` call (its task shut down with its
  supervisor) puts the delivery back unchanged, like the boot sweep.
  """

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Filter.Telemetry, as: FilterTelemetry
  alias FermixCore.Memory.Repo.CuesSql

  @provider_backoff_s %{1 => 30, 2 => 120}
  @held_backoff_s 600
  @held_after 3
  @content_retry_s %{1 => 30, 2 => 120}
  @max_filter_attempts 3
  @budget_window_s 86_400
  @max_examples 20
  @max_claims 16
  @max_error_chars 500
  @failure_results [:provider_failure, :content_failure, :aborted]
  @live_failures [:provider_failure, :content_failure]
  @orphan_error "aborted: no task held this call past its deadline"
  # The most watchers one source's live context is read for at once.
  @max_live_watchers 200

  @within_budget """
  (w.filter_budget = 0 OR (SELECT count(*) FROM cue_filter_calls c
     WHERE c.watcher_id = w.id AND c.started_at > ?) < w.filter_budget)
  """

  @type conn :: term()
  @type failure :: %{kind: atom(), message: String.t()}
  @type result ::
          {:pass, String.t(), String.t() | nil}
          | {:drop, String.t()}
          | {:provider_failure, failure()}
          | {:content_failure, failure()}
          | {:aborted, failure()}
  @type live_result ::
          {:pass, String.t(), String.t() | nil}
          | {:drop, String.t()}
          | {:provider_failure, failure()}
          | {:content_failure, failure()}

  @doc """
  The keys of a settle's `{:ok, outcome}`: `result` (`:passed | :withheld |
  :dropped | :retry | :held | :exhausted | :aborted`), `passed?`, `exhausted?`,
  `held_now?` (this failure made the watcher held), `held?`, `recovered?` (a
  held watcher's call succeeded), `watcher_id`, `watcher_name`, `task_job_id`,
  `delivery_id`, `cue_id`, `source_ref`, `attempt` (the delivery's filter
  attempts after this settle), `filter_failures` (the watcher's, after),
  `retry_at` (the watcher's or the delivery's next try, when one is set) and
  `waiting` (the watcher's `pending` deliveries).
  """
  @spec settle_outcome() :: [atom()]
  def settle_outcome do
    [:result, :passed?, :exhausted?, :held_now?, :held?, :recovered?, :watcher_id] ++
      [:watcher_name, :task_job_id, :delivery_id, :cue_id, :source_ref, :attempt] ++
      [:filter_failures, :retry_at, :waiting]
  end

  @doc "Serves one request on `conn`; an unknown request is an error, never a raise."
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:claim, %DateTime{} = now, free, exclude})
      when is_integer(free) and free > 0 and free <= @max_claims and is_list(exclude) do
    if Enum.all?(exclude, &is_binary/1) do
      CuesSql.with_immediate_transaction(conn, fn -> claim_in_tx(conn, now, free, exclude) end)
    else
      {:error, {:invalid, :exclude}}
    end
  end

  def handle(conn, {:settle, call_id, result, %DateTime{} = now}) when is_binary(call_id) do
    if valid_result?(result) do
      conn
      |> CuesSql.with_immediate_transaction(fn -> settle_in_tx(conn, call_id, result, now) end)
      |> stale_after_commit()
    else
      {:error, {:invalid, :result}}
    end
  end

  def handle(conn, {:reset, %DateTime{} = now}) do
    CuesSql.with_immediate_transaction(conn, fn -> reset_in_tx(conn, now) end)
  end

  def handle(conn, {:reclaim_orphans, in_flight, %DateTime{} = cutoff, %DateTime{} = now})
      when is_list(in_flight) and length(in_flight) <= @max_claims do
    if Enum.all?(in_flight, &is_binary/1) do
      CuesSql.with_immediate_transaction(conn, fn ->
        reclaim_in_tx(conn, in_flight, cutoff, now)
      end)
    else
      {:error, {:invalid, :in_flight}}
    end
  end

  def handle(conn, {:held_watchers}), do: held_watchers(conn)

  def handle(conn, {:live_context, watcher_ids, %DateTime{} = now})
      when is_list(watcher_ids) and length(watcher_ids) <= @max_live_watchers do
    if Enum.all?(watcher_ids, &is_binary/1),
      do: live_context(conn, watcher_ids, now),
      else: {:error, {:invalid, :watcher_ids}}
  end

  def handle(conn, {:settle_live, watcher_id, call, result, %DateTime{} = now})
      when is_binary(watcher_id) and is_map(call) do
    if live_result?(result) and live_call?(call) do
      CuesSql.with_immediate_transaction(conn, fn ->
        record_live(conn, watcher_id, call, result, now)
      end)
    else
      {:error, {:invalid, :live_result}}
    end
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  defp valid_result?({:pass, reason, hint}) when is_binary(reason) and reason != "",
    do: is_binary(hint) or is_nil(hint)

  defp valid_result?({:drop, reason}) when is_binary(reason) and reason != "", do: true

  defp valid_result?({kind, %{kind: failure_kind, message: message}})
       when kind in @failure_results and is_atom(failure_kind) and is_binary(message),
       do: true

  defp valid_result?(_result), do: false

  # A pass is not settled here: it is written with its cue (`{:pass_live, …}`).
  defp live_result?({kind, _detail} = result) when kind in [:drop | @live_failures],
    do: valid_result?(result)

  defp live_result?(_result), do: false

  @doc "Whether `call` is a live call as `record_live/5` writes it."
  @spec live_call?(term()) :: boolean()
  def live_call?(%{id: id, session_id: session, started_at: %DateTime{}} = call)
      when is_binary(id) and is_binary(session),
      do:
        Enum.all?(
          [:provider, :model],
          &(is_binary(Map.get(call, &1)) or is_nil(Map.get(call, &1)))
        )

  def live_call?(_call), do: false

  # --- claim ------------------------------------------------------------------------

  defp claim_in_tx(conn, now, free, exclude) do
    # Over budget is read before the claims, so a watcher is reported only when
    # its budget, not this pass's own claim, holds its deliveries back.
    with {:ok, over} <- over_budget(conn, now),
         {:ok, picks} <- eligible(conn, now, free, exclude),
         {:ok, claims} <- claim_all(conn, picks, now),
         {:ok, next_at} <- next_due(conn, now) do
      {:ok, %{claims: claims, over_budget: over, next_at: next_at}}
    end
  end

  defp eligible(conn, now, free, exclude) do
    stamp = CuesSql.stamp(now)
    {exclude_sql, exclude_params} = exclude_clause(exclude)

    sql = """
    SELECT w.id, MIN(d.id) FROM cue_watchers w
    JOIN cue_deliveries d ON d.watcher_id = w.id AND d.state = 'pending' AND d.ready_at <= ?
      AND d.valid_until > ?
    WHERE w.enabled = 1 AND w.filter = 'llm'
      AND (w.filter_retry_at IS NULL OR w.filter_retry_at <= ?)
      AND NOT EXISTS (SELECT 1 FROM cue_deliveries f
                      WHERE f.watcher_id = w.id AND f.state = 'filtering')
      AND #{@within_budget}
      #{exclude_sql}
    GROUP BY w.id
    ORDER BY MIN(d.id)
    LIMIT ?
    """

    params = [stamp, stamp, stamp, budget_window(now)] ++ exclude_params ++ [free]

    with {:ok, rows} <- CuesSql.query_all(conn, sql, params) do
      {:ok, Enum.map(rows, fn [watcher_id, delivery_id] -> {watcher_id, delivery_id} end)}
    end
  end

  defp exclude_clause([]), do: {"", []}

  defp exclude_clause(ids),
    do: {"AND w.id NOT IN (#{Enum.map_join(ids, ", ", fn _id -> "?" end)})", ids}

  defp budget_window(now), do: now |> DateTime.add(-@budget_window_s, :second) |> CuesSql.stamp()

  defp claim_all(conn, picks, now) do
    Enum.reduce_while(picks, {:ok, []}, fn pick, {:ok, acc} ->
      case claim_one(conn, pick, now) do
        {:ok, claim} -> {:cont, {:ok, acc ++ [claim]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp claim_one(conn, {watcher_id, delivery_id}, now) do
    call_id = Cues.id("cfc")
    session_id = FilterTelemetry.session_id(watcher_id, now)
    patch = %{filter_call_id: call_id}

    with {:ok, watcher} <- fetch_watcher(conn, watcher_id),
         {:ok, delivery, cue} <- fetch_delivery(conn, delivery_id),
         {:ok, instructions} <- instructions(conn, watcher_id),
         {:ok, examples} <- examples(conn, watcher_id),
         :ok <- CuesSql.transition(conn, delivery_id, "pending", :none, "filtering", patch),
         :ok <- insert_call(conn, call_id, watcher, delivery_id, session_id, now) do
      {:ok,
       %{
         call_id: call_id,
         session_id: session_id,
         started_at: now,
         delivery: delivery,
         cue: cue,
         watcher: watcher,
         instructions: instructions,
         examples: examples
       }}
    end
  end

  defp fetch_watcher(conn, watcher_id) do
    sql = """
    SELECT id, name, purpose, listen_for, task_job_id, filter_failures, filter_budget
    FROM cue_watchers WHERE id = ?
    """

    case CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, [[id, name, purpose, words, job_id, failures, budget]]} ->
        with {:ok, listen_for} <- words(words) do
          {:ok,
           %{
             id: id,
             name: name,
             purpose: purpose,
             listen_for: listen_for,
             task_job_id: job_id,
             filter_failures: failures,
             filter_budget: budget
           }}
        end

      {:ok, []} ->
        {:error, {:not_found, :watcher}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A watcher's words, which a decision model's screen reads as hints.
  defp words(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, {:corrupt, "cue_watchers", {:json_list, :listen_for}}}

      _not_a_list ->
        {:error, {:corrupt, "cue_watchers", {:json_list, :listen_for}}}
    end
  end

  defp fetch_delivery(conn, delivery_id) do
    sql = """
    SELECT d.id, d.cue_id, d.source_ref, d.subject, d.received_at, d.filter_attempts,
      c.item_id, c.revision, c.type, c.subject, c.occurred_at, c.received_at, c.payload, c.snapshot
    FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id WHERE d.id = ?
    """

    case CuesSql.query_all(conn, sql, [delivery_id]) do
      {:ok, [row]} -> delivery_and_cue(row)
      {:ok, []} -> {:error, {:not_found, :delivery}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_and_cue([id, cue_id, ref, subject, received, attempts | cue_columns]) do
    [item_id, revision, type, cue_subject, occurred, cue_received, payload, snapshot] =
      cue_columns

    delivery = %{
      id: id,
      cue_id: cue_id,
      source_ref: ref,
      subject: subject,
      received_at: CuesSql.parse_stamp(received),
      filter_attempts: attempts
    }

    cue = %{
      id: cue_id,
      source_ref: ref,
      item_id: item_id,
      revision: revision,
      type: type,
      subject: cue_subject,
      occurred_at: CuesSql.parse_stamp(occurred),
      received_at: CuesSql.parse_stamp(cue_received),
      payload: payload,
      snapshot: snapshot
    }

    {:ok, delivery, cue}
  end

  defp instructions(conn, watcher_id) do
    sql =
      "SELECT number, text FROM cue_watcher_instructions " <>
        "WHERE watcher_id = ? AND removed_at IS NULL ORDER BY number"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, Enum.map(rows, fn [number, text] -> %{number: number, text: text} end)}
    end
  end

  # The most recent examples, presented oldest first.
  defp examples(conn, watcher_id) do
    sql =
      "SELECT label, note, snapshot FROM cue_watcher_examples WHERE watcher_id = ? " <>
        "ORDER BY created_at DESC, rowid DESC LIMIT ?"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [watcher_id, @max_examples]) do
      {:ok,
       rows
       |> Enum.reverse()
       |> Enum.map(fn [label, note, snapshot] ->
         %{label: label, note: note, snapshot: snapshot}
       end)}
    end
  end

  # The call's provider and model stay null here: every call uses the one Cues
  # filter model, which the task resolves when it runs.
  defp insert_call(conn, call_id, watcher, delivery_id, session_id, now) do
    CuesSql.execute(
      conn,
      """
      INSERT INTO cue_filter_calls (id, watcher_id, delivery_id, session_id, started_at)
      VALUES (?, ?, ?, ?, ?)
      """,
      [call_id, watcher.id, delivery_id, session_id, CuesSql.stamp(now)]
    )
  end

  defp over_budget(conn, now) do
    sql = """
    SELECT w.id, w.name, w.filter_budget,
      (SELECT count(*) FROM cue_deliveries d WHERE d.watcher_id = w.id AND d.state = 'pending')
    FROM cue_watchers w
    WHERE w.enabled = 1 AND w.filter = 'llm' AND w.filter_budget > 0
      AND (SELECT count(*) FROM cue_filter_calls c
           WHERE c.watcher_id = w.id AND c.started_at > ?) >= w.filter_budget
      AND EXISTS (SELECT 1 FROM cue_deliveries d
                  WHERE d.watcher_id = w.id AND d.state = 'pending' AND d.ready_at <= ?)
      AND NOT EXISTS (SELECT 1 FROM cue_deliveries f
                      WHERE f.watcher_id = w.id AND f.state = 'filtering')
    ORDER BY w.id
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [budget_window(now), CuesSql.stamp(now)]) do
      {:ok,
       Enum.map(rows, fn [id, name, budget, waiting] ->
         %{watcher_id: id, watcher_name: name, budget: budget, waiting: waiting}
       end)}
    end
  end

  defp next_due(conn, now) do
    stamp = CuesSql.stamp(now)

    sql = """
    SELECT MIN(t) FROM (
      SELECT w.filter_retry_at AS t FROM cue_watchers w
      WHERE w.enabled = 1 AND w.filter = 'llm' AND w.filter_retry_at > ?
        AND EXISTS (SELECT 1 FROM cue_deliveries d WHERE d.watcher_id = w.id AND d.state = 'pending')
      UNION ALL
      SELECT d.ready_at AS t FROM cue_deliveries d JOIN cue_watchers w ON w.id = d.watcher_id
      WHERE d.state = 'pending' AND d.ready_at > ? AND w.enabled = 1 AND w.filter = 'llm'
    )
    """

    case CuesSql.query_all(conn, sql, [stamp, stamp]) do
      {:ok, [[next]]} -> {:ok, CuesSql.parse_stamp(next)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- settle -------------------------------------------------------------------------

  defp settle_in_tx(conn, call_id, result, now) do
    with {:ok, call} <- open_call(conn, call_id) do
      case settle_open_call(conn, call, call_id, result, now) do
        {:error, :stale} -> abort_stale_call(conn, call_id, now)
        settled -> settled
      end
    end
  end

  defp settle_open_call(conn, call, call_id, result, now) do
    with {:ok, target} <- settle_context(conn, call),
         {:ok, outcome} <- apply_result(conn, call_id, target, result, now),
         :ok <- finish_call(conn, call_id, result, now),
         {:ok, waiting} <- waiting(conn, call.watcher_id) do
      {:ok, Map.put(outcome, :waiting, waiting)}
    end
  end

  # The delivery left this call's fence (a settle that came twice, or late):
  # the result is refused, and the open call is closed `aborted` in the commit
  # that refuses it. `stale_after_commit/1` turns the commit into the refusal.
  defp abort_stale_call(conn, call_id, now) do
    failure =
      {:aborted,
       %{kind: :stale, message: "The delivery had left this call when its result came."}}

    with :ok <- finish_call(conn, call_id, failure, now), do: {:ok, :stale}
  end

  defp stale_after_commit({:ok, :stale}), do: {:error, :stale}
  defp stale_after_commit(settled), do: settled

  defp open_call(conn, call_id) do
    sql =
      "SELECT watcher_id, delivery_id FROM cue_filter_calls WHERE id = ? AND finished_at IS NULL"

    case CuesSql.query_all(conn, sql, [call_id]) do
      {:ok, [[watcher_id, delivery_id]]} ->
        {:ok, %{watcher_id: watcher_id, delivery_id: delivery_id}}

      {:ok, []} ->
        Logger.warning(
          "Cue filter call #{call_id} is unknown or already finished; settle refused."
        )

        {:error, :stale}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The watcher may be gone (a removed watcher's deliveries outlive it): its
  # fields default and the watcher updates below change no row. Whether it is
  # enabled is read here, in the settle's transaction on the single writer, so
  # no pause lands between this read and the move.
  defp settle_context(conn, %{watcher_id: watcher_id, delivery_id: delivery_id}) do
    sql = """
    SELECT d.filter_attempts, d.cue_id, d.source_ref, w.name, w.task_job_id, w.filter_failures,
      coalesce(w.enabled, 0)
    FROM cue_deliveries d LEFT JOIN cue_watchers w ON w.id = d.watcher_id WHERE d.id = ?
    """

    case CuesSql.query_all(conn, sql, [delivery_id]) do
      {:ok, [[attempts, cue_id, ref, name, job_id, failures, enabled]]} ->
        {:ok,
         %{
           watcher_id: watcher_id,
           delivery_id: delivery_id,
           cue_id: cue_id,
           source_ref: ref,
           attempts: attempts,
           watcher_name: name,
           task_job_id: job_id,
           failures: failures || 0,
           enabled?: enabled == 1
         }}

      {:ok, []} ->
        {:error, :stale}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A watcher paused while its call ran filters nothing (design §8.8): its pass
  # is withheld and the delivery waits `pending` with the ones the pause found
  # waiting, its attempts unchanged, to be judged again on resume. The call
  # stays recorded as the pass it was, for the budget and its cost. A source
  # taken off the watcher needs no check here: the change expires the row
  # under the call, so its settle is refused as stale (`CuesWatchersSql`).
  defp apply_result(conn, call_id, target, {:pass, reason, hint}, now) do
    if target.enabled?,
      do: pass_delivery(conn, call_id, target, {reason, hint}, now),
      else: withhold(conn, call_id, target)
  end

  defp apply_result(conn, call_id, target, {:drop, reason}, now) do
    patch = %{decision_reason: reason, settled_at: now}

    with :ok <- move(conn, target, call_id, "dropped", patch) do
      watcher_succeeded(conn, target, :dropped, %{})
    end
  end

  defp apply_result(conn, call_id, target, {:provider_failure, _failure}, now) do
    with :ok <- move(conn, target, call_id, "pending", %{filter_call_id: nil}) do
      watcher_failed(conn, target, now)
    end
  end

  defp apply_result(conn, call_id, target, {:content_failure, _failure}, now) do
    attempts = target.attempts + 1

    if attempts >= @max_filter_attempts do
      patch = %{filter_attempts: attempts, outcome: "filter_failed", settled_at: now}

      with :ok <- move(conn, target, call_id, "exhausted", patch) do
        {:ok, outcome(target, :exhausted, %{exhausted?: true, attempt: attempts})}
      end
    else
      retry_at = DateTime.add(now, Map.fetch!(@content_retry_s, attempts), :second)
      patch = %{filter_attempts: attempts, ready_at: retry_at, filter_call_id: nil}

      with :ok <- move(conn, target, call_id, "pending", patch) do
        {:ok, outcome(target, :retry, %{attempt: attempts, retry_at: retry_at})}
      end
    end
  end

  defp apply_result(conn, call_id, target, {:aborted, _failure}, _now) do
    with :ok <- move(conn, target, call_id, "pending", %{filter_call_id: nil}) do
      {:ok, outcome(target, :aborted, %{})}
    end
  end

  defp pass_delivery(conn, call_id, target, {reason, hint}, now) do
    patch = %{decision_reason: reason, hint: hint, ready_at: now}

    with :ok <- move(conn, target, call_id, "passed", patch) do
      watcher_succeeded(conn, target, :passed, %{passed?: true})
    end
  end

  # The model answered, so the watcher's failures clear as for any pass.
  defp withhold(conn, call_id, target) do
    with :ok <- move(conn, target, call_id, "pending", %{filter_call_id: nil}) do
      watcher_succeeded(conn, target, :withheld, %{})
    end
  end

  defp move(conn, target, call_id, to, patch) do
    CuesSql.transition(
      conn,
      target.delivery_id,
      "filtering",
      {:filter_call_id, call_id},
      to,
      patch
    )
  end

  # The watcher's side of a decision, the same for a stored call and a live
  # one: a pass or a drop clears its failures; a provider failure is its next
  # failure in a row, backed off, and from the third it is held.
  defp watcher_succeeded(conn, target, result, extra) do
    with :ok <- clear_failures(conn, target.watcher_id),
         do: {:ok, succeeded(target, result, extra)}
  end

  defp watcher_failed(conn, target, now) do
    failures = target.failures + 1
    retry_at = DateTime.add(now, Map.get(@provider_backoff_s, failures, @held_backoff_s), :second)

    with :ok <- add_failure(conn, target.watcher_id, retry_at) do
      held? = failures >= @held_after

      {:ok,
       outcome(target, if(held?, do: :held, else: :retry), %{
         held?: held?,
         held_now?: failures == @held_after,
         filter_failures: failures,
         retry_at: retry_at
       })}
    end
  end

  defp succeeded(target, result, extra) do
    outcome(
      target,
      result,
      Map.merge(
        %{recovered?: target.failures >= @held_after, filter_failures: 0, held?: false},
        extra
      )
    )
  end

  defp outcome(target, result, extra) do
    Map.merge(
      %{
        result: result,
        passed?: false,
        exhausted?: false,
        held_now?: false,
        held?: target.failures >= @held_after,
        recovered?: false,
        watcher_id: target.watcher_id,
        watcher_name: target.watcher_name,
        task_job_id: target.task_job_id,
        delivery_id: target.delivery_id,
        cue_id: target.cue_id,
        source_ref: target.source_ref,
        attempt: target.attempts,
        filter_failures: target.failures,
        retry_at: nil
      },
      extra
    )
  end

  defp clear_failures(conn, watcher_id) do
    CuesSql.execute(
      conn,
      "UPDATE cue_watchers SET filter_failures = 0, filter_retry_at = NULL WHERE id = ?",
      [watcher_id]
    )
  end

  defp add_failure(conn, watcher_id, retry_at) do
    CuesSql.execute(
      conn,
      "UPDATE cue_watchers SET filter_failures = filter_failures + 1, filter_retry_at = ? " <>
        "WHERE id = ?",
      [CuesSql.stamp(retry_at), watcher_id]
    )
  end

  defp finish_call(conn, call_id, result, now) do
    CuesSql.execute(
      conn,
      "UPDATE cue_filter_calls SET finished_at = ?, result = ?, error = ? " <>
        "WHERE id = ? AND finished_at IS NULL",
      [CuesSql.stamp(now), result_text(result), error_text(result), call_id]
    )
  end

  defp result_text({:pass, _reason, _hint}), do: "pass"
  defp result_text({:drop, _reason}), do: "drop"
  defp result_text({kind, _failure}), do: Atom.to_string(kind)

  defp error_text({kind, %{kind: failure_kind, message: message}})
       when kind in @failure_results,
       do: String.slice("#{failure_kind}: #{message}", 0, @max_error_chars)

  defp error_text(_decision), do: nil

  defp waiting(conn, watcher_id) do
    sql = "SELECT count(*) FROM cue_deliveries WHERE watcher_id = ? AND state = 'pending'"

    case CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, [[count]]} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- live calls (M60_CUE_INTAKE_AT_SCALE.md §3.2) --------------------------------------

  @doc """
  Writes one live call's end inside the caller's transaction: its ledger row
  (`delivery_id` null), then the watcher's side as the stored settle does (a
  pass or a drop clears its failures, a provider failure backs it off and
  holds it from the third). A content failure is the item's: nothing is
  written on the watcher. Both are written once: when the call's row is
  already there (a write sent again after a timeout that still ran), nothing
  is written and the answer reads the watcher as that first write left it.
  Returns the settle's outcome keys (`settle_outcome/0`) without `waiting`,
  with `result` `:passed`, `:dropped`, `:retry`, `:held` or `:failed`. A
  watcher removed since is no error: its fields default and no watcher row
  changes.
  """
  @spec record_live(conn(), String.t(), map(), live_result(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def record_live(conn, watcher_id, call, result, %DateTime{} = now)
      when is_binary(watcher_id) and is_map(call) do
    with {:ok, target, first?} <- write_live_call(conn, watcher_id, call, result, now) do
      if first?,
        do: live_outcome(conn, target, result, now),
        else: {:ok, recorded_outcome(target, result)}
    end
  end

  @doc """
  Writes a live pass the store withheld (its watcher paused, or no longer
  listening to the source, when the pass was written) inside the caller's
  transaction: the ledger row as `record_live/5` writes a pass, the watcher's
  failures cleared on the first write since the model answered, and the
  outcome `:withheld`, with nothing passed.
  """
  @spec record_withheld(conn(), String.t(), map(), live_result(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def record_withheld(conn, watcher_id, call, {:pass, _reason, _hint} = result, %DateTime{} = now)
      when is_binary(watcher_id) and is_map(call) do
    with {:ok, target, first?} <- write_live_call(conn, watcher_id, call, result, now) do
      if first?,
        do: watcher_succeeded(conn, target, :withheld, %{}),
        else: {:ok, outcome(target, :withheld, %{})}
    end
  end

  # The call's ledger row, written once: `first?` is false when a write sent
  # again after a timeout finds the first one's row.
  defp write_live_call(conn, watcher_id, call, result, now) do
    with {:ok, target} <- live_target(conn, watcher_id, call),
         :ok <- insert_live_call(conn, watcher_id, call, result, now),
         {:ok, inserted} <- CuesSql.changes(conn),
         do: {:ok, target, inserted == 1}
  end

  defp live_outcome(conn, target, {:pass, _reason, _hint}, _now),
    do: watcher_succeeded(conn, target, :passed, %{passed?: true})

  defp live_outcome(conn, target, {:drop, _reason}, _now),
    do: watcher_succeeded(conn, target, :dropped, %{})

  defp live_outcome(conn, target, {:provider_failure, _failure}, now),
    do: watcher_failed(conn, target, now)

  defp live_outcome(_conn, target, {:content_failure, _failure}, _now),
    do: {:ok, outcome(target, :failed, %{})}

  # The call's row was there already, so its first write wrote the watcher's
  # side too. A watcher at its third failure still reads `held_now?`, so the
  # hold's notice (sent once per hold) is not lost with the first answer.
  defp recorded_outcome(target, {:provider_failure, _failure}) do
    held? = target.failures >= @held_after

    outcome(target, if(held?, do: :held, else: :retry), %{
      held_now?: target.failures == @held_after,
      retry_at: target.retry_at
    })
  end

  defp recorded_outcome(target, {:pass, _reason, _hint}),
    do: outcome(target, :passed, %{passed?: true})

  defp recorded_outcome(target, {:drop, _reason}), do: outcome(target, :dropped, %{})
  defp recorded_outcome(target, {:content_failure, _failure}), do: outcome(target, :failed, %{})

  defp live_target(conn, watcher_id, call) do
    sql =
      "SELECT name, task_job_id, filter_failures, filter_retry_at FROM cue_watchers WHERE id = ?"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [watcher_id]),
         [name, job_id, failures, stored_retry] = List.first(rows, [nil, nil, 0, nil]),
         {:ok, retry_at} <- CuesSql.read_stamp(stored_retry, "cue_watchers", :filter_retry_at) do
      {:ok,
       %{
         watcher_id: watcher_id,
         watcher_name: name,
         task_job_id: job_id,
         failures: failures,
         retry_at: retry_at,
         delivery_id: nil,
         cue_id: nil,
         source_ref: Map.get(call, :source_ref),
         attempts: Map.get(call, :attempt, 0)
       }}
    end
  end

  defp insert_live_call(conn, watcher_id, call, result, now) do
    CuesSql.execute(
      conn,
      """
      INSERT INTO cue_filter_calls (id, watcher_id, delivery_id, provider, model, session_id,
        started_at, finished_at, result, error)
      VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO NOTHING
      """,
      [
        call.id,
        watcher_id,
        Map.get(call, :provider),
        Map.get(call, :model),
        call.session_id,
        CuesSql.stamp(call.started_at),
        CuesSql.stamp(now),
        result_text(result),
        error_text(result)
      ]
    )
  end

  defp live_context(conn, watcher_ids, now) do
    Enum.reduce_while(watcher_ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case watcher_context(conn, id, now) do
        {:ok, context} -> {:cont, {:ok, Map.put(acc, id, context)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp watcher_context(conn, watcher_id, now) do
    sql = "SELECT count(*) FROM cue_filter_calls WHERE watcher_id = ? AND started_at > ?"

    with {:ok, instructions} <- instructions(conn, watcher_id),
         {:ok, examples} <- examples(conn, watcher_id),
         {:ok, [[used]]} <- CuesSql.query_all(conn, sql, [watcher_id, budget_window(now)]) do
      {:ok, %{instructions: instructions, examples: examples, used: used}}
    end
  end

  # --- reset and reads ------------------------------------------------------------------

  defp reset_in_tx(conn, now) do
    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT id, filter_call_id FROM cue_deliveries WHERE state = 'filtering' ORDER BY id",
             []
           ),
         {:ok, reset} <- reset_each(conn, rows),
         :ok <-
           CuesSql.execute(
             conn,
             "UPDATE cue_filter_calls SET finished_at = ?, result = 'aborted', error = ? " <>
               "WHERE finished_at IS NULL",
             [CuesSql.stamp(now), "aborted: the filter dispatcher started again"]
           ),
         {:ok, aborted} <- CuesSql.changes(conn) do
      {:ok, %{reset: length(reset), aborted: aborted, delivery_ids: reset}}
    end
  end

  defp reset_each(conn, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [id, call_id], {:ok, done} ->
      fence = if is_binary(call_id), do: {:filter_call_id, call_id}, else: :none

      case CuesSql.transition(conn, id, "filtering", fence, "pending", %{filter_call_id: nil}) do
        :ok -> {:cont, {:ok, done ++ [id]}}
        {:error, :stale} -> {:cont, {:ok, done}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The boot reset's fenced move, for the rows no task holds (TLA cue_inbox
  # CUE-1): their call is not in flight and started before `cutoff`. Only
  # their calls are finished; a call still in flight is never touched.
  defp reclaim_in_tx(conn, in_flight, cutoff, now) do
    with {:ok, rows} <- orphans(conn, in_flight, cutoff),
         {:ok, reclaimed} <- reset_each(conn, rows),
         {:ok, aborted} <- abort_orphan_calls(conn, orphan_call_ids(rows, reclaimed), now) do
      {:ok, %{reclaimed: reclaimed, aborted: aborted}}
    end
  end

  defp orphans(conn, in_flight, cutoff) do
    {held_sql, held_params} = held_clause(in_flight)

    sql = """
    SELECT d.id, d.filter_call_id FROM cue_deliveries d
    LEFT JOIN cue_filter_calls c ON c.id = d.filter_call_id
    WHERE d.state = 'filtering' AND (c.id IS NULL OR c.started_at < ?)
      #{held_sql}
    ORDER BY d.id
    """

    CuesSql.query_all(conn, sql, [CuesSql.stamp(cutoff)] ++ held_params)
  end

  defp held_clause([]), do: {"", []}

  defp held_clause(ids) do
    marks = Enum.map_join(ids, ", ", fn _id -> "?" end)
    {"AND (d.filter_call_id IS NULL OR d.filter_call_id NOT IN (#{marks}))", ids}
  end

  defp orphan_call_ids(rows, reclaimed) do
    for [id, call_id] <- rows, id in reclaimed, is_binary(call_id), do: call_id
  end

  defp abort_orphan_calls(_conn, [], _now), do: {:ok, 0}

  defp abort_orphan_calls(conn, call_ids, now) do
    marks = Enum.map_join(call_ids, ", ", fn _id -> "?" end)

    sql =
      "UPDATE cue_filter_calls SET finished_at = ?, result = 'aborted', error = ? " <>
        "WHERE finished_at IS NULL AND id IN (#{marks})"

    with :ok <- CuesSql.execute(conn, sql, [CuesSql.stamp(now), @orphan_error] ++ call_ids) do
      CuesSql.changes(conn)
    end
  end

  defp held_watchers(conn) do
    sql = """
    SELECT w.id, w.name, w.filter_failures, w.filter_retry_at,
      (SELECT count(*) FROM cue_deliveries d WHERE d.watcher_id = w.id AND d.state = 'pending')
    FROM cue_watchers w
    WHERE w.filter = 'llm' AND w.filter_failures >= ?
    ORDER BY w.id
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [@held_after]) do
      {:ok,
       Enum.map(rows, fn [id, name, failures, retry_at, waiting] ->
         %{
           watcher_id: id,
           watcher_name: name,
           filter_failures: failures,
           filter_retry_at: CuesSql.parse_stamp(retry_at),
           waiting: waiting
         }
       end)}
    end
  end
end
