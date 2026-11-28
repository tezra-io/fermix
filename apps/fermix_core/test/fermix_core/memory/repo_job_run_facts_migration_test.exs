defmodule FermixCore.Memory.RepoJobRunFactsMigrationTest do
  # M106 §5.1: a job run's failure kind and tool timeline live in a table of
  # their own, `job_run_facts`, made under one version. `job_runs` keeps exactly
  # the columns it had: an engine at the current home format reads it with
  # `SELECT *` into a fixed number of fields (`Home.Readable`), so a wider row
  # would be one it cannot read. Membership, never list equality: the versions
  # before it stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 69
  @at ~U[2026-11-20 06:30:00Z]
  @timeline [
    %{"name" => "web_fetch", "duration_ms" => 812, "status" => "ok"},
    %{"name" => "tide_lookup", "plugin" => "harbour", "duration_ms" => 40, "status" => "error"}
  ]

  # The table as 69 makes it, and the tally 73 adds after it
  # (`RepoJobRunTallyMigrationTest`).
  @facts_columns ~w(run_id failure_kind tool_timeline_json tool_tally_json)
  # The columns 74 adds to `job_heals` (`RepoJobHealsAnswerMigrationTest`),
  # which a store from before 69 does not have either.
  @answer_columns ~w(change_job_digest answer answered_at decided_from applied_at owner_wrote_at)
  # The card's columns (76), dropped with its index for the same reason.
  @card_columns ~w(card_token card_token_digest card_platform card_chat_id card_user_id)

  # `job_runs` as an engine at home format 1 reads it, in order.
  @job_run_columns ~w(id job_id session_id trigger status claimed_at started_at completed_at
                      prompt_snapshot job_config_snapshot_json capability_policy_snapshot_json
                      output_ref final_response error delivery_status delivery_error iterations
                      token_usage_json latency_json created_at updated_at tool_failures
                      tools_started_at cue_delivery_id)

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-run-facts-migration-#{unique}.db")
    repo = :"memory_repo_job_run_facts_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    :ok = create_job(repo)
    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has the facts table, and job_runs keeps its columns and its width", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert columns(db_path, "job_run_facts") == @facts_columns
    assert columns(db_path, "job_runs") == @job_run_columns

    facts = [failure_kind: "time_limit", tool_timeline: @timeline]
    assert {:ok, _run} = Repo.upsert_job_run(run_attrs("run_wide", facts), server: repo)

    assert [row] = rows(db_path, "SELECT * FROM job_runs WHERE id = ?", ["run_wide"])
    assert length(row) == length(@job_run_columns)
  end

  test "a run's kind and timeline round-trip through the facts table", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, failed} =
             Repo.upsert_job_run(
               run_attrs("run_failed", failure_kind: "time_limit", tool_timeline: @timeline),
               server: repo
             )

    assert failed.failure_kind == "time_limit"
    assert failed.tool_timeline == @timeline

    assert {:ok, fetched} = Repo.get_job_run("run_failed", server: repo)
    assert fetched.failure_kind == "time_limit"
    assert fetched.tool_timeline == @timeline

    assert [["time_limit", json]] = facts_row(db_path, "run_failed")
    assert Jason.decode!(json) == @timeline

    # A run with neither fact has no facts row, and reads both as absent.
    assert {:ok, plain} = Repo.upsert_job_run(run_attrs("run_plain", []), server: repo)
    assert plain.failure_kind == nil
    assert plain.tool_timeline == nil
    assert facts_row(db_path, "run_plain") == []

    assert {:ok, listed} = Repo.list_job_runs(%{job_id: "job_facts"}, server: repo)

    assert listed |> Enum.map(&{&1.id, &1.failure_kind}) |> Enum.sort() ==
             [{"run_failed", "time_limit"}, {"run_plain", nil}]
  end

  test "the unsettled runs the reconcile pass reads carry their facts", %{repo: repo} do
    attrs = run_attrs("run_pending", status: "ok", delivery_status: "pending")
    facts = [failure_kind: "crashed", tool_timeline: @timeline]
    assert {:ok, _run} = Repo.upsert_job_run(Map.merge(attrs, Map.new(facts)), server: repo)

    assert {:ok, [pending]} = Repo.unsettled_job_runs(server: repo)
    assert pending.id == "run_pending"
    assert pending.failure_kind == "crashed"
    assert pending.tool_timeline == @timeline
  end

  # Every runner write after the settle is a whole-row upsert of the row it
  # read; the first writer of each fact wins, as for `tools_started_at`.
  test "a later whole-row write keeps the facts stored", %{repo: repo, db_path: db_path} do
    facts = [failure_kind: "crashed", tool_timeline: @timeline]
    assert {:ok, _run} = Repo.upsert_job_run(run_attrs("run_kept", facts), server: repo)

    assert {:ok, rewritten} =
             Repo.upsert_job_run(
               run_attrs("run_kept",
                 delivery_status: "failed",
                 delivery_error: "send refused",
                 failure_kind: "reaped",
                 tool_timeline: []
               ),
               server: repo
             )

    assert rewritten.delivery_status == "failed"
    assert rewritten.failure_kind == "crashed"
    assert rewritten.tool_timeline == @timeline

    assert {:ok, _run} = Repo.upsert_job_run(run_attrs("run_kept", []), server: repo)
    assert [["crashed", _json]] = facts_row(db_path, "run_kept")
  end

  # What lets an engine at the current format delete a job a newer engine ran:
  # foreign keys are on, so the job takes its runs and each run its facts.
  test "a deleted job or run takes its facts row with it", %{repo: repo, db_path: db_path} do
    facts = [failure_kind: "time_limit", tool_timeline: @timeline]

    for id <- ["run_gone_with_job", "run_gone_alone"] do
      assert {:ok, _run} = Repo.upsert_job_run(run_attrs(id, facts), server: repo)
    end

    raw(db_path, """
    PRAGMA foreign_keys = ON;
    DELETE FROM job_runs WHERE id = 'run_gone_alone';
    """)

    assert facts_row(db_path, "run_gone_alone") == []
    assert [["time_limit", _json]] = facts_row(db_path, "run_gone_with_job")

    assert :ok = Repo.delete_scheduled_job("job_facts", server: repo)
    assert rows(db_path, "SELECT count(*) FROM job_runs", []) == [[0]]
    assert rows(db_path, "SELECT count(*) FROM job_run_facts", []) == [[0]]
  end

  # The upgrade: a store the previous release wrote, its run rows as they were,
  # gains the table and reads every row back intact, with no facts.
  test "a store from before the table migrates, and its rows read back with no facts", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, _run} =
             Repo.upsert_job_run(
               run_attrs("run_old",
                 status: "ok",
                 final_response: "Tides fetched.",
                 iterations: 3,
                 tool_failures: 1,
                 tools_started_at: @at,
                 token_usage: %{"total" => 4_210}
               ),
               server: repo
             )

    stop_supervised!(:first)

    # A store from before 69 has none of the versions that widen its table.
    raw(db_path, """
    DROP TABLE job_run_facts;
    ALTER TABLE job_heals DROP COLUMN tool_json;
    DROP INDEX IF EXISTS job_heals_card_token;
    #{Enum.map_join(@answer_columns ++ @card_columns, "\n", &"ALTER TABLE job_heals DROP COLUMN #{&1};")}
    DELETE FROM schema_migrations WHERE version IN (#{@version}, 73, 74, 76);
    """)

    assert columns(db_path, "job_run_facts") == []
    reopen(repo, db_path)

    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert columns(db_path, "job_run_facts") == @facts_columns
    assert columns(db_path, "job_runs") == @job_run_columns

    assert {:ok, run} = Repo.get_job_run("run_old", server: repo)
    assert run.failure_kind == nil
    assert run.tool_timeline == nil
    assert run.status == "ok"
    assert run.final_response == "Tides fetched."
    assert run.iterations == 3
    assert run.tool_failures == 1
    assert run.tools_started_at == @at
    assert run.token_usage == %{"total" => 4_210}
    assert run.created_at == @at
  end

  # A version row lost while the table stands (a store copied mid-upgrade): the
  # migration runs again, keeps the table and its rows, and records its version
  # once.
  test "reapplying the migration changes nothing", %{repo: repo, db_path: db_path} do
    assert {:ok, _run} =
             Repo.upsert_job_run(run_attrs("run_again", failure_kind: "reaped"), server: repo)

    stop_supervised!(:first)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert {:ok, %{failure_kind: "reaped"}} = Repo.get_job_run("run_again", server: repo)
  end

  defp reopen(repo, db_path) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :reopened)
  end

  defp create_job(repo) do
    {:ok, _job} =
      Repo.create_job_with_source(
        %{
          id: "job_facts",
          name: "Harbour tide table",
          schedule_kind: "cron",
          schedule_expr: "0 6 * * *",
          timezone: "Europe/Lisbon",
          task_prompt: "Fetch this morning's tides.",
          memory_source_id: "job:job_facts",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator"
        },
        %{
          id: "job:job_facts",
          source_type: "scheduled_job",
          name: "Harbour tide table",
          memory_scope: "job:job_facts",
          output_scope: "cron:job_facts"
        },
        server: repo
      )

    :ok
  end

  defp run_attrs(id, extra) do
    Map.merge(
      %{
        id: id,
        job_id: "job_facts",
        session_id: "cron_job_facts_#{id}",
        trigger: "schedule",
        status: "error",
        created_at: @at,
        updated_at: @at
      },
      Map.new(extra)
    )
  end

  defp facts_row(db_path, run_id) do
    rows(db_path, "SELECT failure_kind, tool_timeline_json FROM job_run_facts WHERE run_id = ?", [
      run_id
    ])
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
