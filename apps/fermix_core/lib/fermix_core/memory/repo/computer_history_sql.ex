defmodule FermixCore.Memory.Repo.ComputerHistorySql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s computer-history operations
  # (MILESTONE_32 §7). Every function takes the caller's `conn` and is invoked
  # only from Repo's `handle_call`s, so the single-writer architecture is
  # unchanged; the split keeps `repo.ex` bounded (the TemporalSql precedent).
  #
  # Three tables, three additive migrations (23/24/25):
  #   * computer_history_events   — the <=48h raw interaction-event spool
  #   * computer_history_memories — durable, derived activity summaries
  #   * computer_history_state    — the summarizer singleton (claim + cursor)
  #
  # The spool's identity is a DB-generated `id` (AUTOINCREMENT), NOT the
  # capturer's per-boot `source_seq` (which restarts at 1 each boot): the id is
  # the summarizer's high-water cursor, and `UNIQUE(boot_id, source_seq)` makes
  # a re-delivered event idempotent. `ts` (epoch ms) is for windowed retention
  # and range queries only, never the processing cursor.

  require Logger

  alias Exqlite.Sqlite3

  # Writable columns of computer_history_events (id/AUTOINCREMENT excluded), in
  # the order the INSERT binds them. The single source of truth for the writer.
  @event_columns [
    :boot_id,
    :source_seq,
    :ts,
    :type,
    :bundle_id,
    :prev_bundle_id,
    :window_title,
    :page_title,
    :url,
    :host,
    :role,
    :role_desc,
    :field_label,
    :text,
    :browser_id,
    :window_ref,
    :tab_ref,
    :private_state,
    :content_withheld,
    :gap_reason,
    :gap_from_ts,
    :gap_to_ts,
    :scan_flag,
    :char_len
  ]

  @event_insert_columns Enum.map_join(@event_columns, ", ", &Atom.to_string/1)
  @event_insert_placeholders Enum.map_join(@event_columns, ", ", fn _column -> "?" end)

  # Read shape includes the DB id (the summarizer cursor) ahead of the writable
  # columns, in a fixed order the row-zip depends on.
  @event_read_columns [:id | @event_columns]
  @event_read_select Enum.map_join(@event_read_columns, ", ", &Atom.to_string/1)

  # Writable columns of computer_history_memories (id/AUTOINCREMENT excluded).
  @memory_columns [
    :created_at,
    :provenance_from_ts,
    :provenance_to_ts,
    :summary,
    :apps,
    :sites,
    :titles,
    :urls,
    :event_count,
    :model,
    :superseded_at
  ]

  @memory_insert_columns Enum.map_join(@memory_columns, ", ", &Atom.to_string/1)
  @memory_insert_placeholders Enum.map_join(@memory_columns, ", ", fn _column -> "?" end)

  # Read shape for recall (the id ahead of the writable columns).
  @memory_read_columns [:id | @memory_columns]
  @memory_read_select Enum.map_join(@memory_read_columns, ", ", &Atom.to_string/1)

  @state_columns [
    :id,
    :last_run_at,
    :claimed_at,
    :claim_owner,
    :status,
    :last_status,
    :last_summarized_id,
    :purge_watermark_ts,
    :paused_reason,
    :pause_until,
    :summarizer_route,
    :summarizer_model,
    :updated_at
  ]

  @state_select Enum.map_join(@state_columns, ", ", &Atom.to_string/1)

  @events_schema_sql """
  CREATE TABLE IF NOT EXISTS computer_history_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    boot_id TEXT NOT NULL,
    source_seq INTEGER NOT NULL,
    ts INTEGER NOT NULL,
    type TEXT NOT NULL,
    bundle_id TEXT,
    prev_bundle_id TEXT,
    window_title TEXT,
    page_title TEXT,
    url TEXT,
    host TEXT,
    role TEXT,
    role_desc TEXT,
    field_label TEXT,
    text TEXT,
    browser_id TEXT,
    window_ref TEXT,
    tab_ref TEXT,
    private_state TEXT,
    content_withheld INTEGER,
    gap_reason TEXT,
    gap_from_ts INTEGER,
    gap_to_ts INTEGER,
    scan_flag TEXT,
    char_len INTEGER
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_computer_history_events_source
    ON computer_history_events(boot_id, source_seq);
  CREATE INDEX IF NOT EXISTS idx_computer_history_events_ts
    ON computer_history_events(ts);
  CREATE INDEX IF NOT EXISTS idx_computer_history_events_bundle
    ON computer_history_events(bundle_id);
  """

  @memories_schema_sql """
  CREATE TABLE IF NOT EXISTS computer_history_memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    provenance_from_ts INTEGER NOT NULL,
    provenance_to_ts INTEGER NOT NULL,
    summary TEXT NOT NULL,
    apps TEXT,
    sites TEXT,
    titles TEXT,
    urls TEXT,
    event_count INTEGER NOT NULL DEFAULT 0,
    model TEXT NOT NULL,
    superseded_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_computer_history_memories_provenance
    ON computer_history_memories(provenance_from_ts, provenance_to_ts);
  CREATE INDEX IF NOT EXISTS idx_computer_history_memories_created
    ON computer_history_memories(created_at);
  """

  @state_schema_sql """
  CREATE TABLE IF NOT EXISTS computer_history_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    last_run_at TEXT,
    claimed_at TEXT,
    claim_owner TEXT,
    status TEXT NOT NULL DEFAULT 'idle' CHECK (status IN ('idle', 'running')),
    last_status TEXT,
    last_summarized_id INTEGER NOT NULL DEFAULT 0,
    purge_watermark_ts INTEGER,
    paused_reason TEXT,
    pause_until TEXT,
    summarizer_route TEXT,
    summarizer_model TEXT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );
  """

  @doc "Schema for migration 23 — the raw event spool."
  @spec events_schema_sql() :: String.t()
  def events_schema_sql, do: @events_schema_sql

  @doc "Schema for migration 24 — durable activity memories."
  @spec memories_schema_sql() :: String.t()
  def memories_schema_sql, do: @memories_schema_sql

  @doc "Schema for migration 25 — the summarizer singleton state row."
  @spec state_schema_sql() :: String.t()
  def state_schema_sql, do: @state_schema_sql

  # --- events -------------------------------------------------------------

  @doc """
  Insert a batch of spool events idempotently. Each event is a map keyed by a
  subset of `@event_columns`; absent keys bind NULL. `INSERT OR IGNORE` +
  `UNIQUE(boot_id, source_seq)` makes a re-delivered event a no-op. Returns the
  count of rows actually inserted (ignored duplicates do not count).
  """
  @spec insert_events(term(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_events(conn, events) when is_list(events) do
    # Validate element shapes at the boundary, before BEGIN IMMEDIATE — a raise
    # inside the transaction body would otherwise leak an open transaction on
    # the single-writer connection (settle_transaction only rolls back an
    # `{:error, _}` return, not an exception).
    if Enum.all?(events, &is_map/1) do
      in_transaction(conn, fn -> insert_events_in_tx(conn, events) end)
    else
      {:error, :invalid_events}
    end
  end

  defp insert_events_in_tx(conn, events) do
    sql =
      "INSERT OR IGNORE INTO computer_history_events (#{@event_insert_columns}) " <>
        "VALUES (#{@event_insert_placeholders})"

    Enum.reduce_while(events, {:ok, 0}, fn event, {:ok, inserted} ->
      params = Enum.map(@event_columns, fn column -> to_param(Map.get(event, column)) end)

      case execute(conn, sql, params) do
        :ok -> {:cont, {:ok, inserted + changed(conn)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Delete every spool event older than `cutoff_ts` (epoch ms). The 48h retention
  sweep and the byte-ceiling backstop use this. Returns the count deleted.
  """
  @spec sweep_expired_events(term(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_expired_events(conn, cutoff_ts) when is_integer(cutoff_ts) do
    with :ok <- execute(conn, "DELETE FROM computer_history_events WHERE ts < ?", [cutoff_ts]) do
      {:ok, changed(conn)}
    end
  end

  @doc "Count of spool events."
  @spec count_events(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_events(conn) do
    with {:ok, [[count]]} <- query_all(conn, "SELECT count(*) FROM computer_history_events", []) do
      {:ok, count}
    end
  end

  @doc "The oldest spool event's `ts` (epoch ms), or nil when the spool is empty."
  @spec oldest_event_ts(term()) :: {:ok, integer() | nil} | {:error, term()}
  def oldest_event_ts(conn) do
    with {:ok, rows} <- query_all(conn, "SELECT min(ts) FROM computer_history_events", []) do
      case rows do
        [[ts]] -> {:ok, ts}
        _empty -> {:ok, nil}
      end
    end
  end

  @doc """
  Read up to `limit` spool events with `id > after_id`, oldest first — the
  summarizer's id high-water cursor (§10). Returns each row as a map keyed by
  column atom (including `id`). Never a wall-clock `ts` cursor, which would skip
  ms-collision / late-flushed / post-clock-correction events (§7.1).
  """
  @spec events_after_id(term(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def events_after_id(conn, after_id, limit)
      when is_integer(after_id) and after_id >= 0 and is_integer(limit) and limit > 0 do
    sql =
      "SELECT #{@event_read_select} FROM computer_history_events " <>
        "WHERE id > ? ORDER BY id ASC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [after_id, limit]) do
      {:ok, Enum.map(rows, &event_row/1)}
    end
  end

  defp event_row(row), do: Map.new(Enum.zip(@event_read_columns, row))

  @doc """
  Purge a `[from_ts, to_ts]` window (epoch ms), atomically: delete spool events
  in the window, delete activity memories whose provenance window **intersects**
  it, and advance the purge watermark to `to_ts` (§12). The watermark blocks an
  in-flight summarizer write from re-materializing just-purged events. Returns
  the deleted counts.
  """
  @spec purge_window(term(), integer(), integer()) ::
          {:ok, %{events: non_neg_integer(), memories: non_neg_integer()}} | {:error, term()}
  def purge_window(conn, from_ts, to_ts) when is_integer(from_ts) and is_integer(to_ts) do
    in_transaction(conn, fn -> purge_window_in_tx(conn, from_ts, to_ts) end)
  end

  defp purge_window_in_tx(conn, from_ts, to_ts) do
    with :ok <-
           execute(
             conn,
             "DELETE FROM computer_history_events WHERE ts >= ? AND ts <= ?",
             [from_ts, to_ts]
           ),
         events_deleted <- changed(conn),
         :ok <-
           execute(
             conn,
             # Interval intersection: memory [pf, pt] overlaps purge [from, to].
             "DELETE FROM computer_history_memories " <>
               "WHERE provenance_from_ts <= ? AND provenance_to_ts >= ?",
             [to_ts, from_ts]
           ),
         memories_deleted <- changed(conn),
         :ok <-
           execute(
             conn,
             "INSERT INTO computer_history_state (id) VALUES (1) ON CONFLICT(id) DO NOTHING",
             []
           ),
         :ok <-
           execute(
             conn,
             "UPDATE computer_history_state " <>
               "SET purge_watermark_ts = MAX(COALESCE(purge_watermark_ts, 0), ?) WHERE id = 1",
             [to_ts]
           ) do
      {:ok, %{events: events_deleted, memories: memories_deleted}}
    end
  end

  # --- memories -----------------------------------------------------------

  @doc "Count of durable activity memories (excluding superseded)."
  @spec count_memories(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_memories(conn) do
    sql = "SELECT count(*) FROM computer_history_memories WHERE superseded_at IS NULL"

    with {:ok, [[count]]} <- query_all(conn, sql, []) do
      {:ok, count}
    end
  end

  @doc """
  The most recent (non-superseded) activity memories, newest first — the
  Recent Activity section source (§11.1). Reads only derived summaries, never
  the raw spool.
  """
  @spec recent_memories(term(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def recent_memories(conn, limit) when is_integer(limit) and limit > 0 do
    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL ORDER BY provenance_to_ts DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  Non-superseded activity memories whose provenance window intersects
  `[from_ts, to_ts]` (epoch ms), newest first — the `recall_activity` query
  (§11.2). Derived summaries only.
  """
  @spec memories_in_window(term(), integer(), integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def memories_in_window(conn, from_ts, to_ts, limit)
      when is_integer(from_ts) and is_integer(to_ts) and is_integer(limit) and limit > 0 do
    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_from_ts <= ? AND provenance_to_ts >= ? " <>
        "ORDER BY provenance_to_ts DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [to_ts, from_ts, limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  defp memory_row(row), do: Map.new(Enum.zip(@memory_read_columns, row))

  @doc """
  Insert one durable activity memory. `memory` is a map keyed by a subset of
  `@memory_columns`; `created_at`/`provenance_from_ts`/`provenance_to_ts`/
  `summary`/`model` are required by the schema. Returns the new row id.
  """
  @spec insert_memory(term(), map()) :: {:ok, integer()} | {:error, term()}
  def insert_memory(conn, memory) when is_map(memory) do
    sql =
      "INSERT INTO computer_history_memories (#{@memory_insert_columns}) " <>
        "VALUES (#{@memory_insert_placeholders})"

    params = Enum.map(@memory_columns, fn column -> to_param(Map.get(memory, column)) end)

    with :ok <- execute(conn, sql, params),
         {:ok, [[rowid]]} <- query_all(conn, "SELECT last_insert_rowid()", []) do
      {:ok, rowid}
    end
  end

  # --- state --------------------------------------------------------------

  @doc """
  Ensure the singleton state row exists (idempotent upsert), then return it.
  The default `status`/`last_summarized_id`/`updated_at` come from the schema.
  """
  @spec ensure_state(term()) :: {:ok, map()} | {:error, term()}
  def ensure_state(conn) do
    with :ok <-
           execute(
             conn,
             "INSERT INTO computer_history_state (id) VALUES (1) ON CONFLICT(id) DO NOTHING",
             []
           ) do
      fetch_state(conn)
    end
  end

  @doc "Read the singleton state row as a map keyed by column atom."
  @spec fetch_state(term()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch_state(conn) do
    with {:ok, rows} <-
           query_all(conn, "SELECT #{@state_select} FROM computer_history_state WHERE id = 1", []) do
      case rows do
        [row] -> {:ok, state_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp state_row(row), do: Map.new(Enum.zip(@state_columns, row))

  @doc """
  Atomically claim a summarizer cycle: `idle -> running`. A `running` claim
  older than `stale_after_ms` (daemon killed mid-cycle) is reclaimed. Serialized
  by the single-writer GenServer (the skill-curation claim precedent).
  """
  @spec claim_cycle(term(), DateTime.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :concurrent_run | term()}
  def claim_cycle(conn, %DateTime{} = now, stale_after_ms) when is_integer(stale_after_ms) do
    with {:ok, _row} <- ensure_state(conn),
         {:ok, state} <- fetch_state(conn) do
      case claim_kind(state, now, stale_after_ms) do
        :active -> {:error, :concurrent_run}
        :fresh -> write_claim(conn, now, nil)
        :stale -> write_claim(conn, now, "error:stale_claim")
      end
    end
  end

  defp claim_kind(%{status: "running", claimed_at: claimed}, now, stale_after_ms)
       when is_binary(claimed) do
    case DateTime.from_iso8601(claimed) do
      {:ok, claimed_at, _offset} ->
        if DateTime.diff(now, claimed_at, :millisecond) < stale_after_ms,
          do: :active,
          else: :stale

      _unparseable ->
        :stale
    end
  end

  defp claim_kind(_row, _now, _stale_after_ms), do: :fresh

  defp write_claim(conn, now, last_status) do
    now_iso = DateTime.to_iso8601(now)

    {set_sql, params} =
      case last_status do
        nil -> {"", []}
        value -> {", last_status = ?", [value]}
      end

    with :ok <-
           execute(
             conn,
             "UPDATE computer_history_state " <>
               "SET status = 'running', claimed_at = ?, updated_at = ?#{set_sql} WHERE id = 1",
             [now_iso, now_iso] ++ params
           ) do
      fetch_state(conn)
    end
  end

  @doc """
  Write a cycle's result atomically (§10, §12): if a memory was produced and its
  provenance does not intersect a purge issued during the cycle (the watermark
  guard), supersede overlapping memories and insert it; then advance the
  `last_summarized_id` cursor and return the summarizer to `idle`. A `nil`
  memory (validation failed / empty window) only advances the cursor.
  """
  @spec write_cycle_result(
          term(),
          non_neg_integer(),
          map() | nil,
          integer(),
          DateTime.t(),
          String.t()
        ) ::
          {:ok, %{memory_written: boolean()}} | {:error, term()}
  def write_cycle_result(conn, last_id, memory, superseded_at_ms, %DateTime{} = now, last_status) do
    in_transaction(conn, fn ->
      write_cycle_result_in_tx(conn, last_id, memory, superseded_at_ms, now, last_status)
    end)
  end

  defp write_cycle_result_in_tx(conn, last_id, memory, superseded_at_ms, now, last_status) do
    with {:ok, _row} <- ensure_state(conn),
         {:ok, watermark} <- read_watermark(conn),
         {:ok, written?} <- maybe_write_memory(conn, memory, watermark, superseded_at_ms),
         :ok <- advance_cursor(conn, last_id, now, last_status) do
      {:ok, %{memory_written: written?}}
    end
  end

  defp read_watermark(conn) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT purge_watermark_ts FROM computer_history_state WHERE id = 1",
             []
           ) do
      case rows do
        [[watermark]] -> {:ok, watermark}
        _empty -> {:ok, nil}
      end
    end
  end

  # No memory, or its window intersects an issued purge ⇒ do not (re-)materialize.
  defp maybe_write_memory(_conn, nil, _watermark, _superseded_at), do: {:ok, false}

  defp maybe_write_memory(conn, %{} = memory, watermark, superseded_at) do
    if purged?(memory, watermark) do
      {:ok, false}
    else
      with :ok <- supersede_overlapping(conn, memory, superseded_at),
           {:ok, _id} <- insert_memory(conn, memory) do
        {:ok, true}
      end
    end
  end

  defp purged?(_memory, nil), do: false

  defp purged?(%{provenance_from_ts: from_ts}, watermark) when is_integer(watermark),
    do: from_ts <= watermark

  defp purged?(_memory, _watermark), do: false

  defp supersede_overlapping(conn, %{provenance_from_ts: from_ts, provenance_to_ts: to_ts}, at_ms) do
    execute(
      conn,
      "UPDATE computer_history_memories SET superseded_at = ? " <>
        "WHERE superseded_at IS NULL AND provenance_from_ts <= ? AND provenance_to_ts >= ?",
      [at_ms, to_ts, from_ts]
    )
  end

  # Cursor + outcome only; the `status` (idle/running) lifecycle is owned by the
  # scheduler's claim/release so a paused or errored cycle can't leave a
  # self-finalized idle that masks a still-held claim.
  defp advance_cursor(conn, last_id, now, last_status) do
    now_iso = DateTime.to_iso8601(now)

    execute(
      conn,
      "UPDATE computer_history_state SET last_summarized_id = ?, last_run_at = ?, " <>
        "last_status = ?, updated_at = ? WHERE id = 1",
      [last_id, now_iso, last_status, now_iso]
    )
  end

  @doc "Release a claimed cycle: `running -> idle` (the scheduler's finalize)."
  @spec release_claim(term(), DateTime.t()) :: :ok | {:error, term()}
  def release_claim(conn, %DateTime{} = now) do
    now_iso = DateTime.to_iso8601(now)

    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET status = 'idle', updated_at = ? WHERE id = 1",
        [now_iso]
      )
    end
  end

  @doc """
  Set (or clear, with nil) the capture pause horizon — an ISO8601 string. A
  `/history pause 30m` persists this so the pause survives a mid-pause daemon
  restart rather than silently lapsing (§7.3).
  """
  @spec set_pause_until(term(), String.t() | nil) :: :ok | {:error, term()}
  def set_pause_until(conn, pause_until) do
    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET pause_until = ?, updated_at = " <>
          "strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = 1",
        [pause_until]
      )
    end
  end

  @doc "Record why the summarizer is paused (e.g. no-local-model, route-down), surfaced to status."
  @spec set_paused_reason(term(), String.t() | nil) :: :ok | {:error, term()}
  def set_paused_reason(conn, reason) do
    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET paused_reason = ?, updated_at = " <>
          "strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = 1",
        [reason]
      )
    end
  end

  # --- primitives (single-writer conn; the TemporalSql shape) -------------

  defp in_transaction(conn, fun) do
    case execute(conn, "BEGIN IMMEDIATE", []) do
      :ok -> settle_transaction(conn, fun.())
      {:error, reason} -> {:error, reason}
    end
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
          "computer_history transaction rollback failed: #{inspect(rollback_error)} " <>
            "(original error: #{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  defp changed(conn) do
    case query_all(conn, "SELECT changes()", []) do
      {:ok, [[count]]} when is_integer(count) -> count
      _other -> 0
    end
  end

  defp query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        Sqlite3.fetch_all(conn, stmt)
      end
    end)
  end

  defp execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        step_result(Sqlite3.step(conn, stmt))
      end
    end)
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

  defp to_param(true), do: 1
  defp to_param(false), do: 0
  defp to_param(other), do: other
end
