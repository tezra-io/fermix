defmodule FermixCore.Memory.RepoJobSettleMigrationTest do
  # Two versions ship with the atomic run settle: a partial index that keeps the
  # reconcile scan of pending deliveries an index read, and a one-time repair
  # that releases every job an older release left in `running` with no active
  # run (the wedge the settle now makes impossible). Membership, never list
  # equality: the versions before them stay reserved.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @pending_index_version 30
  @release_version 31
  @at ~U[2026-09-20 08:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-settle-migration-#{unique}.db")
    repo = :"memory_repo_job_settle_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh database carries both versions and the pending-delivery index", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @pending_index_version in versions
    assert @release_version in versions

    assert "idx_job_runs_pending_delivery" in index_names(db_path, "job_runs")
  end

  test "a store opened before the index gains it on the next open", %{
    repo: repo,
    db_path: db_path
  } do
    stop_supervised!(:first)
    raw(db_path, "DROP INDEX idx_job_runs_pending_delivery;")
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@pending_index_version};")

    reopen(repo, db_path)

    assert "idx_job_runs_pending_delivery" in index_names(db_path, "job_runs")
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @pending_index_version in versions
  end

  test "the upgrade releases every job left running with no active run, once", %{
    repo: repo,
    db_path: db_path
  } do
    wedged = seed_job!(repo, "job_wedged", "interval", "running", "ok")
    # A due claim of a one-off clears next_run_at: that run consumed it.
    once = seed_job!(repo, "job_once", "once", "running", "error", next_run_at: nil)
    # An edit set a fresh instant after the claim: that one-off is still to come.
    rescheduled = seed_job!(repo, "job_rescheduled", "once", "running", "ok")
    live = seed_job!(repo, "job_live", "interval", "running", "running")
    paused = seed_job!(repo, "job_paused", "interval", "paused", "ok")

    stop_supervised!(:first)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@release_version};")
    reopen(repo, db_path)

    assert {:ok, released} = Repo.get_scheduled_job(wedged.id, server: repo)
    assert released.state == "scheduled"
    assert released.enabled? == true
    assert released.next_run_at == @at
    assert released.last_status == wedged.last_status

    assert {:ok, completed} = Repo.get_scheduled_job(once.id, server: repo)
    assert completed.state == "completed"
    assert completed.enabled? == false
    assert completed.next_run_at == nil

    assert {:ok, pending} = Repo.get_scheduled_job(rescheduled.id, server: repo)
    assert pending.state == "scheduled"
    assert pending.enabled? == true
    assert pending.next_run_at == @at

    # A run still queued/running is the reconcile pass's to settle, not the
    # migration's: its job keeps the claim until that run is settled.
    assert {:ok, %{state: "running"}} = Repo.get_scheduled_job(live.id, server: repo)
    assert {:ok, %{state: "paused"}} = Repo.get_scheduled_job(paused.id, server: repo)

    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @release_version in versions
  end

  defp reopen(repo, db_path) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :reopened)
  end

  defp seed_job!(repo, id, kind, state, run_status, opts \\ []) do
    expr = if kind == "once", do: DateTime.to_iso8601(@at), else: "every 15 minutes"

    {:ok, job} =
      Repo.create_job_with_source(
        %{
          id: id,
          name: id,
          schedule_kind: kind,
          schedule_expr: expr,
          timezone: "UTC",
          next_run_at: Keyword.get(opts, :next_run_at, @at),
          task_prompt: "Run.",
          memory_source_id: "job:#{id}",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator",
          state: state,
          enabled?: state != "paused"
        },
        %{
          id: "job:#{id}",
          source_type: "scheduled_job",
          name: id,
          memory_scope: "job:#{id}",
          output_scope: "cron:#{id}"
        },
        server: repo
      )

    {:ok, _run} =
      Repo.upsert_job_run(
        %{
          id: "run_#{id}",
          job_id: id,
          session_id: "cron_#{id}",
          trigger: "schedule",
          status: run_status,
          created_at: @at,
          updated_at: @at
        },
        server: repo
      )

    job
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp index_names(db_path, table) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, "PRAGMA index_list(#{table})")
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      Enum.map(rows, fn [_seq, name | _rest] -> name end)
    after
      Sqlite3.close(conn)
    end
  end
end
