defmodule FermixCore.Jobs.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-jobs-registry-#{unique}.db")
    repo_name = :"jobs_registry_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "creates a scheduled job and matching memory source", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Daily Digest",
                 description: "Summarize the morning project state.",
                 schedule: "every 15 minutes",
                 timezone: "America/New_York",
                 task_prompt: "Summarize what changed since the last run.",
                 created_by_agent_id: "main",
                 created_by_session_id: "telegram:chat-1:root",
                 expires_at: ~U[2026-05-02 16:00:00Z],
                 allowed_tools: ["memory_recall"],
                 capability_policy: ["read_only"],
                 delivery_mode: "none"
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert job.id =~ "daily_digest"
    assert job.schedule_kind == "interval"
    assert job.schedule_expr == "every 15 minutes"
    assert job.timezone == "America/New_York"
    assert job.next_run_at == ~U[2026-05-02 14:15:00Z]
    assert job.expires_at == ~U[2026-05-02 16:00:00Z]
    assert job.memory_source_id == "job:#{job.id}"
    assert job.state == "scheduled"
    assert job.enabled? == true
    assert job.allowed_tools == ["memory_recall"]
    assert job.capability_policy == ["read_only"]

    assert {:ok, [listed]} = Registry.list_jobs(repo: repo)
    assert listed.id == job.id
    assert listed.expires_at == ~U[2026-05-02 16:00:00Z]

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.id == job.memory_source_id
    assert source.source_type == "scheduled_job"
    assert source.name == "Daily Digest"
    assert source.description == "Summarize the morning project state."
    assert source.schedule_summary == "every 15 minutes"
    assert source.status == "enabled"
    assert source.memory_scope == "job:#{job.id}"
    assert source.metadata == %{"job_id" => job.id}
  end

  test "scheduled jobs default to the current investigation step cap", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Deep Digest",
                 schedule: "every 15 minutes",
                 task_prompt: "Investigate the project state deeply."
               },
               repo: repo
             )

    assert job.max_iterations == 100
  end

  test "pauses, resumes, and removes a job", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "One Shot Reminder",
                 schedule: "2099-05-03T12:00:00Z",
                 task_prompt: "Remind me to review the launch notes."
               },
               repo: repo
             )

    assert {:ok, paused} = Registry.pause_job(job.id, repo: repo)
    assert paused.enabled? == false
    assert paused.state == "paused"

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.status == "paused"

    assert {:ok, resumed} = Registry.resume_job(job.id, repo: repo)
    assert resumed.enabled? == true
    assert resumed.state == "scheduled"

    assert :ok = Registry.remove_job(job.id, repo: repo)
    assert {:error, :not_found} = Registry.get_job(job.id, repo: repo)

    assert {:ok, removed_source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert removed_source.status == "removed"
  end

  test "remove rejects jobs with active runs", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Running Job",
                 schedule: "every 15 minutes",
                 task_prompt: "Keep running."
               },
               repo: repo
             )

    assert {:ok, _run} =
             Repo.upsert_job_run(
               %{
                 id: "run_active",
                 job_id: job.id,
                 session_id: "cron_#{job.id}_20260502_141500",
                 trigger: "schedule",
                 status: "running"
               },
               server: repo
             )

    assert {:error, :job_running} = Registry.remove_job(job.id, repo: repo)
    assert {:ok, _still_exists} = Registry.get_job(job.id, repo: repo)

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.status == "enabled"
  end

  test "resume recomputes next_run_at from the resume time", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Frequent Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check project status."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert job.next_run_at == ~U[2026-05-02 14:15:00Z]

    assert {:ok, _paused} = Registry.pause_job(job.id, repo: repo)

    assert {:ok, resumed} =
             Registry.resume_job(job.id,
               repo: repo,
               now: ~U[2026-05-02 18:00:00Z]
             )

    assert resumed.next_run_at == ~U[2026-05-02 18:15:00Z]
  end

  test "resume rejects expired one-shot jobs", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Expired Reminder",
                 schedule: "2026-05-03T12:00:00Z",
                 task_prompt: "Remind me."
               },
               repo: repo
             )

    assert {:ok, _paused} = Registry.pause_job(job.id, repo: repo)
    job_id = job.id

    assert {:error, {:expired_once_job, ^job_id}} =
             Registry.resume_job(job.id,
               repo: repo,
               now: ~U[2026-05-04 12:00:00Z]
             )

    assert {:ok, still_paused} = Registry.get_job(job.id, repo: repo)
    assert still_paused.state == "paused"
  end

  test "resume rejects jobs whose expires_at already passed", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Temporary Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check temporarily.",
                 expires_at: ~U[2026-05-02 16:00:00Z]
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert {:ok, _paused} = Registry.pause_job(job.id, repo: repo)
    job_id = job.id

    assert {:error, {:expired_job, ^job_id}} =
             Registry.resume_job(job.id,
               repo: repo,
               now: ~U[2026-05-02 16:00:00Z]
             )

    assert {:ok, still_paused} = Registry.get_job(job.id, repo: repo)
    assert still_paused.state == "paused"
  end

  test "update_job revises the task prompt without disturbing the schedule", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{name: "Weather", schedule: "every 15 minutes", task_prompt: "Send weather."},
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert job.next_run_at == ~U[2026-05-02 14:15:00Z]

    assert {:ok, updated} =
             Registry.update_job(job.id, %{task_prompt: "Send weather for 94105."},
               repo: repo,
               now: ~U[2026-05-02 14:05:00Z]
             )

    assert updated.task_prompt == "Send weather for 94105."
    assert updated.schedule_expr == "every 15 minutes"
    assert updated.next_run_at == ~U[2026-05-02 14:15:00Z]
  end

  test "update_job accepts the task alias, reschedules, and syncs the source", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{name: "Digest", schedule: "every 15 minutes", task_prompt: "Old."},
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert {:ok, updated} =
             Registry.update_job(
               job.id,
               %{task: "New task.", schedule: "every 30 minutes", description: "Refreshed."},
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert updated.task_prompt == "New task."
    assert updated.schedule_kind == "interval"
    assert updated.schedule_expr == "every 30 minutes"
    assert updated.next_run_at == ~U[2026-05-02 14:30:00Z]

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.schedule_summary == "every 30 minutes"
    assert source.description == "Refreshed."
  end

  test "create_job persists a pinned provider and model", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 name: "Pinned",
                 schedule: "every 15 minutes",
                 task_prompt: "Run on a pinned route.",
                 provider: "anthropic",
                 model: "claude-opus-4-8"
               },
               repo: repo
             )

    assert job.provider == "anthropic"
    assert job.model == "claude-opus-4-8"

    assert {:ok, reloaded} = Registry.get_job(job.id, repo: repo)
    assert reloaded.provider == "anthropic"
    assert reloaded.model == "claude-opus-4-8"
  end

  test "update_job persists provider and model and leaves them untouched when omitted",
       %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{name: "Repin", schedule: "every 15 minutes", task_prompt: "Run."},
               repo: repo
             )

    assert job.provider == nil
    assert job.model == nil

    assert {:ok, pinned} =
             Registry.update_job(
               job.id,
               %{provider: "anthropic", model: "claude-opus-4-8"},
               repo: repo
             )

    assert pinned.provider == "anthropic"
    assert pinned.model == "claude-opus-4-8"

    assert {:ok, retouched} =
             Registry.update_job(job.id, %{task_prompt: "Run differently."}, repo: repo)

    assert retouched.task_prompt == "Run differently."
    assert retouched.provider == "anthropic"
    assert retouched.model == "claude-opus-4-8"
  end

  test "update_job rejects an empty patch and unknown jobs", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{name: "Empty", schedule: "every 15 minutes", task_prompt: "Do."},
               repo: repo
             )

    assert {:error, :empty_update} = Registry.update_job(job.id, %{}, repo: repo)
    assert {:error, :not_found} = Registry.update_job("missing_job", %{task: "x"}, repo: repo)
  end

  test "update_job rejects an invalid schedule and leaves the job unchanged", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{name: "Stable", schedule: "every 15 minutes", task_prompt: "Keep."},
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert {:error, {:invalid_schedule, "sometimes"}} =
             Registry.update_job(job.id, %{schedule: "sometimes"}, repo: repo)

    assert {:ok, unchanged} = Registry.get_job(job.id, repo: repo)
    assert unchanged.schedule_expr == "every 15 minutes"
    assert unchanged.task_prompt == "Keep."
  end

  test "rejects invalid schedules before writing anything", %{repo: repo} do
    assert {:error, {:invalid_schedule, "sometimes"}} =
             Registry.create_job(
               %{name: "Bad", schedule: "sometimes", task_prompt: "Do a thing."},
               repo: repo
             )

    assert {:ok, []} = Registry.list_jobs(repo: repo)

    assert {:error, {:invalid_schedule, "99 * * * *"}} =
             Registry.create_job(
               %{name: "Bad Cron", schedule: "99 * * * *", task_prompt: "Do a thing."},
               repo: repo
             )

    assert {:ok, []} = Registry.list_jobs(repo: repo)
  end
end
