defmodule FermixCore.Jobs.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Schedule
  alias FermixCore.Memory.Repo

  @released_at ~U[2026-05-02 14:20:00Z]

  defmodule InjectBeforeWriteRepo do
    @moduledoc false
    # A transparent proxy in front of the real Repo. On the first request that
    # writes the job row (a whole-row upsert or an in-place column update) it
    # first runs `inject` against the real Repo, a concurrent writer landing
    # between the caller's read and its write, then forwards the request. The
    # interleaving is forced, never raced.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{real: Keyword.fetch!(opts, :real), inject: Keyword.fetch!(opts, :inject)}}
    end

    @impl true
    def handle_call(request, _from, %{real: real, inject: inject} = state) do
      if is_function(inject, 0) and job_row_write?(request) do
        :ok = inject.()
        {:reply, GenServer.call(real, request), %{state | inject: nil}}
      else
        {:reply, GenServer.call(real, request), state}
      end
    end

    defp job_row_write?(request) when is_tuple(request),
      do: elem(request, 0) in [:upsert_scheduled_job, :update_scheduled_job_fields]

    defp job_row_write?(_request), do: false
  end

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
                 created_by_trust: "operator",
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
                 created_by_trust: "operator",
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
                 created_by_trust: "operator",
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
                 created_by_trust: "operator",
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
                 created_by_trust: "operator",
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
                 created_by_trust: "operator",
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
                 created_by_trust: "operator",
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
               %{
                 created_by_trust: "operator",
                 name: "Weather",
                 schedule: "every 15 minutes",
                 task_prompt: "Send weather."
               },
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
               %{
                 created_by_trust: "operator",
                 name: "Digest",
                 schedule: "every 15 minutes",
                 task_prompt: "Old."
               },
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
                 created_by_trust: "operator",
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
               %{
                 created_by_trust: "operator",
                 name: "Repin",
                 schedule: "every 15 minutes",
                 task_prompt: "Run."
               },
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
               %{
                 created_by_trust: "operator",
                 name: "Empty",
                 schedule: "every 15 minutes",
                 task_prompt: "Do."
               },
               repo: repo
             )

    assert {:error, :empty_update} = Registry.update_job(job.id, %{}, repo: repo)
    assert {:error, :not_found} = Registry.update_job("missing_job", %{task: "x"}, repo: repo)
  end

  test "update_job rejects an invalid schedule and leaves the job unchanged", %{repo: repo} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Stable",
                 schedule: "every 15 minutes",
                 task_prompt: "Keep."
               },
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
               %{
                 created_by_trust: "operator",
                 name: "Bad",
                 schedule: "sometimes",
                 task_prompt: "Do a thing."
               },
               repo: repo
             )

    assert {:ok, []} = Registry.list_jobs(repo: repo)

    assert {:error, {:invalid_schedule, "99 * * * *"}} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Bad Cron",
                 schedule: "99 * * * *",
                 task_prompt: "Do a thing."
               },
               repo: repo
             )

    assert {:ok, []} = Registry.list_jobs(repo: repo)
  end

  test "create_job fails loudly when created_by_trust is missing", %{repo: repo} do
    assert {:error, reason} =
             Registry.create_job(
               %{
                 name: "No Trust",
                 schedule: "every 15 minutes",
                 task_prompt: "Run."
               },
               repo: repo
             )

    assert reason =~ "created_by_trust"
    assert {:ok, []} = Registry.list_jobs(repo: repo)
  end

  test "create_job rejects an out-of-vocabulary created_by_trust", %{repo: repo} do
    assert {:error, reason} =
             Registry.create_job(
               %{
                 name: "Bad Trust",
                 schedule: "every 15 minutes",
                 task_prompt: "Run.",
                 created_by_trust: "core"
               },
               repo: repo
             )

    assert reason =~ "created_by_trust"
    assert {:ok, []} = Registry.list_jobs(repo: repo)
  end

  # M60 §9.1: a watcher's task is a job with no schedule of its own. Only
  # `create_cue_job/2` makes one; `Schedule.parse/2` has no word for it.
  describe "a job that runs on cues" do
    @report_to %{"platform" => "telegram", "chat_id" => "4242"}

    defp cue_attrs(extra) do
      Map.merge(
        %{
          created_by_trust: "operator",
          name: "Release Notes Task",
          task_prompt: "Tell me what changed in the release the cue names.",
          delivery_mode: "origin",
          delivery_target: @report_to
        },
        extra
      )
    end

    defp create_cue_job!(repo, extra \\ %{}) do
      {:ok, job} = Registry.create_cue_job(cue_attrs(extra), repo: repo, scheduler: nil)
      job
    end

    test "is created with no schedule, no next run, no expiry and a 10-minute timeout", %{
      repo: repo
    } do
      job = create_cue_job!(repo)

      assert job.schedule_kind == "cue"
      assert job.schedule_expr == "cue"
      assert job.next_run_at == nil
      assert job.expires_at == nil
      assert job.timeout_seconds == 600
      assert job.delivery_mode == "origin"
      assert job.delivery_target == @report_to
      assert job.state == "scheduled"
      assert job.enabled? == true
      assert Registry.cue_job?(job)

      assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
      assert source.schedule_summary == "runs on cues"
    end

    test "takes a timeout of up to 30 minutes and refuses 45", %{repo: repo} do
      assert create_cue_job!(repo, %{timeout_seconds: 1_800}).timeout_seconds == 1_800

      assert {:error, "A job that runs on cues may run for at most 30 minutes."} =
               Registry.create_cue_job(cue_attrs(%{timeout_seconds: 2_700}),
                 repo: repo,
                 scheduler: nil
               )
    end

    test "refuses a schedule of any kind, a timezone and an expiry", %{repo: repo} do
      for extra <- [
            %{schedule: "2099-05-03T12:00:00Z"},
            %{schedule: "every 15 minutes"},
            %{timezone: "America/New_York"}
          ] do
        assert {:error, "A job that runs on cues has no schedule of its own."} =
                 Registry.create_cue_job(cue_attrs(extra), repo: repo, scheduler: nil)
      end

      assert {:error, "A job that runs on cues cannot expire."} =
               Registry.create_cue_job(cue_attrs(%{expires_at: ~U[2099-05-03 12:00:00Z]}),
                 repo: repo,
                 scheduler: nil
               )

      assert {:ok, []} = Registry.list_jobs(repo: repo)
    end

    test "refuses a delivery that does not reach the owner", %{repo: repo} do
      for extra <- [
            %{delivery_mode: "none", delivery_target: nil},
            %{delivery_mode: "local", delivery_target: nil},
            %{delivery_mode: "channel", delivery_target: nil},
            %{delivery_mode: nil, delivery_target: nil}
          ] do
        assert {:error, "A watcher's task must reach you: pick where it reports."} =
                 Registry.create_cue_job(cue_attrs(extra), repo: repo, scheduler: nil)
      end

      assert {:ok, []} = Registry.list_jobs(repo: repo)
    end

    # Its surface is `Jobs.CueSurface`'s alone: a policy would narrow it
    # silently (the note tools, a mandate's write tools).
    test "refuses a capability policy at creation and on update_job", %{repo: repo} do
      sentence = "A job that runs on cues uses the cue surface; it takes no capability policy."

      assert {:error, ^sentence} =
               Registry.create_cue_job(cue_attrs(%{capability_policy: ["read_only"]}),
                 repo: repo,
                 scheduler: nil
               )

      job = create_cue_job!(repo, %{capability_policy: []})
      assert job.capability_policy == []

      for attrs <- [%{capability_policy: ["read_only"]}, %{"capability_policy" => ["network"]}] do
        assert {:error, ^sentence} =
                 Registry.update_job(job.id, attrs, repo: repo, scheduler: nil)
      end

      assert {:ok, ^job} = Registry.get_job(job.id, repo: repo)
    end

    test "resumes with no next run", %{repo: repo} do
      job = create_cue_job!(repo)
      assert {:ok, _paused} = Registry.pause_job(job.id, repo: repo, scheduler: nil)

      assert {:ok, resumed} =
               Registry.resume_job(job.id,
                 repo: repo,
                 scheduler: nil,
                 now: ~U[2026-05-02 18:00:00Z]
               )

      assert resumed.state == "scheduled"
      assert resumed.enabled? == true
      assert resumed.next_run_at == nil
      assert resumed.schedule_kind == "cue"
    end

    test "update_job refuses a schedule, a timezone or an expiry and leaves the job unchanged",
         %{repo: repo} do
      job = create_cue_job!(repo)

      for attrs <- [
            %{schedule: "2099-05-03T12:00:00Z"},
            %{schedule: "0 8 * * *"},
            %{"schedule" => "every 15 minutes"},
            %{timezone: "America/New_York"},
            %{expires_at: ~U[2099-05-03 12:00:00Z]},
            %{task_prompt: "A new prompt.", schedule: "every 1 hour"}
          ] do
        assert {:error, "This job runs on cues; its schedule cannot change."} =
                 Registry.update_job(job.id, attrs, repo: repo, scheduler: nil)
      end

      assert {:ok, ^job} = Registry.get_job(job.id, repo: repo)
    end

    test "update_job refuses a silent delivery and takes any other edit", %{repo: repo} do
      job = create_cue_job!(repo)

      for mode <- ["none", "local", "channel"] do
        assert {:error, "A watcher's task must reach you: pick where it reports."} =
                 Registry.update_job(job.id, %{delivery_mode: mode, delivery_target: nil},
                   repo: repo,
                   scheduler: nil
                 )
      end

      assert {:ok, updated} =
               Registry.update_job(job.id, %{task_prompt: "Summarize the release."},
                 repo: repo,
                 scheduler: nil
               )

      assert updated.task_prompt == "Summarize the release."
      assert updated.schedule_kind == "cue"
      assert updated.next_run_at == nil
      assert updated.delivery_mode == "origin"
    end

    test "no other job becomes one: the schedule parser has no word for it", %{repo: repo} do
      job = create_frequent_job!(repo, "Cron Job")

      assert {:error, {:invalid_schedule, "cue"}} =
               Registry.update_job(job.id, %{schedule: "cue"}, repo: repo, scheduler: nil)

      assert {:error, {:invalid_schedule, "cue"}} =
               Registry.create_job(
                 %{
                   created_by_trust: "operator",
                   name: "Typed Cue",
                   schedule: "cue",
                   task_prompt: "Run."
                 },
                 repo: repo,
                 scheduler: nil
               )

      assert {:ok, %{schedule_kind: "interval"}} = Registry.get_job(job.id, repo: repo)
      refute Registry.cue_job?(job)
    end

    test "check_run_now refuses it and passes any other job", %{repo: repo} do
      cue_job = create_cue_job!(repo)
      cron_job = create_frequent_job!(repo, "Cron Job")

      assert {:error, "This job runs on cues."} = Registry.check_run_now(cue_job.id, repo: repo)
      assert :ok = Registry.check_run_now(cron_job.id, repo: repo)
      assert {:error, :not_found} = Registry.check_run_now("job_missing", repo: repo)
    end

    test "the due scan and the next-wakeup lookup never see it", %{repo: repo} do
      _job = create_cue_job!(repo)

      assert {:ok, []} = Repo.due_scheduled_jobs(~U[2099-12-31 23:59:00Z], server: repo)
      assert {:ok, nil} = Repo.next_scheduled_job(server: repo)
    end

    test "a settled run hands it back to scheduled, never completed", %{repo: repo} do
      job = create_cue_job!(repo)
      claimed_at = ~U[2026-05-02 14:00:00Z]

      assert {:ok, {running, run}} =
               Repo.claim_job_now(
                 job.id,
                 %{state: "running", updated_at: claimed_at},
                 %{
                   id: "run_cue_settle",
                   job_id: job.id,
                   session_id: "cron_#{job.id}_20260502_140000",
                   trigger: "manual",
                   status: "queued",
                   claimed_at: claimed_at,
                   delivery_status: "none",
                   created_at: claimed_at,
                   updated_at: claimed_at
                 },
                 server: repo
               )

      assert running.state == "running"

      final =
        Map.merge(run, %{status: "ok", completed_at: @released_at, updated_at: @released_at})

      assert {:ok, {_settled, released}} = Repo.settle_job_run(final, server: repo)
      assert released.state == "scheduled"
      assert released.enabled? == true
      assert released.next_run_at == nil
    end
  end

  # A watcher's follow-up (M60_WATCHER_CODING_RUNS.md §4.1): the `"watcher"`
  # kind, made only by `create_follow_up_job/2`, inherits every refusal of the
  # cue kind but one: the owner may run it now by hand.
  describe "a watcher's follow-up" do
    defp follow_up_attrs(extra) do
      Map.merge(
        %{
          created_by_trust: "operator",
          name: "Codex review",
          task_prompt: "Review the last day's commits on dev and report the findings.",
          allowed_tools: ["codex_run"],
          delivery_mode: "origin",
          delivery_target: %{"platform" => "telegram", "chat_id" => "4242"}
        },
        extra
      )
    end

    defp create_follow_up!(repo, extra \\ %{}) do
      {:ok, job} =
        Registry.create_follow_up_job(follow_up_attrs(extra), repo: repo, scheduler: nil)

      job
    end

    test "is made with no schedule, no next run and no expiry; no schedule names its kind", %{
      repo: repo
    } do
      job = create_follow_up!(repo)

      assert {job.schedule_kind, job.schedule_expr} == {"watcher", "watcher"}
      assert {job.next_run_at, job.expires_at, job.timeout_seconds} == {nil, nil, 600}
      assert job.allowed_tools == ["codex_run"]
      assert Registry.follow_up_job?(job)
      refute Registry.cue_job?(job)

      assert {:error, {:invalid_schedule, "watcher"}} = Schedule.parse("watcher")

      assert {:error, {:invalid_schedule, "watcher"}} =
               Registry.create_job(Map.put(follow_up_attrs(%{}), :schedule, "watcher"),
                 repo: repo,
                 scheduler: nil
               )
    end

    test "refuses a schedule, an expiry, a policy, no tools and a delivery that reaches no one",
         %{repo: repo} do
      for {extra, sentence} <- [
            {%{schedule: "every 1 hour"}, "A job that runs on cues has no schedule of its own."},
            {%{expires_at: ~U[2099-05-03 12:00:00Z]}, "A job that runs on cues cannot expire."},
            {%{capability_policy: ["exec"]},
             "A watcher's follow-up runs with the tools it names; it takes no capability policy."},
            {%{allowed_tools: []}, "A watcher's follow-up names the tools it may use."},
            {%{delivery_mode: "none", delivery_target: nil},
             "A watcher's follow-up must reach you: pick where it reports."},
            {%{timeout_seconds: 2_700}, "A job that runs on cues may run for at most 30 minutes."}
          ] do
        assert {:error, ^sentence} =
                 Registry.create_follow_up_job(follow_up_attrs(extra), repo: repo, scheduler: nil)
      end

      assert {:ok, []} = Registry.list_jobs(repo: repo)
    end

    test "update_job keeps its schedule, its tools as its grant and its delivery to the owner",
         %{repo: repo} do
      job = create_follow_up!(repo)
      opts = [repo: repo, scheduler: nil]

      for attrs <- [%{schedule: "every 1 hour"}, %{timezone: "Europe/Paris"}] do
        assert {:error, "This job runs on cues; its schedule cannot change."} =
                 Registry.update_job(job.id, attrs, opts)
      end

      assert {:error,
              "A watcher's follow-up runs with the tools it names; it takes no " <>
                "capability policy."} =
               Registry.update_job(job.id, %{capability_policy: ["exec"]}, opts)

      assert {:error, "A watcher's follow-up must reach you: pick where it reports."} =
               Registry.update_job(job.id, %{delivery_mode: "local"}, opts)

      assert {:ok, %{task_prompt: "Run the deploy check."}} =
               Registry.update_job(job.id, %{task_prompt: "Run the deploy check."}, opts)
    end

    test "resume arms no next run; the due scan never sees it; the owner may run it now", %{
      repo: repo
    } do
      job = create_follow_up!(repo)
      opts = [repo: repo, scheduler: nil]

      assert {:ok, %{state: "paused"}} = Registry.pause_job(job.id, opts)
      assert {:ok, %{state: "scheduled", next_run_at: nil}} = Registry.resume_job(job.id, opts)
      assert {:ok, []} = Repo.due_scheduled_jobs(~U[2099-12-31 23:59:00Z], server: repo)
      assert {:ok, nil} = Repo.next_scheduled_job(server: repo)
      assert :ok = Registry.check_run_now(job.id, repo: repo)
    end

    test "update_follow_up_job is the one path that changes its tools, never to none", %{
      repo: repo
    } do
      job = create_follow_up!(repo)
      cron_job = create_frequent_job!(repo, "Cron Job")
      opts = [repo: repo, scheduler: nil]

      assert {:ok, changed} =
               Registry.update_follow_up_job(
                 job.id,
                 %{allowed_tools: ["codex_run", "slack_post"], timeout_seconds: 900},
                 opts
               )

      assert {changed.allowed_tools, changed.timeout_seconds} ==
               {["codex_run", "slack_post"], 900}

      assert {:error, "A watcher's follow-up names the tools it may use."} =
               Registry.update_follow_up_job(job.id, %{allowed_tools: []}, opts)

      assert {:error, "Job " <> _rest} =
               Registry.update_follow_up_job(cron_job.id, %{allowed_tools: ["shell"]}, opts)

      # The generic update path never touches a job's tools.
      assert {:ok, %{allowed_tools: ["codex_run", "slack_post"]}} =
               Registry.update_job(job.id, %{allowed_tools: ["shell"], task_prompt: "x"}, opts)
    end
  end

  # An owner write lands in the middle of a run's life, and the run's release
  # (state and last_* bookkeeping) can land between the owner's read and write.
  # Each owner verb writes only the columns it owns, so neither write reverts
  # the other.
  describe "owner writes racing a run's release" do
    test "update_job keeps a release that lands between its read and its write", %{repo: repo} do
      job = create_frequent_job!(repo, "Edited Mid-Run")
      _running = put_job!(repo, job, %{state: "running"})
      proxy = start_inject_repo(repo, fn -> release_as_settle(repo, job.id) end)

      assert {:ok, updated} =
               Registry.update_job(job.id, %{task_prompt: "Edited mid-run."},
                 repo: proxy,
                 scheduler: nil
               )

      assert updated.task_prompt == "Edited mid-run."
      assert updated.state == "scheduled"
      assert updated.last_status == "ok"
      assert updated.last_run_at == @released_at
      assert {:ok, ^updated} = Registry.get_job(job.id, repo: repo)
    end

    test "pause writes only enabled and state, keeping a release that lands before it", %{
      repo: repo
    } do
      job = create_frequent_job!(repo, "Paused Mid-Run")
      _running = put_job!(repo, job, %{state: "running"})
      proxy = start_inject_repo(repo, fn -> release_as_settle(repo, job.id) end)

      assert {:ok, paused} = Registry.pause_job(job.id, repo: proxy, scheduler: nil)

      assert paused.state == "paused"
      assert paused.enabled? == false
      assert paused.last_status == "ok"
      assert paused.last_run_at == @released_at
    end

    test "resume keeps a release that lands between its read and its write", %{repo: repo} do
      job = create_frequent_job!(repo, "Resumed Mid-Run")
      _paused = put_job!(repo, job, %{state: "paused", enabled?: false})
      proxy = start_inject_repo(repo, fn -> release_as_settle(repo, job.id) end)

      assert {:ok, resumed} =
               Registry.resume_job(job.id,
                 repo: proxy,
                 scheduler: nil,
                 now: ~U[2026-05-02 14:25:00Z]
               )

      assert resumed.state == "scheduled"
      assert resumed.enabled? == true
      assert resumed.next_run_at == ~U[2026-05-02 14:40:00Z]
      assert resumed.last_status == "ok"
      assert resumed.last_run_at == @released_at
    end
  end

  defp create_frequent_job!(repo, name) do
    {:ok, job} =
      Registry.create_job(
        %{
          created_by_trust: "operator",
          name: name,
          schedule: "every 15 minutes",
          task_prompt: "Run."
        },
        repo: repo,
        now: ~U[2026-05-02 14:00:00Z]
      )

    job
  end

  defp put_job!(repo, job, patch) do
    {:ok, updated} = Repo.upsert_scheduled_job(Map.merge(job, patch), server: repo)
    updated
  end

  # What a run's settle does to the job row: `running` back to `scheduled`
  # (any other state kept) and the run's outcome in last_*.
  defp release_as_settle(repo, job_id) do
    {:ok, current} = Repo.get_scheduled_job(job_id, server: repo)
    state = if current.state == "running", do: "scheduled", else: current.state
    release = %{state: state, last_status: "ok", last_run_at: @released_at}
    {:ok, _released} = Repo.upsert_scheduled_job(Map.merge(current, release), server: repo)
    :ok
  end

  defp start_inject_repo(real, inject) do
    {:ok, pid} = start_supervised({InjectBeforeWriteRepo, real: real, inject: inject})
    pid
  end
end
