defmodule FermixCore.Memory.RepoJobHealsMigrationTest do
  # M106 §5.4: heals live in two tables of their own, made under one version.
  # `scheduled_jobs`, `job_runs` and the earlier facts and retry tables keep
  # exactly the columns they had (`Home.Readable`). Membership, never list
  # equality: the versions before it stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 71
  @at "2026-11-20T07:10:00.000000Z"

  @heal_columns ~w(id subject_kind subject_id job_id failure_kind failure_text failure_words state
                   outcome run_count last_run_id last_failed_at opened_at updated_at
                   waiting_since closed_at
                   lease_token lease_until message inbox_platform inbox_destination
                   inbox_thread_scope delivery_status delivery_attempts next_delivery_at
                   last_delivery_error delivered_at)
  # The columns 72 adds after these (`RepoJobHealsDiagnosisMigrationTest`),
  # the one 73 adds after those (`RepoJobRunTallyMigrationTest`), and the ones
  # 74 adds after it (`RepoJobHealsAnswerMigrationTest`).
  @diagnosis_columns ~w(conclusion decision note read_outside change_json change_job_version
                        rerun_at rerun_outcome)
  @tool_columns ~w(tool_json)
  @answer_columns ~w(change_job_digest answer answered_at decided_from applied_at owner_wrote_at)
  # The columns 76 adds for a proposal's card (M106 §5.7, D5, stage S4b).
  @card_columns ~w(card_token card_token_digest card_platform card_chat_id card_user_id)
  @scheduled_job_width 36
  @job_run_width 24

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heals-migration-#{unique}.db")
    repo = :"memory_repo_job_heals_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    :ok = seed_job_and_run(repo)
    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has the two heal tables, and every older table keeps its columns", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions

    assert columns(db_path, "job_heals") ==
             @heal_columns ++
               @diagnosis_columns ++
               @tool_columns ++
               @answer_columns ++
               @card_columns

    assert columns(db_path, "job_heal_runs") == ~w(run_id heal_id job_id)
    assert length(columns(db_path, "scheduled_jobs")) == @scheduled_job_width
    assert length(columns(db_path, "job_runs")) == @job_run_width

    assert columns(db_path, "job_run_facts") ==
             ~w(run_id failure_kind tool_timeline_json tool_tally_json)

    assert columns(db_path, "job_retries") == ~w(job_id attempts retry_at)
  end

  # The table's own checks: a closed heal has an outcome and only a closed one
  # does; a job heal names its job and no other does; one heal per subject is
  # not closed.
  test "the checks and the one-per-subject index hold", %{db_path: db_path} do
    insert_heal(db_path, "jhl_one", "open", "NULL")

    for {id, state, outcome} <- [
          {"jhl_two", "open", "NULL"},
          {"jhl_closed_bare", "closed", "NULL"},
          {"jhl_open_done", "waiting", "'healed'"}
        ] do
      assert {:error, _reason} = try_insert_heal(db_path, id, state, outcome), id
    end

    assert :ok = try_insert_heal(db_path, "jhl_done", "closed", "'expired'")
  end

  test "a removed job takes its heal and its heal's runs, a removed run its link", %{
    repo: repo,
    db_path: db_path
  } do
    link =
      "INSERT INTO job_heal_runs (run_id, heal_id, job_id) VALUES ('run_heals', 'jhl_one', 'job_heals');"

    insert_heal(db_path, "jhl_one", "open", "NULL")
    raw(db_path, link)

    raw(db_path, "DELETE FROM job_runs WHERE id = 'run_heals';")
    assert rows(db_path, "SELECT count(*) FROM job_heal_runs") == [[0]]
    assert rows(db_path, "SELECT count(*) FROM job_heals") == [[1]]

    assert :ok = Repo.delete_scheduled_job("job_heals", server: repo)
    assert rows(db_path, "SELECT count(*) FROM job_heals") == [[0]]
  end

  test "a store from before the tables migrates, and reapplying changes nothing", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)

    raw(db_path, """
    DROP TABLE job_heal_runs;
    DROP TABLE job_heals;
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    reopen(repo, db_path, :second)
    assert columns(db_path, "job_heals") == @heal_columns
    insert_heal(db_path, "jhl_kept", "open", "NULL")

    stop_supervised!(:second)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path, :third)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert rows(db_path, "SELECT id FROM job_heals") == [["jhl_kept"]]
  end

  defp reopen(repo, db_path, id) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: id)
  end

  defp seed_job_and_run(repo) do
    {:ok, _job} =
      Repo.create_job_with_source(
        %{
          id: "job_heals",
          name: "Harbour tide table",
          schedule_kind: "interval",
          schedule_expr: "every 1 hour",
          timezone: "UTC",
          task_prompt: "Fetch this morning's tides.",
          memory_source_id: "job:job_heals",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator"
        },
        %{
          id: "job:job_heals",
          source_type: "scheduled_job",
          name: "Harbour tide table",
          memory_scope: "job:job_heals",
          output_scope: "cron:job_heals"
        },
        server: repo
      )

    {:ok, _run} =
      Repo.upsert_job_run(
        %{
          id: "run_heals",
          job_id: "job_heals",
          session_id: "cron_job_heals_1",
          trigger: "schedule",
          status: "error"
        },
        server: repo
      )

    :ok
  end

  defp insert_heal(db_path, id, state, outcome),
    do: :ok = try_insert_heal(db_path, id, state, outcome)

  defp try_insert_heal(db_path, id, state, outcome) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000; PRAGMA foreign_keys = ON;")

      Sqlite3.execute(conn, """
      INSERT INTO job_heals (id, subject_kind, subject_id, job_id, failure_kind, failure_text,
        state, outcome, run_count, opened_at, updated_at, delivery_status)
      VALUES ('#{id}', 'job', 'job_heals', 'job_heals', 'time_limit', 'The run timed out.',
        '#{state}', #{outcome}, 1, '#{@at}', '#{@at}', 'pending');
      """)
    after
      Sqlite3.close(conn)
    end
  end

  defp columns(db_path, table),
    do: db_path |> rows("SELECT name FROM pragma_table_info('#{table}')") |> List.flatten()

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000; PRAGMA foreign_keys = ON;")
      :ok = Sqlite3.execute(conn, sql)
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
