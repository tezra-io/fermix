defmodule FermixCore.Memory.RepoJobHealsDiagnosisMigrationTest do
  # M106 §5.5, §5.9 (stage S3): what a heal's diagnosis decided, its note, its
  # change and its conclusion are columns on `job_heals`, this milestone's own
  # table read by column name, added under one version after 71. `job_runs`
  # and `scheduled_jobs`, which older engines read by position, keep their
  # widths. Membership, never list equality: the versions before stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 72
  @at "2031-03-04T07:10:00.000000Z"

  @heal_columns_71 ~w(id subject_kind subject_id job_id failure_kind failure_text failure_words
                      state outcome run_count last_run_id last_failed_at opened_at updated_at
                      waiting_since closed_at lease_token lease_until message inbox_platform
                      inbox_destination inbox_thread_scope delivery_status delivery_attempts
                      next_delivery_at last_delivery_error delivered_at)
  @added ~w(conclusion decision note read_outside change_json change_job_version rerun_at
            rerun_outcome)
  # The column 73 adds after these (`RepoJobRunTallyMigrationTest`), and the
  # ones 74 adds after it (`RepoJobHealsAnswerMigrationTest`).
  @tool_columns ~w(tool_json)
  @answer_columns ~w(change_job_digest answer answered_at decided_from applied_at owner_wrote_at)
  @scheduled_job_width 36
  @job_run_width 24

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heals-diagnosis-#{unique}.db")
    repo = :"memory_repo_job_heals_diagnosis_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh store's heals have the added columns, and no other table widens", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions

    assert columns(db_path, "job_heals") ==
             @heal_columns_71 ++ @added ++ @tool_columns ++ @answer_columns

    assert length(columns(db_path, "scheduled_jobs")) == @scheduled_job_width
    assert length(columns(db_path, "job_runs")) == @job_run_width
    assert columns(db_path, "job_heal_runs") == ~w(run_id heal_id job_id)
  end

  test "the added columns' own checks hold", %{db_path: db_path} do
    seed_job(db_path)
    insert_heal(db_path, "jhl_one", "")

    for set <- [
          "conclusion = 'third'",
          "decision = 'remove'",
          "read_outside = 2",
          "rerun_outcome = 'maybe'"
        ] do
      assert {:error, _reason} =
               try_raw(db_path, "UPDATE job_heals SET #{set} WHERE id = 'jhl_one'")
    end

    assert rows(db_path, "SELECT conclusion, decision FROM job_heals") == [["first", nil]]
  end

  test "a store at 71 migrates, keeping its heals, and reapplying changes nothing", %{
    repo: repo,
    db_path: db_path
  } do
    seed_job(db_path)
    stop_supervised!(:first)

    # A store at 71 has none of the versions that widen its table.
    raw(db_path, """
    DROP INDEX IF EXISTS job_heals_watching;
    #{Enum.map_join(@added ++ @tool_columns ++ @answer_columns, "\n", &"ALTER TABLE job_heals DROP COLUMN #{&1};")}
    DELETE FROM schema_migrations WHERE version IN (#{@version}, 73, 74);
    """)

    assert columns(db_path, "job_heals") == @heal_columns_71
    insert_heal(db_path, "jhl_kept", "")

    reopen(repo, db_path, :second)

    assert columns(db_path, "job_heals") ==
             @heal_columns_71 ++ @added ++ @tool_columns ++ @answer_columns

    assert rows(db_path, "SELECT id, conclusion, decision FROM job_heals") == [
             ["jhl_kept", "first", nil]
           ]

    stop_supervised!(:second)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path, :third)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1

    assert columns(db_path, "job_heals") ==
             @heal_columns_71 ++ @added ++ @tool_columns ++ @answer_columns
  end

  test "a table that holds neither column set is refused, never rewritten", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)

    raw(db_path, """
    ALTER TABLE job_heals DROP COLUMN rerun_at;
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _reason} =
               start_supervised({Repo, name: repo, enabled: true, database_path: db_path},
                 id: :refused
               )
    end)

    assert "rerun_at" not in columns(db_path, "job_heals")
    assert "conclusion" in columns(db_path, "job_heals")
  end

  defp reopen(repo, db_path, id) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: id)
  end

  defp seed_job(db_path) do
    raw(db_path, """
    INSERT INTO memory_sources (id, source_type, name, memory_scope)
      VALUES ('job:job_heals', 'scheduled_job', 'Harbour tide table', 'job:job_heals');
    INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
      memory_source_id, created_by_trust)
      VALUES ('job_heals', 'Harbour tide table', 'interval', 'every 1 hour', 'UTC',
        'Fetch this morning''s tides.', 'job:job_heals', 'operator');
    """)
  end

  defp insert_heal(db_path, id, _extra) do
    raw(db_path, """
    INSERT INTO job_heals (id, subject_kind, subject_id, job_id, failure_kind, failure_text,
      state, run_count, opened_at, updated_at, delivery_status)
    VALUES ('#{id}', 'job', 'job_heals', 'job_heals', 'time_limit', 'The run timed out.',
      'open', 1, '#{@at}', '#{@at}', 'pending');
    """)
  end

  defp columns(db_path, table),
    do: db_path |> rows("SELECT name FROM pragma_table_info('#{table}')") |> List.flatten()

  defp raw(db_path, sql), do: :ok = try_raw(db_path, sql)

  defp try_raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000; PRAGMA foreign_keys = ON;")
      Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp rows(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end
end
