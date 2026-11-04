defmodule FermixCore.Memory.RepoFollowUpAlwaysAllowMigrationTest do
  # Migration 58 (M60_WATCHER_CODING_RUNS.md, the 2026-10-31 revision): Always
  # allow replaces automatic mode. `cue_watchers` loses `follow_up_mode`: an
  # automatic follow-up whose approval still matches what it runs and what
  # sets it off stays allowed, and every other follow-up asks first. The
  # approval prompts' table goes with its rows, so a prompt waiting at the
  # upgrade is dropped, and a follow-up's trigger gains the digest its card
  # showed and what the owner's Always allow came to. The test seeds a store
  # as it stood before 58, with nothing in config.toml, and opens it twice.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpAllowSql

  @version 58
  @stamp "2026-10-01T00:00:00.000000Z"

  # `cue_watchers` as migration 54 left it, the approval prompts' table, and the
  # trigger table without the columns 58 adds.
  @store_57 """
  CREATE TABLE cue_watchers_57 (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    purpose TEXT,
    filter TEXT NOT NULL CHECK (filter IN ('llm','none')),
    task_job_id TEXT UNIQUE REFERENCES scheduled_jobs(id),
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
    updated_at TEXT NOT NULL,
    listen_for TEXT NOT NULL DEFAULT '[]',
    follow_up_job_id TEXT UNIQUE REFERENCES scheduled_jobs(id),
    follow_up_mode TEXT CHECK (follow_up_mode IN ('approve','auto')),
    follow_up_approved_at TEXT,
    follow_up_approval_digest TEXT,
    CHECK (task_job_id IS NOT NULL OR follow_up_job_id IS NOT NULL),
    CHECK ((follow_up_job_id IS NULL) = (follow_up_mode IS NULL)),
    CHECK ((follow_up_approved_at IS NULL) = (follow_up_approval_digest IS NULL))
  );
  DROP TABLE cue_watchers;
  ALTER TABLE cue_watchers_57 RENAME TO cue_watchers;
  CREATE TABLE cue_follow_up_approvals (
    id TEXT PRIMARY KEY,
    watcher_id TEXT NOT NULL,
    shown_digest TEXT NOT NULL,
    token_digest TEXT UNIQUE,
    chat_platform TEXT,
    chat_id TEXT,
    chat_user_id TEXT,
    expires_at TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('waiting','approved','denied','expired')),
    decided_from TEXT,
    decided_at TEXT,
    created_at TEXT NOT NULL,
    CHECK ((state IN ('approved','denied')) = (decided_at IS NOT NULL))
  );
  CREATE INDEX cue_follow_up_approvals_state ON cue_follow_up_approvals (state, expires_at);
  ALTER TABLE cue_follow_up_triggers DROP COLUMN shown_digest;
  ALTER TABLE cue_follow_up_triggers DROP COLUMN always_allow;
  """

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-always-allow-migration-#{unique}.db")
    repo = :"memory_repo_always_allow_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has no mode, no prompts' table, and the trigger's two columns", ctx do
    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions

    watchers = columns(ctx.db_path, "cue_watchers")
    refute Map.has_key?(watchers, "follow_up_mode")
    assert Map.has_key?(watchers, "follow_up_approval_digest")
    assert tables(ctx.db_path, "cue_follow_up_approvals") == []

    triggers = columns(ctx.db_path, "cue_follow_up_triggers")
    assert Map.has_key?(triggers, "shown_digest")
    assert Map.has_key?(triggers, "always_allow")
  end

  test "an upgraded store keeps a matching automatic approval and asks first for the rest",
       ctx do
    stop_supervised!(:first)
    seed_store_57(ctx.db_path)

    reopen(ctx, :second)
    assert_upgraded(ctx)

    # Run again, as a store that lost its version row would: nothing moves.
    stop_supervised!(:second)
    raw(ctx.db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(ctx, :third)
    assert_upgraded(ctx)
  end

  test "an always-allowed follow-up needs a follow-up on its watcher", ctx do
    stop_supervised!(:first)

    assert {:error, message} =
             raw_result(ctx.db_path, """
             INSERT INTO memory_sources (id, source_type, name, memory_scope)
               VALUES ('src_t', 'job', 'task', 'job:job_t');
             INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone,
               task_prompt, memory_source_id, created_by_trust)
               VALUES ('job_t', 'task', 'cue', 'cue', 'UTC', 'Report it.', 'src_t', 'operator');
             INSERT INTO cue_watchers (id, name, filter, task_job_id, follow_up_approved_at,
               follow_up_approval_digest, created_at, updated_at)
             VALUES ('cwt_t', 'task-only', 'none', 'job_t', '#{@stamp}', 'digest', '#{@stamp}',
               '#{@stamp}');
             """)

    assert message =~ "CHECK constraint failed"
  end

  test "a store holding a column the copy would leave behind is refused, not cut", ctx do
    stop_supervised!(:first)
    seed_store_57(ctx.db_path)
    raw(ctx.db_path, "ALTER TABLE cue_watchers ADD COLUMN extra TEXT;")

    assert {:error, _reason} =
             start_supervised({Repo, name: ctx.repo, enabled: true, database_path: ctx.db_path},
               id: :refused
             )

    assert Map.has_key?(columns(ctx.db_path, "cue_watchers"), "follow_up_mode")
    assert tables(ctx.db_path, "cue_follow_up_approvals") == [["cue_follow_up_approvals"]]

    refute @version in List.flatten(
             raw_rows(ctx.db_path, "SELECT version FROM schema_migrations")
           )
  end

  defp assert_upgraded(ctx) do
    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions

    refute Map.has_key?(columns(ctx.db_path, "cue_watchers"), "follow_up_mode")

    assert [
             ["cwt_ask", "job_ask", nil],
             ["cwt_auto", "job_auto", digest],
             ["cwt_stale", "job_stale", nil],
             ["cwt_task", nil, nil]
           ] =
             raw_rows(
               ctx.db_path,
               "SELECT id, follow_up_job_id, follow_up_approval_digest FROM cue_watchers " <>
                 "ORDER BY id"
             )

    assert digest == current_digest(ctx.db_path, "cwt_auto")

    # The children of the rebuilt table, its other index, and the prompts gone.
    assert [["cwt_auto", "src-a"]] =
             raw_rows(ctx.db_path, "SELECT watcher_id, source_ref FROM cue_watcher_sources")

    assert "cue_watchers_other_enabled" in index_names(ctx.db_path, "cue_watchers")
    assert tables(ctx.db_path, "cue_follow_up_approvals") == []

    # A card that waited at the upgrade still waits, with no digest it showed.
    assert [["cft_waiting", "waiting", nil, nil]] =
             raw_rows(
               ctx.db_path,
               "SELECT id, state, shown_digest, always_allow FROM cue_follow_up_triggers"
             )
  end

  # --- the store as it stood before 58 --------------------------------------------------

  # A task-only watcher; an automatic follow-up approved for what it is now; one
  # approved for what it was before a change; one that asks first; a prompt and
  # a card each waiting.
  defp seed_store_57(db_path) do
    raw(db_path, "PRAGMA foreign_keys=OFF;")

    raw(db_path, """
    BEGIN;
    #{@store_57}
    DELETE FROM schema_migrations WHERE version = #{@version};
    COMMIT;
    """)

    raw(db_path, """
    PRAGMA foreign_keys=ON;
    INSERT INTO memory_sources (id, source_type, name, memory_scope)
      VALUES ('src_old', 'job', 'old jobs', 'job:job_task');
    #{job_sql("job_task", "cue", "Report it.")}
    #{job_sql("job_auto", "watcher", "Review the commits of the last day.")}
    #{job_sql("job_stale", "watcher", "Run the deploy check.")}
    #{job_sql("job_ask", "watcher", "Post in ops.")}
    INSERT INTO cue_watchers (id, name, filter, task_job_id, created_at, updated_at)
      VALUES ('cwt_task', 'task', 'none', 'job_task', '#{@stamp}', '#{@stamp}');
    #{follow_up_watcher_sql("cwt_auto", "job_auto", "auto")}
    #{follow_up_watcher_sql("cwt_stale", "job_stale", "auto")}
    #{follow_up_watcher_sql("cwt_ask", "job_ask", "approve")}
    INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES ('cwt_auto', 'src-a');
    INSERT INTO cues (id, source_ref, item_id, received_at, content_hash, last_seen_at)
      VALUES (1, 'src-a', 'item-1', '#{@stamp}', 'h1', '#{@stamp}');
    INSERT INTO cue_deliveries (id, cue_id, watcher_id, source_ref, received_at, state, outcome,
      ready_at, valid_until, settled_at)
      VALUES (1, 1, 'cwt_ask', 'src-a', '#{@stamp}', 'acked', 'follow_up', '#{@stamp}',
        '#{@stamp}', '#{@stamp}');
    INSERT INTO cue_follow_up_triggers (id, watcher_id, delivery_id, cue_id, job_id, mode, state,
      expires_at, created_at)
      VALUES ('cft_waiting', 'cwt_ask', 1, 1, 'job_ask', 'approve', 'waiting', '#{@stamp}',
        '#{@stamp}');
    INSERT INTO cue_follow_up_approvals (id, watcher_id, shown_digest, expires_at, state,
      created_at)
      VALUES ('cfa_waiting', 'cwt_stale', 'shown', '#{@stamp}', 'waiting', '#{@stamp}');
    CREATE INDEX cue_watchers_other_enabled ON cue_watchers (enabled, name);
    """)

    approve(db_path, "cwt_auto", current_digest(db_path, "cwt_auto"))
    approve(db_path, "cwt_stale", "a digest of what it ran before")
  end

  defp job_sql(id, kind, prompt) do
    """
    INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
      allowed_tools_json, memory_source_id, created_by_trust)
      VALUES ('#{id}', '#{id}', '#{kind}', '#{kind}', 'UTC', '#{prompt}', '["shell"]', 'src_old',
        'operator');
    """
  end

  defp follow_up_watcher_sql(id, job_id, mode) do
    """
    INSERT INTO cue_watchers (id, name, filter, follow_up_job_id, follow_up_mode, created_at,
      updated_at)
      VALUES ('#{id}', '#{id}', 'none', '#{job_id}', '#{mode}', '#{@stamp}', '#{@stamp}');
    """
  end

  defp approve(db_path, watcher_id, digest) do
    raw(db_path, """
    UPDATE cue_watchers SET follow_up_approved_at = '#{@stamp}',
      follow_up_approval_digest = '#{digest}' WHERE id = '#{watcher_id}';
    """)
  end

  # --- plumbing -------------------------------------------------------------------------

  defp reopen(ctx, id) do
    start_supervised!({Repo, name: ctx.repo, enabled: true, database_path: ctx.db_path}, id: id)
  end

  defp current_digest(db_path, watcher_id) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      {:ok, digest} = CuesFollowUpAllowSql.current_digest(conn, watcher_id)
      digest
    after
      Sqlite3.close(conn)
    end
  end

  defp columns(db_path, table) do
    db_path
    |> raw_rows("SELECT name, \"notnull\" FROM pragma_table_info('#{table}')")
    |> Map.new(fn [name, notnull] -> {name, notnull} end)
  end

  defp tables(db_path, name),
    do:
      raw_rows(
        db_path,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '#{name}'"
      )

  defp index_names(db_path, table) do
    db_path
    |> raw_rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = '#{table}'")
    |> List.flatten()
  end

  defp raw(db_path, sql), do: :ok = raw_result(db_path, sql)

  defp raw_result(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp raw_rows(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end
end
