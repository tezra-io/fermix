defmodule FermixCore.Memory.Repo.ComputerHistorySql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s computer-history operations
  # (MILESTONE_32 §7). Every function takes the caller's `conn` and is invoked
  # only from Repo's `handle_call`s, so the single-writer architecture is
  # unchanged; the split keeps `repo.ex` bounded (the TemporalSql precedent).
  #
  # Four tables, five additive migrations (23/24/25/27/28):
  #   * computer_history_events   — the <=48h raw interaction-event spool
  #   * computer_history_memories — durable, derived activity summaries
  #   * computer_history_state    — the summarizer singleton (claim + cursor)
  #   * computer_history_access   — metadata-only audit rows for agent reads (§22.8)
  #
  # The spool's identity is a DB-generated `id` (AUTOINCREMENT), NOT the
  # capturer's per-boot `source_seq` (which restarts at 1 each boot): the id is
  # the summarizer's high-water cursor, and `UNIQUE(boot_id, source_seq)` makes
  # a re-delivered event idempotent. `ts` (epoch ms) is for windowed retention
  # and range queries only, never the processing cursor.
  #
  # Memories ACCRETE: one memory per summarized batch, never superseded at write
  # time. Because the cursor is the id high-water mark, every event is summarized
  # exactly once, so a new memory can never cover an earlier memory's source
  # events — a ts-intersection supersede could only destroy information (a
  # late-flushed event whose `ts` reaches back, or a shared boundary millisecond,
  # hid a whole earlier memory). The `superseded_at` column and every
  # `WHERE superseded_at IS NULL` filter stay: the schema is additive and the
  # EXPLICIT roll-up (§24.3) is the one case that needs them.
  #
  # Two KINDS share the memories table (§24.1). `kind = 'session'` is the
  # immutable journal — one note per closed sitting, still accreting, never
  # superseded. `kind = 'thread'` is the mutable current-work layer: each daily
  # roll-up supersedes exactly the previous thread rows and inserts the new set,
  # so a thread the model stops re-emitting retires while the journal underneath
  # is untouched. Every windowed reader takes a kind so today's callers keep
  # reading sessions; purge is kind-blind and intersects both by provenance.
  #
  # `computer_history_memories_fts` is an FTS5 external-content companion over
  # summary/subject/titles/urls, mirroring the `memories_fts` trigger pattern in
  # `repo.ex`. Its only reader is `search_memories/3` (Recall's "about" query),
  # deliberately NOT wired into `Memory.Search`, so a general memory search can
  # never return activity.

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
    :superseded_at,
    # Migration 28, APPENDED so a migrated store and a fresh one share column
    # order (the reminder-snooze precedent).
    :kind,
    :subject,
    :source_ids,
    :last_touched_ts
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
    :updated_at,
    # Migration 28: the roll-up clock, its attempt clock (what rate-limits a
    # roll-up whose reply was unusable), and the open-sitting diagnostic (§24.1).
    :last_rollup_ts,
    :last_rollup_attempt_ts,
    :session_open_since_ts
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

  # Metadata-only audit of agent reads (§22.8, the cua-RFC lesson): when, which
  # sink, the resolved window, and how many summaries were returned — never any
  # activity content. Lets the owner answer "what has the agent read from my
  # history" from the store itself, independent of rotating traces.
  @access_schema_sql """
  CREATE TABLE IF NOT EXISTS computer_history_access (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    sink TEXT NOT NULL,
    window_from_ts INTEGER,
    window_to_ts INTEGER,
    result_count INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS idx_computer_history_access_ts
    ON computer_history_access(ts);
  """

  # Migration 28 (§24.1), additive in three parts: the four thread columns on
  # the memories table, the two marks on the state row, and the FTS5 companion
  # with its insert/update/delete triggers — the `memories_fts` pattern, rebuilt
  # once so rows written before it are searchable.
  @sessions_schema_sql """
  ALTER TABLE computer_history_memories
    ADD COLUMN kind TEXT NOT NULL DEFAULT 'session';
  ALTER TABLE computer_history_memories ADD COLUMN subject TEXT;
  ALTER TABLE computer_history_memories ADD COLUMN source_ids TEXT;
  ALTER TABLE computer_history_memories ADD COLUMN last_touched_ts INTEGER;

  CREATE INDEX IF NOT EXISTS idx_computer_history_memories_kind
    ON computer_history_memories(kind, superseded_at, last_touched_ts);

  ALTER TABLE computer_history_state ADD COLUMN last_rollup_ts INTEGER;
  ALTER TABLE computer_history_state ADD COLUMN last_rollup_attempt_ts INTEGER;
  ALTER TABLE computer_history_state ADD COLUMN session_open_since_ts INTEGER;

  CREATE VIRTUAL TABLE IF NOT EXISTS computer_history_memories_fts
  USING fts5(summary, subject, titles, urls,
             content=computer_history_memories, content_rowid=id);

  CREATE TRIGGER IF NOT EXISTS computer_history_memories_ai
  AFTER INSERT ON computer_history_memories BEGIN
    INSERT INTO computer_history_memories_fts(rowid, summary, subject, titles, urls)
    VALUES (new.id, new.summary, new.subject, new.titles, new.urls);
  END;

  CREATE TRIGGER IF NOT EXISTS computer_history_memories_ad
  AFTER DELETE ON computer_history_memories BEGIN
    INSERT INTO computer_history_memories_fts(
      computer_history_memories_fts, rowid, summary, subject, titles, urls)
    VALUES('delete', old.id, old.summary, old.subject, old.titles, old.urls);
  END;

  CREATE TRIGGER IF NOT EXISTS computer_history_memories_au
  AFTER UPDATE ON computer_history_memories BEGIN
    INSERT INTO computer_history_memories_fts(
      computer_history_memories_fts, rowid, summary, subject, titles, urls)
    VALUES('delete', old.id, old.summary, old.subject, old.titles, old.urls);
    INSERT INTO computer_history_memories_fts(rowid, summary, subject, titles, urls)
    VALUES (new.id, new.summary, new.subject, new.titles, new.urls);
  END;

  INSERT INTO computer_history_memories_fts(computer_history_memories_fts) VALUES('rebuild');
  """

  # The two kinds, as stored. `:all` is the kind-blind read (counts and purge).
  @kinds %{session: "session", thread: "thread"}
  @default_kind "session"
  # Code Rule 2: an id lookup is built from caller-supplied ids, so the SQL it
  # generates has to have a ceiling.
  @max_ids_per_lookup 500

  @doc "Schema for migration 23 — the raw event spool."
  @spec events_schema_sql() :: String.t()
  def events_schema_sql, do: @events_schema_sql

  @doc "Schema for migration 24 — durable activity memories."
  @spec memories_schema_sql() :: String.t()
  def memories_schema_sql, do: @memories_schema_sql

  @doc "Schema for migration 25 — the summarizer singleton state row."
  @spec state_schema_sql() :: String.t()
  def state_schema_sql, do: @state_schema_sql

  @doc "Schema for migration 27 — the agent-read access audit."
  @spec access_schema_sql() :: String.t()
  def access_schema_sql, do: @access_schema_sql

  @doc "Schema for migration 28 — memory kinds, threads, state marks, the FTS companion."
  @spec sessions_schema_sql() :: String.t()
  def sessions_schema_sql, do: @sessions_schema_sql

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
  Delete every spool event older than `cutoff_ts` (epoch ms) — the 48h retention
  sweep. Returns the count deleted. (The byte-ceiling backstop is
  `sweep_spool_over_bytes/2`, which deletes by id, not time.)
  """
  @spec sweep_expired_events(term(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_expired_events(conn, cutoff_ts) when is_integer(cutoff_ts) do
    with :ok <- execute(conn, "DELETE FROM computer_history_events WHERE ts < ?", [cutoff_ts]) do
      {:ok, changed(conn)}
    end
  end

  # Estimated content bytes per spool row: the four unbounded text columns plus a
  # fixed overhead for the bounded rest. An estimate is fine — this is a backstop
  # ceiling, not accounting.
  @row_bytes_sql "LENGTH(COALESCE(text,'')) + LENGTH(COALESCE(window_title,'')) + " <>
                   "LENGTH(COALESCE(page_title,'')) + LENGTH(COALESCE(url,'')) + 160"

  @doc """
  The byte-ceiling backstop (§22.8): keep the newest spool events whose estimated
  content bytes fit `ceiling_bytes`; delete everything older, exactly (by id, so
  ms-timestamp collisions can't over- or under-delete). A no-op while the spool
  fits. Returns the count deleted — a non-zero count is data loss inside the 48h
  retention promise and the caller must say so loudly.
  """
  @spec sweep_spool_over_bytes(term(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sweep_spool_over_bytes(conn, ceiling_bytes)
      when is_integer(ceiling_bytes) and ceiling_bytes > 0 do
    # Newest-first running total; the row that crosses the ceiling and all older
    # rows are deleted. The capturer's 1 MiB frame cap makes the degenerate
    # single-row-over-ceiling case unreachable at any sane ceiling.
    sql =
      "DELETE FROM computer_history_events WHERE id IN (" <>
        "SELECT id FROM (" <>
        "SELECT id, SUM(#{@row_bytes_sql}) OVER (ORDER BY id DESC) AS running_bytes " <>
        "FROM computer_history_events" <>
        ") WHERE running_bytes > ?)"

    with :ok <- execute(conn, sql, [ceiling_bytes]) do
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
  The `text` of the newest `limit` spool events that carry any — the source side
  of the verbatim guard when the guarded prose was NOT built from one batch (the
  roll-up, §24.3, reasons over notes and must still be checked against whatever
  spool text is still present). Newest first: a thread describes current work.
  """
  @spec recent_event_texts(term(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def recent_event_texts(conn, limit) when is_integer(limit) and limit > 0 do
    sql =
      "SELECT text FROM computer_history_events " <>
        "WHERE text IS NOT NULL AND text != '' ORDER BY id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [limit]) do
      {:ok, Enum.map(rows, fn [text] -> text end)}
    end
  end

  @doc """
  Summarizer lag: `{count, oldest_ts | nil}` over the spool events the cursor has
  not reached (`id > last_summarized_id`). The cursor is read here, in the same
  call, so the two halves can never be read a batch apart; an absent state row
  reads as cursor 0 (nothing summarized yet). Surfaced by `/history status` —
  a backlog is otherwise invisible until the spool starts expiring under it.
  """
  @spec unsummarized_stats(term()) ::
          {:ok, {non_neg_integer(), integer() | nil}} | {:error, term()}
  def unsummarized_stats(conn) do
    with {:ok, cursor} <- summarized_cursor(conn),
         {:ok, [[count, oldest_ts]]} <-
           query_all(
             conn,
             "SELECT count(*), min(ts) FROM computer_history_events WHERE id > ?",
             [cursor]
           ) do
      {:ok, {count, oldest_ts}}
    end
  end

  @doc """
  Per-app coverage states inside the window (§8.4a): the distinct
  `{bundle_id, gap_reason}` pairs of `observer.gap` rows that name an app AND a
  coverage reason (`title_only`, `private_unknown`, `ax_refused:<notifications>`),
  with `ts >= since_ts`. Machine-wide gaps (sleep, wake, write_failure) name no app
  and are excluded — this answers "which apps can Fermix only see titles in, and
  which browsers can it not classify as private", which `/history status` has to
  tell the owner rather than silently record nothing.

  This reason set and `/history status`'s clauses are ONE contract: the command
  raises on a reason it has no clause for, so a reason added here without a clause
  fails loud instead of rendering as the wrong coverage sentence.

  The `ax_refused` prefix is matched with `substr/3`, not `LIKE`: `_` is a LIKE
  wildcard, so `'ax_refused%'` would also match reasons that merely look like it.
  """
  @spec coverage_gaps(term(), integer()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def coverage_gaps(conn, since_ts) when is_integer(since_ts) do
    sql =
      "SELECT DISTINCT bundle_id, gap_reason FROM computer_history_events " <>
        "WHERE type = 'observer.gap' AND ts >= ? AND bundle_id IS NOT NULL " <>
        "AND (gap_reason = 'title_only' OR gap_reason = 'private_unknown' " <>
        "OR substr(gap_reason, 1, 10) = 'ax_refused') " <>
        "ORDER BY bundle_id ASC, gap_reason ASC"

    with {:ok, rows} <- query_all(conn, sql, [since_ts]) do
      {:ok, Enum.map(rows, fn [bundle_id, reason] -> {bundle_id, reason} end)}
    end
  end

  defp summarized_cursor(conn) do
    sql = "SELECT last_summarized_id FROM computer_history_state WHERE id = 1"

    with {:ok, rows} <- query_all(conn, sql, []) do
      case rows do
        [[cursor]] when is_integer(cursor) -> {:ok, cursor}
        _absent -> {:ok, 0}
      end
    end
  end

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
             # Access rows recorded in the window go too: purge means "erase
             # everything this feature stored in that window", audit included.
             "DELETE FROM computer_history_access WHERE ts >= ? AND ts <= ?",
             [from_ts, to_ts]
           ),
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

  @doc """
  Count of durable activity memories. `kind` is `:all` (both kinds — the
  store-wide count), `:session` or `:thread`; `scope` is `:active` (the default —
  non-superseded) or `:all`, which counts retired thread rows too and is how
  "retired, never deleted" (§24.3, inv. 23) is checked at all.
  """
  @spec count_memories(term(), :all | :session | :thread, :active | :all) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_memories(conn, kind \\ :all, scope \\ :active)
      when kind in [:all, :session, :thread] and scope in [:active, :all] do
    {kind_sql, kind_params} = kind_clause(kind)
    sql = "SELECT count(*) FROM computer_history_memories WHERE #{scope_clause(scope)}#{kind_sql}"

    with {:ok, [[count]]} <- query_all(conn, sql, kind_params) do
      {:ok, count}
    end
  end

  defp scope_clause(:active), do: "superseded_at IS NULL"
  defp scope_clause(:all), do: "1 = 1"

  # The kind filter every windowed reader carries, so today's callers keep
  # reading the journal and nothing has to guess which layer it is looking at.
  defp kind_clause(:all), do: {"", []}
  defp kind_clause(kind), do: {" AND kind = ?", [Map.fetch!(@kinds, kind)]}

  @doc """
  The most recent (non-superseded) activity memories whose provenance ends at or
  after `since_ts` (epoch ms), newest first — the Recent Activity section source
  (§11.1). The horizon is the caller's: an undated summary from an arbitrarily
  old window is not "recent activity". Reads only derived summaries, never the
  raw spool.
  """
  @spec recent_memories(term(), integer(), pos_integer(), :all | :session | :thread) ::
          {:ok, [map()]} | {:error, term()}
  def recent_memories(conn, since_ts, limit, kind \\ :session)
      when is_integer(since_ts) and is_integer(limit) and limit > 0 and
             kind in [:all, :session, :thread] do
    {kind_sql, kind_params} = kind_clause(kind)

    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_to_ts >= ?#{kind_sql} " <>
        "ORDER BY provenance_to_ts DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [since_ts] ++ kind_params ++ [limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  Non-superseded activity memories whose provenance window intersects
  `[from_ts, to_ts]` (epoch ms), newest first — the `recall_activity` query
  (§11.2). Derived summaries only.
  """
  @spec memories_in_window(term(), integer(), integer(), pos_integer(), :all | :session | :thread) ::
          {:ok, [map()]} | {:error, term()}
  def memories_in_window(conn, from_ts, to_ts, limit, kind \\ :session)
      when is_integer(from_ts) and is_integer(to_ts) and is_integer(limit) and limit > 0 and
             kind in [:all, :session, :thread] do
    {kind_sql, kind_params} = kind_clause(kind)

    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_from_ts <= ? AND provenance_to_ts >= ?" <>
        "#{kind_sql} ORDER BY provenance_to_ts DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [to_ts, from_ts] ++ kind_params ++ [limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  How many non-superseded memories intersect `[from_ts, to_ts]` — the honest
  denominator behind `memories_in_window/4`'s limited page, so recall can say
  when older entries were omitted instead of truncating silently (§11.2).
  """
  @spec count_memories_in_window(term(), integer(), integer(), :all | :session | :thread) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_memories_in_window(conn, from_ts, to_ts, kind \\ :session)
      when is_integer(from_ts) and is_integer(to_ts) and kind in [:all, :session, :thread] do
    {kind_sql, kind_params} = kind_clause(kind)

    sql =
      "SELECT count(*) FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_from_ts <= ? AND provenance_to_ts >= ?" <>
        kind_sql

    with {:ok, [[count]]} <- query_all(conn, sql, [to_ts, from_ts] ++ kind_params) do
      {:ok, count}
    end
  end

  @doc """
  The active thread set (§24.3): non-superseded `kind = 'thread'` rows, most
  recently touched first, bounded by `limit`. This is what "what am I working
  on" reads; the journal is read by the windowed queries above.
  """
  @spec active_threads(term(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def active_threads(conn, limit) when is_integer(limit) and limit > 0 do
    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND kind = 'thread' " <>
        "ORDER BY last_touched_ts DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  Session notes written after `since_ts` (`created_at`, epoch ms), **newest first**
  and bounded — the roll-up's input (§24.3). Ordered by write time, not by the
  window they cover: the roll-up reasons about what has been learned since the last
  one. Newest first is what makes the bound safe — when a day produced more notes
  than one call can carry, the ones most likely to describe current work are the
  ones that reach it, and the rest stay in the journal. The caller re-orders for
  rendering.
  """
  @spec session_notes_since(term(), integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def session_notes_since(conn, since_ts, limit)
      when is_integer(since_ts) and is_integer(limit) and limit > 0 do
    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND kind = 'session' AND created_at > ? " <>
        "ORDER BY created_at DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [since_ts, limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  How many session notes exist after `since_ts` — the honest denominator behind
  `session_notes_since/3`'s bounded page, so the roll-up can say it read the newest
  N of M instead of implying it read everything.
  """
  @spec count_session_notes_since(term(), integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_session_notes_since(conn, since_ts) when is_integer(since_ts) do
    sql =
      "SELECT count(*) FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND kind = 'session' AND created_at > ?"

    with {:ok, [[count]]} <- query_all(conn, sql, [since_ts]) do
      {:ok, count}
    end
  end

  @doc """
  Memories of `kind` with these ids, in the order given, **regardless of
  supersession** — existence is the question (§24.3): the roll-up resolves a
  thread's stored citations against the store, so a note the owner purged or an id
  the model invented simply is not found. A session note is never superseded, so
  for the session kind this is an existence lookup; for threads it is also how a
  retired row is read back.
  """
  @spec memories_by_ids(term(), [integer()], :all | :session | :thread) ::
          {:ok, [map()]} | {:error, term()}
  def memories_by_ids(conn, ids, kind \\ :session)
      when is_list(ids) and kind in [:all, :session, :thread] do
    ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.take(@max_ids_per_lookup)
    |> fetch_by_ids(conn, kind)
  end

  defp fetch_by_ids([], _conn, _kind), do: {:ok, []}

  defp fetch_by_ids(ids, conn, kind) do
    {kind_sql, kind_params} = kind_clause(kind)
    placeholders = Enum.map_join(ids, ", ", fn _id -> "?" end)

    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE id IN (#{placeholders})#{kind_sql}"

    with {:ok, rows} <- query_all(conn, sql, ids ++ kind_params) do
      {:ok, order_by_ids(Enum.map(rows, &memory_row/1), ids)}
    end
  end

  # The caller asked in citation order and reads the result in citation order.
  defp order_by_ids(rows, ids) do
    by_id = Map.new(rows, &{&1.id, &1})
    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  @doc """
  Topic search (§24.1): the FTS5 companion, non-superseded rows of BOTH kinds,
  newest first. `query` is user text, never FTS syntax — it is split on
  whitespace and each token is passed as a quoted phrase, so `OR`, `NEAR(`, a
  column filter or a stray quote are all literal words. A query with no
  searchable token is refused rather than run as an empty MATCH.
  """
  @spec search_memories(term(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :empty_query | term()}
  def search_memories(conn, query, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    case match_expression(query) do
      {:ok, match} -> search_memories_matching(conn, match, limit)
      {:error, :empty_query} -> {:error, :empty_query}
    end
  end

  @doc """
  How many non-superseded memories of either kind match `query` — the honest
  denominator behind `search_memories/3`'s bounded page (§24.4). Same sanitizing as
  the search itself, so the count and the page can never disagree about what the
  query meant.
  """
  @spec count_search_memories(term(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :empty_query | term()}
  def count_search_memories(conn, query) when is_binary(query) do
    case match_expression(query) do
      {:ok, match} -> count_matching(conn, match)
      {:error, :empty_query} -> {:error, :empty_query}
    end
  end

  defp count_matching(conn, match) do
    sql =
      "SELECT count(*) FROM computer_history_memories_fts f " <>
        "JOIN computer_history_memories m ON m.id = f.rowid " <>
        "WHERE computer_history_memories_fts MATCH ? AND m.superseded_at IS NULL"

    with {:ok, [[count]]} <- query_all(conn, sql, [match]) do
      {:ok, count}
    end
  end

  defp search_memories_matching(conn, match, limit) do
    sql =
      "SELECT #{Enum.map_join(@memory_read_columns, ", ", &("m." <> Atom.to_string(&1)))} " <>
        "FROM computer_history_memories_fts f " <>
        "JOIN computer_history_memories m ON m.id = f.rowid " <>
        "WHERE computer_history_memories_fts MATCH ? AND m.superseded_at IS NULL " <>
        "ORDER BY m.provenance_to_ts DESC, m.id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [match, limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  # One quoted phrase per whitespace-separated token, ANDed: quoting is what
  # makes user text data. A token with no letter or digit cannot be tokenized by
  # FTS5 and would make the phrase a syntax error, so it is dropped.
  defp match_expression(query) do
    tokens =
      query
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.filter(&searchable_token?/1)

    case tokens do
      [] -> {:error, :empty_query}
      tokens -> {:ok, Enum.map_join(tokens, " AND ", &quoted_token/1)}
    end
  end

  defp searchable_token?(token), do: Regex.match?(~r/[\p{L}\p{N}]/u, token)

  defp quoted_token(token), do: ~s("#{String.replace(token, ~s("), ~s(""))}")

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

    with :ok <- execute(conn, sql, memory_params(memory)),
         {:ok, [[rowid]]} <- query_all(conn, "SELECT last_insert_rowid()", []) do
      {:ok, rowid}
    end
  end

  # `kind` is NOT NULL with a schema default, but this INSERT names every column,
  # so an absent key would bind NULL and be refused: the writer supplies the
  # default. Every other new column is nullable (a session note has no subject,
  # no sources and no last-touched).
  defp memory_params(memory) do
    Enum.map(@memory_columns, fn
      :kind -> to_param(Map.get(memory, :kind, @default_kind))
      column -> to_param(Map.get(memory, column))
    end)
  end

  # --- access audit (§22.8) -----------------------------------------------

  @doc """
  Record one agent read of history: `ts` (epoch ms), `sink`
  (`"recall_activity"` / `"recent_activity"`), the resolved window bounds (nil
  for the windowless section read), and the result count. Metadata only — never
  content.
  """
  @spec record_access(term(), map()) :: :ok | {:error, term()}
  def record_access(conn, %{ts: ts, sink: sink, result_count: count} = access)
      when is_integer(ts) and is_binary(sink) and is_integer(count) do
    execute(
      conn,
      "INSERT INTO computer_history_access " <>
        "(ts, sink, window_from_ts, window_to_ts, result_count) VALUES (?, ?, ?, ?, ?)",
      [ts, sink, Map.get(access, :window_from_ts), Map.get(access, :window_to_ts), count]
    )
  end

  @doc "Access-audit stats for `/history status`: `{count, last_read_ts | nil}`."
  @spec access_stats(term()) :: {:ok, {non_neg_integer(), integer() | nil}} | {:error, term()}
  def access_stats(conn) do
    with {:ok, [[count, last_ts]]} <-
           query_all(conn, "SELECT count(*), max(ts) FROM computer_history_access", []) do
      {:ok, {count, last_ts}}
    end
  end

  @doc """
  Bound the audit (Code Rule 2): keep the newest `max_rows` access rows, delete
  the rest. Returns the count deleted.
  """
  @spec cap_access_rows(term(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cap_access_rows(conn, max_rows) when is_integer(max_rows) and max_rows > 0 do
    sql =
      "DELETE FROM computer_history_access WHERE id NOT IN (" <>
        "SELECT id FROM computer_history_access ORDER BY id DESC LIMIT ?)"

    with :ok <- execute(conn, sql, [max_rows]) do
      {:ok, changed(conn)}
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
  Write a sitting's result atomically (§10, §12): if a note was produced and its
  provenance does not intersect a purge issued during the cycle (the watermark
  guard), insert it beside the existing memories; then advance the
  `last_summarized_id` cursor to the last summarized event. A `nil` memory
  (empty/abstained output) only advances the cursor. Nothing is superseded here
  — see the module comment.

  A `nil` `last_status` advances the cursor and **keeps** the recorded outcome: it
  is how consuming a boundary marker — which is not a sitting and has no outcome —
  avoids overwriting the last real one (§24.2).
  """
  @spec write_cycle_result(
          term(),
          non_neg_integer(),
          map() | nil,
          DateTime.t(),
          String.t() | nil
        ) ::
          {:ok, %{memory_written: boolean()}} | {:error, term()}
  def write_cycle_result(conn, last_id, memory, %DateTime{} = now, last_status) do
    in_transaction(conn, fn ->
      write_cycle_result_in_tx(conn, last_id, memory, now, last_status)
    end)
  end

  defp write_cycle_result_in_tx(conn, last_id, memory, now, last_status) do
    with {:ok, _row} <- ensure_state(conn),
         {:ok, watermark} <- read_watermark(conn),
         {:ok, written?} <- maybe_write_memory(conn, memory, watermark),
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
  defp maybe_write_memory(_conn, nil, _watermark), do: {:ok, false}

  defp maybe_write_memory(conn, %{} = memory, watermark) do
    if purged?(memory, watermark) do
      {:ok, false}
    else
      with {:ok, _id} <- insert_memory(conn, memory), do: {:ok, true}
    end
  end

  defp purged?(_memory, nil), do: false

  defp purged?(%{provenance_from_ts: from_ts}, watermark) when is_integer(watermark),
    do: from_ts <= watermark

  defp purged?(_memory, _watermark), do: false

  # Cursor + outcome only; the `status` (idle/running) lifecycle is owned by the
  # scheduler's claim/release so a paused or errored cycle can't leave a
  # self-finalized idle that masks a still-held claim.
  defp advance_cursor(conn, last_id, now, last_status) do
    now_iso = DateTime.to_iso8601(now)

    execute(
      conn,
      "UPDATE computer_history_state SET last_summarized_id = ?, last_run_at = ?, " <>
        "last_status = COALESCE(?, last_status), updated_at = ? WHERE id = 1",
      [last_id, now_iso, last_status, now_iso]
    )
  end

  @doc """
  Write one roll-up atomically (§24.3): supersede every current thread row at
  `now_ts`, insert the new set, and stamp `last_rollup_ts`. Session notes are
  never touched — the journal under the threads is what makes retirement safe.
  An empty set is REFUSED rather than superseding the whole active set: "the
  model returned nothing" must not read as "the owner is working on nothing".

  The **purge watermark is re-read here**, inside the transaction, and a thread
  whose provenance reaches into a purge issued while the roll-up call was in
  flight is dropped — the same read-infer-write race `write_cycle_result` closes
  for notes (§12). A roll-up whose every thread was purged supersedes nothing and
  does not stamp the mark: the erased window must not come back as a thread
  citing a deleted row.

  Returns how many rows were written, how many retired, how many the watermark
  dropped, and the subjects actually stored (so the caller's log names what the
  store holds, not what the model proposed).
  """
  @spec write_rollup(term(), [map()], integer()) ::
          {:ok,
           %{
             written: non_neg_integer(),
             retired: non_neg_integer(),
             purged: non_neg_integer(),
             subjects: [String.t()]
           }}
          | {:error, term()}
  def write_rollup(conn, threads, now_ts) when is_list(threads) and is_integer(now_ts) do
    cond do
      threads == [] -> {:error, :no_threads}
      not Enum.all?(threads, &is_map/1) -> {:error, :invalid_threads}
      true -> in_transaction(conn, fn -> write_rollup_in_tx(conn, threads, now_ts) end)
    end
  end

  defp write_rollup_in_tx(conn, threads, now_ts) do
    with {:ok, _row} <- ensure_state(conn),
         {:ok, watermark} <- read_watermark(conn) do
      threads
      |> Enum.reject(&purged?(&1, watermark))
      |> write_surviving_threads(conn, now_ts, length(threads))
    end
  end

  # Every proposed thread drew on a purged window: nothing is superseded and the
  # mark stays put, so the next roll-up rebuilds from what survived.
  defp write_surviving_threads([], _conn, _now_ts, proposed),
    do: {:ok, %{written: 0, retired: 0, purged: proposed, subjects: []}}

  defp write_surviving_threads(threads, conn, now_ts, proposed) do
    with :ok <- supersede_threads(conn, now_ts),
         retired <- changed(conn),
         {:ok, written} <- insert_threads(conn, threads),
         :ok <- stamp_rollup(conn, now_ts) do
      {:ok,
       %{
         written: written,
         retired: retired,
         purged: proposed - length(threads),
         subjects: Enum.map(threads, &Map.get(&1, :subject))
       }}
    end
  end

  defp supersede_threads(conn, now_ts) do
    execute(
      conn,
      "UPDATE computer_history_memories SET superseded_at = ? " <>
        "WHERE kind = 'thread' AND superseded_at IS NULL",
      [now_ts]
    )
  end

  defp insert_threads(conn, threads) do
    Enum.reduce_while(threads, {:ok, 0}, fn thread, {:ok, written} ->
      case insert_memory(conn, Map.put(thread, :kind, "thread")) do
        {:ok, _id} -> {:cont, {:ok, written + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stamp_rollup(conn, now_ts) do
    execute(
      conn,
      "UPDATE computer_history_state SET last_rollup_ts = ?, updated_at = " <>
        "strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = 1",
      [now_ts]
    )
  end

  @doc """
  Record that a roll-up CALL was made at `ts`, whatever came back (§24.3). This is
  what bounds a broken reply to one attempt a day; `last_rollup_ts` is a different
  mark that moves only on a real write, because it is also the notes cursor.
  """
  @spec stamp_rollup_attempt(term(), integer()) :: :ok | {:error, term()}
  def stamp_rollup_attempt(conn, ts) when is_integer(ts) do
    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET last_rollup_attempt_ts = ?, updated_at = " <>
          "strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = 1",
        [ts]
      )
    end
  end

  @doc """
  Set (or clear, with nil) the first `ts` of the sitting the summarizer is still
  waiting on — a diagnostic for `/history status`, never a cursor (§24.1).
  """
  @spec set_session_open_since(term(), integer() | nil) :: :ok | {:error, term()}
  def set_session_open_since(conn, ts) when is_integer(ts) or is_nil(ts) do
    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET session_open_since_ts = ?, updated_at = " <>
          "strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = 1",
        [ts]
      )
    end
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
