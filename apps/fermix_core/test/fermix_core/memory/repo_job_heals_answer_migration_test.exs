defmodule FermixCore.Memory.RepoJobHealsAnswerMigrationTest do
  # M106 §5.7 and decision D5 (stage S4): the version of the job a proposal
  # was drawn for, the owner's answer to it (which answer, when, from which
  # surface, and when the change was applied), and the mark of an owner's
  # write while a heal run diagnoses (JOB-12) are columns on `job_heals`,
  # this milestone's own table read by column name, added under one version
  # after 73. `job_runs` and `scheduled_jobs`, which an engine at the current
  # home format reads by position, keep their widths. Membership, never list
  # equality: the versions before stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 74
  @at "2031-03-04T07:10:00.000000Z"

  @heal_columns_73 ~w(id subject_kind subject_id job_id failure_kind failure_text failure_words
                      state outcome run_count last_run_id last_failed_at opened_at updated_at
                      waiting_since closed_at lease_token lease_until message inbox_platform
                      inbox_destination inbox_thread_scope delivery_status delivery_attempts
                      next_delivery_at last_delivery_error delivered_at conclusion decision note
                      read_outside change_json change_job_version rerun_at rerun_outcome
                      tool_json)
  @added ~w(change_job_digest answer answered_at decided_from applied_at owner_wrote_at)
  @scheduled_job_width 36
  @job_run_width 24

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heals-answer-#{unique}.db")
    repo = :"memory_repo_job_heals_answer_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh store's heals have the added columns, and no table read by position widens",
       %{repo: repo, db_path: db_path} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert columns(db_path, "job_heals") == @heal_columns_73 ++ @added
    assert length(columns(db_path, "scheduled_jobs")) == @scheduled_job_width
    assert length(columns(db_path, "job_runs")) == @job_run_width
    assert columns(db_path, "job_heal_runs") == ~w(run_id heal_id job_id)
  end

  test "the answer column's own check holds", %{db_path: db_path} do
    seed_job(db_path)
    insert_heal(db_path, "jhl_one")

    assert {:error, _reason} =
             try_raw(db_path, "UPDATE job_heals SET answer = 'maybe' WHERE id = 'jhl_one'")

    for answer <- ["apply", "leave"] do
      assert :ok =
               try_raw(db_path, "UPDATE job_heals SET answer = '#{answer}' WHERE id = 'jhl_one'")
    end
  end

  test "a store at 73 migrates, keeping its heals, and reapplying changes nothing", %{
    repo: repo,
    db_path: db_path
  } do
    seed_job(db_path)
    stop_supervised!(:first)

    raw(db_path, """
    #{Enum.map_join(@added, "\n", &"ALTER TABLE job_heals DROP COLUMN #{&1};")}
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    assert columns(db_path, "job_heals") == @heal_columns_73
    insert_heal(db_path, "jhl_kept")

    reopen(repo, db_path, :second)
    assert columns(db_path, "job_heals") == @heal_columns_73 ++ @added

    assert {:ok, %{state: "open", answer: nil, answered_at: nil, change_job_digest: nil}} =
             Repo.job_heals_call({:get, "jhl_kept"}, server: repo)

    stop_supervised!(:second)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path, :third)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert columns(db_path, "job_heals") == @heal_columns_73 ++ @added
  end

  test "a table that holds neither column set is refused, never rewritten", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)

    raw(db_path, """
    ALTER TABLE job_heals DROP COLUMN applied_at;
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _reason} =
               start_supervised({Repo, name: repo, enabled: true, database_path: db_path},
                 id: :refused
               )
    end)

    assert "applied_at" not in columns(db_path, "job_heals")
    assert "answer" in columns(db_path, "job_heals")
  end

  defp reopen(repo, db_path, id) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: id)
  end

  defp seed_job(db_path) do
    raw(db_path, """
    INSERT INTO memory_sources (id, source_type, name, memory_scope)
      VALUES ('job:job_answer', 'scheduled_job', 'Harbour tide table', 'job:job_answer');
    INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
      memory_source_id, created_by_trust)
      VALUES ('job_answer', 'Harbour tide table', 'interval', 'every 1 hour', 'UTC',
        'Fetch this morning''s tides.', 'job:job_answer', 'operator');
    """)
  end

  defp insert_heal(db_path, id) do
    raw(db_path, """
    INSERT INTO job_heals (id, subject_kind, subject_id, job_id, failure_kind, failure_text,
      state, run_count, opened_at, updated_at, delivery_status)
    VALUES ('#{id}', 'job', 'job_answer', 'job_answer', 'time_limit', 'The run timed out.',
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
