defmodule FermixCore.Tools.JobsTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.ListJobRuns
  alias FermixCore.Tools.ListJobs
  alias FermixCore.Tools.MemorySourcesList
  alias FermixCore.Tools.PauseJob
  alias FermixCore.Tools.RemoveJob
  alias FermixCore.Tools.ResumeJob
  alias FermixCore.Tools.ScheduleJob
  alias FermixCore.Tools.UpdateJob

  defmodule SkillRegistryStub do
    @moduledoc false
    # Minimal stand-in for FermixCore.Agents.SkillRegistry. schedule_job's
    # create-time validation only ever calls `SkillRegistry.load(registry,
    # name)`, so a map-backed GenServer keeps the binding tests hermetic — no
    # fixture skill files, no default-skill seeding.
    use GenServer

    def start_link(skills) when is_list(skills) do
      GenServer.start_link(__MODULE__, MapSet.new(skills))
    end

    @impl true
    def init(skills), do: {:ok, skills}

    @impl true
    def handle_call({:load, name}, _from, skills) do
      reply =
        if MapSet.member?(skills, name) do
          {:ok, %{name: name}}
        else
          {:error, {:unknown_skill, name}}
        end

      {:reply, reply, skills}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-tools-#{unique}.db")
    repo = :"job_tools_repo_#{unique}"
    jobs_config = Application.get_env(:fermix_core, :jobs, [])

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Application.put_env(:fermix_core, :jobs, jobs_config)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{
      context: %{
        agent_name: "test_agent",
        memory_repo: repo,
        memory_agent_id: "main",
        conversation_key: {"telegram", "chat-1", :root},
        session_id: "telegram:chat-1:root"
      }
    }
  end

  test "main-agent job tools create, list, pause, resume, and remove jobs", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Daily Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Summarize what changed.",
                 "timezone" => "America/New_York",
                 # F-08: capability_policy was removed from the public schema —
                 # the runner derives it from the creator's trust. allowed_tools
                 # must be a subset of what the caller can currently see, so the
                 # test passes an empty list (full caller visibility implied).
                 "allowed_tools" => []
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)
    job_id = created_payload["id"]

    assert created_payload["memory_source_id"] == "job:#{job_id}"
    assert created_payload["state"] == "scheduled"

    assert {:ok, listed} = ListJobs.execute(%{}, context)
    assert %{"jobs" => [listed_job]} = Jason.decode!(listed.output)
    assert listed_job["id"] == job_id
    assert listed_job["task_prompt"] == "Summarize what changed."

    assert {:ok, paused} = PauseJob.execute(%{"job_id" => job_id}, context)
    assert %{"enabled" => false, "state" => "paused"} = Jason.decode!(paused.output)

    assert {:ok, sources} =
             MemorySourcesList.execute(%{"source_type" => "scheduled_job"}, context)

    assert %{"sources" => [source]} = Jason.decode!(sources.output)
    assert source["id"] == "job:#{job_id}"
    assert source["status"] == "paused"

    assert {:ok, resumed} = ResumeJob.execute(%{"job_id" => job_id}, context)
    assert %{"enabled" => true, "state" => "scheduled"} = Jason.decode!(resumed.output)

    assert {:ok, removed} = RemoveJob.execute(%{"job_id" => job_id}, context)
    assert %{"removed" => true, "job_id" => ^job_id} = Jason.decode!(removed.output)

    assert {:ok, final_sources} =
             MemorySourcesList.execute(%{"source_type" => "scheduled_job"}, context)

    assert %{"sources" => [%{"status" => "removed"}]} = Jason.decode!(final_sources.output)
  end

  test "update_job edits an existing job's task and schedule in place", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Weather",
                 "schedule" => "every 15 minutes",
                 "task" => "Send weather.",
                 "allowed_tools" => []
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(
               %{
                 "job_id" => job_id,
                 "task" => "Send weather for 94105.",
                 "schedule" => "every 30 minutes"
               },
               context
             )

    assert updated.success == true
    payload = Jason.decode!(updated.output)
    assert payload["id"] == job_id
    assert payload["schedule_expr"] == "every 30 minutes"

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.task_prompt == "Send weather for 94105."
    assert job.schedule_expr == "every 30 minutes"
  end

  test "update_job requires at least one field to change", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "NoOp", "schedule" => "every 15 minutes", "task" => "Do."},
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, result} = UpdateJob.execute(%{"job_id" => job_id}, context)
    assert result.success == false
    assert result.error =~ "at least one of task, schedule, description, skill_name, or delivery"
  end

  test "schedule_job exposes and persists runner timeout controls", %{context: context} do
    params = ScheduleJob.parameters()
    assert Map.has_key?(params.properties, :timeout_seconds)
    assert Map.has_key?(params.properties, :inactivity_timeout_seconds)
    assert Map.has_key?(params.properties, :expires_at)
    assert ScheduleJob.description() =~ "cron-style recurring work"
    assert ScheduleJob.description() =~ "expires_at"
    assert ScheduleJob.description() =~ "instead of shell, browser, computer-use"
    assert params.properties.schedule.description =~ "5-field cron"
    assert params.properties.schedule.description =~ "steps (*/15)"
    assert params.properties.task.description =~ "Do not execute the task now"

    assert params.properties.task.description =~
             "Keep lifecycle timing in schedule and expires_at"

    assert params.properties.task.description =~ "cannot see this conversation"

    assert params.properties.expires_at.description =~ "temporary"
    assert params.properties.delivery_mode.description =~ "delivery_mode"
    assert params.properties.delivery_mode.description =~ "origin"

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Timeout Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Summarize what changed.",
                 "expires_at" => "2099-05-02T16:00:00Z",
                 "timeout_seconds" => 900,
                 "inactivity_timeout_seconds" => 300
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)
    assert created_payload["expires_at"] == "2099-05-02T16:00:00Z"
    assert created_payload["timeout_seconds"] == 900
    assert created_payload["inactivity_timeout_seconds"] == 300

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.expires_at == ~U[2099-05-02 16:00:00Z]
    assert job.timeout_seconds == 900
    assert job.inactivity_timeout_seconds == 300
  end

  test "schedule_job derives origin delivery target from the current conversation", %{
    context: context
  } do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Origin Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Report back here.",
                 "delivery_mode" => "origin"
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.delivery_mode == "origin"
    assert job.delivery_target == %{"platform" => "telegram", "chat_id" => "chat-1"}
    assert job.created_by_session_id == "telegram:chat-1:root"
  end

  test "schedule_job keeps origin thread metadata when present", %{context: context} do
    context = %{context | conversation_key: {"slack", "C123", "1700000000.123"}}

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Thread Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Report in this thread.",
                 "delivery_mode" => "origin"
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)

    assert job.delivery_target == %{
             "platform" => "slack",
             "chat_id" => "C123",
             "thread_ts" => "1700000000.123",
             "message_thread_id" => "1700000000.123"
           }

    assert job.created_by_session_id == "slack:C123:1700000000.123"
  end

  test "schedule_job uses configured cron default delivery target when omitted", %{
    context: context
  } do
    Application.put_env(
      :fermix_core,
      :jobs,
      default_delivery_mode: "channel",
      default_delivery_target: [platform: "telegram", chat_id: "default-chat"]
    )

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Default Delivery Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Report to the default cron channel."
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.delivery_mode == "channel"
    assert job.delivery_target == %{"platform" => "telegram", "chat_id" => "default-chat"}
  end

  test "explicit schedule_job delivery settings override cron defaults", %{context: context} do
    Application.put_env(
      :fermix_core,
      :jobs,
      default_delivery_mode: "channel",
      default_delivery_target: [platform: "telegram", chat_id: "default-chat"]
    )

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Explicit Local Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Save only.",
                 "delivery_mode" => "local"
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.delivery_mode == "local"
    assert job.delivery_target == nil
  end

  test "explicit channel mode can use the configured cron default target", %{context: context} do
    Application.put_env(
      :fermix_core,
      :jobs,
      default_delivery_mode: "channel",
      default_delivery_target: [platform: "telegram", chat_id: "default-chat"]
    )

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Channel Default Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Use the configured channel.",
                 "delivery_mode" => "channel"
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.delivery_mode == "channel"
    assert job.delivery_target == %{"platform" => "telegram", "chat_id" => "default-chat"}
  end

  test "schedule_job returns a tool error instead of raising for invalid input", %{
    context: context
  } do
    telemetry_id = "schedule-job-error-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      telemetry_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    assert {:ok, result} =
             ScheduleJob.execute(%{"name" => "Bad", "schedule" => "sometimes"}, context)

    assert result.success == false
    assert result.error == "Missing required parameter: task"

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
    assert metadata.tool == "schedule_job"
    assert metadata.success == false
    assert metadata.error == "Missing required parameter: task"
  end

  test "schedule_job rejects channel mode without a delivery target", %{context: context} do
    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Channel No Target",
                 "schedule" => "every 15 minutes",
                 "task" => "Send report.",
                 "delivery_mode" => "channel"
               },
               context
             )

    assert result.success == false
    assert result.error =~ ~s(delivery_mode "channel" requires delivery_target)
  end

  test "schedule_job rejects channel mode when target is missing platform", %{context: context} do
    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Channel No Platform",
                 "schedule" => "every 15 minutes",
                 "task" => "Send report.",
                 "delivery_mode" => "channel",
                 "delivery_target" => %{"chat_id" => "123"}
               },
               context
             )

    assert result.success == false
    assert result.error =~ ~s(delivery_target is missing "platform")
  end

  test "schedule_job rejects channel mode when target is missing a destination", %{
    context: context
  } do
    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Channel No Destination",
                 "schedule" => "every 15 minutes",
                 "task" => "Send report.",
                 "delivery_mode" => "channel",
                 "delivery_target" => %{"platform" => "telegram"}
               },
               context
             )

    assert result.success == false
    assert result.error =~ "missing a destination"
  end

  test "schedule_job rejects origin mode without a conversation context", %{context: context} do
    context = Map.delete(context, :conversation_key)

    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Origin No Context",
                 "schedule" => "every 15 minutes",
                 "task" => "Report back.",
                 "delivery_mode" => "origin"
               },
               context
             )

    assert result.success == false
    assert result.error =~ ~s(delivery_mode "origin" requires a conversation context)
  end

  test "schedule_job exposes the skill_name binding parameter" do
    params = ScheduleJob.parameters()
    assert Map.has_key?(params.properties, :skill_name)
    assert params.properties.skill_name.description =~ "confinement"
  end

  test "schedule_job binds a job to an existing skill and surfaces it", %{context: context} do
    {:ok, skill_registry} = SkillRegistryStub.start_link(["weather"])
    context = Map.put(context, :skill_registry, skill_registry)

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Weather Watcher",
                 "schedule" => "every 15 minutes",
                 "task" => "Check the forecast.",
                 "skill_name" => "weather"
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)
    assert created_payload["skill_name"] == "weather"

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.skill_name == "weather"
  end

  test "schedule_job rejects an unknown skill_name at create time", %{context: context} do
    {:ok, skill_registry} = SkillRegistryStub.start_link(["weather"])
    context = Map.put(context, :skill_registry, skill_registry)

    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Ghost Skill Job",
                 "schedule" => "every 15 minutes",
                 "task" => "Run inside a skill that does not exist.",
                 "skill_name" => "nonexistent"
               },
               context
             )

    assert result.success == false
    assert result.error =~ "unknown_skill: nonexistent"

    assert {:ok, %{"jobs" => []}} =
             Jason.decode(elem(ListJobs.execute(%{}, context), 1).output)
  end

  test "update_job exposes delivery and skill_name parameters" do
    params = UpdateJob.parameters()
    assert Map.has_key?(params.properties, :skill_name)
    assert Map.has_key?(params.properties, :delivery_mode)
    assert Map.has_key?(params.properties, :delivery_target)
    assert params.properties.delivery_mode.enum == ["none", "origin", "channel", "local"]
  end

  test "update_job changes delivery mode and target in place", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Redirect Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Report.",
                 "delivery_mode" => "local"
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(
               %{
                 "job_id" => job_id,
                 "delivery_mode" => "channel",
                 "delivery_target" => %{"platform" => "telegram", "chat_id" => "987"}
               },
               context
             )

    assert updated.success == true
    payload = Jason.decode!(updated.output)
    assert payload["delivery_mode"] == "channel"
    assert payload["delivery_target"] == %{"platform" => "telegram", "chat_id" => "987"}

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.delivery_mode == "channel"
    assert job.delivery_target == %{"platform" => "telegram", "chat_id" => "987"}
  end

  test "update_job leaves delivery untouched when delivery fields are omitted", %{
    context: context
  } do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Keep Delivery",
                 "schedule" => "every 15 minutes",
                 "task" => "Report.",
                 "delivery_mode" => "origin"
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]
    assert {:ok, before} = Repo.get_scheduled_job(job_id, server: context.memory_repo)

    assert {:ok, updated} =
             UpdateJob.execute(%{"job_id" => job_id, "task" => "Report something else."}, context)

    assert updated.success == true
    assert {:ok, after_job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert after_job.task_prompt == "Report something else."
    assert after_job.delivery_mode == before.delivery_mode
    assert after_job.delivery_target == before.delivery_target
  end

  test "update_job switching to local clears a stale delivery target", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Silence Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Report.",
                 "delivery_mode" => "channel",
                 "delivery_target" => %{"platform" => "telegram", "chat_id" => "55"}
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(%{"job_id" => job_id, "delivery_mode" => "local"}, context)

    assert updated.success == true
    assert Jason.decode!(updated.output)["delivery_target"] == nil

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.delivery_mode == "local"
    assert job.delivery_target == nil
  end

  test "update_job rebinds a job to an existing skill", %{context: context} do
    {:ok, skill_registry} = SkillRegistryStub.start_link(["weather"])
    context = Map.put(context, :skill_registry, skill_registry)

    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "Unbound", "schedule" => "every 15 minutes", "task" => "Report."},
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(%{"job_id" => job_id, "skill_name" => "weather"}, context)

    assert updated.success == true
    assert Jason.decode!(updated.output)["skill_name"] == "weather"

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.skill_name == "weather"
  end

  test "update_job rejects rebinding to an unknown skill", %{context: context} do
    {:ok, skill_registry} = SkillRegistryStub.start_link(["weather"])
    context = Map.put(context, :skill_registry, skill_registry)

    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "Stay Unbound", "schedule" => "every 15 minutes", "task" => "Report."},
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, result} =
             UpdateJob.execute(%{"job_id" => job_id, "skill_name" => "ghost"}, context)

    assert result.success == false
    assert result.error =~ "unknown_skill: ghost"

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.skill_name == nil
  end

  test "list_job_runs returns a job's run history newest-first", %{context: context} do
    job_id = seed_job(context, "History")

    seed_run(context, job_id, "run_old", "ok", ~U[2026-06-01 08:00:00Z])
    seed_run(context, job_id, "run_new", "error", ~U[2026-06-02 08:00:00Z])

    assert {:ok, listed} = ListJobRuns.execute(%{"job_id" => job_id}, context)
    assert listed.success == true
    assert %{"runs" => [first, second]} = Jason.decode!(listed.output)
    assert first["id"] == "run_new"
    assert second["id"] == "run_old"
    assert first["status"] == "error"
  end

  test "list_job_runs filters by status", %{context: context} do
    job_id = seed_job(context, "Filtered")

    seed_run(context, job_id, "run_ok", "ok", ~U[2026-06-01 08:00:00Z])
    seed_run(context, job_id, "run_err", "error", ~U[2026-06-02 08:00:00Z])

    assert {:ok, listed} =
             ListJobRuns.execute(%{"job_id" => job_id, "status" => "error"}, context)

    assert %{"runs" => [only]} = Jason.decode!(listed.output)
    assert only["id"] == "run_err"
  end

  test "list_job_runs requires a job_id", %{context: context} do
    assert {:ok, result} = ListJobRuns.execute(%{}, context)
    assert result.success == false
  end

  test "get_job_run returns the full run record", %{context: context} do
    job_id = seed_job(context, "Detailed")
    seed_run(context, job_id, "run_detail", "ok", ~U[2026-06-01 08:00:00Z])

    assert {:ok, fetched} = GetJobRun.execute(%{"run_id" => "run_detail"}, context)
    assert fetched.success == true
    payload = Jason.decode!(fetched.output)
    assert payload["id"] == "run_detail"
    assert payload["job_id"] == job_id
    assert payload["status"] == "ok"
    assert payload["final_response"] == "done"
    assert payload["task_prompt"] == "Report."
    assert Map.has_key?(payload, "prompt_snapshot")
    assert Map.has_key?(payload, "token_usage")
  end

  test "get_job_run reports a missing run", %{context: context} do
    assert {:ok, result} = GetJobRun.execute(%{"run_id" => "nope"}, context)
    assert result.success == false
    assert result.error =~ "Not found"
  end

  defp seed_job(context, name) do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => name, "schedule" => "every 15 minutes", "task" => "Report."},
               context
             )

    Jason.decode!(created.output)["id"]
  end

  defp seed_run(context, job_id, run_id, status, at) do
    {:ok, _run} =
      Repo.upsert_job_run(
        %{
          id: run_id,
          job_id: job_id,
          session_id: "cron_#{job_id}_#{run_id}",
          trigger: "schedule",
          status: status,
          claimed_at: at,
          started_at: at,
          completed_at: at,
          prompt_snapshot: "do the thing",
          job_config_snapshot: %{"task_prompt" => "Report."},
          final_response: "done",
          token_usage: %{"total" => 10},
          created_at: at,
          updated_at: at
        },
        server: context.memory_repo
      )
  end
end
