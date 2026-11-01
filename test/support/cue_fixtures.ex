defmodule FermixTestSupport.CueFixtures do
  @moduledoc """
  A private memory Repo on a temp database for the cue tests, with a direct
  connection for the rows a test inserts or reads by hand (watchers before
  their lane's SQL exists, a delivery moved to `filtering`, a back-dated row).

  Never touches the real home: the database lives under `System.tmp_dir!/0`
  and is removed through `FermixTestSupport.SafeRm` when the test exits.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias Exqlite.Sqlite3
  alias FermixCore.Cues.Item
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpAllowSql

  @doc """
  Starts a Repo on a fresh temp database and opens a second connection to it.
  Returns `%{repo: name, db_path: path, conn: conn}`.
  """
  @spec start_repo(String.t()) :: %{repo: atom(), db_path: String.t(), conn: term()}
  def start_repo(tag) when is_binary(tag) do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-cues-#{tag}-#{unique}.db")
    repo = :"cues_repo_#{tag}_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    conn = open_conn(db_path)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path, conn: conn}
  end

  @doc "Opens a direct connection to `db_path`, closed when the test exits."
  @spec open_conn(String.t()) :: term()
  def open_conn(db_path) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;")
    on_exit(fn -> Sqlite3.close(conn) end)
    conn
  end

  @doc "All rows of `sql`, as lists."
  @spec rows(term(), String.t(), list()) :: [list()]
  def rows(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = if params == [], do: :ok, else: Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  @doc "Runs one statement that returns no rows."
  @spec exec!(term(), String.t(), list()) :: :ok
  def exec!(conn, sql, params \\ []) do
    [] = rows(conn, sql, params)
    :ok
  end

  @doc """
  Inserts an enabled watcher listening to `sources`, with the memory source and
  cue-only job it needs. `attrs`: `:name`, `:filter` (`"llm"` or `"none"`),
  `:sources` (list of refs), `:listen_for` (its words, default none: an `llm`
  watcher with no words is offered nothing), `:enabled` (default true).
  Returns its id.
  """
  @spec insert_watcher(term(), map()) :: String.t()
  def insert_watcher(conn, attrs) when is_map(attrs) do
    unique = System.unique_integer([:positive])
    id = "cwt_test#{unique}"
    job_id = "job_test#{unique}"
    source_id = "src_test#{unique}"
    stamp = "2026-10-01T00:00:00.000000Z"

    exec!(
      conn,
      "INSERT INTO memory_sources (id, source_type, name, memory_scope) VALUES (?, 'job', ?, ?)",
      [source_id, "watcher task #{unique}", "job:#{job_id}"]
    )

    exec!(
      conn,
      """
      INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
        memory_source_id, created_by_trust)
      VALUES (?, ?, 'interval', '3600', 'Etc/UTC', 'Report it.', ?, 'operator')
      """,
      [job_id, "watcher task #{unique}", source_id]
    )

    exec!(
      conn,
      """
      INSERT INTO cue_watchers (id, name, filter, listen_for, task_job_id, enabled, created_at,
        updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        Map.get(attrs, :name, "watcher-#{unique}"),
        Map.fetch!(attrs, :filter),
        Jason.encode!(Map.get(attrs, :listen_for, [])),
        job_id,
        if(Map.get(attrs, :enabled, true), do: 1, else: 0),
        stamp,
        stamp
      ]
    )

    Enum.each(Map.fetch!(attrs, :sources), fn ref ->
      exec!(conn, "INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES (?, ?)", [
        id,
        ref
      ])
    end)

    id
  end

  @doc """
  Always allows watcher `watcher_id`'s follow-up for what it runs and what sets
  it off now, written straight to its row as the owner's Always allow on a card
  writes it. Returns the digest it allowed.
  """
  @spec always_allow!(term(), String.t()) :: String.t()
  def always_allow!(conn, watcher_id) when is_binary(watcher_id) do
    {:ok, digest} = CuesFollowUpAllowSql.current_digest(conn, watcher_id)

    exec!(
      conn,
      "UPDATE cue_watchers SET follow_up_approved_at = ?, follow_up_approval_digest = ? " <>
        "WHERE id = ?",
      ["2026-10-01T00:00:00.000000Z", digest, watcher_id]
    )

    digest
  end

  @doc "A valid item built at `now`; raises when the fields are refused."
  @spec item!(map(), DateTime.t()) :: Item.t()
  def item!(fields, now) do
    {:ok, item} = Item.new(fields, now)
    item
  end
end
