defmodule FermixCore.Memory.Repo.CuesFollowUpSql do
  @moduledoc """
  SQL for watcher follow-ups (M60_WATCHER_CODING_RUNS.md §4.3–§4.5): the
  trigger table `cue_follow_up_triggers`, which is both a follow-up's trigger
  and, in ask first, its card; the pass hook that writes one; the card's
  answers; and the expiry. An automatic follow-up's approval and its prompts
  are `CuesFollowUpApprovalsSql`'s.

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`. One `handle/2` head per request tuple,
  every head contiguous and above the catch-all, which must stay last. Delivery
  moves go through `CuesSql.transition/6`, transactions through
  `CuesSql.with_immediate_transaction/2`, timestamps through `CuesSql.stamp/1`.

  `on_pass/3`, `claimable/2`, `mark_started/4` and `refuse_starting/3` are not
  requests: a pass and a run's claim are each one transaction with other rows,
  so the module that owns that transaction calls them with its own connection
  inside it (`CuesSql`, `CuesFilterSql`, `CuesWatchersSql`, `Memory.Repo`).

  ## A trigger's life

  A delivery passing a watcher that has a follow-up writes one trigger, keyed
  by the delivery, so one item sets the follow-up off at most once:

  - `skipped`: the item is older than 15 minutes, the watcher's daily cap is
    reached (task runs and follow-ups started or proposed in 24 hours), or a
    card of this follow-up already waits;
  - `starting`: an automatic follow-up whose approval still matches what it
    runs (`CuesFollowUpApprovalsSql.effective_mode/2`); the scheduler's next
    admission pass starts it;
  - `waiting`: ask first, or an automatic follow-up whose approval no longer
    matches, with an expiry 30 minutes on; the scheduler offers its card.

  Then `waiting → starting` (the owner's yes), `waiting → skipped` (no),
  `waiting → expired`, `waiting | starting → refused` (held, or not runnable
  when its turn came, with Fermix's sentence in `reason`) and
  `starting → started` with the run's id. A watcher with no task settles the
  delivery `acked` with outcome `follow_up` in the pass's transaction.

  A `cp_` token answers a mandate's proposal, a follow-up's card or an
  approval's prompt: `{:token_kind, digest}` says which table holds it, so
  `Cues.Proposals` dispatches each answer from one place.
  """

  alias FermixCore.Cues
  alias FermixCore.Memory.Repo.CuesFollowUpApprovalsSql
  alias FermixCore.Memory.Repo.CuesSql

  @fresh_s 15 * 60
  @card_s 30 * 60
  @cap_window_s 86_400
  @offers_max 20

  @states ~w(waiting starting started skipped expired refused)

  @stale "The item is older than 15 minutes."
  @card_waiting "A card for this follow-up is already waiting."
  @denied "You skipped it."
  @no_card "It expired with no answer."

  @schema_sql """
  CREATE TABLE IF NOT EXISTS cue_follow_up_triggers (
    id TEXT PRIMARY KEY,
    watcher_id TEXT NOT NULL,
    delivery_id INTEGER NOT NULL UNIQUE,
    cue_id INTEGER NOT NULL,
    job_id TEXT NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('approve','auto')),
    state TEXT NOT NULL CHECK (state IN
      ('waiting','starting','started','skipped','expired','refused')),
    reason TEXT,
    token_digest TEXT UNIQUE,
    chat_platform TEXT,
    chat_id TEXT,
    chat_user_id TEXT,
    offered_at TEXT,
    expires_at TEXT,
    run_id TEXT,
    decided_from TEXT,
    decided_at TEXT,
    created_at TEXT NOT NULL,
    CHECK (state != 'waiting' OR expires_at IS NOT NULL),
    CHECK ((state = 'started') = (run_id IS NOT NULL)),
    CHECK (state NOT IN ('skipped','refused') OR reason IS NOT NULL)
  );
  CREATE INDEX IF NOT EXISTS cue_follow_up_triggers_state ON cue_follow_up_triggers (state, created_at);
  CREATE INDEX IF NOT EXISTS cue_follow_up_triggers_watcher ON cue_follow_up_triggers (watcher_id, created_at);
  CREATE INDEX IF NOT EXISTS cue_follow_up_triggers_job ON cue_follow_up_triggers (job_id, state);
  """

  # A trigger counts toward its watcher's daily cap once its follow-up was
  # proposed or set to start (design §4.4): waiting, starting, started or
  # expired, or answered (a card the owner skipped). One written skipped or
  # refused at once, never proposed, does not.
  @counted_sql "(t.state IN ('waiting', 'starting', 'started', 'expired') " <>
                 "OR t.decided_at IS NOT NULL)"

  @trigger_columns """
  t.id, t.watcher_id, t.delivery_id, t.cue_id, t.job_id, t.mode, t.state, t.reason,
  t.token_digest IS NOT NULL, t.chat_platform, t.chat_id, t.chat_user_id, t.offered_at,
  t.expires_at, t.run_id, t.decided_from, t.decided_at, t.created_at
  """

  @pass_facts_sql """
  SELECT d.watcher_id, d.cue_id, w.task_job_id, w.follow_up_job_id, w.follow_up_mode,
         w.follow_up_approval_digest, w.daily_cap, coalesce(c.occurred_at, c.received_at)
  FROM cue_deliveries d
  JOIN cue_watchers w ON w.id = d.watcher_id
  JOIN cues c ON c.id = d.cue_id
  WHERE d.id = ?
  """

  @card_sql """
  SELECT t.id, t.state, t.mode, t.reason, t.created_at, t.expires_at, t.decided_at,
         t.decided_from, t.run_id, t.watcher_id, w.name, t.job_id, j.name, j.task_prompt,
         j.allowed_tools_json, j.delivery_mode, j.delivery_target_json, d.source_ref,
         d.decision_reason, d.received_at, c.occurred_at, c.snapshot
  FROM cue_follow_up_triggers t
  LEFT JOIN cue_watchers w ON w.id = t.watcher_id
  LEFT JOIN scheduled_jobs j ON j.id = t.job_id
  LEFT JOIN cue_deliveries d ON d.id = t.delivery_id
  LEFT JOIN cues c ON c.id = t.cue_id
  """

  @type conn :: term()
  @type trigger :: %{
          id: String.t(),
          watcher_id: String.t(),
          delivery_id: pos_integer(),
          cue_id: pos_integer(),
          job_id: String.t(),
          mode: String.t(),
          state: String.t(),
          reason: String.t() | nil,
          offered?: boolean(),
          chat: %{platform: String.t(), chat_id: String.t(), user_id: String.t() | nil} | nil,
          offered_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          run_id: String.t() | nil,
          decided_from: String.t() | nil,
          decided_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }
  @typedoc "Where a card went: the token's digest and the chat that may answer it."
  @type binding :: %{
          token_digest: String.t() | nil,
          platform: String.t() | nil,
          chat_id: String.t() | nil,
          user_id: String.t() | nil
        }

  @doc "The DDL of the trigger table and its indexes (migration 54)."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc """
  The condition, on a trigger aliased `t`, under which it counts toward its
  watcher's daily cap, for `CuesRunsSql`'s cap rule.
  """
  @spec counted_sql() :: String.t()
  def counted_sql, do: @counted_sql

  # --- requests -------------------------------------------------------------------

  @doc """
  Serves one request on `conn`; an unknown request is an error, never a raise.

  - `{:claim_offers, now, limit}` → `{:ok, [trigger]}`: waiting triggers not
    yet offered and not past their expiry, oldest first, each stamped
    `offered_at` so it is offered once.
  - `{:record_offer, id, binding, now}` → `{:ok, trigger}`: where the card
    went, on a waiting trigger with no card yet; `{:error, :not_waiting}`.
  - `{:refuse, id, from_states, reason}` → `{:ok, trigger}`: to
    `refused` with Fermix's sentence, from one of `from_states`;
    `{:error, :stale}` when it is in none of them.
  - `{:starting_triggers, limit}` → `{:ok, [trigger]}`, oldest first.
  - `{:confirm, digest, origin, now}`, `{:deny, digest, origin, now}`: the
    owner's answer by token, fenced on the digest, `waiting`, the chat it went
    to and the expiry (`waiting → starting | skipped`).
  - `{:decide, id, "starting" | "skipped", decided_from, now}`: an answer by
    id from an app the transport authenticated, fenced on `waiting` and the
    expiry.
  - `{:waiting_in_chat, origin, now}` → `{:ok, [trigger]}`: the cards waiting
    in that chat.
  - `{:card, id}` → `{:ok, card_row | nil}`: what the card shows.
  - `{:waiting_cards, now, limit}` → `{:ok, [card_row]}`: every card still
    waiting that went out, oldest first, for an app that connects.
  - `{:token_kind, digest}` → `{:ok, :mandate | :follow_up | :approval | nil}`:
    which table holds a `cp_` token's digest.
  - `{:expire, now, limit}` → `{:ok, [trigger]}`: waiting past the expiry →
    `expired`.
  - `{:run_trigger, run_id}` → `{:ok, %{trigger: trigger, watcher_name:
    name} | nil}`: the trigger that started a run.
  """
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:claim_offers, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 and limit <= @offers_max do
    CuesSql.with_immediate_transaction(conn, fn -> claim_offers(conn, now, limit) end)
  end

  def handle(conn, {:record_offer, id, binding, %DateTime{} = now})
      when is_binary(id) and is_map(binding) do
    CuesSql.with_immediate_transaction(conn, fn -> record_offer(conn, id, binding, now) end)
  end

  def handle(conn, {:refuse, id, [_ | _] = from, reason})
      when is_binary(id) and is_binary(reason) do
    CuesSql.with_immediate_transaction(conn, fn -> refuse(conn, id, from, reason) end)
  end

  def handle(conn, {:starting_triggers, limit}) when is_integer(limit) and limit > 0,
    do:
      list_triggers(conn, "t.state = 'starting' ORDER BY t.created_at, t.rowid LIMIT ?", [limit])

  def handle(conn, {:confirm, digest, origin, %DateTime{} = now}) when is_binary(digest) do
    answer_by_token(conn, digest, origin, {"starting", nil}, now)
  end

  def handle(conn, {:deny, digest, origin, %DateTime{} = now}) when is_binary(digest) do
    answer_by_token(conn, digest, origin, {"skipped", @denied}, now)
  end

  def handle(conn, {:decide, id, to_state, decided_from, %DateTime{} = now})
      when is_binary(id) and to_state in ["starting", "skipped"] and is_binary(decided_from) do
    CuesSql.with_immediate_transaction(conn, fn ->
      decide_by_id(conn, id, to_state, decided_from, now)
    end)
  end

  def handle(conn, {:waiting_in_chat, origin, %DateTime{} = now}) do
    where =
      "t.state = 'waiting' AND t.expires_at > ? AND t.chat_platform = ? AND t.chat_id = ? " <>
        "AND t.chat_user_id = ? ORDER BY t.created_at, t.rowid"

    case CuesSql.checked_origin(origin) do
      {:ok, chat} ->
        list_triggers(conn, where, [CuesSql.stamp(now), chat.platform, chat.chat_id, chat.user_id])

      :error ->
        {:error, :wrong_origin}
    end
  end

  def handle(conn, {:card, id}) when is_binary(id) do
    case CuesSql.query_all(conn, @card_sql <> "WHERE t.id = ?", [id]) do
      {:ok, [row]} -> {:ok, card_row(row)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(conn, {:waiting_cards, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    where =
      "WHERE t.state = 'waiting' AND t.offered_at IS NOT NULL AND t.expires_at > ? " <>
        "ORDER BY t.created_at, t.rowid LIMIT ?"

    with {:ok, rows} <- CuesSql.query_all(conn, @card_sql <> where, [CuesSql.stamp(now), limit]),
         do: {:ok, Enum.map(rows, &card_row/1)}
  end

  def handle(conn, {:token_kind, digest}) when is_binary(digest) do
    sql = """
    SELECT 'mandate' FROM cue_proposals WHERE token_digest = ?
    UNION ALL SELECT 'follow_up' FROM cue_follow_up_triggers WHERE token_digest = ?
    UNION ALL SELECT 'approval' FROM cue_follow_up_approvals WHERE token_digest = ?
    LIMIT 1
    """

    case CuesSql.query_all(conn, sql, [digest, digest, digest]) do
      {:ok, []} -> {:ok, nil}
      {:ok, [[kind]]} -> {:ok, token_kind(kind)}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(conn, {:expire, %DateTime{} = now, limit}) when is_integer(limit) and limit > 0 do
    CuesSql.with_immediate_transaction(conn, fn -> expire(conn, now, limit) end)
  end

  def handle(conn, {:run_trigger, run_id}) when is_binary(run_id) do
    with {:ok, triggers} <- list_triggers(conn, "t.run_id = ?", [run_id]) do
      run_trigger(conn, triggers)
    end
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- the pass hook ----------------------------------------------------------------

  @doc """
  Writes the trigger of delivery `delivery_id`, which has just passed, inside
  the pass's own transaction: nothing for a watcher with no follow-up (`{:ok,
  nil}`), else the trigger in the state the rules give, keyed by the delivery
  (a second call for it writes nothing). A watcher with no task settles the
  delivery `passed → acked`, outcome `follow_up`, in the same transaction.

  The answer is the trigger with `code`, a short label of why it was written
  in its state (`stale`, `capped`, `card_waiting`, `ask_first`, `automatic`),
  and `settled_delivery?` (the watcher had no task), for its lifecycle event.
  """
  @spec on_pass(conn(), pos_integer(), DateTime.t()) :: {:ok, map() | nil} | {:error, term()}
  def on_pass(conn, delivery_id, %DateTime{} = now) when is_integer(delivery_id) do
    case CuesSql.query_all(conn, @pass_facts_sql, [delivery_id]) do
      {:ok, [[_watcher, _cue, _task, nil | _rest]]} -> {:ok, nil}
      {:ok, [row]} -> trigger_pass(conn, pass_facts(delivery_id, row), now)
      {:ok, []} -> {:error, {:no_delivery, delivery_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pass_facts(delivery_id, [watcher, cue, task, job, mode, approval, cap, item_at]) do
    %{
      delivery_id: delivery_id,
      watcher_id: watcher,
      cue_id: cue,
      task_job_id: task,
      job_id: job,
      mode: mode,
      approval_digest: approval,
      daily_cap: cap,
      item_at: CuesSql.parse_stamp(item_at)
    }
  end

  # A delivery that already has its trigger (a pass written again) gets nothing
  # more: no second trigger and no second settle.
  defp trigger_pass(conn, facts, now) do
    with {:ok, {mode, state, code, reason}} <- pass_decision(conn, facts, now),
         {:ok, trigger} when is_map(trigger) <-
           insert_trigger(conn, facts, {mode, state, reason}, now),
         :ok <- settle_taskless(conn, facts, now) do
      {:ok, Map.merge(trigger, %{code: code, settled_delivery?: is_nil(facts.task_job_id)})}
    end
  end

  # The rules in order (design §4.4): freshness, the daily cap, then the mode;
  # ask first writes a card only while none of this follow-up waits.
  defp pass_decision(conn, facts, now) do
    with {:ok, used} <- cap_used(conn, facts, now),
         {:ok, mode} <- CuesFollowUpApprovalsSql.effective_mode(conn, facts) do
      cond do
        stale?(facts.item_at, now) -> {:ok, {mode, "skipped", "stale", @stale}}
        capped?(facts.daily_cap, used) -> {:ok, {mode, "skipped", "capped", capped(facts)}}
        mode == "auto" -> {:ok, {"auto", "starting", "automatic", nil}}
        true -> card_decision(conn, facts, now)
      end
    end
  end

  defp stale?(item_at, now), do: DateTime.diff(now, item_at, :second) > @fresh_s

  defp capped?(0, _used), do: false
  defp capped?(cap, used), do: used >= cap

  defp capped(%{daily_cap: cap}), do: "The watcher's daily cap of #{cap} is reached."

  # Task runs and counted triggers of the last 24 hours. `julianday` reads
  # job_runs times, which are ISO 8601 of varying width, as instants.
  defp cap_used(conn, facts, now) do
    window = DateTime.add(now, -@cap_window_s, :second)

    sql = """
    SELECT
      (SELECT COUNT(*) FROM cue_follow_up_triggers t
       WHERE t.watcher_id = ? AND t.created_at > ? AND #{@counted_sql}),
      (SELECT COUNT(*) FROM job_runs r
       WHERE r.job_id = ? AND r.trigger = 'cue' AND julianday(r.created_at) > julianday(?))
    """

    params = [facts.watcher_id, CuesSql.stamp(window), facts.task_job_id, CuesSql.stamp(window)]

    case CuesSql.query_all(conn, sql, params) do
      {:ok, [[triggers, runs]]} -> {:ok, triggers + runs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp card_decision(conn, facts, now) do
    sql =
      "SELECT 1 FROM cue_follow_up_triggers WHERE job_id = ? AND state = 'waiting' " <>
        "AND expires_at > ? LIMIT 1"

    case CuesSql.query_all(conn, sql, [facts.job_id, CuesSql.stamp(now)]) do
      {:ok, []} -> {:ok, {"approve", "waiting", "ask_first", nil}}
      {:ok, [_row]} -> {:ok, {"approve", "skipped", "card_waiting", @card_waiting}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_trigger(conn, facts, {mode, state, reason}, now) do
    id = Cues.id("cft")
    expires_at = if state == "waiting", do: CuesSql.stamp(DateTime.add(now, @card_s, :second))

    sql = """
    INSERT INTO cue_follow_up_triggers (id, watcher_id, delivery_id, cue_id, job_id, mode, state,
      reason, expires_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (delivery_id) DO NOTHING
    """

    params = [id, facts.watcher_id, facts.delivery_id, facts.cue_id, facts.job_id, mode, state]

    with :ok <- CuesSql.execute(conn, sql, params ++ [reason, expires_at, CuesSql.stamp(now)]),
         {:ok, inserted} <- CuesSql.changes(conn) do
      if inserted == 1, do: fetch_trigger(conn, id), else: {:ok, nil}
    end
  end

  # A watcher with no task has nothing to wake: its item settles now, and what
  # came of it is its trigger's (design §4.3).
  defp settle_taskless(conn, %{task_job_id: nil, delivery_id: id}, now) do
    patch = %{outcome: "follow_up", settled_at: now}
    CuesSql.transition(conn, id, "passed", :none, "acked", patch)
  end

  defp settle_taskless(_conn, _facts, _now), do: :ok

  # --- offers ----------------------------------------------------------------------

  defp claim_offers(conn, now, limit) do
    where =
      "t.state = 'waiting' AND t.offered_at IS NULL AND t.expires_at > ? " <>
        "ORDER BY t.created_at, t.rowid LIMIT ?"

    with {:ok, triggers} <- list_triggers(conn, where, [CuesSql.stamp(now), limit]),
         :ok <- stamp_offered(conn, triggers, now) do
      {:ok, Enum.map(triggers, &%{&1 | offered_at: now})}
    end
  end

  defp stamp_offered(conn, triggers, now) do
    Enum.reduce_while(triggers, :ok, fn trigger, :ok ->
      sql = "UPDATE cue_follow_up_triggers SET offered_at = ? WHERE id = ?"

      case CuesSql.execute(conn, sql, [CuesSql.stamp(now), trigger.id]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_offer(conn, id, binding, now) do
    sql = """
    UPDATE cue_follow_up_triggers
    SET token_digest = ?, chat_platform = ?, chat_id = ?, chat_user_id = ?,
        offered_at = coalesce(offered_at, ?)
    WHERE id = ? AND state = 'waiting' AND token_digest IS NULL
    """

    params = [
      Map.get(binding, :token_digest),
      Map.get(binding, :platform),
      Map.get(binding, :chat_id),
      Map.get(binding, :user_id),
      CuesSql.stamp(now),
      id
    ]

    one_change(conn, sql, params, id, :not_waiting)
  end

  # --- refusals and answers -------------------------------------------------------------

  # A refusal leaves `decided_at` as it was: a card the owner confirmed and
  # that could not start still counts toward the cap, one refused before
  # anyone saw it does not.
  defp refuse(conn, id, from, reason) do
    if Enum.all?(from, &(&1 in ["waiting", "starting"])) do
      sql =
        "UPDATE cue_follow_up_triggers SET state = 'refused', reason = ? " <>
          "WHERE id = ? AND state IN (#{marks(from)})"

      one_change(conn, sql, [reason, id | from], id, :stale)
    else
      {:error, {:invalid_from, from}}
    end
  end

  @doc """
  The trigger `id` while it is `starting`, read inside a run's claim
  transaction (`Memory.Repo.claim_follow_up_run/4`); `{:error, :nothing_due}`
  otherwise.
  """
  @spec claimable(conn(), String.t()) :: {:ok, trigger()} | {:error, :nothing_due | term()}
  def claimable(conn, id) when is_binary(id) do
    case list_triggers(conn, "t.id = ? AND t.state = 'starting'", [id]) do
      {:ok, [trigger]} -> {:ok, trigger}
      {:ok, []} -> {:error, :nothing_due}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Moves trigger `id` `starting → started` with its run, inside the claim's transaction."
  @spec mark_started(conn(), String.t(), String.t(), DateTime.t()) ::
          {:ok, trigger()} | {:error, term()}
  def mark_started(conn, id, run_id, %DateTime{}) when is_binary(id) and is_binary(run_id) do
    sql =
      "UPDATE cue_follow_up_triggers SET state = 'started', run_id = ? " <>
        "WHERE id = ? AND state = 'starting'"

    one_change(conn, sql, [run_id, id], id, :stale)
  end

  @doc """
  Moves trigger `id` `starting → refused` with `reason`, inside the claim's
  transaction: its job could not take a run when its turn came.
  """
  @spec refuse_starting(conn(), String.t(), String.t()) :: {:ok, trigger()} | {:error, term()}
  def refuse_starting(conn, id, reason) when is_binary(id) and is_binary(reason),
    do: refuse(conn, id, ["starting"], reason)

  defp answer_by_token(conn, digest, origin, {to_state, reason}, now) do
    case CuesSql.checked_origin(origin) do
      {:ok, origin} ->
        CuesSql.with_immediate_transaction(conn, fn ->
          token_answer(conn, digest, origin, {to_state, reason}, now)
        end)

      :error ->
        {:error, :wrong_origin}
    end
  end

  defp token_answer(conn, digest, origin, {to_state, reason}, now) do
    stamp = CuesSql.stamp(now)

    sql = """
    UPDATE cue_follow_up_triggers
    SET state = ?, reason = ?, decided_at = ?, decided_from = ?
    WHERE token_digest = ? AND state = 'waiting' AND chat_platform = ? AND chat_id = ?
      AND chat_user_id = ? AND expires_at > ?
    """

    params = [to_state, reason, stamp, CuesSql.origin_text(origin), digest]
    params = params ++ [origin.platform, origin.chat_id, origin.user_id, stamp]

    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      answered_or_why(conn, "t.token_digest = ?", [digest], changed, now)
    end
  end

  defp decide_by_id(conn, id, to_state, decided_from, now) do
    stamp = CuesSql.stamp(now)
    reason = if to_state == "skipped", do: @denied

    sql = """
    UPDATE cue_follow_up_triggers
    SET state = ?, reason = ?, decided_at = ?, decided_from = ?
    WHERE id = ? AND state = 'waiting' AND expires_at > ?
    """

    with :ok <- CuesSql.execute(conn, sql, [to_state, reason, stamp, decided_from, id, stamp]),
         {:ok, changed} <- CuesSql.changes(conn) do
      answered_or_why(conn, "t.id = ?", [id], changed, now)
    end
  end

  defp answered_or_why(conn, where, params, 1, _now), do: fetch_one(conn, where, params)

  defp answered_or_why(conn, where, params, 0, now) do
    case list_triggers(conn, where, params) do
      {:ok, []} -> {:error, :unknown}
      {:ok, [%{state: "waiting"} = trigger]} -> {:error, CuesSql.waiting_why(trigger, now)}
      {:ok, [%{state: state}]} -> {:error, {:not_waiting, state}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- expiry ----------------------------------------------------------------------

  defp expire(conn, now, limit) do
    where = "t.state = 'waiting' AND t.expires_at <= ? ORDER BY t.expires_at, t.rowid LIMIT ?"
    sql = "UPDATE cue_follow_up_triggers SET state = 'expired', reason = ? WHERE id = ?"

    with {:ok, triggers} <- list_triggers(conn, where, [CuesSql.stamp(now), limit]) do
      Enum.reduce_while(triggers, {:ok, []}, &expire_one(conn, sql, &1, &2))
    end
  end

  defp expire_one(conn, sql, trigger, {:ok, done}) do
    case CuesSql.execute(conn, sql, [@no_card, trigger.id]) do
      :ok -> {:cont, {:ok, done ++ [%{trigger | state: "expired", reason: @no_card}]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # --- the run's trigger -------------------------------------------------------------

  defp run_trigger(_conn, []), do: {:ok, nil}

  defp run_trigger(conn, [trigger]) do
    sql = "SELECT name FROM cue_watchers WHERE id = ?"

    case CuesSql.query_all(conn, sql, [trigger.watcher_id]) do
      {:ok, [[name]]} -> {:ok, %{trigger: trigger, watcher_name: name}}
      {:ok, []} -> {:ok, %{trigger: trigger, watcher_name: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- tokens ----------------------------------------------------------------------

  defp token_kind("mandate"), do: :mandate
  defp token_kind("follow_up"), do: :follow_up
  defp token_kind("approval"), do: :approval

  # --- reads -----------------------------------------------------------------------

  defp list_triggers(conn, where, params) do
    sql = "SELECT #{@trigger_columns} FROM cue_follow_up_triggers t WHERE " <> where

    with {:ok, rows} <- CuesSql.query_all(conn, sql, params) do
      {:ok, Enum.map(rows, &trigger_row/1)}
    end
  end

  defp fetch_trigger(conn, id), do: fetch_one(conn, "t.id = ?", [id])

  defp fetch_one(conn, where, params) do
    with {:ok, rows} <- list_triggers(conn, where, params), do: one(rows, :not_found)
  end

  defp one_change(conn, sql, params, id, none) do
    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      if changed == 1, do: fetch_trigger(conn, id), else: {:error, none}
    end
  end

  defp one([row], _none), do: {:ok, row}
  defp one([], none), do: {:error, none}

  defp trigger_row([
         id,
         watcher_id,
         delivery_id,
         cue_id,
         job_id,
         mode,
         state,
         reason,
         offered,
         platform,
         chat_id,
         user_id,
         offered_at,
         expires_at,
         run_id,
         decided_from,
         decided_at,
         created_at
       ])
       when state in @states do
    %{
      id: id,
      watcher_id: watcher_id,
      delivery_id: delivery_id,
      cue_id: cue_id,
      job_id: job_id,
      mode: mode,
      state: state,
      reason: reason,
      offered?: offered == 1,
      chat: CuesSql.answer_chat(platform, chat_id, user_id),
      offered_at: CuesSql.parse_stamp(offered_at),
      expires_at: CuesSql.parse_stamp(expires_at),
      run_id: run_id,
      decided_from: decided_from,
      decided_at: CuesSql.parse_stamp(decided_at),
      created_at: CuesSql.parse_stamp(created_at)
    }
  end

  defp card_row([
         id,
         state,
         mode,
         reason,
         created_at,
         expires_at,
         decided_at,
         decided_from,
         run_id,
         watcher_id,
         watcher_name,
         job_id,
         job_name,
         prompt,
         tools,
         delivery_mode,
         delivery_target,
         source_ref,
         decision_reason,
         received_at,
         occurred_at,
         snapshot
       ]) do
    %{
      id: id,
      state: state,
      mode: mode,
      reason: reason,
      created_at: CuesSql.parse_stamp(created_at),
      expires_at: CuesSql.parse_stamp(expires_at),
      decided_at: CuesSql.parse_stamp(decided_at),
      decided_from: decided_from,
      run_id: run_id,
      watcher_id: watcher_id,
      watcher_name: watcher_name,
      job_id: job_id,
      job_name: job_name,
      task_prompt: prompt,
      allowed_tools: tools,
      delivery_mode: delivery_mode,
      delivery_target: delivery_target,
      source_ref: source_ref,
      decision_reason: decision_reason,
      received_at: CuesSql.parse_stamp(received_at),
      occurred_at: CuesSql.parse_stamp(occurred_at),
      snapshot: snapshot
    }
  end

  defp marks(list), do: Enum.map_join(list, ", ", fn _item -> "?" end)
end
