defmodule FermixCore.Memory.Repo.CuesSql do
  @moduledoc """
  SQL for the cue inbox (M60 §7): the schema of migration 42, accept and route,
  source state, gaps and retention. Lane A owns it.

  Like every `Memory.Repo` SQL module it is pure SQL over the caller's `conn`,
  reached only through `Memory.Repo.cues_call/3`, so the single writer stays the
  only writer. `handle/2` has one head per request tuple. A request that matches
  no head answers `{:error, {:unknown_request, request}}`: nothing here may raise
  inside the Repo process.

  ## Shared helpers for the cue SQL modules

  `CuesWatchersSql`, `CuesFilterSql`, `CuesRunsSql` and `CuesMandateSql` reuse:

  - `transition/6`: the one fenced compare-and-set every delivery move goes
    through (PLAN §1 "Fenced transitions", decision 7);
  - `with_immediate_transaction/2`: `BEGIN IMMEDIATE` … `COMMIT`, rolled back on
    any error;
  - `execute/3`, `query_all/3`, `changes/1`: statement helpers;
  - `stamp/1`, `parse_stamp/1`: the repo's fixed-width UTC timestamp form
    (`TemporalSql.timestamp/1`), which keeps text comparison in time order;
  - `extend_gap/7`: one open gap row per (source, watcher, reason).
  """

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Cues
  alias FermixCore.Cues.Item
  alias FermixCore.Memory.Repo.TemporalSql

  @inbox_cap 250
  @lifetime_days 7
  @horizon_days 7
  @payload_grace_hours 24
  @prune_days 30
  @list_default 100
  @list_max 500

  @delivery_states ~w(pending filtering passed claimed acked dropped exhausted expired)
  @live_states ~w(pending filtering passed claimed)
  @terminal_states ~w(acked dropped exhausted expired)
  @patch_columns [
    :outcome,
    :decision_reason,
    :hint,
    :filter_attempts,
    :task_attempts,
    :ready_at,
    :valid_until,
    :filter_call_id,
    :claimed_run_id,
    :settled_at
  ]
  @gap_reasons ~w(disconnect inbox_full rate_limited budget expired stale identity_conflict
                  watcher_removed read_limit page_limit backfill_limit)
  @source_statuses ~w(connected reconnecting auth_failed polling over_budget idle stopped
                      unavailable)
  @item_rejects ~w(invalid stale rate_limited over_budget)
  @reject_gaps %{"stale" => "stale", "rate_limited" => "rate_limited", "over_budget" => "budget"}
  @source_times [:last_good_at, :last_accepted_at, :last_rejected_at]
  @reason_pattern ~r/^[a-z][a-z_]{0,31}$/

  @schema_sql """
  CREATE TABLE cues (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_ref TEXT NOT NULL,
    item_id TEXT NOT NULL,
    revision TEXT NOT NULL DEFAULT '1',
    type TEXT,
    subject TEXT,
    occurred_at TEXT,
    received_at TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    body_hash TEXT,
    payload TEXT,
    payload_bytes INTEGER NOT NULL DEFAULT 0,
    snapshot TEXT,
    self_caused INTEGER NOT NULL DEFAULT 0 CHECK (self_caused IN (0, 1)),
    routed_count INTEGER NOT NULL DEFAULT 0,
    terminal_at TEXT,
    last_seen_at TEXT NOT NULL,
    UNIQUE (source_ref, item_id, revision)
  );
  CREATE INDEX cues_source_body_hash ON cues (source_ref, body_hash) WHERE body_hash IS NOT NULL;
  CREATE INDEX cues_received_at ON cues (received_at);
  CREATE INDEX cues_terminal_at ON cues (terminal_at);

  CREATE TABLE cue_sources (
    source_ref TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'idle' CHECK (status IN
      ('connected','reconnecting','auth_failed','polling','over_budget','idle','stopped','unavailable')),
    last_good_at TEXT,
    cursor TEXT,
    items_today INTEGER NOT NULL DEFAULT 0,
    items_day TEXT,
    last_accepted_at TEXT,
    last_rejected_at TEXT,
    reject_counts TEXT NOT NULL DEFAULT '{}',
    notices TEXT NOT NULL DEFAULT '{}',
    updated_at TEXT NOT NULL
  );

  CREATE TABLE cue_watchers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    purpose TEXT,
    filter TEXT NOT NULL CHECK (filter IN ('llm','none')),
    filter_provider TEXT,
    filter_model TEXT,
    task_job_id TEXT NOT NULL UNIQUE REFERENCES scheduled_jobs(id),
    task_notes INTEGER NOT NULL DEFAULT 0 CHECK (task_notes IN (0, 1)),
    daily_cap INTEGER NOT NULL DEFAULT 0 CHECK (daily_cap >= 0),
    filter_budget INTEGER NOT NULL DEFAULT 0 CHECK (filter_budget >= 0),
    filter_failures INTEGER NOT NULL DEFAULT 0,
    filter_retry_at TEXT,
    held_notified_at TEXT,
    notices TEXT NOT NULL DEFAULT '{}',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_from TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE cue_watcher_sources (
    watcher_id TEXT NOT NULL REFERENCES cue_watchers(id) ON DELETE CASCADE,
    source_ref TEXT NOT NULL,
    PRIMARY KEY (watcher_id, source_ref)
  );
  CREATE INDEX cue_watcher_sources_ref ON cue_watcher_sources (source_ref);

  CREATE TABLE cue_watcher_instructions (
    id TEXT PRIMARY KEY,
    watcher_id TEXT NOT NULL REFERENCES cue_watchers(id) ON DELETE CASCADE,
    number INTEGER NOT NULL,
    text TEXT NOT NULL,
    added_at TEXT NOT NULL,
    added_from TEXT,
    removed_at TEXT,
    removed_from TEXT,
    replaced_by TEXT,
    UNIQUE (watcher_id, number)
  );

  CREATE TABLE cue_watcher_examples (
    id TEXT PRIMARY KEY,
    watcher_id TEXT NOT NULL REFERENCES cue_watchers(id) ON DELETE CASCADE,
    cue_id INTEGER NOT NULL,
    label TEXT NOT NULL CHECK (label IN ('pass','drop')),
    note TEXT,
    snapshot TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE TABLE cue_deliveries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cue_id INTEGER NOT NULL REFERENCES cues(id),
    watcher_id TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    subject TEXT,
    received_at TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN
      ('pending','filtering','passed','claimed','acked','dropped','exhausted','expired')),
    outcome TEXT CHECK (outcome IS NULL OR outcome IN
      ('ignored','acted','filter_failed','task_failed','failed_after_action',
       'lifetime','inbox_full','watcher_removed')),
    decision_reason TEXT,
    hint TEXT,
    filter_attempts INTEGER NOT NULL DEFAULT 0 CHECK (filter_attempts BETWEEN 0 AND 3),
    task_attempts INTEGER NOT NULL DEFAULT 0 CHECK (task_attempts BETWEEN 0 AND 3),
    ready_at TEXT NOT NULL,
    valid_until TEXT NOT NULL,
    filter_call_id TEXT,
    claimed_run_id TEXT,
    settled_at TEXT,
    UNIQUE (cue_id, watcher_id)
  );
  CREATE INDEX cue_deliveries_watcher_state ON cue_deliveries (watcher_id, state, id);
  CREATE INDEX cue_deliveries_watcher_source ON cue_deliveries (watcher_id, source_ref, state, id);
  CREATE INDEX cue_deliveries_subject ON cue_deliveries (watcher_id, subject, id)
    WHERE subject IS NOT NULL;
  CREATE INDEX cue_deliveries_valid_until ON cue_deliveries (state, valid_until);
  CREATE INDEX cue_deliveries_settled_at ON cue_deliveries (settled_at)
    WHERE settled_at IS NOT NULL;

  CREATE TABLE cue_gaps (
    id TEXT PRIMARY KEY,
    source_ref TEXT NOT NULL,
    watcher_id TEXT,
    reason TEXT NOT NULL CHECK (reason IN
      ('disconnect','inbox_full','rate_limited','budget','expired','stale','identity_conflict',
       'watcher_removed','read_limit','page_limit','backfill_limit')),
    count INTEGER NOT NULL DEFAULT 1,
    range_from TEXT,
    range_to TEXT,
    first_at TEXT NOT NULL,
    last_at TEXT NOT NULL,
    reported_at TEXT,
    closed_at TEXT
  );
  CREATE UNIQUE INDEX cue_gaps_open ON cue_gaps (source_ref, coalesce(watcher_id, ''), reason)
    WHERE closed_at IS NULL;
  CREATE INDEX cue_gaps_last_at ON cue_gaps (last_at);

  CREATE TABLE cue_filter_calls (
    id TEXT PRIMARY KEY,
    watcher_id TEXT NOT NULL,
    delivery_id INTEGER NOT NULL,
    provider TEXT,
    model TEXT,
    session_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    result TEXT CHECK (result IS NULL OR result IN
      ('pass','drop','provider_failure','content_failure','aborted')),
    error TEXT
  );
  CREATE INDEX cue_filter_calls_watcher ON cue_filter_calls (watcher_id, started_at);
  CREATE INDEX cue_filter_calls_started ON cue_filter_calls (started_at);

  CREATE TABLE cue_mandate_calls (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    job_id TEXT NOT NULL,
    mandate TEXT NOT NULL,
    tool TEXT NOT NULL,
    args_json TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    delivery_id INTEGER,
    decision TEXT CHECK (decision IS NULL OR decision IN ('allow','refuse','propose')),
    reason TEXT,
    validator TEXT CHECK (validator IS NULL OR validator IN ('program','none')),
    proposal_id TEXT,
    result_status TEXT,
    result_summary TEXT,
    created_at TEXT NOT NULL,
    decided_at TEXT,
    finished_at TEXT
  );
  CREATE INDEX cue_mandate_calls_run ON cue_mandate_calls (run_id, created_at);
  CREATE INDEX cue_mandate_calls_job ON cue_mandate_calls (job_id, decided_at);

  CREATE TABLE cue_proposals (
    id TEXT PRIMARY KEY,
    mandate_call_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    job_id TEXT NOT NULL,
    mandate TEXT NOT NULL,
    watcher_id TEXT,
    delivery_id INTEGER,
    tool TEXT NOT NULL,
    args_json TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    token_digest TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK (state IN ('waiting','confirmed','denied','expired','refused')),
    sent_platform TEXT,
    sent_chat_id TEXT,
    sent_user_id TEXT,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    decided_at TEXT,
    decided_from TEXT,
    refusal_reason TEXT,
    result_status TEXT,
    result_summary TEXT,
    finished_at TEXT,
    reported_at TEXT
  );
  CREATE INDEX cue_proposals_state ON cue_proposals (state, expires_at);

  CREATE TABLE cue_mandate_approvals (
    mandate TEXT PRIMARY KEY,
    digest TEXT NOT NULL,
    approved_at TEXT NOT NULL,
    approved_from TEXT,
    disabled_at TEXT,
    disabled_reason TEXT
  );

  ALTER TABLE job_runs ADD COLUMN tools_started_at TEXT;
  ALTER TABLE job_runs ADD COLUMN cue_delivery_id INTEGER;
  """

  @type conn :: term()
  @type fence :: :none | {:filter_call_id, String.t()} | {:claimed_run_id, String.t()}
  @type gap_event :: %{
          gap_id: String.t(),
          source_ref: String.t(),
          watcher_id: String.t() | nil,
          reason: String.t(),
          count: pos_integer()
        }

  @doc "The DDL of migration 42: every cue table and the two `job_runs` columns."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc "Delivery states that hold a delivery open (never touched by retention)."
  @spec live_states() :: [String.t()]
  def live_states, do: @live_states

  @doc "Delivery states that end a delivery; each needs `settled_at`."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @doc "The per (watcher, source) inbox cap of `pending` and `passed` deliveries."
  @spec inbox_cap() :: pos_integer()
  def inbox_cap, do: @inbox_cap

  # --- requests ----------------------------------------------------------------

  @doc """
  Serves one cue request on `conn`. See the moduledoc of `FermixCore.Cues.Ingest`
  for `:accept` and the docs below for each helper.
  """
  @spec handle(conn(), tuple()) :: term()
  def handle(
        conn,
        {:accept, %{ref: ref, rejected: rejected, daily_budget: budget} = source, items,
         %DateTime{} = now, state}
      )
      when is_binary(ref) and is_map(rejected) and is_integer(budget) and budget >= 0 and
             is_list(items) and (is_map(state) or is_nil(state)) do
    with :ok <- valid_items(items),
         :ok <- valid_rejects(rejected),
         {:ok, attrs} <- source_attrs(state || %{}) do
      with_immediate_transaction(conn, fn -> accept_in_tx(conn, source, items, now, attrs) end)
    end
  end

  def handle(conn, {:source_touch, ref, attrs, %DateTime{} = now})
      when is_binary(ref) and is_map(attrs) do
    with {:ok, normalized} <- source_attrs(attrs) do
      with_immediate_transaction(conn, fn -> touch_and_fetch(conn, ref, normalized, now) end)
    end
  end

  def handle(conn, {:source_reject, ref, counts, %DateTime{} = now})
      when is_binary(ref) and is_map(counts) and map_size(counts) > 0 do
    if Enum.all?(counts, &reject_count?/1) do
      with_immediate_transaction(conn, fn -> add_rejects(conn, ref, counts, stamp(now)) end)
    else
      {:error, {:invalid, :reason}}
    end
  end

  def handle(conn, {:get_source, ref}) when is_binary(ref), do: fetch_source(conn, ref)

  def handle(conn, {:list_sources}) do
    with {:ok, rows} <- query_all(conn, "#{source_select()} ORDER BY source_ref", []) do
      source_rows(rows)
    end
  end

  def handle(conn, {:extend_gap, ref, watcher, reason, count, range, %DateTime{} = now})
      when is_binary(ref) and (is_binary(watcher) or is_nil(watcher)) and is_binary(reason) and
             is_integer(count) and count > 0 do
    with {:ok, {from, to}} <- gap_range(range) do
      extend_gap(conn, ref, watcher, reason, count, {from, to}, now)
    end
  end

  def handle(conn, {:close_gap, ref, watcher, reason, %DateTime{} = now})
      when is_binary(ref) and (is_binary(watcher) or is_nil(watcher)) and is_binary(reason) do
    close_gap(conn, ref, watcher, reason, now)
  end

  def handle(conn, {:list_gaps, filters}) when is_map(filters), do: list_gaps(conn, filters)

  def handle(conn, {:expire_lifetime, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    with_immediate_transaction(conn, fn -> expire_lifetime(conn, now, limit) end)
  end

  def handle(conn, {step, %DateTime{} = now, limit})
      when step in [
             :mark_terminal,
             :drop_payloads,
             :delete_receipts,
             :prune_deliveries,
             :prune_gaps,
             :prune_filter_calls,
             :drop_snapshots
           ] and is_integer(limit) and limit > 0 do
    {sql, params} = retention_sql(step, now)

    with :ok <- execute(conn, sql, params ++ [limit]) do
      changes(conn)
    end
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- accept and route (design §7.1) ------------------------------------------

  defp valid_items(items) do
    if Enum.all?(items, &match?(%Item{}, &1)), do: :ok, else: {:error, {:invalid, :items}}
  end

  defp valid_rejects(rejected) do
    if Enum.all?(rejected, fn {reason, n} ->
         reason in @item_rejects and is_integer(n) and n > 0
       end),
       do: :ok,
       else: {:error, {:invalid, :rejected}}
  end

  defp accept_in_tx(conn, %{ref: ref, daily_budget: budget} = source, items, now, attrs) do
    with {:ok, room} <- budget_room(conn, ref, budget, now),
         {:ok, watchers} <- listening_watchers(conn, ref),
         initial = %{results: [], gaps: [], llm?: false, none?: false, room: room},
         {:ok, acc} <- accept_items(conn, ref, items, watchers, now, initial),
         rejected = with_over_budget(source.rejected, acc.results),
         {:ok, reject_gaps} <- record_rejects(conn, ref, rejected, now),
         :ok <- count_accepted(conn, ref, budget, items, acc.results, now),
         :ok <- write_accept_state(conn, ref, attrs, acc, rejected, now) do
      {:ok,
       acc
       |> Map.delete(:room)
       |> Map.merge(%{results: Enum.reverse(acc.results), gaps: acc.gaps ++ reject_gaps})}
    end
  end

  # The daily budget (0 = none) counts the items accepted today (UTC), read and
  # spent inside the accept transaction: a duplicate or a refused item spends
  # nothing, and a transaction that fails has spent nothing.
  defp budget_room(_conn, _ref, 0, _now), do: {:ok, :unlimited}

  defp budget_room(conn, ref, budget, now) do
    sql = "SELECT items_today, items_day FROM cue_sources WHERE source_ref = ?"

    case query_all(conn, sql, [ref]) do
      {:ok, [[today, day]]} -> {:ok, max(budget - spent_today(today, day, now), 0)}
      {:ok, []} -> {:ok, budget}
      {:error, reason} -> {:error, reason}
    end
  end

  defp spent_today(count, day, now), do: if(day == utc_day(now), do: count, else: 0)

  defp with_over_budget(rejected, results) do
    case Enum.count(results, &(&1.result == :over_budget)) do
      0 -> rejected
      n -> Map.update(rejected, "over_budget", n, &(&1 + n))
    end
  end

  defp count_accepted(_conn, _ref, 0, _items, _results, _now), do: :ok
  defp count_accepted(_conn, _ref, _budget, [], _results, _now), do: :ok

  defp count_accepted(conn, ref, _budget, _items, results, now) do
    accepted = Enum.count(results, &(&1.result == :accepted))

    with {:ok, _today} <- count_items(conn, ref, accepted, now), do: :ok
  end

  defp listening_watchers(conn, ref) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT w.id, w.filter FROM cue_watcher_sources s
             JOIN cue_watchers w ON w.id = s.watcher_id
             WHERE s.source_ref = ? AND w.enabled = 1
             ORDER BY w.id
             """,
             [ref]
           ) do
      {:ok, Enum.map(rows, fn [id, filter] -> {id, filter} end)}
    end
  end

  defp accept_items(_conn, _ref, [], _watchers, _now, acc), do: {:ok, acc}

  defp accept_items(conn, ref, [item | rest], watchers, now, acc) do
    case accept_item(conn, ref, item, watchers, now, acc.room) do
      {:ok, result, gaps} ->
        accept_items(conn, ref, rest, watchers, now, add_result(acc, result, gaps))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_result(acc, result, gaps) do
    states = result |> Map.get(:deliveries, []) |> Enum.map(& &1.state)

    %{
      acc
      | results: [result | acc.results],
        gaps: acc.gaps ++ gaps,
        llm?: acc.llm? or "pending" in states,
        none?: acc.none? or "passed" in states,
        room: spend(acc.room, result)
    }
  end

  defp spend(room, %{result: :accepted}) when is_integer(room), do: room - 1
  defp spend(room, _result), do: room

  defp accept_item(conn, ref, item, watchers, now, room) do
    case find_identity(conn, ref, item) do
      {:ok, nil} -> accept_new(conn, ref, item, watchers, now, room)
      {:ok, {id, hash}} when hash == item.content_hash -> touch_duplicate(conn, id, now)
      {:ok, {id, _other_hash}} -> record_conflict(conn, ref, id, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_identity(conn, ref, item) do
    case query_all(
           conn,
           "SELECT id, content_hash FROM cues WHERE source_ref = ? AND item_id = ? AND revision = ?",
           [ref, item.item_id, item.revision]
         ) do
      {:ok, [[id, hash]]} -> {:ok, {id, hash}}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # A new item past the daily budget is refused before anything is stored.
  defp accept_new(conn, ref, item, watchers, now, room) do
    case find_body_duplicate(conn, ref, item.body_hash, now) do
      {:ok, nil} when room == 0 -> {:ok, %{result: :over_budget, cue_id: nil}, []}
      {:ok, nil} -> insert_and_route(conn, ref, item, watchers, now)
      {:ok, id} -> touch_duplicate(conn, id, now)
      {:error, reason} -> {:error, reason}
    end
  end

  # GitHub signs the body, not its delivery id: the same body within the receipt
  # horizon is a duplicate whatever its id (design §6.5, C38).
  defp find_body_duplicate(_conn, _ref, nil, _now), do: {:ok, nil}

  defp find_body_duplicate(conn, ref, body_hash, now) do
    horizon = now |> DateTime.add(-@horizon_days, :day) |> stamp()

    case query_all(
           conn,
           "SELECT id FROM cues WHERE source_ref = ? AND body_hash = ? AND last_seen_at >= ? " <>
             "ORDER BY id DESC LIMIT 1",
           [ref, body_hash, horizon]
         ) do
      {:ok, [[id]]} -> {:ok, id}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp touch_duplicate(conn, id, now) do
    with :ok <-
           execute(conn, "UPDATE cues SET last_seen_at = max(last_seen_at, ?) WHERE id = ?", [
             stamp(now),
             id
           ]) do
      {:ok, %{result: :duplicate, cue_id: id}, []}
    end
  end

  defp record_conflict(conn, ref, id, now) do
    with {:ok, gap_id} <- extend_gap(conn, ref, nil, "identity_conflict", 1, {nil, nil}, now) do
      {:ok, %{result: :conflict, cue_id: id},
       [gap_event(gap_id, ref, nil, "identity_conflict", 1)]}
    end
  end

  defp insert_and_route(conn, ref, item, watchers, now) do
    targets = if item.self_caused? or item.receipt_only?, do: [], else: watchers

    with {:ok, cue_id} <- insert_cue(conn, ref, item, length(targets), now),
         {:ok, deliveries} <- insert_deliveries(conn, cue_id, ref, item, targets, now),
         {:ok, evicted, gaps} <- evict_overflow(conn, ref, deliveries, now) do
      {:ok, %{result: :accepted, cue_id: cue_id, deliveries: deliveries, evicted: evicted}, gaps}
    end
  end

  # A cue no watcher gets is a receipt: no payload, and terminal from the start,
  # so retention's clocks run from its arrival.
  defp insert_cue(conn, ref, item, routed_count, now) do
    received = stamp(now)
    {payload, terminal_at} = if routed_count == 0, do: {nil, received}, else: {item.payload, nil}

    insert_returning_id(
      conn,
      """
      INSERT INTO cues (source_ref, item_id, revision, type, subject, occurred_at, received_at,
        content_hash, body_hash, payload, payload_bytes, snapshot, self_caused, routed_count,
        terminal_at, last_seen_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      RETURNING id
      """,
      [
        ref,
        item.item_id,
        item.revision,
        item.type,
        item.subject,
        optional_stamp(item.occurred_at),
        received,
        item.content_hash,
        item.body_hash,
        payload,
        item.payload_bytes,
        item.snapshot,
        if(item.self_caused?, do: 1, else: 0),
        routed_count,
        terminal_at,
        received
      ]
    )
  end

  defp insert_deliveries(conn, cue_id, ref, item, targets, now) do
    received = stamp(now)
    valid_until = now |> DateTime.add(@lifetime_days, :day) |> stamp()

    Enum.reduce_while(targets, {:ok, []}, fn {watcher_id, filter}, {:ok, acc} ->
      {state, reason} = if filter == "none", do: {"passed", "no filter"}, else: {"pending", nil}

      case insert_returning_id(
             conn,
             """
             INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, subject, received_at, state,
               decision_reason, ready_at, valid_until)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
             RETURNING id
             """,
             [
               cue_id,
               watcher_id,
               ref,
               item.subject,
               received,
               state,
               reason,
               received,
               valid_until
             ]
           ) do
        {:ok, id} ->
          {:cont, {:ok, acc ++ [%{delivery_id: id, watcher_id: watcher_id, state: state}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Design §7.1 step 3: past 250 `pending|passed` from this source, the oldest
  # `pending` goes, else the oldest `passed`; never a delivery in a filter call
  # or a run, and never the one just inserted (the newest input is kept).
  defp evict_overflow(conn, ref, deliveries, now) do
    Enum.reduce_while(deliveries, {:ok, [], []}, fn delivery, {:ok, evicted, gaps} ->
      case evict_for(conn, ref, delivery, now) do
        {:ok, [], []} -> {:cont, {:ok, evicted, gaps}}
        {:ok, more, gap} -> {:cont, {:ok, evicted ++ more, gaps ++ gap}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp evict_for(conn, ref, %{delivery_id: new_id, watcher_id: watcher}, now) do
    with {:ok, [[held]]} <-
           query_all(
             conn,
             "SELECT count(*) FROM cue_deliveries WHERE watcher_id = ? AND source_ref = ? " <>
               "AND state IN ('pending', 'passed')",
             [watcher, ref]
           ) do
      evict_oldest(conn, ref, watcher, new_id, held - @inbox_cap, now)
    end
  end

  defp evict_oldest(_conn, _ref, _watcher, _new_id, over, _now) when over <= 0, do: {:ok, [], []}

  defp evict_oldest(conn, ref, watcher, new_id, over, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT id FROM cue_deliveries
             WHERE watcher_id = ? AND source_ref = ? AND state IN ('pending', 'passed') AND id <> ?
             ORDER BY CASE state WHEN 'pending' THEN 0 ELSE 1 END, id
             LIMIT ?
             """,
             [watcher, ref, new_id, over]
           ),
         {:ok, ids} <- expire_each(conn, List.flatten(rows), "inbox_full", now),
         {:ok, gap_id} <-
           extend_gap(conn, ref, watcher, "inbox_full", length(ids), {nil, nil}, now) do
      evicted = Enum.map(ids, &%{delivery_id: &1, watcher_id: watcher})
      {:ok, evicted, [gap_event(gap_id, ref, watcher, "inbox_full", length(ids))]}
    end
  end

  defp expire_each(conn, ids, outcome, now) do
    patch = %{outcome: outcome, settled_at: now}

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, done} ->
      case transition(conn, id, ["pending", "passed"], :none, "expired", patch) do
        :ok -> {:cont, {:ok, done ++ [id]}}
        {:error, :stale} -> {:cont, {:ok, done}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_rejects(_conn, _ref, rejected, _now) when map_size(rejected) == 0, do: {:ok, []}

  defp record_rejects(conn, ref, rejected, now) do
    with {:ok, _counts} <- add_rejects(conn, ref, rejected, stamp(now)) do
      rejected
      |> Enum.filter(fn {reason, _n} -> Map.has_key?(@reject_gaps, reason) end)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, &reject_gap(conn, ref, &1, &2, now))
    end
  end

  defp reject_gap(conn, ref, {reason, n}, {:ok, gaps}, now) do
    gap_reason = Map.fetch!(@reject_gaps, reason)

    case extend_gap(conn, ref, nil, gap_reason, n, {nil, nil}, now) do
      {:ok, gap_id} -> {:cont, {:ok, gaps ++ [gap_event(gap_id, ref, nil, gap_reason, n)]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp write_accept_state(conn, ref, attrs, acc, rejected, now) do
    accepted? = Enum.any?(acc.results, &(&1.result == :accepted))

    attrs
    |> maybe_put(accepted?, :last_accepted_at, stamp(now))
    |> maybe_put(Map.has_key?(rejected, "over_budget"), :status, "over_budget")
    |> write_attrs_if_any(conn, ref, acc, rejected, now)
  end

  defp write_attrs_if_any(attrs, conn, ref, acc, rejected, now) do
    if attrs == %{} and acc.results == [] and rejected == %{} do
      :ok
    else
      touch_source(conn, ref, attrs, stamp(now))
    end
  end

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map

  # --- source state ------------------------------------------------------------

  # Keys with a nil value leave the column as it was.
  defp source_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case source_attr(key, value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, column_value} -> {:cont, {:ok, Map.put(acc, key, column_value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp source_attr(_key, nil), do: {:ok, nil}
  defp source_attr(:status, status) when status in @source_statuses, do: {:ok, status}
  defp source_attr(:status, _status), do: {:error, {:invalid, :status}}
  defp source_attr(:cursor, cursor) when is_binary(cursor), do: {:ok, cursor}

  defp source_attr(key, %DateTime{} = at) when key in @source_times, do: {:ok, stamp(at)}

  defp source_attr(key, _value), do: {:error, {:invalid, key}}

  defp ensure_source(conn, ref, stamp) do
    execute(
      conn,
      "INSERT INTO cue_sources (source_ref, updated_at) VALUES (?, ?) ON CONFLICT (source_ref) DO NOTHING",
      [ref, stamp]
    )
  end

  defp touch_source(conn, ref, attrs, stamp) do
    columns = attrs |> Map.keys() |> Enum.sort()
    set_sql = Enum.map_join(columns, "", &", #{&1} = ?")
    params = Enum.map(columns, &Map.fetch!(attrs, &1))

    with :ok <- ensure_source(conn, ref, stamp) do
      execute(
        conn,
        "UPDATE cue_sources SET updated_at = ?#{set_sql} WHERE source_ref = ?",
        [stamp | params] ++ [ref]
      )
    end
  end

  defp touch_and_fetch(conn, ref, attrs, now) do
    with :ok <- touch_source(conn, ref, attrs, stamp(now)), do: fetch_source(conn, ref)
  end

  defp reject_count?({reason, n}) do
    is_binary(reason) and Regex.match?(@reason_pattern, reason) and is_integer(n) and n > 0
  end

  defp utc_day(now),
    do: now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date() |> Date.to_iso8601()

  defp count_items(conn, ref, n, now) do
    day = utc_day(now)

    case query_all(
           conn,
           """
           INSERT INTO cue_sources (source_ref, items_today, items_day, updated_at) VALUES (?, ?, ?, ?)
           ON CONFLICT (source_ref) DO UPDATE SET
             items_today = CASE WHEN cue_sources.items_day = excluded.items_day
               THEN cue_sources.items_today + excluded.items_today
               ELSE excluded.items_today END,
             items_day = excluded.items_day,
             updated_at = excluded.updated_at
           RETURNING items_today
           """,
           [ref, n, day, stamp(now)]
         ) do
      {:ok, [[count]]} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # Coalesced: one counter per reason in `reject_counts`, never a row per refusal.
  defp add_rejects(conn, ref, additions, stamp) do
    with :ok <- ensure_source(conn, ref, stamp),
         {:ok, [[raw]]} <-
           query_all(conn, "SELECT reject_counts FROM cue_sources WHERE source_ref = ?", [ref]),
         {:ok, counts} <- decode_object(raw, :reject_counts) do
      merged = Map.merge(counts, additions, fn _reason, old, new -> old + new end)

      with :ok <-
             execute(
               conn,
               "UPDATE cue_sources SET reject_counts = ?, last_rejected_at = ?, updated_at = ? " <>
                 "WHERE source_ref = ?",
               [Jason.encode!(merged), stamp, stamp, ref]
             ) do
        {:ok, merged}
      end
    end
  end

  defp source_select do
    "SELECT source_ref, status, last_good_at, cursor, items_today, items_day, last_accepted_at, " <>
      "last_rejected_at, reject_counts, notices, updated_at FROM cue_sources"
  end

  defp fetch_source(conn, ref) do
    case query_all(conn, "#{source_select()} WHERE source_ref = ?", [ref]) do
      {:ok, [row]} -> source_row(row)
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case source_row(row) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      {:error, reason} -> {:error, reason}
    end)
  end

  # Only this module writes these columns, but a row that does not decode (a
  # broken writer, a hand edit) is an error for the caller, never a raise inside
  # the single writer: `{:error, {:corrupt, "cue_sources", detail}}`.
  defp source_row([
         ref,
         status,
         good,
         cursor,
         today,
         day,
         accepted,
         rejected,
         counts,
         notices,
         at
       ]) do
    with {:ok, reject_counts} <- decode_object(counts, :reject_counts),
         {:ok, notice_stamps} <- decode_object(notices, :notices),
         {:ok, last_good_at} <- read_stamp(good, "cue_sources", :last_good_at),
         {:ok, last_accepted_at} <- read_stamp(accepted, "cue_sources", :last_accepted_at),
         {:ok, last_rejected_at} <- read_stamp(rejected, "cue_sources", :last_rejected_at),
         {:ok, updated_at} <- read_stamp(at, "cue_sources", :updated_at) do
      {:ok,
       %{
         source_ref: ref,
         status: status,
         last_good_at: last_good_at,
         cursor: cursor,
         items_today: today,
         items_day: day,
         last_accepted_at: last_accepted_at,
         last_rejected_at: last_rejected_at,
         reject_counts: reject_counts,
         notices: notice_stamps,
         updated_at: updated_at
       }}
    end
  end

  defp decode_object(raw, column) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> {:ok, map}
      _other -> {:error, {:corrupt, "cue_sources", {:json_object, column}}}
    end
  end

  defp decode_object(_raw, column),
    do: {:error, {:corrupt, "cue_sources", {:json_object, column}}}

  # --- gaps --------------------------------------------------------------------

  @doc """
  Extends the one open gap of `(source_ref, watcher_id, reason)` by `count`, or
  opens it; `range` widens to cover `{from, to}` (either side may be nil).
  Returns the gap's id. Call it inside the caller's transaction.
  """
  @spec extend_gap(
          conn(),
          String.t(),
          String.t() | nil,
          String.t(),
          pos_integer(),
          {String.t() | nil, String.t() | nil},
          DateTime.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def extend_gap(conn, ref, watcher, reason, count, {from, to}, %DateTime{} = now)
      when reason in @gap_reasons and is_integer(count) and count > 0 do
    at = stamp(now)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO cue_gaps (id, source_ref, watcher_id, reason, count, range_from, range_to,
               first_at, last_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (source_ref, coalesce(watcher_id, ''), reason) WHERE closed_at IS NULL
             DO UPDATE SET
               count = cue_gaps.count + excluded.count,
               last_at = excluded.last_at,
               range_from = CASE WHEN excluded.range_from IS NULL THEN cue_gaps.range_from
                 WHEN cue_gaps.range_from IS NULL OR excluded.range_from < cue_gaps.range_from
                 THEN excluded.range_from ELSE cue_gaps.range_from END,
               range_to = CASE WHEN excluded.range_to IS NULL THEN cue_gaps.range_to
                 WHEN cue_gaps.range_to IS NULL OR excluded.range_to > cue_gaps.range_to
                 THEN excluded.range_to ELSE cue_gaps.range_to END
             """,
             [Cues.id("cgp"), ref, watcher, reason, count, from, to, at, at]
           ) do
      open_gap_id(conn, ref, watcher, reason)
    end
  end

  def extend_gap(_conn, _ref, _watcher, _reason, _count, _range, _now),
    do: {:error, {:invalid, :reason}}

  defp open_gap_id(conn, ref, watcher, reason) do
    case query_all(
           conn,
           "SELECT id FROM cue_gaps WHERE source_ref = ? AND coalesce(watcher_id, '') = ? " <>
             "AND reason = ? AND closed_at IS NULL",
           [ref, watcher || "", reason]
         ) do
      {:ok, [[id]]} -> {:ok, id}
      {:ok, _none} -> {:error, :gap_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gap_range(nil), do: {:ok, {nil, nil}}

  defp gap_range({from, to}) do
    with {:ok, from} <- range_end(from), {:ok, to} <- range_end(to), do: {:ok, {from, to}}
  end

  defp gap_range(_range), do: {:error, {:invalid, :range}}

  defp range_end(nil), do: {:ok, nil}
  defp range_end(%DateTime{} = at), do: {:ok, stamp(at)}
  defp range_end(text) when is_binary(text), do: {:ok, text}
  defp range_end(_other), do: {:error, {:invalid, :range}}

  defp close_gap(conn, ref, watcher, reason, now) do
    with :ok <-
           execute(
             conn,
             "UPDATE cue_gaps SET closed_at = ? WHERE source_ref = ? AND coalesce(watcher_id, '') = ? " <>
               "AND reason = ? AND closed_at IS NULL",
             [stamp(now), ref, watcher || "", reason]
           ) do
      changes(conn)
    end
  end

  defp list_gaps(conn, filters) do
    {where, params} = gap_conditions(filters)
    limit = list_limit(Map.get(filters, :limit))

    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT id, source_ref, watcher_id, reason, count, range_from, range_to, first_at, " <>
               "last_at, reported_at, closed_at FROM cue_gaps#{where} ORDER BY last_at DESC, id LIMIT ?",
             params ++ [limit]
           ) do
      {:ok, Enum.map(rows, &gap_row/1)}
    end
  end

  defp gap_conditions(filters) do
    clauses =
      [
        filter_clause(filters, :source_ref, "source_ref = ?"),
        watcher_clause(filters),
        filter_clause(filters, :reason, "reason = ?"),
        flag_clause(filters, :open, "closed_at IS NULL", "closed_at IS NOT NULL"),
        flag_clause(filters, :unreported, "reported_at IS NULL", "reported_at IS NOT NULL")
      ]
      |> Enum.reject(&is_nil/1)

    where =
      if clauses == [], do: "", else: " WHERE " <> Enum.map_join(clauses, " AND ", &elem(&1, 0))

    {where, Enum.flat_map(clauses, &elem(&1, 1))}
  end

  defp filter_clause(filters, key, sql) do
    case Map.fetch(filters, key) do
      {:ok, value} when is_binary(value) -> {sql, [value]}
      _absent -> nil
    end
  end

  # `watcher_id: nil` asks for source-level gaps only.
  defp watcher_clause(filters) do
    case Map.fetch(filters, :watcher_id) do
      {:ok, nil} -> {"watcher_id IS NULL", []}
      {:ok, id} when is_binary(id) -> {"watcher_id = ?", [id]}
      _absent -> nil
    end
  end

  defp flag_clause(filters, key, true_sql, false_sql) do
    case Map.fetch(filters, key) do
      {:ok, true} -> {true_sql, []}
      {:ok, false} -> {false_sql, []}
      _absent -> nil
    end
  end

  defp list_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @list_max)
  defp list_limit(_limit), do: @list_default

  defp gap_row([id, ref, watcher, reason, count, from, to, first, last, reported, closed]) do
    %{
      id: id,
      source_ref: ref,
      watcher_id: watcher,
      reason: reason,
      count: count,
      range_from: from,
      range_to: to,
      first_at: parse_stamp(first),
      last_at: parse_stamp(last),
      reported_at: parse_stamp(reported),
      closed_at: parse_stamp(closed)
    }
  end

  defp gap_event(gap_id, ref, watcher, reason, count) do
    %{gap_id: gap_id, source_ref: ref, watcher_id: watcher, reason: reason, count: count}
  end

  # --- retention (design §7.4) ---------------------------------------------------

  # `pending|passed` past `valid_until` expire with outcome `lifetime` and one
  # `expired` gap per (watcher, source). `filtering` and `claimed` are never
  # touched: their filter call or run settles them.
  defp expire_lifetime(conn, now, limit) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT id, cue_id, watcher_id, source_ref FROM cue_deliveries " <>
               "WHERE state IN ('pending', 'passed') AND valid_until <= ? ORDER BY id LIMIT ?",
             [stamp(now), limit]
           ),
         {:ok, ids} <- expire_each(conn, Enum.map(rows, &hd/1), "lifetime", now) do
      expired =
        for [id, cue_id, watcher, ref] <- rows, id in ids do
          %{delivery_id: id, cue_id: cue_id, watcher_id: watcher, source_ref: ref}
        end

      with {:ok, gaps} <- expired_gaps(conn, expired, now) do
        {:ok, %{count: length(expired), expired: expired, gaps: gaps}}
      end
    end
  end

  defp expired_gaps(conn, expired, now) do
    expired
    |> Enum.frequencies_by(&{&1.source_ref, &1.watcher_id})
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {{ref, watcher}, n}, {:ok, gaps} ->
      case extend_gap(conn, ref, watcher, "expired", n, {nil, nil}, now) do
        {:ok, gap_id} -> {:cont, {:ok, gaps ++ [gap_event(gap_id, ref, watcher, "expired", n)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp retention_sql(:mark_terminal, now) do
    {"""
     UPDATE cues SET terminal_at = coalesce(
       (SELECT max(d.settled_at) FROM cue_deliveries d WHERE d.cue_id = cues.id), ?)
     WHERE id IN (
       SELECT c.id FROM cues c
       WHERE c.terminal_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM cue_deliveries d WHERE d.cue_id = c.id
           AND d.state IN ('pending', 'filtering', 'passed', 'claimed'))
       ORDER BY c.id LIMIT ?)
     """, [stamp(now)]}
  end

  defp retention_sql(:drop_payloads, now) do
    {"""
     UPDATE cues SET payload = NULL WHERE id IN (
       SELECT id FROM cues WHERE payload IS NOT NULL AND terminal_at IS NOT NULL
         AND terminal_at <= ? ORDER BY terminal_at LIMIT ?)
     """, [ago(now, @payload_grace_hours * 3600)]}
  end

  # 7 days after the payload drop (terminal + 24 h) and 7 days after the last
  # sighting, and only once no delivery row refers to the cue.
  defp retention_sql(:delete_receipts, now) do
    {"""
     DELETE FROM cues WHERE id IN (
       SELECT c.id FROM cues c
       WHERE c.payload IS NULL AND c.terminal_at IS NOT NULL AND c.terminal_at <= ?
         AND c.last_seen_at <= ?
         AND NOT EXISTS (SELECT 1 FROM cue_deliveries d WHERE d.cue_id = c.id)
       ORDER BY c.terminal_at LIMIT ?)
     """,
     [
       ago(now, @payload_grace_hours * 3600 + @horizon_days * 86_400),
       ago(now, @horizon_days * 86_400)
     ]}
  end

  defp retention_sql(:prune_deliveries, now) do
    {"""
     DELETE FROM cue_deliveries WHERE id IN (
       SELECT id FROM cue_deliveries WHERE settled_at IS NOT NULL AND settled_at <= ?
         AND state IN ('acked', 'dropped', 'exhausted', 'expired')
       ORDER BY settled_at LIMIT ?)
     """, [ago(now, @prune_days * 86_400)]}
  end

  defp retention_sql(:prune_gaps, now) do
    {"DELETE FROM cue_gaps WHERE id IN (SELECT id FROM cue_gaps WHERE last_at <= ? " <>
       "ORDER BY last_at LIMIT ?)", [ago(now, @prune_days * 86_400)]}
  end

  # A call is pruned 30 days after it started, finished or not: one left open
  # (a settle that never came) holds nothing a sweep could still need.
  defp retention_sql(:prune_filter_calls, now) do
    {"DELETE FROM cue_filter_calls WHERE id IN (SELECT id FROM cue_filter_calls " <>
       "WHERE started_at <= ? ORDER BY started_at LIMIT ?)", [ago(now, @prune_days * 86_400)]}
  end

  defp retention_sql(:drop_snapshots, now) do
    {"UPDATE cues SET snapshot = NULL WHERE id IN (SELECT id FROM cues " <>
       "WHERE snapshot IS NOT NULL AND received_at <= ? ORDER BY received_at LIMIT ?)",
     [ago(now, @prune_days * 86_400)]}
  end

  defp ago(now, seconds), do: now |> DateTime.add(-seconds, :second) |> stamp()

  # --- the fenced transition (PLAN §1, decision 7) -------------------------------

  @doc """
  Moves delivery `id` from one of `from` (a state or a list) to `to`, writing
  `patch`, only while its fence still holds:

  - `:none` — no fence beyond the state (a claim sets its fence in `patch`);
  - `{:filter_call_id, id}` — the filter call that holds it;
  - `{:claimed_run_id, id}` — the run that holds it.

  `patch` keys are delivery columns (`outcome`, `decision_reason`, `hint`,
  `filter_attempts`, `task_attempts`, `ready_at`, `valid_until`,
  `filter_call_id`, `claimed_run_id`, `settled_at`); values are `nil`, text,
  integers, `DateTime`s, or `{:add, n}` for `column = column + n`. A terminal
  `to` needs `settled_at` (retention prunes by it).

  Zero rows changed is `{:error, :stale}`, logged: the row moved (a sweep, a
  boot reset, another writer) and the late write is refused, never retried
  blindly. Runs inside the caller's transaction; it opens none.
  """
  @spec transition(conn(), pos_integer(), String.t() | [String.t()], fence(), String.t(), map()) ::
          :ok | {:error, :stale} | {:error, term()}
  def transition(conn, id, from, fence, to, patch)
      when is_integer(id) and to in @delivery_states and is_map(patch) do
    from_states = List.wrap(from)

    with :ok <- check_from(from_states),
         :ok <- check_settled(to, patch),
         {:ok, set_sql, set_params} <- patch_clause(patch),
         {:ok, fence_sql, fence_params} <- fence_clause(fence) do
      sql =
        "UPDATE cue_deliveries SET state = ?#{set_sql} WHERE id = ? AND state IN (#{marks(from_states)})" <>
          fence_sql

      with :ok <- execute(conn, sql, [to | set_params] ++ [id | from_states] ++ fence_params) do
        changed(conn, id, from_states, to)
      end
    end
  end

  def transition(_conn, id, from, fence, to, patch),
    do: {:error, {:invalid_transition, {id, from, fence, to, patch}}}

  defp check_from(states) do
    if states != [] and Enum.all?(states, &(&1 in @delivery_states)),
      do: :ok,
      else: {:error, {:invalid_transition, {:from, states}}}
  end

  defp check_settled(to, patch) do
    if to in @terminal_states and not match?(%{settled_at: %DateTime{}}, patch) and
         not match?(%{settled_at: <<_::binary>>}, patch),
       do: {:error, {:invalid_transition, {:settled_at_required, to}}},
       else: :ok
  end

  defp patch_clause(patch) do
    columns = patch |> Map.keys() |> Enum.sort()

    case Enum.reject(columns, &(&1 in @patch_columns)) do
      [] -> patch_parts(columns, patch)
      unknown -> {:error, {:invalid_transition, {:columns, unknown}}}
    end
  end

  defp patch_parts(columns, patch) do
    Enum.reduce_while(columns, {:ok, "", []}, fn column, {:ok, sql, params} ->
      case patch_value(Map.fetch!(patch, column)) do
        {:set, value} -> {:cont, {:ok, sql <> ", #{column} = ?", params ++ [value]}}
        {:add, n} -> {:cont, {:ok, sql <> ", #{column} = #{column} + ?", params ++ [n]}}
        :error -> {:halt, {:error, {:invalid_transition, {:value, column}}}}
      end
    end)
  end

  defp patch_value(nil), do: {:set, nil}
  defp patch_value(%DateTime{} = at), do: {:set, stamp(at)}
  defp patch_value(value) when is_binary(value) or is_integer(value), do: {:set, value}
  defp patch_value({:add, n}) when is_integer(n), do: {:add, n}
  defp patch_value(_value), do: :error

  defp fence_clause(:none), do: {:ok, "", []}

  defp fence_clause({:filter_call_id, id}) when is_binary(id),
    do: {:ok, " AND filter_call_id = ?", [id]}

  defp fence_clause({:claimed_run_id, id}) when is_binary(id),
    do: {:ok, " AND claimed_run_id = ?", [id]}

  defp fence_clause(fence), do: {:error, {:invalid_transition, {:fence, fence}}}

  defp changed(conn, id, from_states, to) do
    case changes(conn) do
      {:ok, 1} ->
        :ok

      {:ok, 0} ->
        Logger.warning(
          "Cue delivery #{id} was no longer #{Enum.join(from_states, "|")} with its fence; " <>
            "the move to #{to} was refused as stale."
        )

        {:error, :stale}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp marks(values), do: Enum.map_join(values, ", ", fn _value -> "?" end)

  # --- shared statement helpers ------------------------------------------------

  @doc """
  Runs `fun` inside `BEGIN IMMEDIATE` … `COMMIT`. `fun` returns `{:ok, value}`
  to commit or `{:error, reason}` to roll back. A failed `BEGIN` (including
  `:busy`) leaves no open transaction; every failure after it rolls back, so
  the single writer's connection is never left inside an open transaction
  (the `TemporalSql` rule). A raise, throw or exit inside `fun` is a bug and
  stays loud: the transaction is rolled back and the same error raised again
  (Code Rule 4, close on every path).
  """
  @spec with_immediate_transaction(conn(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_immediate_transaction(conn, fun) when is_function(fun, 0) do
    case execute(conn, "BEGIN IMMEDIATE", []) do
      :ok -> settle_transaction(conn, run_in_transaction(conn, fun))
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_in_transaction(conn, fun) do
    fun.()
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      {:error, _reason} = rollback(conn, {kind, reason})
      :erlang.raise(kind, reason, stacktrace)
  end

  defp settle_transaction(conn, {:ok, _value} = result) do
    case execute(conn, "COMMIT", []) do
      :ok -> result
      {:error, reason} -> rollback(conn, reason)
    end
  end

  defp settle_transaction(conn, {:error, reason}), do: rollback(conn, reason)

  defp rollback(conn, reason) do
    case execute(conn, "ROLLBACK", []) do
      :ok ->
        {:error, reason}

      {:error, rollback_error} ->
        Logger.error(
          "Cue transaction rollback failed: #{inspect(rollback_error)} " <>
            "(original error: #{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  @doc "Runs one statement, discarding any rows."
  @spec execute(conn(), String.t(), list()) :: :ok | {:error, term()}
  def execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        step_result(Sqlite3.step(conn, stmt))
      end
    end)
  end

  @doc "Runs one statement and returns every row as a list."
  @spec query_all(conn(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  def query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        Sqlite3.fetch_all(conn, stmt)
      end
    end)
  end

  @doc "Rows changed by the last statement on `conn`."
  @spec changes(conn()) :: {:ok, non_neg_integer()} | {:error, term()}
  def changes(conn), do: Sqlite3.changes(conn)

  defp insert_returning_id(conn, sql, params) do
    case query_all(conn, sql, params) do
      {:ok, [[id]]} -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_rows, length(other)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind(_stmt, []), do: :ok
  defp bind(stmt, params), do: Sqlite3.bind(stmt, params)

  defp step_result(:done), do: :ok
  defp step_result(:busy), do: {:error, :busy}
  defp step_result({:row, _row}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}

  defp with_statement(conn, sql, fun) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} -> release_after(conn, stmt, fun.(stmt))
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_after(conn, stmt, result) do
    case Sqlite3.release(conn, stmt) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # --- timestamps ----------------------------------------------------------------

  @doc "A UTC instant in the repo's one fixed-width form (`TemporalSql.timestamp/1`)."
  @spec stamp(DateTime.t()) :: String.t()
  def stamp(%DateTime{} = at) do
    {:ok, text} = TemporalSql.timestamp(at)
    text
  end

  defp optional_stamp(nil), do: nil
  defp optional_stamp(%DateTime{} = at), do: stamp(at)

  @doc """
  Parses a stored timestamp; nil stays nil. A value that does not parse
  raises: use it for columns Fermix writes in the one form `stamp/1` gives. A
  reader that must answer a corrupt row with an error uses `read_stamp/3`.
  """
  @spec parse_stamp(String.t() | nil) :: DateTime.t() | nil
  def parse_stamp(nil), do: nil

  def parse_stamp(text) when is_binary(text) do
    {:ok, at, 0} = DateTime.from_iso8601(text)
    at
  end

  @doc """
  Parses a stored timestamp of `table`'s `column` without raising: nil stays
  nil, and a value that does not parse is `{:error, {:corrupt, table, {:stamp,
  column}}}`.
  """
  @spec read_stamp(term(), String.t(), atom()) ::
          {:ok, DateTime.t() | nil} | {:error, {:corrupt, String.t(), {:stamp, atom()}}}
  def read_stamp(nil, _table, _column), do: {:ok, nil}

  def read_stamp(text, table, column) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, 0} -> {:ok, at}
      _other -> {:error, {:corrupt, table, {:stamp, column}}}
    end
  end

  def read_stamp(_value, table, column), do: {:error, {:corrupt, table, {:stamp, column}}}
end
