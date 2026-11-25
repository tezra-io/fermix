defmodule FermixCore.Memory.RepoJobRunTallyMigrationTest do
  # M106 §6 (stage S5): a run's tool tally (each tool it called, how many
  # calls succeeded and how many did not, its plugin, the last error's text)
  # is a column on `job_run_facts`, and the tool a heal of a run that ended ok
  # without working is about is a column on `job_heals`, both added under one
  # version after 72. Both tables are read by column name; `job_runs` and
  # `scheduled_jobs`, which an engine at the current home format reads by
  # position, keep their widths. Membership, never list equality: the versions
  # before stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 73
  @at ~U[2031-03-04 07:10:00.000000Z]
  @stamp "2031-03-04T07:10:00.000000Z"

  @facts_columns_69 ~w(run_id failure_kind tool_timeline_json)
  @heal_columns_72 ~w(id subject_kind subject_id job_id failure_kind failure_text failure_words
                      state outcome run_count last_run_id last_failed_at opened_at updated_at
                      waiting_since closed_at lease_token lease_until message inbox_platform
                      inbox_destination inbox_thread_scope delivery_status delivery_attempts
                      next_delivery_at last_delivery_error delivered_at conclusion decision note
                      read_outside change_json change_job_version rerun_at rerun_outcome)
  @scheduled_job_width 36
  @job_run_width 24

  @tally [
    %{"name" => "tide_lookup", "ok" => 0, "error" => 2, "unfinished" => 0, "last_error" => "x"},
    %{"name" => "web_fetch", "ok" => 3, "error" => 0, "unfinished" => 0, "plugin" => "harbour"}
  ]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-run-tally-#{unique}.db")
    repo = :"memory_repo_job_run_tally_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    :ok = create_job(repo)
    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has both columns, and no table an older engine reads by position widens",
       %{repo: repo, db_path: db_path} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert columns(db_path, "job_run_facts") == @facts_columns_69 ++ ["tool_tally_json"]
    assert columns(db_path, "job_heals") == @heal_columns_72 ++ ["tool_json"]
    assert length(columns(db_path, "scheduled_jobs")) == @scheduled_job_width
    assert length(columns(db_path, "job_runs")) == @job_run_width
  end

  test "a run's tally round-trips, and a later whole-row write keeps it", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, run} =
             Repo.upsert_job_run(run_attrs("run_tally", tool_tally: @tally), server: repo)

    assert run.tool_tally == @tally
    assert {:ok, %{tool_tally: @tally}} = Repo.get_job_run("run_tally", server: repo)

    assert {:ok, %{tool_tally: @tally}} =
             Repo.upsert_job_run(run_attrs("run_tally", tool_tally: []), server: repo)

    assert [[json]] = rows(db_path, "SELECT tool_tally_json FROM job_run_facts")
    assert Jason.decode!(json) == @tally

    # A run with no tally reads it as absent.
    assert {:ok, %{tool_tally: nil}} =
             Repo.upsert_job_run(run_attrs("run_bare", []), server: repo)
  end

  # What an engine at the current home format runs: its own run select names
  # the two facts it knows, so the added column is read past, and every run
  # row it reads keeps the width it expects.
  test "an older engine's reads of a run read past the added column", %{
    repo: repo,
    db_path: db_path
  } do
    facts = [failure_kind: "time_limit", tool_timeline: [], tool_tally: @tally]
    assert {:ok, _run} = Repo.upsert_job_run(run_attrs("run_old_reader", facts), server: repo)

    older_select = """
    SELECT r.*, f.failure_kind, f.tool_timeline_json
    FROM job_runs r LEFT JOIN job_run_facts f ON f.run_id = r.id
    WHERE r.id = 'run_old_reader'
    """

    assert [row] = rows(db_path, older_select)
    assert length(row) == @job_run_width + 2
    assert Enum.take(row, -2) == ["time_limit", "[]"]
    assert [plain] = rows(db_path, "SELECT * FROM job_runs WHERE id = 'run_old_reader'")
    assert length(plain) == @job_run_width
  end

  test "a store at 72 migrates, keeping its rows, and reapplying changes nothing", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)

    raw(db_path, """
    ALTER TABLE job_run_facts DROP COLUMN tool_tally_json;
    ALTER TABLE job_heals DROP COLUMN tool_json;
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    assert columns(db_path, "job_run_facts") == @facts_columns_69
    assert columns(db_path, "job_heals") == @heal_columns_72

    raw(db_path, """
    INSERT INTO job_runs (id, job_id, session_id, trigger, status, delivery_status, created_at,
      updated_at)
    VALUES ('run_kept', 'job_tally', 'cron_job_tally_kept', 'schedule', 'error', 'none',
      '#{@stamp}', '#{@stamp}');
    INSERT INTO job_run_facts (run_id, failure_kind, tool_timeline_json)
      VALUES ('run_kept', 'time_limit', '[]');
    INSERT INTO job_heals (id, subject_kind, subject_id, job_id, failure_kind, failure_text,
      state, run_count, opened_at, updated_at, delivery_status)
    VALUES ('jhl_kept', 'job', 'job_tally', 'job_tally', 'time_limit', 'The run timed out.',
      'open', 1, '#{@stamp}', '#{@stamp}', 'pending');
    """)

    reopen(repo, db_path, :second)
    assert columns(db_path, "job_run_facts") == @facts_columns_69 ++ ["tool_tally_json"]
    assert columns(db_path, "job_heals") == @heal_columns_72 ++ ["tool_json"]

    assert {:ok, %{failure_kind: "time_limit", tool_timeline: [], tool_tally: nil}} =
             Repo.get_job_run("run_kept", server: repo)

    assert {:ok, %{failure_kind: "time_limit", tool: nil}} =
             Repo.job_heals_call({:get, "jhl_kept"}, server: repo)

    stop_supervised!(:second)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path, :third)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert columns(db_path, "job_run_facts") == @facts_columns_69 ++ ["tool_tally_json"]
    assert columns(db_path, "job_heals") == @heal_columns_72 ++ ["tool_json"]
  end

  test "a table that holds neither column set is refused, never rewritten", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)

    raw(db_path, """
    ALTER TABLE job_run_facts DROP COLUMN tool_timeline_json;
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _reason} =
               start_supervised({Repo, name: repo, enabled: true, database_path: db_path},
                 id: :refused
               )
    end)

    assert "tool_timeline_json" not in columns(db_path, "job_run_facts")
    assert "tool_tally_json" in columns(db_path, "job_run_facts")
  end

  defp reopen(repo, db_path, id) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: id)
  end

  defp create_job(repo) do
    {:ok, _job} =
      Repo.create_job_with_source(
        %{
          id: "job_tally",
          name: "Harbour tide table",
          schedule_kind: "cron",
          schedule_expr: "0 6 * * *",
          timezone: "Europe/Lisbon",
          task_prompt: "Fetch this morning's tides.",
          memory_source_id: "job:job_tally",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator"
        },
        %{
          id: "job:job_tally",
          source_type: "scheduled_job",
          name: "Harbour tide table",
          memory_scope: "job:job_tally",
          output_scope: "cron:job_tally"
        },
        server: repo
      )

    :ok
  end

  defp run_attrs(id, extra) do
    Map.merge(
      %{
        id: id,
        job_id: "job_tally",
        session_id: "cron_job_tally_#{id}",
        trigger: "schedule",
        status: "ok",
        created_at: @at,
        updated_at: @at
      },
      Map.new(extra)
    )
  end

  defp columns(db_path, table),
    do: db_path |> rows("SELECT name FROM pragma_table_info('#{table}')") |> List.flatten()

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
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
