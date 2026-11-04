defmodule FermixCore.Memory.RepoFollowUpMigrationTest do
  # Migration 54 (M60_WATCHER_CODING_RUNS.md §4.1, §4.3) rebuilds `cue_watchers`
  # (a nullable task, the follow-up's columns) and `cue_deliveries` (the
  # outcome `follow_up`) and adds the trigger table. A rebuild drops a table,
  # so the test seeds a store as it stood before 54 and checks that nothing a
  # drop could take went with it: a cascading child row, an index another
  # migration made, the AUTOINCREMENT counter, and a column the copy would
  # not carry.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 54
  @stamp "2026-10-01T00:00:00.000000Z"

  @watchers_53 """
  CREATE TABLE cue_watchers_53 (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    purpose TEXT,
    filter TEXT NOT NULL CHECK (filter IN ('llm','none')),
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
    updated_at TEXT NOT NULL,
    listen_for TEXT NOT NULL DEFAULT '[]'
  );
  INSERT INTO cue_watchers_53 SELECT id, name, purpose, filter, task_job_id, task_notes,
    daily_cap, filter_budget, filter_failures, filter_retry_at, held_notified_at, notices,
    enabled, created_from, created_at, updated_at, listen_for FROM cue_watchers;
  DROP TABLE cue_watchers;
  ALTER TABLE cue_watchers_53 RENAME TO cue_watchers;
  DROP TABLE cue_follow_up_triggers;
  """

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-follow-up-migration-#{unique}.db")
    repo = :"memory_repo_follow_up_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has a nullable task, the follow-up columns and the trigger table", ctx do
    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions

    columns = columns(ctx.db_path, "cue_watchers")
    assert columns["task_job_id"] == 0
    assert Map.has_key?(columns, "follow_up_job_id")
    assert Map.has_key?(columns, "follow_up_approved_at")
    assert Map.has_key?(columns, "follow_up_approval_digest")
    assert "cue_follow_up_triggers_state" in index_names(ctx.db_path, "cue_follow_up_triggers")
  end

  test "an upgraded store keeps every row, child row, index and id, and takes follow_up", ctx do
    stop_supervised!(:first)
    seed_store_53(ctx.db_path)

    reopen(ctx.repo, ctx.db_path)

    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions

    # The watcher and its cascading children survived the drop of their parent.
    assert [["cwt_old", "job_old"]] =
             raw_rows(ctx.db_path, "SELECT id, task_job_id FROM cue_watchers")

    assert [["src-a"]] = raw_rows(ctx.db_path, "SELECT source_ref FROM cue_watcher_sources")

    assert [["Pass launches"]] =
             raw_rows(ctx.db_path, "SELECT text FROM cue_watcher_instructions")

    # The other migration's index came back, and so did the delivery ids.
    assert "cue_deliveries_other_window" in index_names(ctx.db_path, "cue_deliveries")
    assert "cue_deliveries_watcher_state" in index_names(ctx.db_path, "cue_deliveries")
    assert [[1]] = raw_rows(ctx.db_path, "SELECT id FROM cue_deliveries")

    # A pruned delivery's id (7) is never given out again.
    raw(ctx.db_path, insert_delivery_sql({nil, 3}, "acked", "'follow_up'", "'#{@stamp}'"))
    assert [[1], [8]] = raw_rows(ctx.db_path, "SELECT id FROM cue_deliveries ORDER BY id")

    # A watcher with only a follow-up may now be stored.
    raw(ctx.db_path, """
    INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
      memory_source_id, created_by_trust)
    VALUES ('job_fu', 'fu', 'watcher', 'watcher', 'UTC', 'Run it.', 'src_old', 'operator');
    INSERT INTO cue_watchers (id, name, filter, follow_up_job_id, created_at, updated_at)
    VALUES ('cwt_fu', 'fu-only', 'none', 'job_fu', '#{@stamp}', '#{@stamp}');
    """)

    assert [["cwt_fu"]] =
             raw_rows(ctx.db_path, "SELECT id FROM cue_watchers WHERE task_job_id IS NULL")
  end

  test "a watcher with neither a task nor a follow-up is refused by the table", ctx do
    stop_supervised!(:first)

    assert {:error, message} =
             raw_result(ctx.db_path, """
             INSERT INTO cue_watchers (id, name, filter, created_at, updated_at)
             VALUES ('cwt_none', 'none', 'none', '#{@stamp}', '#{@stamp}');
             """)

    assert message =~ "CHECK constraint failed"
  end

  test "a store holding a column the copy would leave behind is refused, not cut", ctx do
    stop_supervised!(:first)
    seed_store_53(ctx.db_path)
    raw(ctx.db_path, "ALTER TABLE cue_deliveries ADD COLUMN extra TEXT;")

    assert {:error, _reason} =
             start_supervised({Repo, name: ctx.repo, enabled: true, database_path: ctx.db_path},
               id: :refused
             )

    assert [["extra"]] =
             raw_rows(
               ctx.db_path,
               "SELECT name FROM pragma_table_info('cue_deliveries') WHERE name = 'extra'"
             )

    refute @version in List.flatten(
             raw_rows(ctx.db_path, "SELECT version FROM schema_migrations")
           )
  end

  test "a store that holds 54's shape but lost its version row reapplies nothing", ctx do
    stop_supervised!(:first)
    seed_store_53(ctx.db_path)
    reopen(ctx.repo, ctx.db_path)
    stop_supervised!(:second)

    raw(ctx.db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    raw(ctx.db_path, insert_delivery_sql({nil, 3}, "acked", "'follow_up'", "'#{@stamp}'"))

    start_supervised!({Repo, name: ctx.repo, enabled: true, database_path: ctx.db_path},
      id: :third
    )

    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions
    assert [[1], [8]] = raw_rows(ctx.db_path, "SELECT id FROM cue_deliveries ORDER BY id")
    assert "cue_deliveries_other_window" in index_names(ctx.db_path, "cue_deliveries")
  end

  # --- the store as it stood before 54 --------------------------------------------------

  # Back to the tables 53 left (a task always set, no trigger table), with a
  # watcher, its children, a delivery kept and one pruned, and an index
  # another migration added. Migration 58, which reshapes what 54 made, runs
  # again after it.
  defp seed_store_53(db_path) do
    raw(db_path, "PRAGMA foreign_keys=OFF;")

    raw(db_path, """
    BEGIN;
    #{@watchers_53}
    DELETE FROM schema_migrations WHERE version IN (#{@version}, 58);
    COMMIT;
    """)

    raw(db_path, """
    PRAGMA foreign_keys=ON;
    INSERT INTO memory_sources (id, source_type, name, memory_scope)
      VALUES ('src_old', 'job', 'old task', 'job:job_old');
    INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
      memory_source_id, created_by_trust)
      VALUES ('job_old', 'old task', 'cue', 'cue', 'UTC', 'Report it.', 'src_old', 'operator');
    INSERT INTO cue_watchers (id, name, filter, task_job_id, created_at, updated_at)
      VALUES ('cwt_old', 'old', 'none', 'job_old', '#{@stamp}', '#{@stamp}');
    INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES ('cwt_old', 'src-a');
    INSERT INTO cue_watcher_instructions (id, watcher_id, number, text, added_at)
      VALUES ('cwi_1', 'cwt_old', 1, 'Pass launches', '#{@stamp}');
    INSERT INTO cues (id, source_ref, item_id, received_at, content_hash, last_seen_at)
      VALUES (1, 'src-a', 'item-1', '#{@stamp}', 'h1', '#{@stamp}'),
             (2, 'src-a', 'item-2', '#{@stamp}', 'h2', '#{@stamp}'),
             (3, 'src-a', 'item-3', '#{@stamp}', 'h3', '#{@stamp}');
    CREATE INDEX cue_deliveries_other_window ON cue_deliveries (received_at, watcher_id);
    """)

    raw(db_path, insert_delivery_sql({1, 1}, "acked", "'acted'", "'#{@stamp}'"))
    raw(db_path, insert_delivery_sql({7, 2}, "acked", "'acted'", "'#{@stamp}'"))
    raw(db_path, "DELETE FROM cue_deliveries WHERE id = 7;")
  end

  defp insert_delivery_sql({id, cue_id}, state, outcome, settled_at) do
    {id_column, id_value} = if id, do: {"id, ", "#{id}, "}, else: {"", ""}

    """
    INSERT INTO cue_deliveries (#{id_column}cue_id, watcher_id, source_ref, received_at, state,
      outcome, ready_at, valid_until, settled_at)
    VALUES (#{id_value}#{cue_id}, 'cwt_old', 'src-a', '#{@stamp}', '#{state}', #{outcome},
      '#{@stamp}', '#{@stamp}', #{settled_at});
    """
  end

  # --- plumbing -------------------------------------------------------------------------

  defp reopen(repo, db_path) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :second)
  end

  defp columns(db_path, table) do
    db_path
    |> raw_rows("SELECT name, \"notnull\" FROM pragma_table_info('#{table}')")
    |> Map.new(fn [name, notnull] -> {name, notnull} end)
  end

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
