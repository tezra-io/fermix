defmodule FermixCore.Tools.JobsTest do
  use ExUnit.Case, async: false

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.ListJobRuns
  alias FermixCore.Tools.ListJobs
  alias FermixCore.Tools.MemorySourcesList
  alias FermixCore.Tools.PauseJob
  alias FermixCore.Tools.RemoveJob
  alias FermixCore.Tools.ResumeJob
  alias FermixCore.Tools.RunJobNow
  alias FermixCore.Tools.ScheduleJob
  alias FermixCore.Tools.Shell
  alias FermixCore.Tools.UpdateJob

  defmodule SkillRegistryStub do
    @moduledoc false
    # Minimal stand-in for FermixCore.Agents.SkillRegistry. The job tools only
    # ever call `SkillRegistry.load(registry, name)`, so a map-backed GenServer
    # keeps the binding tests hermetic — no fixture skill files, no
    # default-skill seeding. A bare name loads a skill with no allowlist;
    # `{name, allowed_tools}` loads one with that list, and `{name, %{...}}`
    # one with those fields.
    use GenServer

    def start_link(skills) when is_list(skills) do
      GenServer.start_link(__MODULE__, Map.new(skills, &definition/1))
    end

    defp definition(name) when is_binary(name), do: {name, %{name: name}}
    defp definition({name, %{} = fields}), do: {name, Map.put(fields, :name, name)}
    defp definition({name, tools}), do: {name, %{name: name, allowed_tools: tools}}

    @impl true
    def init(skills), do: {:ok, skills}

    @impl true
    def handle_call({:load, name}, _from, skills) do
      reply =
        case Map.fetch(skills, name) do
          {:ok, definition} -> {:ok, definition}
          :error -> {:error, {:unknown_skill, name}}
        end

      {:reply, reply, skills}
    end
  end

  defmodule ScriptedModel do
    @moduledoc false
    # A model that answers from a script in the process running the agent loop
    # (the loop calls its adapter there) and keeps the tool results it is
    # handed, so a test reads what a tool told the model.
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts), do: next_turn()

    @impl true
    def continue(_provider_state, tool_results, _opts) do
      Process.put(:tool_results, Process.get(:tool_results, []) ++ tool_results)
      next_turn()
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    # The loop reads `tool_calls` off the turn `chat/3` returns; it never calls this.
    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp next_turn do
      [next | rest] = Process.get(:script)
      Process.put(:script, rest)
      {:ok, next}
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
        session_id: "telegram:chat-1:root",
        source_trust: :operator,
        # A turn that read nothing from outside, as the agent loop stamps one.
        outside_sources: MapSet.new()
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

  describe "a job's time zone and times" do
    setup do
      previous = Application.get_env(:fermix_core, :personalization)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:fermix_core, :personalization)
          value -> Application.put_env(:fermix_core, :personalization, value)
        end
      end)

      :ok
    end

    defp schedule_tide_report!(context) do
      {:ok, created} =
        ScheduleJob.execute(
          %{
            "name" => "Saltmarsh Tide Report",
            "schedule" => "0 9 * * *",
            "task" => "Report today's tide times at Saltmarsh Point.",
            "allowed_tools" => []
          },
          context
        )

      Jason.decode!(created.output)
    end

    test "a job given no zone is read in the owner's, and its times carry the owner's offset",
         %{context: context} do
      Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

      payload = schedule_tide_report!(context)

      assert payload["timezone"] == "America/New_York"
      assert payload["next_run_at"] =~ ~r/T09:00:00-0[45]:00\z/
    end

    test "with no zone configured a job given none is read in UTC, and says so",
         %{context: context} do
      Application.put_env(:fermix_core, :personalization, [])

      payload = schedule_tide_report!(context)

      assert payload["timezone"] == "Etc/UTC"
      assert payload["next_run_at"] =~ ~r/T09:00:00Z\z/
    end
  end

  test "schedule_job without source_trust in context returns a clear tool error", %{
    context: context
  } do
    trustless = Map.delete(context, :source_trust)

    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "No Trust",
                 "schedule" => "every 15 minutes",
                 "task" => "Should never persist."
               },
               trustless
             )

    assert result.success == false
    assert result.error =~ "source_trust"
    assert {:error, :not_found} = Repo.get_scheduled_job("no_trust", server: context.memory_repo)
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

    assert result.error =~
             "at least one of task, schedule, description, skill_name, provider/model, clear_route_pin, or delivery"
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

  # MILESTONE_29_ACP_AGENT_SURFACE §4/§9: an ACP session is owned by the client
  # and ends with it, so a job that reports back "to the origin" would deliver
  # into nothing. Refused at schedule time, naming the way forward.
  test "schedule_job refuses origin mode from an acp conversation", %{context: context} do
    context = %{context | conversation_key: {"acp", "sess-abc", :root}}

    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "ACP Origin",
                 "schedule" => "every 15 minutes",
                 "task" => "Report back here.",
                 "delivery_mode" => "origin"
               },
               context
             )

    assert result.success == false
    assert result.error =~ "ACP session"
    assert result.error =~ "delivery_target"
  end

  # M56 §15: a task asked aloud on a call in the chat runs in the chat's own
  # conversation, so "report back here" is the chat, never the voice channel a
  # later run could not deliver to.
  test "schedule_job from a call's hand-off in the chat reports back into the chat", %{
    context: context
  } do
    context =
      Map.merge(context, %{
        conversation_key: {"companion", "main", :root},
        source_channel: "voice",
        channel: "voice"
      })

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Spoken Origin",
                 "schedule" => "every 15 minutes",
                 "task" => "Report back here.",
                 "delivery_mode" => "origin"
               },
               context
             )

    assert created.success == true
    payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(payload["id"], server: context.memory_repo)
    assert job.delivery_target == %{"platform" => "companion", "chat_id" => "main"}
    assert job.created_by_channel == "voice"
  end

  # A private call's conversation is the call's own and ends with it, so a job
  # that reported back "to the origin" would fail every run. Refused when it is
  # asked for, never created to fail later.
  test "schedule_job refuses origin mode from a private call's hand-off", %{context: context} do
    context =
      Map.merge(context, %{
        conversation_key: {"voice", "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab", :root},
        source_channel: "voice",
        channel: "voice"
      })

    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Private Origin",
                 "schedule" => "every 15 minutes",
                 "task" => "Report back here.",
                 "delivery_mode" => "origin"
               },
               context
             )

    assert result.success == false
    assert result.error =~ "private voice call"
    assert result.error =~ "delivery_target"
    assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: context.memory_repo)
  end

  test "schedule_job accepts an explicit delivery_target from an acp conversation", %{
    context: context
  } do
    context = %{context | conversation_key: {"acp", "sess-abc", :root}}

    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "ACP Explicit Target",
                 "schedule" => "every 15 minutes",
                 "task" => "Report to telegram.",
                 "delivery_mode" => "channel",
                 "delivery_target" => %{"platform" => "telegram", "chat_id" => "chat-1"}
               },
               context
             )

    assert created.success == true
    payload = Jason.decode!(created.output)

    assert {:ok, job} = Repo.get_scheduled_job(payload["id"], server: context.memory_repo)
    assert job.delivery_mode == "channel"
    assert job.delivery_target == %{"platform" => "telegram", "chat_id" => "chat-1"}
  end

  test "schedule_job exposes the skill_name binding parameter" do
    params = ScheduleJob.parameters()
    assert Map.has_key?(params.properties, :skill_name)
    assert params.properties.skill_name.description =~ "confinement"
  end

  test "schedule_job exposes the provider and model pinning parameters" do
    params = ScheduleJob.parameters()
    assert Map.has_key?(params.properties, :provider)
    assert Map.has_key?(params.properties, :model)
    assert params.properties.provider.description =~ "default cron route"
    assert params.properties.model.description =~ "model"
  end

  test "schedule_job pins provider and model on the job row", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Pinned Digest",
                 "schedule" => "every 15 minutes",
                 "task" => "Summarize.",
                 "provider" => "anthropic",
                 "model" => "claude-opus-4-8"
               },
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)
    assert created_payload["provider"] == "anthropic"
    assert created_payload["model"] == "claude-opus-4-8"

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.provider == "anthropic"
    assert job.model == "claude-opus-4-8"
  end

  test "schedule_job leaves provider and model nil when omitted", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "Default Route", "schedule" => "every 15 minutes", "task" => "Go."},
               context
             )

    assert created.success == true
    created_payload = Jason.decode!(created.output)
    assert created_payload["provider"] == nil
    assert created_payload["model"] == nil

    assert {:ok, job} = Repo.get_scheduled_job(created_payload["id"], server: context.memory_repo)
    assert job.provider == nil
    assert job.model == nil
  end

  test "schedule_job rejects an unknown provider and creates no job", %{context: context} do
    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Bad Provider",
                 "schedule" => "every 15 minutes",
                 "task" => "Go.",
                 "provider" => "nope",
                 "model" => "whatever"
               },
               context
             )

    assert result.success == false
    assert result.error =~ ~s(unknown provider "nope")

    assert {:ok, %{"jobs" => []}} =
             Jason.decode(elem(ListJobs.execute(%{}, context), 1).output)
  end

  test "schedule_job rejects model without provider (both-or-neither)", %{context: context} do
    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Half Pin",
                 "schedule" => "every 15 minutes",
                 "task" => "Go.",
                 "model" => "claude-opus-4-8"
               },
               context
             )

    assert result.success == false
    assert result.error =~ "provider and model must be set together"

    assert {:ok, %{"jobs" => []}} =
             Jason.decode(elem(ListJobs.execute(%{}, context), 1).output)
  end

  test "update_job exposes the provider and model pinning parameters" do
    params = UpdateJob.parameters()
    assert Map.has_key?(params.properties, :provider)
    assert Map.has_key?(params.properties, :model)
    assert params.properties.provider.description =~ "unchanged"
  end

  test "update_job pins provider and model in place", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "Repin", "schedule" => "every 15 minutes", "task" => "Go."},
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(
               %{"job_id" => job_id, "provider" => "anthropic", "model" => "claude-opus-4-8"},
               context
             )

    assert updated.success == true
    payload = Jason.decode!(updated.output)
    assert payload["provider"] == "anthropic"
    assert payload["model"] == "claude-opus-4-8"

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.provider == "anthropic"
    assert job.model == "claude-opus-4-8"
  end

  test "update_job leaves provider and model untouched when omitted", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Keep Pin",
                 "schedule" => "every 15 minutes",
                 "task" => "Go.",
                 "provider" => "anthropic",
                 "model" => "claude-opus-4-8"
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(%{"job_id" => job_id, "task" => "Go differently."}, context)

    assert updated.success == true

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.task_prompt == "Go differently."
    assert job.provider == "anthropic"
    assert job.model == "claude-opus-4-8"
  end

  test "update_job rejects an unknown provider and leaves the job unchanged", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "Stable Route", "schedule" => "every 15 minutes", "task" => "Go."},
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, result} =
             UpdateJob.execute(
               %{"job_id" => job_id, "provider" => "nope", "model" => "x"},
               context
             )

    assert result.success == false
    assert result.error =~ ~s(unknown provider "nope")

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.provider == nil
    assert job.model == nil
  end

  test "update_job rejects provider without model (both-or-neither)", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => "Half Repin", "schedule" => "every 15 minutes", "task" => "Go."},
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, result} =
             UpdateJob.execute(%{"job_id" => job_id, "provider" => "anthropic"}, context)

    assert result.success == false
    assert result.error =~ "provider and model must be set together"

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.provider == nil
    assert job.model == nil
  end

  test "update_job exposes the clear_route_pin parameter" do
    params = UpdateJob.parameters()
    assert Map.has_key?(params.properties, :clear_route_pin)
    assert params.properties.clear_route_pin.type == "boolean"
    assert params.properties.clear_route_pin.description =~ "default routing"
  end

  test "update_job clears a pinned route back to default routing", %{context: context} do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Unpin Me",
                 "schedule" => "every 15 minutes",
                 "task" => "Go.",
                 "provider" => "anthropic",
                 "model" => "claude-opus-4-8"
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, %{provider: "anthropic", model: "claude-opus-4-8"}} =
             Repo.get_scheduled_job(job_id, server: context.memory_repo)

    assert {:ok, updated} =
             UpdateJob.execute(%{"job_id" => job_id, "clear_route_pin" => true}, context)

    assert updated.success == true
    payload = Jason.decode!(updated.output)
    assert payload["provider"] == nil
    assert payload["model"] == nil

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.provider == nil
    assert job.model == nil
  end

  test "update_job rejects clearing the route pin together with provider/model", %{
    context: context
  } do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Conflicting Pin",
                 "schedule" => "every 15 minutes",
                 "task" => "Go.",
                 "provider" => "anthropic",
                 "model" => "claude-opus-4-8"
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, result} =
             UpdateJob.execute(
               %{
                 "job_id" => job_id,
                 "clear_route_pin" => true,
                 "provider" => "openai",
                 "model" => "gpt-5"
               },
               context
             )

    assert result.success == false
    assert result.error =~ "clear_route_pin cannot be combined with provider or model"

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.provider == "anthropic"
    assert job.model == "claude-opus-4-8"
  end

  test "update_job leaves an existing route pin when all route fields are omitted", %{
    context: context
  } do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{
                 "name" => "Untouched Pin",
                 "schedule" => "every 15 minutes",
                 "task" => "Go.",
                 "provider" => "anthropic",
                 "model" => "claude-opus-4-8"
               },
               context
             )

    job_id = Jason.decode!(created.output)["id"]

    assert {:ok, updated} =
             UpdateJob.execute(%{"job_id" => job_id, "task" => "Go elsewhere."}, context)

    assert updated.success == true

    assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
    assert job.task_prompt == "Go elsewhere."
    assert job.provider == "anthropic"
    assert job.model == "claude-opus-4-8"
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

  test "list_job_runs reports how many tool calls failed in a run", %{context: context} do
    job_id = seed_job(context, "Blocked")

    seed_run(context, job_id, "run_blocked", "ok", ~U[2026-06-01 08:00:00Z], %{tool_failures: 2})
    seed_run(context, job_id, "run_clean", "ok", ~U[2026-06-02 08:00:00Z], %{tool_failures: 0})

    assert {:ok, listed} = ListJobRuns.execute(%{"job_id" => job_id}, context)
    assert %{"runs" => [clean, blocked]} = Jason.decode!(listed.output)
    assert clean["tool_failures"] == 0
    assert blocked["tool_failures"] == 2
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

  # A job naming an access-sensitive tool may be set up, changed or run now only
  # from a turn that would run that tool directly (Capabilities.AccessGate), so an
  # injected instruction cannot schedule or trigger the command instead.
  describe "jobs naming an access-sensitive tool" do
    setup %{context: context} do
      registry = :"job_access_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})

      flagged =
        Capability.new(%{
          name: "tesla_unlock_doors",
          description: "Unlock the car's doors.",
          parameters: %{"type" => "object"},
          kind: :mcp,
          executor: {__MODULE__, :never_run, []},
          policy_class: :external_api,
          metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
        })

      :ok = CapabilityRegistry.register(registry, flagged)

      direct =
        Map.merge(context, %{
          capability_registry: registry,
          computer_use_origin: :interactive,
          outside_sources: MapSet.new()
        })

      tainted = Map.put(direct, :outside_sources, MapSet.new([{:tool, "web_fetch"}]))
      %{direct: direct, tainted: tainted}
    end

    test "schedule_job refuses to name it from a turn that read outside content", %{
      tainted: tainted,
      direct: direct
    } do
      args = %{
        "name" => "Valet",
        "schedule" => "every 15 minutes",
        "task" => "Unlock the car.",
        "allowed_tools" => ["tesla_unlock_doors"]
      }

      assert {:ok, refused} = ScheduleJob.execute(args, tainted)
      assert refused.success == false
      assert refused.error =~ "tesla_unlock_doors"
      assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: direct.memory_repo)

      assert {:ok, created} = ScheduleJob.execute(args, direct)
      assert created.success == true
    end

    test "schedule_job refuses to name it from a delegated worker", %{direct: direct} do
      args = %{
        "name" => "Valet",
        "schedule" => "every 15 minutes",
        "task" => "Unlock the car.",
        "allowed_tools" => ["tesla_unlock_doors"]
      }

      assert {:ok, refused} = ScheduleJob.execute(args, Map.put(direct, :subagent_depth, 1))
      assert refused.success == false
      assert refused.error =~ "tesla_unlock_doors can be set up"
    end

    # A Buzz channel is one other people can post in, so even a clean request
    # there is not the owner's direct consent to schedule the command.
    test "schedule_job refuses to name it from a Buzz channel", %{direct: direct} do
      args = %{
        "name" => "Valet",
        "schedule" => "every 15 minutes",
        "task" => "Unlock the car.",
        "allowed_tools" => ["tesla_unlock_doors"]
      }

      buzz = Map.put(direct, :session_env, %{"BUZZ_RELAY_URL" => "wss://relay.example.test"})

      assert {:ok, refused} = ScheduleJob.execute(args, buzz)
      assert refused.success == false
      assert refused.error =~ "tesla_unlock_doors can be set up"
      assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: direct.memory_repo)
    end

    test "update_job and run_job_now refuse such a job from a tainted turn and leave it unchanged",
         %{direct: direct, tainted: tainted} do
      assert {:ok, created} =
               ScheduleJob.execute(
                 %{
                   "name" => "Valet",
                   "schedule" => "every 15 minutes",
                   "task" => "Unlock the car.",
                   "allowed_tools" => ["tesla_unlock_doors"]
                 },
                 direct
               )

      job_id = Jason.decode!(created.output)["id"]

      assert {:ok, refused} =
               UpdateJob.execute(%{"job_id" => job_id, "task" => "Unlock it now."}, tainted)

      assert refused.success == false
      assert refused.error =~ "tesla_unlock_doors"
      assert {:ok, job} = Repo.get_scheduled_job(job_id, server: direct.memory_repo)
      assert job.task_prompt == "Unlock the car."

      assert {:ok, refused} = RunJobNow.execute(%{"job_id" => job_id}, tainted)
      assert refused.success == false
      assert refused.error =~ "tesla_unlock_doors"

      assert {:ok, updated} =
               UpdateJob.execute(%{"job_id" => job_id, "task" => "Unlock it now."}, direct)

      assert updated.success == true
    end

    # Resuming a paused job that names the command re-arms it, so it is gated
    # like run-now; pausing only stops it and stays open to any turn.
    test "resume_job refuses such a job from a tainted turn, and pause_job does not", %{
      direct: direct,
      tainted: tainted
    } do
      assert {:ok, created} =
               ScheduleJob.execute(
                 %{
                   "name" => "Valet",
                   "schedule" => "every 15 minutes",
                   "task" => "Unlock the car.",
                   "allowed_tools" => ["tesla_unlock_doors"]
                 },
                 direct
               )

      job_id = Jason.decode!(created.output)["id"]
      assert {:ok, %{success: true}} = PauseJob.execute(%{"job_id" => job_id}, tainted)

      assert {:ok, refused} = ResumeJob.execute(%{"job_id" => job_id}, tainted)
      assert refused.success == false
      assert refused.error =~ "tesla_unlock_doors"

      assert {:ok, %{state: "paused"}} =
               Repo.get_scheduled_job(job_id, server: direct.memory_repo)

      assert {:ok, resumed} = ResumeJob.execute(%{"job_id" => job_id}, direct)
      assert resumed.success == true
    end

    test "jobs that do not name it behave as before from any turn", %{tainted: tainted} do
      assert {:ok, created} =
               ScheduleJob.execute(
                 %{"name" => "Weather", "schedule" => "every 15 minutes", "task" => "Weather."},
                 tainted
               )

      assert created.success == true
      job_id = Jason.decode!(created.output)["id"]

      assert {:ok, updated} = UpdateJob.execute(%{"job_id" => job_id, "task" => "Rain?"}, tainted)
      assert updated.success == true
    end
  end

  # M60 §9.1, §15: a watcher's task is a job that runs on cues. The job tools
  # show it with its label, never run it by hand and never give it a schedule.
  describe "a job that runs on cues" do
    setup %{context: context} do
      {:ok, job} =
        JobsRegistry.create_cue_job(
          %{
            created_by_trust: "operator",
            name: "Release Notes Task",
            task_prompt: "Tell me what changed in the release the cue names.",
            delivery_mode: "origin",
            delivery_target: %{"platform" => "telegram", "chat_id" => "chat-1"}
          },
          repo: context.memory_repo,
          scheduler: nil
        )

      %{cue_job_id: job.id}
    end

    # A cue run always reads its watcher's deliveries through `cue_history`
    # (owner-only, `:read_only`), so a skill whose trust (a plugin skill's
    # guest) or classes (an operator skill asking only for `:exec`) leave it
    # off the run's surface is not bound to a watcher's task.
    test "update_job refuses a skill that leaves its runs without cue_history", %{
      context: context,
      cue_job_id: job_id
    } do
      registry = :"cue_skill_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})

      :ok =
        CapabilityRegistry.register(
          registry,
          BuiltinCapability.from_tool_module(FermixCore.Tools.CueHistory)
        )

      {:ok, skills} =
        SkillRegistryStub.start_link([
          {"plugin_helper", skill_definition("plugin_helper", %{}, :guest)},
          {"exec_helper", skill_definition("exec_helper", %{"policy" => ["exec"]}, :operator)},
          {"weather", skill_definition("weather", %{}, :operator)}
        ])

      context = Map.merge(context, %{skill_registry: skills, capability_registry: registry})

      for skill_name <- ["plugin_helper", "exec_helper"] do
        assert {:ok, refused} =
                 UpdateJob.execute(%{"job_id" => job_id, "skill_name" => skill_name}, context)

        assert refused.success == false

        assert refused.error =~
                 "Skill #{skill_name} leaves a watcher's task without cue_history"

        assert {:ok, %{skill_name: nil}} =
                 Repo.get_scheduled_job(job_id, server: context.memory_repo)
      end

      assert {:ok, %{success: true}} =
               UpdateJob.execute(%{"job_id" => job_id, "skill_name" => "weather"}, context)
    end

    test "run_job_now refuses it before the scheduler is asked", %{
      context: context,
      cue_job_id: job_id
    } do
      context = Map.put(context, :scheduler, :no_scheduler_is_asked)

      assert {:ok, refused} = RunJobNow.execute(%{"job_id" => job_id}, context)
      assert refused.success == false
      assert refused.error == "This job runs on cues."
      assert {:ok, []} = Repo.list_job_runs(%{job_id: job_id}, server: context.memory_repo)
    end

    test "update_job refuses a schedule for it and leaves it unchanged", %{
      context: context,
      cue_job_id: job_id
    } do
      for schedule <- ["2099-05-03T12:00:00Z", "every 15 minutes"] do
        assert {:ok, refused} =
                 UpdateJob.execute(%{"job_id" => job_id, "schedule" => schedule}, context)

        assert refused.success == false
        assert refused.error == "This job runs on cues; its schedule cannot change."
      end

      assert {:ok, job} = Repo.get_scheduled_job(job_id, server: context.memory_repo)
      assert job.schedule_kind == "cue"
      assert job.next_run_at == nil
    end

    test "list_jobs labels it, and only it, as running on cues", %{
      context: context,
      cue_job_id: job_id
    } do
      cron_job_id = seed_job(context, "Weather")

      assert {:ok, listed} = ListJobs.execute(%{}, context)
      jobs = Map.new(Jason.decode!(listed.output)["jobs"], &{&1["id"], &1})

      assert jobs[job_id]["schedule_label"] == "runs on cues"
      assert jobs[job_id]["next_run_at"] == nil
      refute Map.has_key?(jobs[cron_job_id], "schedule_label")
    end

    test "resume_job puts it back with no next run", %{context: context, cue_job_id: job_id} do
      assert {:ok, %{success: true}} = PauseJob.execute(%{"job_id" => job_id}, context)
      assert {:ok, resumed} = ResumeJob.execute(%{"job_id" => job_id}, context)

      assert %{"state" => "scheduled", "next_run_at" => nil, "schedule_kind" => "cue"} =
               Jason.decode!(resumed.output)
    end
  end

  # A job gets at most the tools of the run that creates or changes it, when
  # the run is narrowed in what it is authorized for: an allowlist, policy
  # classes short of its trust, or a loop trust below its person's. Every
  # narrowed context here is the one a tool saw inside a real loop
  # (`loop_context/3`), so the stamps are the loop's own.
  describe "a run narrowed to some tools" do
    setup %{context: context} do
      registry = :"job_ceiling_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})
      register_stand_in(registry, "web_search", :network, {__MODULE__, :report_context, [self()]})
      register_stand_in(registry, "update_job", :read_write)

      # The real shell and schedule_job shapes (shell a host command), so the
      # access gate judges them as it would live; shell never runs.
      shell = BuiltinCapability.from_tool_module(Shell)
      :ok = CapabilityRegistry.register(registry, %{shell | executor: stand_in_executor()})

      :ok =
        CapabilityRegistry.register(registry, BuiltinCapability.from_tool_module(ScheduleJob))

      {:ok, skill_registry} =
        SkillRegistryStub.start_link([{"searcher", ["web_search"]}, {"cleaner", ["shell"]}])

      open = Map.merge(context, %{capability_registry: registry, skill_registry: skill_registry})
      run_tools = ["web_search", "schedule_job", "update_job"]
      narrowed = loop_context(open, registry, allowed_tools: run_tools)
      %{open: open, narrowed: narrowed, registry: registry, run_tools: run_tools}
    end

    test "schedule_job refuses a tool the run does not have, naming it, and creates no job", %{
      narrowed: narrowed
    } do
      args = %{
        "name" => "Cleanup",
        "schedule" => "every 15 minutes",
        "task" => "Clear the cache folder.",
        "allowed_tools" => ["web_search", "shell"]
      }

      assert {:ok, refused} = ScheduleJob.execute(args, narrowed)
      assert refused.success == false
      assert refused.error =~ "can't give a job tools it doesn't have itself: shell"
      refute refused.error =~ "web_search"
      assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: narrowed.memory_repo)
    end

    test "schedule_job with no allowed_tools stores the run's own list and says so", %{
      narrowed: narrowed,
      run_tools: run_tools
    } do
      for allowed <- [:absent, []] do
        args =
          %{"name" => "Digest #{inspect(allowed)}", "schedule" => "every 15 minutes"}
          |> Map.put("task", "Summarize the news.")
          |> put_allowed(allowed)

        assert {:ok, created} = ScheduleJob.execute(args, narrowed)
        assert created.success == true
        payload = Jason.decode!(created.output)
        assert payload["allowed_tools"] == Enum.sort(run_tools)
        assert payload["note"] =~ "allowed_tools was empty or left out"
        assert payload["note"] =~ "this run's own tools (schedule_job, update_job, web_search)"
        refute payload["note"] =~ "unavailable now"

        assert {:ok, job} = Repo.get_scheduled_job(payload["id"], server: narrowed.memory_repo)
        assert job.allowed_tools == Enum.sort(run_tools)
      end
    end

    # Classes that still admit the job tools (`:read_write`) but not `:exec`:
    # a skill whose SKILL.md sets such a `policy:` and no `allowed_tools`.
    test "a run narrowed by policy classes alone gives a job only the tools they admit", %{
      open: open,
      registry: registry
    } do
      by_policy = loop_context(open, registry, policy: [:read_only, :read_write, :network])

      job = %{"name" => "Policy", "schedule" => "every 15 minutes", "task" => "Report."}

      assert {:ok, refused} =
               ScheduleJob.execute(Map.put(job, "allowed_tools", ["shell"]), by_policy)

      assert refused.success == false
      assert refused.error =~ "can't give a job tools it doesn't have itself: shell"
      assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: open.memory_repo)

      assert {:ok, created} = ScheduleJob.execute(job, by_policy)
      assert created.success == true

      assert Jason.decode!(created.output)["allowed_tools"] ==
               ["schedule_job", "update_job", "web_search"]
    end

    # An empty list on a job means every tool, so a run with none of its own
    # has nothing it may give.
    test "schedule_job from a run with no tools at all is refused", %{narrowed: narrowed} do
      no_tools = Map.put(narrowed, :effective_allowed_tools, [])

      assert {:ok, refused} =
               ScheduleJob.execute(
                 %{"name" => "Empty", "schedule" => "every 15 minutes", "task" => "Report."},
                 no_tools
               )

      assert refused.success == false
      assert refused.error =~ "has no tools"
      assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: narrowed.memory_repo)
    end

    test "schedule_job keeps a subset of the run's tools exactly as asked", %{narrowed: narrowed} do
      assert {:ok, created} =
               ScheduleJob.execute(
                 %{
                   "name" => "Search",
                   "schedule" => "every 15 minutes",
                   "task" => "Search for news.",
                   "allowed_tools" => ["web_search"]
                 },
                 narrowed
               )

      assert created.success == true
      payload = Jason.decode!(created.output)
      assert payload["allowed_tools"] == ["web_search"]
      refute Map.has_key?(payload, "note")
    end

    # The owner's turn runs on a cached profile, as `TurnRunner` hands it to
    # the loop. A tool registered after the profile was built (a sandbox
    # profile change, an MCP server connecting) is missing from it, and an ACP
    # session with no posting identity drops the harness tools: neither is an
    # authorization limit, so neither narrows the turn. An operator job with no
    # list runs on the registry's own surface.
    test "the owner's turn and an un-narrowed run schedule and change jobs as before", %{
      open: open,
      registry: registry
    } do
      register_stand_in(registry, "codex_run", :exec, stand_in_executor(), :harness)
      profile = RuntimeContext.build_profile(:operator, [], registry)

      harness_free =
        RuntimeContext.build_profile(:operator, [], registry, excluded_categories: [:harness])

      register_stand_in(registry, "late_tool", :read_only)

      owner_turns =
        for built <- [profile, harness_free] do
          loop_context(open, registry,
            capabilities: built.capabilities,
            dispatchable_capabilities: built.dispatchable
          )
        end

      every_tool_job = seed_job_with_tools(open, "Every Tool Job", [])

      for context <- owner_turns ++ [loop_context(open, registry, []), open],
          {allowed, stored} <- [{["shell"], ["shell"]}, {:absent, []}] do
        args =
          %{"name" => "Open #{System.unique_integer([:positive])}", "task" => "Report."}
          |> Map.put("schedule", "every 15 minutes")
          |> put_allowed(allowed)

        assert {:ok, created} = ScheduleJob.execute(args, context)
        assert created.success == true
        payload = Jason.decode!(created.output)
        assert payload["allowed_tools"] == stored
        refute Map.has_key?(payload, "note")

        assert {:ok, %{success: true}} =
                 UpdateJob.execute(%{"job_id" => every_tool_job, "task" => "Report."}, context)
      end
    end

    test "update_job refuses a job with tools the run does not have and leaves it unchanged", %{
      open: open,
      narrowed: narrowed
    } do
      shell_job = seed_job_with_tools(open, "Shell Job", ["shell"])
      every_tool_job = seed_job_with_tools(open, "Every Tool Job", [])

      assert {:ok, refused} =
               UpdateJob.execute(%{"job_id" => shell_job, "task" => "Delete it all."}, narrowed)

      assert refused.success == false
      assert refused.error =~ "can't change a job with tools it doesn't have itself: shell"

      assert {:ok, refused} =
               UpdateJob.execute(
                 %{"job_id" => every_tool_job, "task" => "Delete it all."},
                 narrowed
               )

      assert refused.success == false
      assert refused.error =~ "no tool list bounds: the job names no tools."

      for job_id <- [shell_job, every_tool_job] do
        assert {:ok, job} = Repo.get_scheduled_job(job_id, server: open.memory_repo)
        assert job.task_prompt == "Report."
      end
    end

    # A job with no list of its own runs inside its skill's (`Jobs.Runner`), and
    # after a rebind inside the new skill's.
    test "update_job reads a job's tools through its skill, the rebound one included", %{
      open: open,
      narrowed: narrowed
    } do
      searcher_job = seed_job_with_tools(open, "Searcher Job", [], "searcher")
      cleaner_job = seed_job_with_tools(open, "Cleaner Job", [], "cleaner")

      assert {:ok, %{success: true}} =
               UpdateJob.execute(%{"job_id" => searcher_job, "task" => "Search."}, narrowed)

      for args <- [
            %{"job_id" => cleaner_job, "task" => "Delete it all."},
            %{"job_id" => searcher_job, "skill_name" => "cleaner"}
          ] do
        assert {:ok, refused} = UpdateJob.execute(args, narrowed)
        assert refused.success == false
        assert refused.error =~ "can't change a job with tools it doesn't have itself: shell"
      end

      assert {:ok, job} = Repo.get_scheduled_job(searcher_job, server: open.memory_repo)
      assert job.skill_name == "searcher"
    end

    # The gate runs after the scoping, on the list the job will hold: a run
    # with `schedule_job` hands a job a way to every host command, so a tainted
    # Linux turn is held, while a run with only `web_search` is not, though the
    # gate refuses the `[]` it was asked for.
    test "the access gate still judges the inherited list", %{open: open, registry: registry} do
      tainted_linux = %{
        os_sandbox: [os: {:unix, :linux}],
        outside_sources: MapSet.new([{:tool, "web_fetch"}])
      }

      job = %{"name" => "Inherited", "schedule" => "every 15 minutes", "task" => "Report."}

      held =
        open
        |> loop_context(registry, allowed_tools: ["web_search", "schedule_job"])
        |> Map.merge(tainted_linux)

      assert {:ok, refused} = ScheduleJob.execute(job, held)
      assert refused.success == false
      assert refused.error =~ "Name the tools the job needs"
      assert {:ok, []} = Repo.list_scheduled_jobs(%{}, server: open.memory_repo)

      searcher =
        open
        |> loop_context(registry, allowed_tools: ["web_search"])
        |> Map.merge(tainted_linux)

      assert {:ok, created} = ScheduleJob.execute(job, searcher)
      assert created.success == true
      assert Jason.decode!(created.output)["allowed_tools"] == ["web_search"]
    end

    test "update_job changes a job within the run's tools, and an un-narrowed run any job", %{
      open: open,
      narrowed: narrowed,
      registry: registry
    } do
      search_job = seed_job_with_tools(open, "Search Job", ["web_search"])
      shell_job = seed_job_with_tools(open, "Shell Job", ["shell"])

      assert {:ok, %{success: true}} =
               UpdateJob.execute(%{"job_id" => search_job, "task" => "Search more."}, narrowed)

      for context <- [open, loop_context(open, registry, [])] do
        assert {:ok, %{success: true}} =
                 UpdateJob.execute(%{"job_id" => shell_job, "task" => "Tidy up."}, context)
      end
    end

    # A name no capability carries right now (a disabled plugin's) is one the
    # run lacks too, so it cannot be inherited; but a run granted it may still
    # change a job holding it, since the change keeps or narrows that list.
    test "a granted name that is not registered now is kept on update, and named when dropped",
         %{open: open, registry: registry} do
      {:ok, job} =
        JobsRegistry.create_job(
          %{
            name: "Plugin Job",
            schedule: "every 15 minutes",
            task_prompt: "Report.",
            allowed_tools: ["web_search", "gone_tool"],
            created_by_trust: "operator"
          },
          repo: open.memory_repo
        )

      granted =
        loop_context(open, registry,
          allowed_tools: ["web_search", "schedule_job", "update_job", "gone_tool"]
        )

      assert {:ok, %{success: true}} =
               UpdateJob.execute(%{"job_id" => job.id, "task" => "Report again."}, granted)

      not_granted = loop_context(open, registry, allowed_tools: ["web_search", "update_job"])

      assert {:ok, refused} =
               UpdateJob.execute(%{"job_id" => job.id, "task" => "Report later."}, not_granted)

      assert refused.success == false
      assert refused.error =~ "doesn't have itself: gone_tool"

      assert {:ok, created} =
               ScheduleJob.execute(
                 %{"name" => "Heir", "schedule" => "every 15 minutes", "task" => "Report."},
                 granted
               )

      payload = Jason.decode!(created.output)
      assert payload["allowed_tools"] == ["schedule_job", "update_job", "web_search"]
      assert payload["note"] =~ "Granted to this run but unavailable now, so left out: gone_tool"
    end

    test "update_job on a job whose skill is gone says the skill is gone", %{
      open: open,
      narrowed: narrowed
    } do
      job_id = seed_job_with_tools(open, "Orphan Job", [], "searcher")
      {:ok, empty_skills} = SkillRegistryStub.start_link([])

      assert {:ok, refused} =
               UpdateJob.execute(
                 %{"job_id" => job_id, "task" => "Search."},
                 Map.put(narrowed, :skill_registry, empty_skills)
               )

      assert refused.success == false
      assert refused.error =~ "the job names no tools, and its skill searcher is gone"
    end

    # The real path: the loop stamps its own allowlist on the context every
    # tool sees, so a job's run, a skill's worker and a sub-agent's worker are
    # each held to the tools their own loop was given.
    test "the agent loop holds schedule_job to the loop's own allowlist", %{
      open: open,
      registry: registry
    } do
      Process.put(:script, [
        scripted_turn([
          scheduled_call("call_1", %{"allowed_tools" => ["shell"]}),
          scheduled_call("call_2", %{})
        ]),
        scripted_turn([])
      ])

      assert {:ok, _result} =
               AgentLoop.run(
                 messages: [%{role: "user", content: "Set up the cleanup job."}],
                 adapter: ScriptedModel,
                 adapter_opts: [model: "mock"],
                 capability_registry: registry,
                 trust: :operator,
                 allowed_tools: ["web_search", "schedule_job"],
                 context: open
               )

      results = Map.new(Process.get(:tool_results), &{&1.call_id, &1.output})
      assert results["call_1"] =~ "can't give a job tools it doesn't have itself: shell"
      assert results["call_2"] =~ "this run's own tools"

      assert {:ok, [job]} = Repo.list_scheduled_jobs(%{}, server: open.memory_repo)
      assert job.allowed_tools == ["schedule_job", "web_search"]
    end
  end

  def never_run(_args, _context), do: raise("the access-sensitive stub must never run")

  def stand_in_never_runs(_args, _context), do: raise("a stand-in tool must never run")

  defp stand_in_executor, do: {__MODULE__, :stand_in_never_runs, []}

  # The web_search stand-in reports the context the loop handed it.
  def report_context(_args, context, test_pid) do
    send(test_pid, {:tool_context, context})
    {:ok, %{success: true, output: "no results", error: nil}}
  end

  defp register_stand_in(
         registry,
         name,
         policy_class,
         executor \\ stand_in_executor(),
         category \\ nil
       ) do
    capability =
      Capability.new(%{
        name: name,
        description: "Stands in for #{name}.",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: executor,
        policy_class: policy_class,
        metadata: if(category, do: %{category: category}, else: %{})
      })

    :ok = CapabilityRegistry.register(registry, capability)
  end

  # The context a tool sees inside an operator agent loop run with `loop_opts`:
  # the scripted model calls web_search once, whose stand-in reports it.
  defp loop_context(base, registry, loop_opts) do
    call = %{id: "fc_probe", call_id: "probe", name: "web_search", arguments: "{}"}
    Process.put(:script, [scripted_turn([call]), scripted_turn([])])

    assert {:ok, _result} =
             [
               messages: [%{role: "user", content: "Look something up."}],
               adapter: ScriptedModel,
               adapter_opts: [model: "mock"],
               capability_registry: registry,
               trust: :operator,
               context: base
             ]
             |> Keyword.merge(loop_opts)
             |> AgentLoop.run()

    assert_receive {:tool_context, context}
    Process.delete(:tool_results)
    context
  end

  defp skill_definition(name, attrs, trust) do
    {:ok, definition} =
      %{"name" => name, "description" => "Use #{name}.", "system_prompt" => "Be #{name}."}
      |> Map.merge(attrs)
      |> AgentDefinition.new()

    AgentDefinition.with_trust(definition, trust)
  end

  defp put_allowed(args, :absent), do: args
  defp put_allowed(args, allowed), do: Map.put(args, "allowed_tools", allowed)

  defp seed_job_with_tools(context, name, allowed_tools, skill_name \\ nil) do
    args =
      %{"name" => name, "schedule" => "every 15 minutes", "task" => "Report."}
      |> Map.put("allowed_tools", allowed_tools)
      |> then(&if(skill_name, do: Map.put(&1, "skill_name", skill_name), else: &1))

    assert {:ok, created} = ScheduleJob.execute(args, context)

    assert created.success == true
    Jason.decode!(created.output)["id"]
  end

  defp scripted_turn(tool_calls) do
    %{
      content: if(tool_calls == [], do: "Done.", else: ""),
      tool_calls: tool_calls,
      provider_state: %{},
      usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
      model: "mock"
    }
  end

  defp scheduled_call(call_id, extra) do
    arguments =
      Map.merge(
        %{"name" => "Cleanup #{call_id}", "schedule" => "every 15 minutes", "task" => "Tidy."},
        extra
      )

    %{
      id: "fc_#{call_id}",
      call_id: call_id,
      name: "schedule_job",
      arguments: Jason.encode!(arguments)
    }
  end

  defp seed_job(context, name) do
    assert {:ok, created} =
             ScheduleJob.execute(
               %{"name" => name, "schedule" => "every 15 minutes", "task" => "Report."},
               context
             )

    Jason.decode!(created.output)["id"]
  end

  defp seed_run(context, job_id, run_id, status, at, extra \\ %{}) do
    {:ok, _run} =
      Repo.upsert_job_run(
        Map.merge(
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
          extra
        ),
        server: context.memory_repo
      )
  end
end
