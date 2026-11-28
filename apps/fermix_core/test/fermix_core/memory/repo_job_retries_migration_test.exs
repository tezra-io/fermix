defmodule FermixCore.Memory.RepoJobRetriesMigrationTest do
  # M106 §5.3: a job's retry state lives in a table of its own, `job_retries`,
  # made under one version. `scheduled_jobs` and `job_runs` keep exactly the
  # columns they had: every engine at the current home format reads both with
  # `SELECT *` into a fixed number of fields (`Home.Readable`). Membership,
  # never list equality: the versions before it stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 70
  @at ~U[2026-11-20 06:30:00.000000Z]

  # Both tables as an engine at home format 1 reads them, in order.
  @scheduled_job_columns ~w(id name description schedule_kind schedule_expr timezone next_run_at
                            task_prompt skill_name session_mode provider model max_iterations
                            timeout_seconds inactivity_timeout_seconds capability_policy_json
                            allowed_tools_json memory_source_id memory_read_scopes_json
                            memory_write_scope main_visible delivery_mode delivery_target_json
                            silent_marker enabled state last_run_at last_status last_error
                            created_by_agent_id created_by_session_id created_at updated_at
                            expires_at created_by_channel created_by_trust)
  @job_run_columns ~w(id job_id session_id trigger status claimed_at started_at completed_at
                      prompt_snapshot job_config_snapshot_json capability_policy_snapshot_json
                      output_ref final_response error delivery_status delivery_error iterations
                      token_usage_json latency_json created_at updated_at tool_failures
                      tools_started_at cue_delivery_id)

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-retries-migration-#{unique}.db")
    repo = :"memory_repo_job_retries_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    :ok = create_job(repo)
    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has the retries table, and the job and run tables keep their widths", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert columns(db_path, "job_retries") == ~w(job_id attempts retry_at)
    assert columns(db_path, "scheduled_jobs") == @scheduled_job_columns
    assert columns(db_path, "job_runs") == @job_run_columns

    seed_retry(db_path, 2)
    assert [row] = rows(db_path, "SELECT * FROM scheduled_jobs WHERE id = ?", ["job_retries"])
    assert length(row) == length(@scheduled_job_columns)
    assert {:ok, %{attempts: 2}} = Repo.get_job_retry("job_retries", server: repo)
  end

  # What lets an engine at the current format delete a job a newer engine
  # retried: foreign keys are on, so the job takes its retry row with it.
  test "a deleted job takes its retry row with it", %{repo: repo, db_path: db_path} do
    seed_retry(db_path, 1)

    assert :ok = Repo.delete_scheduled_job("job_retries", server: repo)
    assert rows(db_path, "SELECT count(*) FROM job_retries", []) == [[0]]
  end

  # The upgrade: a store the previous release wrote gains the table, and its
  # jobs read back with no retry.
  test "a store from before the table migrates, and its jobs have no retry", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)

    raw(db_path, """
    DROP TABLE job_retries;
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    assert columns(db_path, "job_retries") == []
    reopen(repo, db_path)

    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert columns(db_path, "job_retries") == ~w(job_id attempts retry_at)
    assert columns(db_path, "scheduled_jobs") == @scheduled_job_columns
    assert {:ok, nil} = Repo.get_job_retry("job_retries", server: repo)

    assert {:ok, %{name: "Harbour tide table"}} =
             Repo.get_scheduled_job("job_retries", server: repo)
  end

  # A version row lost while the table stands: the migration runs again, keeps
  # the table and its rows, and records its version once.
  test "reapplying the migration changes nothing", %{repo: repo, db_path: db_path} do
    seed_retry(db_path, 3)
    stop_supervised!(:first)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert {:ok, %{attempts: 3}} = Repo.get_job_retry("job_retries", server: repo)
  end

  defp reopen(repo, db_path) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :reopened)
  end

  defp seed_retry(db_path, attempts) do
    raw(db_path, """
    INSERT INTO job_retries (job_id, attempts, retry_at)
    VALUES ('job_retries', #{attempts}, '#{DateTime.to_iso8601(@at)}');
    """)
  end

  defp create_job(repo) do
    {:ok, _job} =
      Repo.create_job_with_source(
        %{
          id: "job_retries",
          name: "Harbour tide table",
          schedule_kind: "interval",
          schedule_expr: "every 1 hour",
          timezone: "UTC",
          next_run_at: @at,
          task_prompt: "Fetch this morning's tides.",
          memory_source_id: "job:job_retries",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator"
        },
        %{
          id: "job:job_retries",
          source_type: "scheduled_job",
          name: "Harbour tide table",
          memory_scope: "job:job_retries",
          output_scope: "cron:job_retries"
        },
        server: repo
      )

    :ok
  end

  defp columns(db_path, table),
    do: db_path |> rows("SELECT name FROM pragma_table_info(?)", [table]) |> List.flatten()

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp rows(db_path, sql, params) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end
end
