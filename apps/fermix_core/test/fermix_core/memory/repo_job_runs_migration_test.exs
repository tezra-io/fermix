defmodule FermixCore.Memory.RepoJobRunsMigrationTest do
  # The job run row gains `tool_failures` under its own version, appended by
  # `ALTER TABLE` so an existing database keeps every row it has. Membership,
  # never list equality: the versions before it stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql

  @tool_failures_version 29
  @at ~U[2026-09-16 11:15:01Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-runs-migration-#{unique}.db")
    repo_name = :"memory_repo_job_runs_migration_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "the tool failures migration is applied on a fresh database", %{repo: repo} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @tool_failures_version in versions
  end

  test "rerunning migrate is idempotent", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)

    assert @tool_failures_version in versions
    assert length(versions) == length(Enum.uniq(versions))
  end

  test "a run's tool failure count round-trips, and an unset count reads as absent", %{
    repo: repo
  } do
    assert {:ok, _job} = create_job(repo)

    assert {:ok, counted} =
             Repo.upsert_job_run(run_attrs("run_counted", tool_failures: 2), server: repo)

    assert counted.tool_failures == 2

    assert {:ok, fetched} = Repo.get_job_run("run_counted", server: repo)
    assert fetched.tool_failures == 2

    assert {:ok, uncounted} = Repo.upsert_job_run(run_attrs("run_uncounted", []), server: repo)
    assert uncounted.tool_failures == nil

    assert {:ok, listed} = Repo.list_job_runs(%{job_id: "job_migration"}, server: repo)

    assert Enum.map(listed, &{&1.id, &1.tool_failures}) |> Enum.sort() ==
             [{"run_counted", 2}, {"run_uncounted", nil}]
  end

  # The upgrade itself: a store the previous release wrote, with a run row in
  # the old shape, gains the column and reads that row back intact. The one
  # test that catches a positional mismatch between `SELECT *` and the row
  # decoder after `ALTER TABLE` appended the column.
  test "a row written before the column survives the upgrade and reads as absent" do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-runs-v28-#{unique}.db")

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    seed_v28_store!(db_path)
    repo = :"memory_repo_job_runs_v28_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :upgraded)

    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @tool_failures_version in versions

    assert {:ok, run} = Repo.get_job_run("run_old", server: repo)
    assert run.tool_failures == nil
    assert run.job_id == "job_old"
    assert run.session_id == "cron_job_old_run_old"
    assert run.status == "ok"
    assert run.final_response == "done before the column existed"
    assert run.iterations == 4
    assert run.token_usage == %{"total" => 64_245}
    assert run.delivery_status == "sent"
    assert run.created_at == @at
  end

  defp seed_v28_store!(path) do
    {:ok, conn} = Sqlite3.open(path, mode: :readwrite)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      );
      """)

    :ok = Sqlite3.execute(conn, Repo.base_schema_sql())
    :ok = Sqlite3.execute(conn, Repo.jobs_schema_sql())
    # The computer-history tables a v28 store holds: a later migration (32) reads
    # one of them, and a store that claims 28 without them is not a real one.
    :ok = Sqlite3.execute(conn, ComputerHistorySql.events_schema_sql())
    :ok = Sqlite3.execute(conn, ComputerHistorySql.memories_schema_sql())
    :ok = Sqlite3.execute(conn, ComputerHistorySql.state_schema_sql())
    :ok = Sqlite3.execute(conn, ComputerHistorySql.access_schema_sql())
    :ok = Sqlite3.execute(conn, ComputerHistorySql.sessions_schema_sql())

    :ok =
      Sqlite3.execute(conn, """
      INSERT INTO job_runs
        (id, job_id, session_id, trigger, status, final_response, delivery_status,
         iterations, token_usage_json, created_at, updated_at)
      VALUES ('run_old', 'job_old', 'cron_job_old_run_old', 'schedule', 'ok',
              'done before the column existed', 'sent', 4, '{"total":64245}',
              '#{DateTime.to_iso8601(@at)}', '#{DateTime.to_iso8601(@at)}');
      """)

    Enum.each(1..28, fn version ->
      :ok = Sqlite3.execute(conn, "INSERT INTO schema_migrations(version) VALUES (#{version});")
    end)

    :ok = Sqlite3.close(conn)
  end

  defp create_job(repo) do
    Repo.create_job_with_source(
      %{
        id: "job_migration",
        name: "Migration job",
        schedule_kind: "cron",
        schedule_expr: "15 7 * * 1-5",
        timezone: "America/New_York",
        task_prompt: "Prepare the outfit.",
        memory_source_id: "job:job_migration",
        created_by_agent_id: "main",
        created_by_channel: "cli",
        created_by_trust: "operator"
      },
      %{
        id: "job:job_migration",
        source_type: "scheduled_job",
        name: "Migration job",
        description: "migration test job",
        memory_scope: "job:job_migration",
        output_scope: "cron:job_migration"
      },
      server: repo
    )
  end

  defp run_attrs(id, extra) do
    Map.merge(
      %{
        id: id,
        job_id: "job_migration",
        session_id: "cron_job_migration_#{id}",
        trigger: "schedule",
        status: "ok",
        created_at: @at,
        updated_at: @at
      },
      Map.new(extra)
    )
  end
end
