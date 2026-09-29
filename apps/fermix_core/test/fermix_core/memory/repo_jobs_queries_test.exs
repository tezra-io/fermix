defmodule FermixCore.Memory.RepoJobsQueriesTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @completed_at ~U[2026-08-02 10:30:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-jobs-queries-#{unique}.db")
    repo_name = :"memory_repo_jobs_queries_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name, db_path: db_path}
  end

  defp create_job!(repo, id, opts \\ []) do
    {:ok, job} =
      Repo.create_job_with_source(
        %{
          id: id,
          name: id,
          schedule_kind: Keyword.get(opts, :schedule_kind, "interval"),
          schedule_expr: Keyword.get(opts, :schedule_expr, "every 1 hour"),
          timezone: "UTC",
          task_prompt: "do the thing",
          memory_source_id: "job:#{id}",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator"
        },
        %{
          id: "job:#{id}",
          source_type: "scheduled_job",
          name: id,
          description: "test job",
          memory_scope: "job:#{id}",
          output_scope: "cron:#{id}"
        },
        server: repo
      )

    job
  end

  defp create_run!(repo, job_id, run_id, status, created_at, delivery_status \\ "none") do
    {:ok, run} =
      Repo.upsert_job_run(
        %{
          id: run_id,
          job_id: job_id,
          session_id: "sess-#{run_id}",
          trigger: "schedule",
          status: status,
          delivery_status: delivery_status,
          created_at: created_at,
          updated_at: created_at
        },
        server: repo
      )

    run
  end

  describe "unsettled_job_runs/1" do
    test "returns active rows first, then rows whose delivery is still pending, oldest first",
         %{repo: repo} do
      create_job!(repo, "job_a")
      create_job!(repo, "job_b")

      create_run!(repo, "job_a", "run_running", "running", ~U[2026-08-02 10:00:00Z])
      create_run!(repo, "job_a", "run_done", "ok", ~U[2026-08-02 09:30:00Z], "sent")
      create_run!(repo, "job_b", "run_queued", "queued", ~U[2026-08-02 08:00:00Z])

      create_run!(
        repo,
        "job_b",
        "run_error_pending",
        "error",
        ~U[2026-08-02 09:00:00Z],
        "pending"
      )

      create_run!(repo, "job_a", "run_ok_pending", "ok", ~U[2026-08-02 06:00:00Z], "pending")
      create_run!(repo, "job_b", "run_skipped", "ok", ~U[2026-08-02 05:00:00Z], "skipped")
      create_run!(repo, "job_b", "run_none", "ok", ~U[2026-08-02 04:00:00Z], "none")
      create_run!(repo, "job_b", "run_failed", "error", ~U[2026-08-02 03:00:00Z], "failed")

      assert {:ok, runs} = Repo.unsettled_job_runs(server: repo)

      assert Enum.map(runs, & &1.id) ==
               ["run_queued", "run_running", "run_ok_pending", "run_error_pending"]
    end

    test "honors the :limit option, active rows first", %{repo: repo} do
      create_job!(repo, "job_c")

      create_run!(repo, "job_c", "run_pending", "ok", ~U[2026-08-02 07:00:00Z], "pending")
      create_run!(repo, "job_c", "run_1", "queued", ~U[2026-08-02 08:00:00Z])
      create_run!(repo, "job_c", "run_2", "queued", ~U[2026-08-02 09:00:00Z])
      create_run!(repo, "job_c", "run_3", "running", ~U[2026-08-02 10:00:00Z])

      assert {:ok, [first]} = Repo.unsettled_job_runs(limit: 1, server: repo)
      assert first.id == "run_1"

      assert {:ok, two} = Repo.unsettled_job_runs(limit: 2, server: repo)
      assert Enum.map(two, & &1.id) == ["run_1", "run_2"]

      assert {:ok, four} = Repo.unsettled_job_runs(limit: 4, server: repo)
      assert Enum.map(four, & &1.id) == ["run_1", "run_2", "run_3", "run_pending"]
    end

    test "returns an empty list when every run is settled", %{repo: repo} do
      create_job!(repo, "job_d")
      create_run!(repo, "job_d", "run_done_only", "ok", ~U[2026-08-02 08:00:00Z], "sent")

      assert {:ok, []} = Repo.unsettled_job_runs(server: repo)
    end

    # job_runs is never pruned, so the 60 s reconcile pass must stay an index
    # read: a bare `SCAN job_runs` would grow with every run ever recorded.
    test "reads only indexes, never the whole job_runs table", %{db_path: db_path} do
      {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")

      try do
        {:ok, stmt} =
          Sqlite3.prepare(conn, "EXPLAIN QUERY PLAN " <> Repo.unsettled_job_runs_sql())

        :ok = Sqlite3.bind(stmt, [50, 50, 50])
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        :ok = Sqlite3.release(conn, stmt)
        details = Enum.map(rows, fn [_id, _parent, _unused, detail] -> detail end)

        # The active rows are an index SEARCH on status. The one SCAN allowed
        # is of the partial index, which holds only the pending rows; a SCAN of
        # any other index still walks the whole run history.
        pending_index = ~r/USING (COVERING )?INDEX idx_job_runs_pending_delivery\b/
        scans = Enum.filter(details, &(&1 =~ ~r/^SCAN job_runs\b/))

        assert Enum.reject(scans, &(&1 =~ pending_index)) == [], inspect(details)
        assert Enum.any?(scans, &(&1 =~ pending_index)), inspect(details)

        assert Enum.any?(
                 details,
                 &(&1 =~
                     ~r/^SEARCH job_runs USING (COVERING )?INDEX idx_job_runs_status_created\b/)
               ),
               inspect(details)
      after
        Sqlite3.close(conn)
      end
    end
  end

  describe "settle_job_run/2" do
    test "writes the final run row and releases a running job in one call", %{repo: repo} do
      job = create_job!(repo, "job_settle")
      job = put_job!(repo, job, %{state: "running", next_run_at: ~U[2026-08-02 11:00:00Z]})
      run = create_run!(repo, job.id, "run_settle", "running", ~U[2026-08-02 10:00:00Z])

      assert {:ok, {settled, released}} =
               Repo.settle_job_run(final_attrs(run, "ok", nil), server: repo)

      assert settled.id == "run_settle"
      assert settled.status == "ok"
      assert settled.completed_at == @completed_at
      assert released.id == job.id
      assert released.state == "scheduled"
      assert released.enabled? == true
      assert released.next_run_at == ~U[2026-08-02 11:00:00Z]
      assert released.last_run_at == @completed_at
      assert released.last_status == "ok"
      assert released.last_error == nil

      assert {:ok, ^settled} = Repo.get_job_run("run_settle", server: repo)
      assert {:ok, ^released} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "records a failed run's status and error on the job", %{repo: repo} do
      job = create_job!(repo, "job_timeout")
      job = put_job!(repo, job, %{state: "running"})
      run = create_run!(repo, job.id, "run_timeout", "running", ~U[2026-08-02 10:00:00Z])

      assert {:ok, {settled, released}} =
               Repo.settle_job_run(final_attrs(run, "timeout", "inactivity timeout"),
                 server: repo
               )

      assert settled.status == "timeout"
      assert settled.error == "inactivity timeout"
      assert released.state == "scheduled"
      assert released.last_status == "timeout"
      assert released.last_error == "inactivity timeout"
    end

    test "keeps a pause that landed mid-run", %{repo: repo} do
      job = create_job!(repo, "job_paused")
      job = put_job!(repo, job, %{state: "paused", enabled?: false})
      run = create_run!(repo, job.id, "run_paused", "running", ~U[2026-08-02 10:00:00Z])

      assert {:ok, {_settled, released}} =
               Repo.settle_job_run(final_attrs(run, "ok", nil), server: repo)

      assert released.state == "paused"
      assert released.enabled? == false
      assert released.last_status == "ok"
    end

    # The claim consumed the occurrence: it cleared next_run_at, as a due claim
    # of a one-off does.
    test "completes and disables a one-off job its claim consumed", %{repo: repo} do
      job =
        create_job!(repo, "job_once",
          schedule_kind: "once",
          schedule_expr: "2026-08-02T10:00:00Z"
        )

      job = put_job!(repo, job, %{state: "running", next_run_at: nil})
      run = create_run!(repo, job.id, "run_once", "queued", ~U[2026-08-02 10:00:00Z])

      assert {:ok, {_settled, released}} =
               Repo.settle_job_run(final_attrs(run, "ok", nil), server: repo)

      assert released.state == "completed"
      assert released.enabled? == false
      assert released.next_run_at == nil
      assert released.last_status == "ok"
    end

    # An edit mid-run set a fresh instant (update_job writes schedule_kind
    # "once" and its next_run_at): that one-off is still to come.
    test "keeps a one-off an edit set while the run was in flight", %{repo: repo} do
      job =
        create_job!(repo, "job_edited_once",
          schedule_kind: "once",
          schedule_expr: "2026-08-03T09:00:00Z"
        )

      job = put_job!(repo, job, %{state: "running", next_run_at: ~U[2026-08-03 09:00:00Z]})
      run = create_run!(repo, job.id, "run_edited_once", "running", ~U[2026-08-02 10:00:00Z])

      assert {:ok, {_settled, released}} =
               Repo.settle_job_run(final_attrs(run, "ok", nil), server: repo)

      assert released.state == "scheduled"
      assert released.enabled? == true
      assert released.next_run_at == ~U[2026-08-03 09:00:00Z]
      assert released.last_status == "ok"
    end

    test "refuses a run that is no longer active and changes nothing", %{repo: repo} do
      job = create_job!(repo, "job_final")
      job = put_job!(repo, job, %{state: "running"})
      run = create_run!(repo, job.id, "run_final", "ok", ~U[2026-08-02 10:00:00Z], "sent")

      assert {:error, :run_not_active} =
               Repo.settle_job_run(final_attrs(run, "error", "reaped"), server: repo)

      assert {:ok, ^run} = Repo.get_job_run("run_final", server: repo)
      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "refuses a run that has no row", %{repo: repo} do
      job = create_job!(repo, "job_no_run")
      job = put_job!(repo, job, %{state: "running"})

      attrs = %{
        id: "run_missing",
        job_id: job.id,
        session_id: "sess-run_missing",
        trigger: "schedule",
        status: "error",
        error: "reaped",
        completed_at: @completed_at,
        created_at: @completed_at,
        updated_at: @completed_at
      }

      assert {:error, :run_not_active} = Repo.settle_job_run(attrs, server: repo)
      assert {:error, :not_found} = Repo.get_job_run("run_missing", server: repo)
      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: repo)
    end
  end

  defp put_job!(repo, job, patch) do
    {:ok, updated} = Repo.upsert_scheduled_job(Map.merge(job, patch), server: repo)
    updated
  end

  defp final_attrs(run, status, error) do
    Map.merge(run, %{
      status: status,
      error: error,
      completed_at: @completed_at,
      updated_at: @completed_at
    })
  end
end
