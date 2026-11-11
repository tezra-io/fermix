defmodule FermixCore.Memory.Repo.ComputerHistorySql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s computer-history operations
  # (MILESTONE_32 §7). Every function takes the caller's `conn` and is invoked
  # only from Repo's `handle_call`s, so the single-writer architecture is
  # unchanged; the split keeps `repo.ex` bounded (the TemporalSql precedent).
  #
  # Five tables, six migrations (23/24/25/27/28 additive; 32 moves the purge
  # watermark into the purges table and leaves its old column unread):
  #   * computer_history_events   — the <=48h raw interaction-event spool
  #   * computer_history_memories — durable, derived activity summaries
  #   * computer_history_state    — the summarizer singleton (claim + cursor)
  #   * computer_history_access   — metadata-only audit rows for agent reads (§22.8)
  #   * computer_history_purges   — the recorded purge intervals (§12)
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
  alias FermixCore.Memory.Repo.FtsMatch

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
    :last_touched_ts,
    # Migration 59 (M97 §8.4), APPENDED likewise: the machine a note was recorded
    # on ("" for the home's own machine, else a computer's id) and the key of the
    # sitting it summarizes, so a sitting submitted twice makes one note.
    :computer_id,
    :sitting
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

  # Migration 32 (§12): recorded purge intervals replace the one high-water purge
  # watermark. One row per purge, in issue order (`id`): `[from_ts, to_ts]` is the
  # window it erased, inclusive like its DELETE, and `issued_at` is when (epoch ms).
  # The spool insert refuses a row stamped inside any interval; a note or thread
  # write refuses when an interval issued after its batch was read reaches it. A
  # stored watermark W (the `purge all` sentinel included) becomes one interval
  # [0, min(W, now)] issued now. Its column stays, unread (nothing reads or writes
  # a watermark any more), so an engine an upgrade rolled back to still opens the
  # store; a later release drops it. Every store has the column (migration 25).
  @purges_schema_sql_template """
  CREATE TABLE IF NOT EXISTS computer_history_purges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_ts INTEGER NOT NULL,
    to_ts INTEGER NOT NULL,
    issued_at INTEGER NOT NULL,
    CHECK (from_ts <= to_ts)
  );
  INSERT INTO computer_history_purges (from_ts, to_ts, issued_at)
    SELECT 0, MIN(purge_watermark_ts, {{migrated_at}}), {{migrated_at}}
    FROM computer_history_state
    WHERE id = 1 AND purge_watermark_ts IS NOT NULL;
  -- purge_watermark_ts stays, unread, so a rolled-back engine still opens the store.
  """

  # Migration 59 (M97 §8.1, §8.4), in memory.db, after the raw spool left for
  # each machine's own store (`ComputerHistory.Spool`, carried by the Repo before
  # this runs): the raw events table goes, the purge record a move or an earlier
  # purge left behind goes (each machine's store fences its own raw events), the
  # single state row keeps only the home's roll-up marks, and every note, read
  # audit and purge names its machine. "" is the home's own machine; a purge or a
  # read with no computer (NULL) is about every machine.
  @machines_schema_sql """
  DROP TABLE IF EXISTS computer_history_events;
  DELETE FROM computer_history_purges;
  UPDATE computer_history_state
    SET last_summarized_id = 0, pause_until = NULL, paused_reason = NULL,
        session_open_since_ts = NULL, status = 'idle', claimed_at = NULL,
        claim_owner = NULL, last_status = NULL;

  CREATE TABLE IF NOT EXISTS computer_history_computers (
    computer_id TEXT PRIMARY KEY,
    delivered_mark INTEGER NOT NULL DEFAULT 0,
    last_submission_at INTEGER,
    last_status TEXT,
    last_reason TEXT,
    submitted INTEGER NOT NULL DEFAULT 0
  );
  """

  # The columns migration 59 adds, each added only where it is missing, so the
  # migration may run again over its own effects (a store rewound by hand).
  @machines_columns [
    {"computer_history_memories", "computer_id", "TEXT NOT NULL DEFAULT ''"},
    {"computer_history_memories", "sitting", "TEXT"},
    {"computer_history_access", "computer_id", "TEXT"},
    {"computer_history_purges", "computer_id", "TEXT"},
    {"computer_history_purges", "kind",
     "TEXT NOT NULL DEFAULT 'purge' CHECK (kind IN ('purge', 'pause'))"}
  ]

  @machines_indexes_sql """
  CREATE UNIQUE INDEX IF NOT EXISTS idx_computer_history_memories_sitting
    ON computer_history_memories(computer_id, sitting) WHERE sitting IS NOT NULL;
  CREATE INDEX IF NOT EXISTS idx_computer_history_memories_computer
    ON computer_history_memories(computer_id, kind, provenance_to_ts);
  """

  @typedoc "Whose notes a read takes: every machine's, or one's (`\"\"` is the home's own)."
  @type computer_scope :: :all | String.t()

  # The two kinds, as stored. `:all` is the kind-blind read (counts and purge).
  @kinds %{session: "session", thread: "thread"}
  @default_kind "session"
  # Code Rule 2: an id lookup is built from caller-supplied ids, so the SQL it
  # generates has to have a ceiling.
  @max_ids_per_lookup 500

  @doc "Schema for migration 23 — the raw event spool."
  @spec events_schema_sql() :: String.t()
  def events_schema_sql, do: @events_schema_sql

  @doc """
  Migration 59 — notes, reads and purges name their machine, in `conn`'s
  open transaction: the raw table and the move's leftovers go, each column is
  added where it is missing, then the indexes. Safe to run again.
  """
  @spec machines_schema(term()) :: :ok | {:error, term()}
  def machines_schema(conn) do
    with :ok <- Sqlite3.execute(conn, @machines_schema_sql),
         :ok <- add_missing_columns(conn, @machines_columns) do
      Sqlite3.execute(conn, @machines_indexes_sql)
    end
  end

  # Migration 60 (M97 §8.5): each machine's row on the home also keeps when the
  # owner asked from chat that its history go off and it has not yet said it
  # did, and the last report it sent of its recorder, its unsent sittings and its
  # coverage, with when it came (counts and a state word, never raw text).
  @reports_columns [
    {"computer_history_computers", "off_requested_at", "INTEGER"},
    {"computer_history_computers", "report", "TEXT"},
    {"computer_history_computers", "report_at", "INTEGER"}
  ]

  @doc """
  Migration 60, in `conn`'s open transaction: each column of the machines' rows
  is added where it is missing. Safe to run again.
  """
  @spec reports_schema(term()) :: :ok | {:error, term()}
  def reports_schema(conn), do: add_missing_columns(conn, @reports_columns)

  # Migration 61 (M97 §8.5): the home's store gets a token of its own, made
  # once, at random. Every store, a server's rebuilt from nothing or another
  # home's, makes its own; a restored one keeps its snapshot's, so the home's
  # identity joins it with the home's epoch, which a restore moves
  # (`ComputerHistory.home_identity/1`).
  @home_schema_sql """
  CREATE TABLE IF NOT EXISTS computer_history_home (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    token TEXT NOT NULL
  );
  INSERT OR IGNORE INTO computer_history_home (id, token)
    VALUES (1, lower(hex(randomblob(16))));
  """

  @doc "Migration 61, in `conn`'s open transaction: the home store's own token. Safe to run again."
  @spec home_schema(term()) :: :ok | {:error, term()}
  def home_schema(conn), do: Sqlite3.execute(conn, @home_schema_sql)

  @doc "The home store's own token (migration 61)."
  @spec home_token(term()) :: {:ok, String.t()} | {:error, term()}
  def home_token(conn) do
    case query_all(conn, "SELECT token FROM computer_history_home WHERE id = 1", []) do
      {:ok, [[token]]} when is_binary(token) -> {:ok, token}
      {:ok, _none} -> {:error, :no_home_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_missing_columns(conn, columns) do
    Enum.reduce_while(columns, :ok, fn column, :ok ->
      case add_missing_column(conn, column) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_missing_column(conn, {table, column, ddl}) do
    case column?(conn, table, column) do
      {:ok, true} -> :ok
      {:ok, false} -> Sqlite3.execute(conn, "ALTER TABLE #{table} ADD COLUMN #{column} #{ddl}")
      {:error, reason} -> {:error, reason}
    end
  end

  defp column?(conn, table, column) do
    with {:ok, rows} <- query_all(conn, "SELECT name FROM pragma_table_info(?)", [table]) do
      {:ok, [column] in rows}
    end
  end

  @doc """
  The schema of a machine's own raw store (`ComputerHistory.Spool`,
  `device/history.db`): the events,
  the purge fence and the state row with the tables and columns memory.db had,
  so every raw read and write here serves both, and `computer_history_link`, what
  this machine last heard from its home. Every statement may run again.
  """
  @spec spool_schema_sql() :: String.t()
  def spool_schema_sql do
    """
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
    CREATE TABLE IF NOT EXISTS computer_history_purges (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_ts INTEGER NOT NULL,
      to_ts INTEGER NOT NULL,
      issued_at INTEGER NOT NULL,
      CHECK (from_ts <= to_ts)
    );
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
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      last_rollup_ts INTEGER,
      last_rollup_attempt_ts INTEGER,
      session_open_since_ts INTEGER
    );
    CREATE TABLE IF NOT EXISTS computer_history_link (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      home_mark INTEGER NOT NULL DEFAULT 0,
      expired_unsent INTEGER NOT NULL DEFAULT 0,
      last_answer TEXT,
      last_reason TEXT,
      last_answer_at INTEGER
    );
    """
  end

  @doc """
  What migration 59 carries from memory.db (`main`) into the machine's store
  attached as `spool`, in one transaction of the caller's: every raw event under
  its own id, every purge interval, the cursor, the pause and the open sitting,
  and the events' id sequence, so a cursor past the last id never skips an event
  recorded after it. `INSERT OR IGNORE` and `MAX` make it safe to run again.
  """
  @spec spool_carry_sql() :: String.t()
  def spool_carry_sql do
    columns = Enum.map_join([:id | @event_columns], ", ", &Atom.to_string/1)

    """
    INSERT OR IGNORE INTO spool.computer_history_events (#{columns})
      SELECT #{columns} FROM main.computer_history_events;
    INSERT OR IGNORE INTO spool.computer_history_purges (id, from_ts, to_ts, issued_at)
      SELECT id, from_ts, to_ts, issued_at FROM main.computer_history_purges;
    INSERT INTO spool.computer_history_state (id) VALUES (1) ON CONFLICT(id) DO NOTHING;
    UPDATE spool.computer_history_state SET
      last_summarized_id = MAX(last_summarized_id,
        COALESCE((SELECT last_summarized_id FROM main.computer_history_state WHERE id = 1), 0)),
      pause_until = COALESCE(pause_until,
        (SELECT pause_until FROM main.computer_history_state WHERE id = 1)),
      session_open_since_ts = COALESCE(session_open_since_ts,
        (SELECT session_open_since_ts FROM main.computer_history_state WHERE id = 1))
      WHERE id = 1;
    INSERT INTO spool.sqlite_sequence (name, seq)
      SELECT 'computer_history_events', 0
      WHERE NOT EXISTS (SELECT 1 FROM spool.sqlite_sequence WHERE name = 'computer_history_events');
    UPDATE spool.sqlite_sequence SET seq = MAX(seq,
        COALESCE((SELECT seq FROM main.sqlite_sequence WHERE name = 'computer_history_events'), 0),
        COALESCE((SELECT last_summarized_id FROM main.computer_history_state WHERE id = 1), 0))
      WHERE name = 'computer_history_events';
    """
  end

  @doc """
  Whether memory.db (`conn`) holds anything migration 59 carries to the machine's
  store: an event, a purge interval, a cursor, a pause or an open sitting.
  """
  @spec spool_carry?(term()) :: {:ok, boolean()} | {:error, term()}
  def spool_carry?(conn) do
    case query_all(
           conn,
           "SELECT 1 FROM sqlite_master WHERE type = 'table' AND " <>
             "name = 'computer_history_events'",
           []
         ) do
      {:ok, []} -> {:ok, false}
      {:ok, [_table]} -> carry_rows?(conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp carry_rows?(conn) do
    sql =
      "SELECT (SELECT count(*) FROM computer_history_events) + " <>
        "(SELECT count(*) FROM computer_history_purges) + " <>
        "(SELECT count(*) FROM computer_history_state WHERE id = 1 AND " <>
        "(last_summarized_id > 0 OR pause_until IS NOT NULL OR session_open_since_ts IS NOT NULL))"

    with {:ok, [[count]]} <- query_all(conn, sql, []), do: {:ok, count > 0}
  end

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

  @doc """
  Migration 32 — the purge intervals, with a stored watermark carried over as one
  interval issued at `migrated_at` (epoch ms). The old column stays, unread.
  """
  @spec purges_schema_sql(integer()) :: String.t()
  def purges_schema_sql(migrated_at) when is_integer(migrated_at) do
    String.replace(@purges_schema_sql_template, "{{migrated_at}}", Integer.to_string(migrated_at))
  end

  # --- events -------------------------------------------------------------

  @doc """
  Insert a batch of spool events idempotently. Each event is a map keyed by a
  subset of `@event_columns`; absent keys bind NULL. `INSERT OR IGNORE` +
  `UNIQUE(boot_id, source_seq)` makes a re-delivered event a no-op. An event
  stamped inside a recorded purge interval is refused (the purge fence, §12) and
  the refused count is logged. Returns the count of rows actually inserted
  (ignored duplicates and fenced rows do not count).
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

    result =
      Enum.reduce_while(events, {:ok, 0, 0}, fn event, {:ok, inserted, fenced} ->
        case insert_unless_purged(conn, sql, event) do
          {:ok, :fenced} -> {:cont, {:ok, inserted, fenced + 1}}
          {:ok, count} -> {:cont, {:ok, inserted + count, fenced}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, inserted, fenced} <- result do
      log_fenced(fenced)
      {:ok, inserted}
    end
  end

  # The purge fence (§12): a row stamped inside any recorded purge interval is
  # refused here, inside the insert's own transaction. That is the one placement
  # that also stops a batch already past Ingest's pause check when the purge
  # committed: the purge and this insert are each one transaction on the single
  # writer, so either the purge's DELETE removes the row or this check sees its
  # interval. A row with no integer `ts` is left to the insert's NOT NULL refusal,
  # as before the fence.
  defp insert_unless_purged(conn, sql, event) do
    case stamped_in_purge?(conn, Map.get(event, :ts)) do
      {:ok, true} -> {:ok, :fenced}
      {:ok, false} -> insert_event(conn, sql, event)
      {:error, reason} -> {:error, reason}
    end
  end

  # Every recorded interval fences, whenever it was issued: ids start at 1.
  defp stamped_in_purge?(conn, ts) when is_integer(ts), do: purge_reaches?(conn, 0, ts, ts)
  defp stamped_in_purge?(_conn, _ts), do: {:ok, false}

  defp insert_event(conn, sql, event) do
    params = Enum.map(@event_columns, fn column -> to_param(Map.get(event, column)) end)

    with :ok <- execute(conn, sql, params), do: {:ok, changed(conn)}
  end

  # Counts only (§15.1). A fenced row is expected right after a purge, and never
  # silent: `written` alone would just read lower.
  defp log_fenced(0), do: :ok

  defp log_fenced(count) do
    Logger.info(
      "computer_history spool insert fenced #{count} event(s) stamped inside a purged window"
    )
  end

  @doc """
  Delete every spool event older than `cutoff_ts` (epoch ms) — the 48h retention
  sweep — and prune the purge intervals that can no longer matter. Returns the
  count of events deleted. (The byte-ceiling backstop is
  `sweep_spool_over_bytes/2`, which deletes by id, not time.)
  """
  @spec sweep_expired_events(term(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_expired_events(conn, cutoff_ts) when is_integer(cutoff_ts) do
    with :ok <- execute(conn, "DELETE FROM computer_history_events WHERE ts < ?", [cutoff_ts]),
         deleted <- changed(conn),
         :ok <- prune_purges(conn, cutoff_ts) do
      {:ok, deleted}
    end
  end

  @doc """
  The retention sweep of a machine's own store (`ComputerHistory.Spool`), in one
  transaction: `sweep_expired_events/2`, and how many of the events it deleted
  were never sent to the home (past the cursor), added to the store's count so a
  sitting that expired unsent is shown, never hidden (M97 §8.1).
  """
  @spec sweep_spool(term(), integer()) ::
          {:ok, %{deleted: non_neg_integer(), unsent: non_neg_integer()}} | {:error, term()}
  def sweep_spool(conn, cutoff_ts) when is_integer(cutoff_ts) do
    in_transaction(conn, fn ->
      with {:ok, cursor} <- summarized_cursor(conn),
           {:ok, [[unsent]]} <-
             query_all(
               conn,
               "SELECT count(*) FROM computer_history_events WHERE ts < ? AND id > ?",
               [cutoff_ts, cursor]
             ),
           {:ok, deleted} <- sweep_expired_events(conn, cutoff_ts),
           :ok <- add_expired_unsent(conn, unsent) do
        {:ok, %{deleted: deleted, unsent: unsent}}
      end
    end)
  end

  defp add_expired_unsent(_conn, 0), do: :ok

  defp add_expired_unsent(conn, count) do
    with :ok <- ensure_link(conn) do
      execute(
        conn,
        "UPDATE computer_history_link SET expired_unsent = expired_unsent + ? WHERE id = 1",
        [count]
      )
    end
  end

  defp ensure_link(conn),
    do:
      execute(
        conn,
        "INSERT INTO computer_history_link (id) VALUES (1) ON CONFLICT(id) DO NOTHING",
        []
      )

  @doc """
  What a machine last heard from its home (`computer_history_link`): the highest
  purge or pause interval it applied (`home_mark`) of the home store `home`
  names (its identity, `ComputerHistory.home_identity/1`, nil before any), how
  many raw events expired before they were sent, and its last answer.
  """
  @spec link(term()) :: {:ok, map()} | {:error, term()}
  def link(conn) do
    sql =
      "SELECT home_mark, home, expired_unsent, last_answer, last_reason, last_answer_at " <>
        "FROM computer_history_link WHERE id = 1"

    with :ok <- ensure_link(conn),
         {:ok, [[mark, home, expired, answer, reason, at]]} <- query_all(conn, sql, []) do
      {:ok,
       %{
         home_mark: mark,
         home: home,
         expired_unsent: expired,
         last_answer: answer,
         last_reason: reason,
         last_answer_at: at
       }}
    end
  end

  @doc "Record the home's answer to this machine's latest sitting."
  @spec record_answer(term(), String.t(), String.t() | nil, integer()) :: :ok | {:error, term()}
  def record_answer(conn, answer, reason, at_ts)
      when is_binary(answer) and (is_binary(reason) or is_nil(reason)) and is_integer(at_ts) do
    with :ok <- ensure_link(conn) do
      execute(
        conn,
        "UPDATE computer_history_link SET last_answer = ?, last_reason = ?, last_answer_at = ? " <>
          "WHERE id = 1",
        [answer, reason, at_ts]
      )
    end
  end

  @doc """
  Record that this machine applied every interval up to `mark` of the home
  store `home` names, in one write: under the same store the mark never goes
  back; under another (a restore, a rebuilt server, another home, whose ids
  start again) the mark and the store are replaced together.
  """
  @spec set_home_mark(term(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def set_home_mark(conn, home, mark)
      when is_binary(home) and home != "" and is_integer(mark) and mark >= 0 do
    with :ok <- ensure_link(conn) do
      execute(
        conn,
        "UPDATE computer_history_link SET " <>
          "home_mark = CASE WHEN home IS ?1 THEN MAX(home_mark, ?2) ELSE ?2 END, home = ?1 " <>
          "WHERE id = 1",
        [home, mark]
      )
    end
  end

  @doc "Forget which home store this machine's mark belongs to: the mark is 0 again."
  @spec forget_home(term()) :: :ok | {:error, term()}
  def forget_home(conn) do
    with :ok <- ensure_link(conn) do
      execute(
        conn,
        "UPDATE computer_history_link SET home_mark = 0, home = NULL WHERE id = 1",
        []
      )
    end
  end

  # The machine store's columns added after its first version (`spool_columns/1`).
  @spool_columns [{"computer_history_link", "home", "TEXT"}]

  @doc """
  The machine store's second version (M97 §8.5), safe to run again: what this
  machine heard from its home also names that home's store (`home`), each
  column added where it is missing.
  """
  @spec spool_columns(term()) :: :ok | {:error, term()}
  def spool_columns(conn), do: add_missing_columns(conn, @spool_columns)

  # An interval matters to the fence while a row stamped inside it could still
  # arrive or be kept, and to the note and thread guard while a batch read before
  # it was issued could still be written. Once it both ended and was issued before
  # the retention cutoff, neither holds: this sweep deletes rows stamped that early,
  # no flush is that late (the Capturer buffers at most one 2 s flush and loses it
  # on a restart), and no cycle is that old (the Scheduler kills one after 15
  # minutes). So the table holds at most one retention window of purges. Pruning
  # never lowers a later purge's id (AUTOINCREMENT never reuses one), so a purge
  # mark still orders every purge after it.
  defp prune_purges(conn, cutoff_ts) do
    execute(
      conn,
      "DELETE FROM computer_history_purges WHERE issued_at < ? AND to_ts < ?",
      [cutoff_ts, cutoff_ts]
    )
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
  Fence a `[from_ts, to_ts]` window (epoch ms) in a machine's own store
  (`ComputerHistory.Spool`), atomically: delete the raw events stamped in it and
  record the interval, issued at `issued_at`, which refuses a row stamped inside
  it that arrives later (§12). Returns how many events went.
  """
  @spec fence_window(term(), integer(), integer(), integer()) ::
          {:ok, %{events: non_neg_integer()}} | {:error, term()}
  def fence_window(conn, from_ts, to_ts, issued_at)
      when is_integer(from_ts) and is_integer(to_ts) and from_ts <= to_ts and
             is_integer(issued_at) do
    in_transaction(conn, fn -> fence_window_in_tx(conn, from_ts, to_ts, issued_at) end)
  end

  defp fence_window_in_tx(conn, from_ts, to_ts, issued_at) do
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
             "INSERT INTO computer_history_purges (from_ts, to_ts, issued_at) VALUES (?, ?, ?)",
             [from_ts, to_ts, issued_at]
           ) do
      {:ok, %{events: events_deleted}}
    end
  end

  @doc """
  Purge a `[from_ts, to_ts]` window (epoch ms) from the home's notes (M97 §8.5),
  atomically: delete the notes and threads whose provenance **intersects** it, of
  the machine `scope` names (`:all`, `""` for the home's own, or a computer's id;
  a thread spans machines, so every thread that reaches the window goes), delete
  the read-audit rows recorded in it, and record the interval for that scope,
  issued at `issued_at`. The interval refuses any sitting or note from that
  machine that reaches the window, whenever it arrives (`note_refusal/4`), and a
  roll-up whose input a later purge reached (§12). Returns the deleted count and
  the interval's id.
  """
  @spec purge_notes(term(), integer(), integer(), integer(), :all | String.t()) ::
          {:ok, %{memories: non_neg_integer(), interval: pos_integer()}} | {:error, term()}
  def purge_notes(conn, from_ts, to_ts, issued_at, scope)
      when is_integer(from_ts) and is_integer(to_ts) and from_ts <= to_ts and
             is_integer(issued_at) and (scope == :all or is_binary(scope)) do
    in_transaction(conn, fn -> purge_notes_in_tx(conn, {from_ts, to_ts}, issued_at, scope) end)
  end

  # Total: a request the single writer cannot take is answered, never a crash.
  def purge_notes(_conn, _from_ts, _to_ts, _issued_at, _scope), do: {:error, :invalid_window}

  defp purge_notes_in_tx(conn, {from_ts, to_ts}, issued_at, scope) do
    {note_sql, note_params} = scoped_notes(scope)

    with :ok <-
           execute(
             conn,
             "DELETE FROM computer_history_memories " <>
               "WHERE provenance_from_ts <= ? AND provenance_to_ts >= ?" <> note_sql,
             [to_ts, from_ts] ++ note_params
           ),
         memories_deleted <- changed(conn),
         :ok <-
           execute(
             conn,
             "DELETE FROM computer_history_access WHERE ts >= ? AND ts <= ?",
             [from_ts, to_ts]
           ),
         {:ok, id} <- insert_interval(conn, {from_ts, to_ts}, issued_at, scope, "purge") do
      {:ok, %{memories: memories_deleted, interval: id}}
    end
  end

  # A purge of one machine's notes still takes every thread that reaches the
  # window: a thread is the home's, drawn from every machine.
  defp scoped_notes(:all), do: {"", []}
  defp scoped_notes(computer), do: {" AND (kind = 'thread' OR computer_id = ?)", [computer]}

  @doc """
  Record a pause from chat (M97 §8.5) for the machine `scope` names over
  `[from_ts, until_ts]`: the home then refuses any sitting or note from it with
  an event stamped inside, as it refuses a purged one, and each machine learns of
  it. Returns the interval's id.
  """
  @spec pause_window(term(), integer(), integer(), integer(), :all | String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def pause_window(conn, from_ts, until_ts, issued_at, scope)
      when is_integer(from_ts) and is_integer(until_ts) and from_ts <= until_ts and
             is_integer(issued_at) and (scope == :all or is_binary(scope)) do
    in_transaction(conn, fn ->
      insert_interval(conn, {from_ts, until_ts}, issued_at, scope, "pause")
    end)
  end

  def pause_window(_conn, _from_ts, _until_ts, _issued_at, _scope), do: {:error, :invalid_window}

  defp insert_interval(conn, {from_ts, to_ts}, issued_at, scope, kind) do
    with :ok <-
           execute(
             conn,
             "INSERT INTO computer_history_purges (from_ts, to_ts, issued_at, computer_id, kind) " <>
               "VALUES (?, ?, ?, ?, ?)",
             [from_ts, to_ts, issued_at, scope_param(scope), kind]
           ),
         {:ok, [[id]]} <- query_all(conn, "SELECT last_insert_rowid()", []) do
      {:ok, id}
    end
  end

  defp scope_param(:all), do: nil
  defp scope_param(computer) when is_binary(computer), do: computer

  @doc """
  The purge mark: the id of the latest recorded purge, or 0 (§12). A reader takes
  it BEFORE it reads a batch and hands it to the write, which refuses when a purge
  issued after it (a higher id) reaches what was read. Ids only grow, so no clock
  is compared: a clock step cannot reorder a purge and a read.
  """
  @spec purge_mark(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_mark(conn) do
    sql = "SELECT COALESCE(MAX(id), 0) FROM computer_history_purges"

    with {:ok, [[mark]]} <- query_all(conn, sql, []), do: {:ok, mark}
  end

  # Does a purge with an id above `after_id` reach [from_ts, to_ts]? The one
  # question a machine's fence (every purge, `after_id` 0) and the home's thread
  # guard (the purges issued after the roll-up read its input, never a pause:
  # `kind_sql`) both ask. Intersection, inclusive like the purge's own DELETEs. A
  # NULL bound matches nothing.
  defp purge_reaches?(conn, after_id, from_ts, to_ts, kind_sql \\ "") do
    sql =
      "SELECT EXISTS(SELECT 1 FROM computer_history_purges " <>
        "WHERE id > ? AND from_ts <= ? AND to_ts >= ?#{kind_sql})"

    case query_all(conn, sql, [after_id, to_ts, from_ts]) do
      {:ok, [[hit]]} -> {:ok, hit == 1}
      {:error, reason} -> {:error, reason}
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

  # The machine filter of a read (M97 §8.4): `:all`, or one machine's notes
  # (`""` for the home's own). A thread is the home's, drawn from every machine,
  # so a filtered read keeps the threads that cite that machine's notes only
  # through those notes.
  defp computer_clause(scope, prefix \\ "")
  defp computer_clause(:all, _prefix), do: {"", []}

  defp computer_clause(computer, prefix) when is_binary(computer),
    do: {" AND #{prefix}computer_id = ?", [computer]}

  @doc """
  The most recent (non-superseded) activity memories whose provenance ends at or
  after `since_ts` (epoch ms), newest first — the Recent Activity section source
  (§11.1). The horizon is the caller's: an undated summary from an arbitrarily
  old window is not "recent activity". Reads only derived summaries, never the
  raw spool.
  """
  @spec recent_memories(
          term(),
          integer(),
          pos_integer(),
          :all | :session | :thread,
          computer_scope()
        ) ::
          {:ok, [map()]} | {:error, term()}
  def recent_memories(conn, since_ts, limit, kind \\ :session, computer \\ :all)
      when is_integer(since_ts) and is_integer(limit) and limit > 0 and
             kind in [:all, :session, :thread] do
    {kind_sql, kind_params} = kind_clause(kind)
    {computer_sql, computer_params} = computer_clause(computer)

    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_to_ts >= ?#{kind_sql}#{computer_sql} " <>
        "ORDER BY provenance_to_ts DESC, id DESC LIMIT ?"

    params = [since_ts] ++ kind_params ++ computer_params ++ [limit]

    with {:ok, rows} <- query_all(conn, sql, params) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  Non-superseded activity memories whose provenance window intersects
  `[from_ts, to_ts]` (epoch ms), newest first — the `recall_activity` query
  (§11.2). Derived summaries only.
  """
  @spec memories_in_window(
          term(),
          integer(),
          integer(),
          pos_integer(),
          :all | :session | :thread,
          computer_scope()
        ) ::
          {:ok, [map()]} | {:error, term()}
  def memories_in_window(conn, from_ts, to_ts, limit, kind \\ :session, computer \\ :all)
      when is_integer(from_ts) and is_integer(to_ts) and is_integer(limit) and limit > 0 and
             kind in [:all, :session, :thread] do
    {kind_sql, kind_params} = kind_clause(kind)
    {computer_sql, computer_params} = computer_clause(computer)

    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_from_ts <= ? AND provenance_to_ts >= ?" <>
        "#{kind_sql}#{computer_sql} ORDER BY provenance_to_ts DESC, id DESC LIMIT ?"

    params = [to_ts, from_ts] ++ kind_params ++ computer_params ++ [limit]

    with {:ok, rows} <- query_all(conn, sql, params) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  How many non-superseded memories intersect `[from_ts, to_ts]` — the honest
  denominator behind `memories_in_window/4`'s limited page, so recall can say
  when older entries were omitted instead of truncating silently (§11.2).
  """
  @spec count_memories_in_window(
          term(),
          integer(),
          integer(),
          :all | :session | :thread,
          computer_scope()
        ) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_memories_in_window(conn, from_ts, to_ts, kind \\ :session, computer \\ :all)
      when is_integer(from_ts) and is_integer(to_ts) and kind in [:all, :session, :thread] do
    {kind_sql, kind_params} = kind_clause(kind)
    {computer_sql, computer_params} = computer_clause(computer)

    sql =
      "SELECT count(*) FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND provenance_from_ts <= ? AND provenance_to_ts >= ?" <>
        kind_sql <> computer_sql

    params = [to_ts, from_ts] ++ kind_params ++ computer_params

    with {:ok, [[count]]} <- query_all(conn, sql, params) do
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
  @spec session_notes_since(term(), integer(), pos_integer(), machines()) ::
          {:ok, [map()]} | {:error, term()}
  def session_notes_since(conn, since_ts, limit, machines \\ :all)
      when is_integer(since_ts) and is_integer(limit) and limit > 0 do
    {machine_sql, machine_params} = machines_clause(machines)

    sql =
      "SELECT #{@memory_read_select} FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND kind = 'session' AND created_at > ?" <>
        machine_sql <> " ORDER BY created_at DESC, id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [since_ts] ++ machine_params ++ [limit]) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  @doc """
  How many session notes exist after `since_ts` — the honest denominator behind
  `session_notes_since/4`'s bounded page, so the roll-up can say it read the newest
  N of M instead of implying it read everything.
  """
  @spec count_session_notes_since(term(), integer(), machines()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_session_notes_since(conn, since_ts, machines \\ :all) when is_integer(since_ts) do
    {machine_sql, machine_params} = machines_clause(machines)

    sql =
      "SELECT count(*) FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND kind = 'session' AND created_at > ?" <> machine_sql

    with {:ok, [[count]]} <- query_all(conn, sql, [since_ts] ++ machine_params) do
      {:ok, count}
    end
  end

  @typedoc """
  Whose session notes a roll-up reads (M97 §8.5): every machine's, or only
  those of the machines named (`""` is the home's own), at most
  #{@max_ids_per_lookup}.
  """
  @type machines :: :all | [String.t()]

  defp machines_clause(:all), do: {"", []}

  defp machines_clause([_ | _] = machines) when length(machines) <= @max_ids_per_lookup do
    true = Enum.all?(machines, &is_binary/1)
    marks = Enum.map_join(machines, ", ", fn _machine -> "?" end)
    {" AND computer_id IN (#{marks})", machines}
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
  newest first. `query` is user text, never FTS syntax (`FtsMatch.expression/1`):
  `OR`, `NEAR(`, a column filter or a stray quote are all literal words. A query
  with no searchable token is refused rather than run as an empty MATCH.
  """
  @spec search_memories(term(), String.t(), pos_integer(), computer_scope()) ::
          {:ok, [map()]} | {:error, :empty_query | term()}
  def search_memories(conn, query, limit, computer \\ :all)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    case FtsMatch.expression(query) do
      {:ok, match} -> search_memories_matching(conn, match, limit, computer)
      {:error, :empty_query} -> {:error, :empty_query}
    end
  end

  @doc """
  How many non-superseded memories of either kind match `query` — the honest
  denominator behind `search_memories/3`'s bounded page (§24.4). Same sanitizing as
  the search itself, so the count and the page can never disagree about what the
  query meant.
  """
  @spec count_search_memories(term(), String.t(), computer_scope()) ::
          {:ok, non_neg_integer()} | {:error, :empty_query | term()}
  def count_search_memories(conn, query, computer \\ :all) when is_binary(query) do
    case FtsMatch.expression(query) do
      {:ok, match} -> count_matching(conn, match, computer)
      {:error, :empty_query} -> {:error, :empty_query}
    end
  end

  defp count_matching(conn, match, computer) do
    {computer_sql, computer_params} = computer_clause(computer, "m.")

    sql =
      "SELECT count(*) FROM computer_history_memories_fts f " <>
        "JOIN computer_history_memories m ON m.id = f.rowid " <>
        "WHERE computer_history_memories_fts MATCH ? AND m.superseded_at IS NULL" <>
        computer_sql

    with {:ok, [[count]]} <- query_all(conn, sql, [match] ++ computer_params) do
      {:ok, count}
    end
  end

  defp search_memories_matching(conn, match, limit, computer) do
    {computer_sql, computer_params} = computer_clause(computer, "m.")

    sql =
      "SELECT #{Enum.map_join(@memory_read_columns, ", ", &("m." <> Atom.to_string(&1)))} " <>
        "FROM computer_history_memories_fts f " <>
        "JOIN computer_history_memories m ON m.id = f.rowid " <>
        "WHERE computer_history_memories_fts MATCH ? AND m.superseded_at IS NULL" <>
        computer_sql <> " ORDER BY m.provenance_to_ts DESC, m.id DESC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [match] ++ computer_params ++ [limit]) do
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
      # A thread is the home's, drawn from every machine, and a note written with
      # no machine named is the home's own (M97 §8.4).
      :computer_id -> to_param(Map.get(memory, :computer_id, ""))
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
        "(ts, sink, window_from_ts, window_to_ts, result_count, computer_id) " <>
        "VALUES (?, ?, ?, ?, ?, ?)",
      [
        ts,
        sink,
        Map.get(access, :window_from_ts),
        Map.get(access, :window_to_ts),
        count,
        Map.get(access, :computer_id)
      ]
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
  Advance a machine's cursor (`ComputerHistory.Spool`) past `last_id` and record
  the outcome (§10): what its home answered for the sitting that ended there,
  or `no_signal` for one it never had to send. A `nil` `last_status` advances the
  cursor and **keeps** the recorded outcome: consuming a boundary marker, which
  is not a sitting, must not overwrite the last real one (§24.2). The cursor only
  ever moves forward. The `status` (idle/running) lifecycle stays with the
  scheduler's claim and release.
  """
  @spec advance_cursor(term(), non_neg_integer(), DateTime.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def advance_cursor(conn, last_id, %DateTime{} = now, last_status)
      when is_integer(last_id) and last_id >= 0 and
             (is_binary(last_status) or is_nil(last_status)) do
    now_iso = DateTime.to_iso8601(now)

    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET last_summarized_id = MAX(last_summarized_id, ?), " <>
          "last_run_at = ?, last_status = COALESCE(?, last_status), updated_at = ? WHERE id = 1",
        [last_id, now_iso, last_status, now_iso]
      )
    end
  end

  # --- the home's notes from every machine (M97 §8.1, §8.4) -------------------

  @doc """
  Write one note from the machine `computer` (`""` for the home's own) for the
  sitting `sitting` keys, atomically with the one rule that keeps a purged or
  paused window empty: a purge or pause interval of that machine or of every
  machine that reaches the note's provenance refuses it, whenever either arrived
  (M97 §8.5), so a purge and a late sitting give the same store in either order.
  A sitting already noted answers `:duplicate` and writes nothing. The machine's
  row records the outcome either way. `memory` is `insert_memory/2`'s map;
  `mark` is the highest interval the machine had applied when it read the
  sitting, so only intervals above it can reach it.
  """
  @spec insert_note(term(), map(), String.t(), String.t(), integer(), non_neg_integer()) ::
          {:ok, {:written, integer()} | :duplicate | {:refused, :purged | :paused, [map()]}}
          | {:error, term()}
  def insert_note(conn, memory, computer, sitting, now_ts, mark \\ 0)

  def insert_note(conn, %{} = memory, computer, sitting, now_ts, mark)
      when is_binary(computer) and is_binary(sitting) and sitting != "" and is_integer(now_ts) and
             is_integer(mark) and mark >= 0 do
    in_transaction(conn, fn ->
      insert_note_in_tx(conn, memory, {computer, sitting, mark}, now_ts)
    end)
  end

  def insert_note(_conn, _memory, _computer, _sitting, _now_ts, _mark),
    do: {:error, :invalid_note}

  defp insert_note_in_tx(conn, memory, {computer, sitting, mark}, now_ts) do
    from_ts = Map.fetch!(memory, :provenance_from_ts)
    to_ts = Map.fetch!(memory, :provenance_to_ts)

    with {:ok, nil} <- noted(conn, computer, sitting),
         {:ok, []} <- reaching_intervals(conn, computer, from_ts, to_ts, mark),
         {:ok, id} <-
           insert_memory(conn, Map.merge(memory, %{computer_id: computer, sitting: sitting})),
         :ok <- record_submission(conn, computer, "summarized", nil, now_ts) do
      {:ok, {:written, id}}
    else
      {:ok, id} when is_integer(id) -> {:ok, :duplicate}
      {:ok, [first | _rest] = intervals} -> refused(conn, computer, first, intervals, now_ts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp refused(conn, computer, %{kind: kind}, intervals, now_ts) do
    reason = if kind == "pause", do: :paused, else: :purged

    with :ok <- record_submission(conn, computer, "refused", Atom.to_string(reason), now_ts) do
      {:ok, {:refused, reason, intervals}}
    end
  end

  @doc """
  The id of the note `computer` already has for `sitting`, or nil: a sitting sent
  again is answered from it rather than summarized twice.
  """
  @spec noted(term(), String.t(), String.t()) :: {:ok, integer() | nil} | {:error, term()}
  def noted(conn, computer, sitting) when is_binary(computer) and is_binary(sitting) do
    sql =
      "SELECT id FROM computer_history_memories WHERE computer_id = ? AND sitting = ? LIMIT 1"

    case query_all(conn, sql, [computer, sitting]) do
      {:ok, [[id]]} -> {:ok, id}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every purge or pause interval of `computer` or of every machine, with an id
  above `after_id` (what the machine had applied), that reaches
  `[from_ts, to_ts]`, oldest first: the reason the home refuses a sitting, and
  what it tells the machine so it applies them first.
  """
  @spec reaching_intervals(term(), String.t(), integer(), integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def reaching_intervals(conn, computer, from_ts, to_ts, after_id \\ 0)
      when is_binary(computer) and is_integer(from_ts) and is_integer(to_ts) and
             is_integer(after_id) do
    sql =
      "SELECT id, from_ts, to_ts, issued_at, kind FROM computer_history_purges " <>
        "WHERE (computer_id IS NULL OR computer_id = ?) AND from_ts <= ? AND to_ts >= ? " <>
        "AND id > ? ORDER BY id ASC"

    with {:ok, rows} <- query_all(conn, sql, [computer, to_ts, from_ts, after_id]) do
      {:ok, Enum.map(rows, &interval_row/1)}
    end
  end

  @doc """
  The intervals of `computer` or of every machine with an id above `after_id`,
  oldest first and at most `limit`: what a machine has not yet applied.
  """
  @spec intervals_after(term(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def intervals_after(conn, computer, after_id, limit)
      when is_binary(computer) and is_integer(after_id) and after_id >= 0 and
             is_integer(limit) and limit > 0 do
    sql =
      "SELECT id, from_ts, to_ts, issued_at, kind FROM computer_history_purges " <>
        "WHERE (computer_id IS NULL OR computer_id = ?) AND id > ? ORDER BY id ASC LIMIT ?"

    with {:ok, rows} <- query_all(conn, sql, [computer, after_id, limit]) do
      {:ok, Enum.map(rows, &interval_row/1)}
    end
  end

  defp interval_row([id, from_ts, to_ts, issued_at, kind]),
    do: %{id: id, from_ts: from_ts, to_ts: to_ts, issued_at: issued_at, kind: kind}

  @doc """
  Record what the home answered `computer` for its latest sitting (`status` and
  an optional `reason`), at `now_ts`, in that machine's row.
  """
  @spec record_submission(term(), String.t(), String.t(), String.t() | nil, integer()) ::
          :ok | {:error, term()}
  def record_submission(conn, computer, status, reason, now_ts)
      when is_binary(computer) and is_binary(status) and is_integer(now_ts) do
    execute(
      conn,
      "INSERT INTO computer_history_computers " <>
        "(computer_id, last_submission_at, last_status, last_reason, submitted) " <>
        "VALUES (?, ?, ?, ?, 1) ON CONFLICT(computer_id) DO UPDATE SET " <>
        "last_submission_at = excluded.last_submission_at, last_status = excluded.last_status, " <>
        "last_reason = excluded.last_reason, submitted = submitted + 1",
      [computer, now_ts, status, reason]
    )
  end

  @doc "Record that `computer` applied every interval up to `mark`; the mark never goes back."
  @spec record_delivered(term(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def record_delivered(conn, computer, mark)
      when is_binary(computer) and is_integer(mark) and mark >= 0 do
    execute(
      conn,
      "INSERT INTO computer_history_computers (computer_id, delivered_mark) VALUES (?, ?) " <>
        "ON CONFLICT(computer_id) DO UPDATE SET " <>
        "delivered_mark = MAX(delivered_mark, excluded.delivered_mark)",
      [computer, mark]
    )
  end

  @doc """
  Record that the owner asked from chat, at `at_ts`, that `computer`'s history
  go off (M97 §8.5): until it says it did (`clear_off/3`), the home takes no
  sitting from it and leaves its notes out of the roll-up. A later request
  replaces an earlier one's time.
  """
  @spec request_off(term(), String.t(), integer()) :: :ok | {:error, term()}
  def request_off(conn, computer, at_ts)
      when is_binary(computer) and computer != "" and is_integer(at_ts) do
    execute(
      conn,
      "INSERT INTO computer_history_computers (computer_id, off_requested_at) VALUES (?, ?) " <>
        "ON CONFLICT(computer_id) DO UPDATE SET off_requested_at = excluded.off_requested_at",
      [computer, at_ts]
    )
  end

  @doc """
  Record that `computer` switched its history off as asked at `requested_ts`:
  that request is done. A request made after it (another `/history off` while
  the answer was on its way) stands.
  """
  @spec clear_off(term(), String.t(), integer()) :: :ok | {:error, term()}
  def clear_off(conn, computer, requested_ts)
      when is_binary(computer) and is_integer(requested_ts) do
    execute(
      conn,
      "UPDATE computer_history_computers SET off_requested_at = NULL " <>
        "WHERE computer_id = ? AND off_requested_at <= ?",
      [computer, requested_ts]
    )
  end

  @doc """
  Record `computer`'s report of its recorder (`report`, the JSON text
  `ComputerHistory.Report` validated), received at `at_ts`.
  """
  @spec record_report(term(), String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def record_report(conn, computer, report, at_ts)
      when is_binary(computer) and computer != "" and is_binary(report) and is_integer(at_ts) do
    execute(
      conn,
      "INSERT INTO computer_history_computers (computer_id, report, report_at) VALUES (?, ?, ?) " <>
        "ON CONFLICT(computer_id) DO UPDATE SET report = excluded.report, " <>
        "report_at = excluded.report_at",
      [computer, report, at_ts]
    )
  end

  @doc "Every machine's row, by its id (`\"\"` for the home's own)."
  @spec computer_rows(term()) :: {:ok, [map()]} | {:error, term()}
  def computer_rows(conn) do
    sql =
      "SELECT computer_id, delivered_mark, last_submission_at, last_status, last_reason, " <>
        "submitted, off_requested_at, report, report_at FROM computer_history_computers " <>
        "ORDER BY computer_id"

    with {:ok, rows} <- query_all(conn, sql, []) do
      {:ok, Enum.map(rows, &computer_row/1)}
    end
  end

  defp computer_row([id, mark, at, status, reason, submitted, off_at, report, report_at]) do
    %{
      computer_id: id,
      delivered_mark: mark,
      last_submission_at: at,
      last_status: status,
      last_reason: reason,
      submitted: submitted,
      off_requested_at: off_at,
      report: report,
      report_at: report_at
    }
  end

  @doc """
  Notes per machine (`{computer_id, sessions}`), for `/history status`'s block of
  each.
  """
  @spec notes_by_computer(term()) :: {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def notes_by_computer(conn) do
    sql =
      "SELECT computer_id, count(*) FROM computer_history_memories " <>
        "WHERE superseded_at IS NULL AND kind = 'session' GROUP BY computer_id ORDER BY computer_id"

    with {:ok, rows} <- query_all(conn, sql, []) do
      {:ok, Enum.map(rows, fn [id, count] -> {id, count} end)}
    end
  end

  @doc """
  Prune the home's purge and pause intervals that can no longer matter: ended and
  issued before `cutoff_ts`, the retention window, past which no machine holds a
  raw event they could refuse. Returns how many went.
  """
  @spec prune_home_intervals(term(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_home_intervals(conn, cutoff_ts) when is_integer(cutoff_ts) do
    with :ok <-
           execute(
             conn,
             "DELETE FROM computer_history_purges WHERE issued_at < ? AND to_ts < ?",
             [cutoff_ts, cutoff_ts]
           ) do
      {:ok, changed(conn)}
    end
  end

  @doc """
  Write one roll-up atomically (§24.3): supersede every current thread row at
  `now_ts`, insert the new set, and stamp `last_rollup_ts`. Session notes are
  never touched — the journal under the threads is what makes retirement safe.
  An empty set is REFUSED rather than superseding the whole active set: "the
  model returned nothing" must not read as "the owner is working on nothing".

  The **purge intervals are checked here**, inside the transaction, against
  `read`: the purge mark taken before the roll-up read its input and the window
  spanning every note and thread that input held. When a purge issued after the
  read (an id above the mark) reaches that window, every proposed thread is
  dropped — the same read-infer-write race `write_cycle_result` closes for notes
  (§12). The whole input, not each thread's own provenance, because the call saw
  all of it and any thread's state can carry any of it. Such a roll-up supersedes
  nothing and does not stamp the mark: the erased window must not come back as a
  thread citing a deleted row. A purge issued before the read refuses nothing: its
  rows were gone before the input was read.

  Returns how many rows were written, how many retired, how many a purge dropped,
  and the subjects actually stored (so the caller's log names what the store
  holds, not what the model proposed).
  """
  @spec write_rollup(term(), [map()], integer(), %{
          purge_mark: non_neg_integer(),
          from_ts: integer(),
          to_ts: integer()
        }) ::
          {:ok,
           %{
             written: non_neg_integer(),
             retired: non_neg_integer(),
             purged: non_neg_integer(),
             subjects: [String.t()]
           }}
          | {:error, term()}
  def write_rollup(conn, threads, now_ts, %{purge_mark: mark, from_ts: from_ts, to_ts: to_ts})
      when is_list(threads) and is_integer(now_ts) and is_integer(mark) and mark >= 0 and
             is_integer(from_ts) and is_integer(to_ts) do
    cond do
      threads == [] ->
        {:error, :no_threads}

      not Enum.all?(threads, &is_map/1) ->
        {:error, :invalid_threads}

      true ->
        in_transaction(conn, fn ->
          write_rollup_in_tx(conn, threads, now_ts, mark, {from_ts, to_ts})
        end)
    end
  end

  # A purge after the read reached the input: nothing is superseded and the mark
  # stays put, so the next roll-up rebuilds from what survived.
  defp write_rollup_in_tx(conn, threads, now_ts, mark, {from_ts, to_ts}) do
    with {:ok, _row} <- ensure_state(conn),
         {:ok, purged?} <- purge_reaches?(conn, mark, from_ts, to_ts, " AND kind = 'purge'") do
      if purged?,
        do: {:ok, %{written: 0, retired: 0, purged: length(threads), subjects: []}},
        else: write_threads(threads, conn, now_ts)
    end
  end

  defp write_threads(threads, conn, now_ts) do
    with :ok <- supersede_threads(conn, now_ts),
         retired <- changed(conn),
         {:ok, written} <- insert_threads(conn, threads),
         :ok <- stamp_rollup(conn, now_ts) do
      {:ok,
       %{
         written: written,
         retired: retired,
         purged: 0,
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
  Raise the capture pause horizon to `until` (an ISO 8601 string) in one write
  that never lowers it (M97 §8.5): a horizon already set that ends later is
  kept, and so is one that cannot be read, which keeps capture paused until it
  is cleared (`Ingest` fails closed on it). Two writers that race (a pause from
  chat, and one applied from a refusal or a delivery) cannot leave the earlier
  horizon in place.
  """
  @spec raise_pause_until(term(), String.t()) :: :ok | {:error, term()}
  def raise_pause_until(conn, until) when is_binary(until) and until != "" do
    with {:ok, _row} <- ensure_state(conn) do
      execute(
        conn,
        "UPDATE computer_history_state SET pause_until = ?1, updated_at = " <>
          "strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = 1 AND julianday(?1) IS NOT NULL " <>
          "AND (pause_until IS NULL OR julianday(pause_until) < julianday(?1))",
        [until]
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

  # --- a move's machine (M97 §8.4) --------------------------------------------

  @doc """
  At a move, every row of the home's history that names the machine `from`
  names `to` instead, in one transaction: its session notes, its reads, its
  purge and pause intervals, and its machine's row with its delivered mark (a
  row `to` already had gives way to it). Threads are the home's, drawn from
  every machine, and stay. The home's own machine is `""`: a move to a server
  names the computer it left for the notes it made there, and a move back
  makes them `""` again. The home's own machine is switched off and reports in
  process, so a row that becomes `""` keeps no off request or report of a
  computer (migration 60); `offs` counts an off request that was still
  pending. Run again over its own work it changes nothing. A store from before
  notes named their machine (migration 59) has none to rename:
  `{:ok, :unnamed}`.
  """
  @spec rename_machine(term(), String.t(), String.t()) ::
          {:ok,
           %{notes: count, reads: count, intervals: count, rows: count, offs: count}
           | :unnamed}
          | {:error, term()}
        when count: non_neg_integer()
  def rename_machine(conn, from, to) when is_binary(from) and is_binary(to) and from != to do
    case column?(conn, "computer_history_memories", "computer_id") do
      {:ok, true} -> in_transaction(conn, fn -> rename_machine_in_tx(conn, from, to) end)
      {:ok, false} -> {:ok, :unnamed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_machine_in_tx(conn, from, to) do
    rename = "SET computer_id = ? WHERE computer_id = ?"

    with {:ok, notes} <-
           renamed(conn, "UPDATE computer_history_memories #{rename} AND kind = 'session'", [
             to,
             from
           ]),
         {:ok, reads} <- renamed(conn, "UPDATE computer_history_access #{rename}", [to, from]),
         {:ok, intervals} <- renamed(conn, "UPDATE computer_history_purges #{rename}", [to, from]),
         :ok <-
           execute(
             conn,
             "DELETE FROM computer_history_computers WHERE computer_id = ? AND EXISTS " <>
               "(SELECT 1 FROM computer_history_computers WHERE computer_id = ?)",
             [to, from]
           ),
         {:ok, rows} <- renamed(conn, "UPDATE computer_history_computers #{rename}", [to, from]),
         {:ok, offs} <- own_row(conn, to) do
      {:ok, %{notes: notes, reads: reads, intervals: intervals, rows: rows, offs: offs}}
    end
  end

  defp own_row(conn, "") do
    case column?(conn, "computer_history_computers", "off_requested_at") do
      {:ok, true} -> clear_own_row(conn)
      {:ok, false} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp own_row(_conn, _computer), do: {:ok, 0}

  defp clear_own_row(conn) do
    with {:ok, [[offs]]} <-
           query_all(
             conn,
             "SELECT count(*) FROM computer_history_computers " <>
               "WHERE computer_id = '' AND off_requested_at IS NOT NULL",
             []
           ),
         :ok <-
           execute(
             conn,
             "UPDATE computer_history_computers " <>
               "SET off_requested_at = NULL, report = NULL, report_at = NULL WHERE computer_id = ''",
             []
           ) do
      {:ok, offs}
    end
  end

  defp renamed(conn, sql, params) do
    with :ok <- execute(conn, sql, params), do: {:ok, changed(conn)}
  end
end
