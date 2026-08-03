defmodule FermixCore.Memory.RepoJobsQueriesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo

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

    %{repo: repo_name}
  end

  defp create_job!(repo, id) do
    {:ok, job} =
      Repo.create_job_with_source(
        %{
          id: id,
          name: id,
          schedule_kind: "interval",
          schedule_expr: "every 1 hour",
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

  defp create_run!(repo, job_id, run_id, status, created_at) do
    {:ok, run} =
      Repo.upsert_job_run(
        %{
          id: run_id,
          job_id: job_id,
          session_id: "sess-#{run_id}",
          trigger: "schedule",
          status: status,
          created_at: created_at,
          updated_at: created_at
        },
        server: repo
      )

    run
  end

  describe "active_job_runs/1" do
    test "returns only queued and running rows, oldest first", %{repo: repo} do
      create_job!(repo, "job_a")
      create_job!(repo, "job_b")

      create_run!(repo, "job_a", "run_running", "running", ~U[2026-08-02 10:00:00Z])
      create_run!(repo, "job_a", "run_done", "completed", ~U[2026-08-02 09:00:00Z])
      create_run!(repo, "job_b", "run_queued", "queued", ~U[2026-08-02 08:00:00Z])
      create_run!(repo, "job_b", "run_failed", "failed", ~U[2026-08-02 07:00:00Z])

      assert {:ok, runs} = Repo.active_job_runs(server: repo)
      assert Enum.map(runs, & &1.id) == ["run_queued", "run_running"]
      assert Enum.map(runs, & &1.status) == ["queued", "running"]
    end

    test "honors the :limit option", %{repo: repo} do
      create_job!(repo, "job_c")

      create_run!(repo, "job_c", "run_1", "queued", ~U[2026-08-02 08:00:00Z])
      create_run!(repo, "job_c", "run_2", "queued", ~U[2026-08-02 09:00:00Z])
      create_run!(repo, "job_c", "run_3", "running", ~U[2026-08-02 10:00:00Z])

      assert {:ok, [first]} = Repo.active_job_runs(limit: 1, server: repo)
      assert first.id == "run_1"

      assert {:ok, two} = Repo.active_job_runs(limit: 2, server: repo)
      assert Enum.map(two, & &1.id) == ["run_1", "run_2"]
    end

    test "returns an empty list when nothing is active", %{repo: repo} do
      create_job!(repo, "job_d")
      create_run!(repo, "job_d", "run_done_only", "completed", ~U[2026-08-02 08:00:00Z])

      assert {:ok, []} = Repo.active_job_runs(server: repo)
    end
  end
end
