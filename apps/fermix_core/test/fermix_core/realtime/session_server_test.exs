defmodule FermixCore.Realtime.SessionServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.OpenAIClient
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.Tools.ScheduleJob

  defmodule FakeOpenAIClient do
    def start_link(opts) do
      Agent.start_link(fn -> %{opts: opts, events: [], closed?: false} end)
    end

    def send_event(pid, event) do
      Agent.update(pid, fn state -> %{state | events: state.events ++ [event]} end)
    end

    def close(pid), do: Agent.update(pid, &%{&1 | closed?: true})
    def events(pid), do: Agent.get(pid, & &1.events)
  end

  defmodule ProgrammableOpenAIClient do
    @moduledoc """
    Test fake whose `start_link/1` consults a pre-set queue of behaviors.
    Each call dequeues one entry: `:ok` returns a fresh Agent pid;
    `{:error, reason}` returns that error tuple.
    """

    def configure(behaviors, test_pid) do
      Agent.start_link(fn -> %{behaviors: behaviors, test_pid: test_pid, attempts: 0} end,
        name: __MODULE__
      )
    end

    def reset do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _pid -> Agent.stop(__MODULE__)
      end
    catch
      :exit, _reason -> :ok
    end

    def start_link(opts) do
      action =
        Agent.get_and_update(__MODULE__, fn state ->
          [next | rest] = state.behaviors
          {next, %{state | behaviors: rest, attempts: state.attempts + 1}}
        end)

      send(Agent.get(__MODULE__, & &1.test_pid), {:start_link_called, opts})

      case action do
        :ok -> Agent.start_link(fn -> %{opts: opts, events: [], closed?: false} end)
        {:error, _reason} = err -> err
      end
    end

    def send_event(pid, event) do
      Agent.update(pid, fn state -> %{state | events: state.events ++ [event]} end)
    end

    def close(pid), do: Agent.update(pid, &%{&1 | closed?: true})
    def events(pid), do: Agent.get(pid, & &1.events)
    def attempts, do: Agent.get(__MODULE__, & &1.attempts)
  end

  defmodule FakeTool do
    def execute(%{"text" => text}, context) do
      {:ok, %{success: true, output: "#{context.agent_name}:#{text}", error: nil}}
    end
  end

  defmodule FakeRecorder do
    def record_exchange(config, device_id, user_text, assistant_text, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:record_exchange, config, device_id, user_text, assistant_text, opts}
      )

      :ok
    end
  end

  defmodule SleepyTool do
    def execute(%{"sleep_ms" => ms}, _context) when is_integer(ms) do
      Process.sleep(ms)
      {:ok, %{success: true, output: "slept #{ms}", error: nil}}
    end
  end

  defmodule RaisingTool do
    def execute(_args, _context), do: raise("tool boom")
  end

  setup do
    config = Config.normalize(enabled: true)
    capability = capability()
    task_supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: config,
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [capability],
        task_supervisor: task_supervisor,
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    %{server: pid, task_supervisor: task_supervisor}
  end

  test "call_start opens OpenAI session and sends filtered session.update", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert_receive {:realtime, %{type: "state", state: "listening"}}

    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)

    assert event.type == "session.update"
    assert event.session.instructions == "prompt"
    assert [%{name: "echo"}] = event.session.tools
  end

  test "call_start waits for provider session_updated before listening", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    refute_receive {:realtime, %{type: "state", state: "listening"}}, 50

    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert_receive {:realtime, %{type: "state", state: "listening"}}
  end

  test "call_start composes the prompt with the realtime overlay enabled" do
    test_pid = self()
    capability = capability()

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [capability],
        prompt_loader: fn opts ->
          send(test_pid, {:prompt_opts, opts})
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    assert :ok = SessionServer.call_start(server)

    assert_receive {:prompt_opts, opts}
    assert Keyword.get(opts, :realtime?) == true
    assert Keyword.get(opts, :runtime_capabilities) == [capability]
  end

  test "default voice capabilities exclude channel-specific tools" do
    file_name = "voice_file_#{System.unique_integer([:positive])}"
    channel_name = "voice_channel_#{System.unique_integer([:positive])}"

    :ok = CapabilityRegistry.register(CapabilityRegistry, capability(file_name, :file))
    :ok = CapabilityRegistry.register(CapabilityRegistry, capability(channel_name, :channel))

    on_exit(fn ->
      CapabilityRegistry.unregister(CapabilityRegistry, file_name)
      CapabilityRegistry.unregister(CapabilityRegistry, channel_name)
    end)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    assert :ok = SessionServer.call_start(server)

    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)
    tool_names = Enum.map(event.session.tools, & &1.name)

    assert file_name in tool_names
    refute channel_name in tool_names
  end

  test "default voice capabilities exclude delegation tools" do
    file_name = "voice_file_#{System.unique_integer([:positive])}"
    delegation_name = "voice_delegate_#{System.unique_integer([:positive])}"

    :ok = CapabilityRegistry.register(CapabilityRegistry, capability(file_name, :file))

    :ok =
      CapabilityRegistry.register(CapabilityRegistry, capability(delegation_name, :delegation))

    on_exit(fn ->
      CapabilityRegistry.unregister(CapabilityRegistry, file_name)
      CapabilityRegistry.unregister(CapabilityRegistry, delegation_name)
    end)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    assert :ok = SessionServer.call_start(server)

    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)
    tool_names = Enum.map(event.session.tools, & &1.name)

    # Voice gains honest :operator trust, so `subagents` would otherwise become
    # executable — but a multi-minute blocking fan-out does not fit a live voice
    # session, so the delegation category is excluded from the voice surface.
    assert file_name in tool_names
    refute delegation_name in tool_names
  end

  test "schedule_job from the voice context persists created_by_trust operator" do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-realtime-schedule-#{unique}.db")
    repo = :"realtime_schedule_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    # The voice call is the operator at the keyboard: its default tool context
    # carries `source_trust: :operator`, so a scheduled job it creates is stamped
    # with the creator's real trust rather than a minted default.
    context = Map.put(:sys.get_state(server).tool_context, :memory_repo, repo)

    assert {:ok, result} =
             ScheduleJob.execute(
               %{
                 "name" => "Voice Reminder",
                 "schedule" => "every 15 minutes",
                 "task" => "Remind me tomorrow at 9.",
                 "allowed_tools" => []
               },
               context
             )

    assert result.success == true
    job_id = Jason.decode!(result.output)["id"]

    assert {:ok, job} = Registry.get_job(job_id, repo: repo)
    assert job.created_by_trust == "operator"
  end

  test "reload_runtime sends active realtime sessions a refreshed tool list" do
    suffix = System.unique_integer([:positive])
    registry = :"realtime_reload_capabilities_#{suffix}"
    first_name = "voice_first_#{suffix}"
    second_name = "voice_second_#{suffix}"

    {:ok, _pid} =
      start_supervised({CapabilityRegistry, [name: registry]},
        id: :"realtime_reload_capabilities_#{suffix}"
      )

    :ok = CapabilityRegistry.register(registry, capability(first_name, :file))

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capability_registry: registry,
        prompt_loader: fn opts ->
          capabilities = Keyword.fetch!(opts, :runtime_capabilities)
          names = Enum.map(capabilities, & &1.name)
          {:ok, %{messages: [%{role: "system", content: Enum.join(names, ",")}], parts: []}}
        end
      )

    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)
    [initial_event] = FakeOpenAIClient.events(openai)
    assert [%{name: ^first_name}] = initial_event.session.tools

    :ok = CapabilityRegistry.register(registry, capability(second_name, :file))

    assert {:ok, %{tools: 2}} = SessionServer.reload_runtime(server)

    [_initial_event, refreshed_event] = FakeOpenAIClient.events(openai)
    refreshed_names = Enum.map(refreshed_event.session.tools, & &1.name)

    assert first_name in refreshed_names
    assert second_name in refreshed_names
    assert refreshed_event.session.instructions =~ second_name
  end

  test "default runtime path renders skills through RuntimeContext" do
    fixture = runtime_session_fixture(["voice_skill"])

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capability_registry: fixture.capability_registry,
        skill_registry: fixture.skill_registry
      )

    assert :ok = SessionServer.call_start(server)

    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)
    tool_names = Enum.map(event.session.tools, & &1.name)

    assert event.session.instructions =~ ~s(<skill name="voice_skill")
    assert "skill_view" in tool_names
    assert "skill_run" in tool_names
    refute "voice_skill" in tool_names
  end

  test "skill reload does not mutate an active realtime session snapshot" do
    fixture = runtime_session_fixture(["voice_skill"])

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capability_registry: fixture.capability_registry,
        skill_registry: fixture.skill_registry
      )

    assert :ok = SessionServer.call_start(server)
    write_skill(fixture.skills_dir, "late_skill")

    assert {:ok, summary} = SkillRegistry.reload(fixture.skill_registry)
    assert "late_skill" in summary.added

    state = :sys.get_state(server)
    names = Enum.map(state.available_skills, & &1.name)

    assert names == ["voice_skill"]
    assert state.session_update_event.session.instructions =~ "voice_skill"
    refute state.session_update_event.session.instructions =~ "late_skill"
  end

  test "the voice tool context is tagged as an attended computer-use origin (:voice)" do
    fixture = runtime_session_fixture([])

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capability_registry: fixture.capability_registry,
        skill_registry: fixture.skill_registry
      )

    # This is the handoff that lets computer-use start a host session from voice,
    # mirroring TurnRunner's `:interactive` tag for the text path.
    assert :sys.get_state(server).tool_context.computer_use_origin == :voice
  end

  test "audio_chunk forwards provider append event and tracks usage", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.audio_chunk(server, "1234")

    openai = SessionServer.openai_pid(server)
    [_session_update, append] = FakeOpenAIClient.events(openai)

    assert append == OpenAIClient.audio_append_event("1234")
    assert SessionServer.usage(server).estimated.input_audio_ms > 0
    assert_receive {:realtime, %{type: "usage", status: "estimated"}}
  end

  test "audio_chunk keeps streaming while the assistant is responding", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.audio_chunk(server, "1234")

    openai = SessionServer.openai_pid(server)
    before_response_count = length(FakeOpenAIClient.events(openai))

    assert :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
    assert :ok = SessionServer.handle_provider_event(server, {:audio_delta, "item-1", "abc"})
    assert :ok = SessionServer.audio_chunk(server, "during-speaking")

    assert :ok =
             SessionServer.handle_provider_event(server, {:response_done, %{"usage" => %{}}})

    assert :ok = SessionServer.audio_chunk(server, "after-response")

    # audio_chunk is now a cast; a follow-up call is a barrier that guarantees
    # the cast has been processed before we read the fake client's events.
    _ = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)
    assert length(events) == before_response_count + 2

    assert OpenAIClient.audio_append_event("during-speaking") in events
    assert OpenAIClient.audio_append_event("after-response") in events
    assert_receive {:realtime, %{type: "state", state: "listening"}}
  end

  test "provider speech start keeps playback alive and keeps call live", %{
    server: server
  } do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:audio_delta, "item-7", "audio"})

    assert :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_started, %{}})
    assert :ok = SessionServer.audio_chunk(server, "barge-in")

    openai = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)

    assert OpenAIClient.audio_append_event("barge-in") in events
    refute_receive {:realtime, %{type: "playback_stop"}}, 50
  end

  test "active-response race from provider is nonfatal", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert_receive {:realtime, %{type: "state", state: "listening"}}

    openai = SessionServer.openai_pid(server)

    error = %{
      "code" => "conversation_already_has_active_response",
      "message" => "Conversation already has an active response in progress"
    }

    assert :ok = SessionServer.handle_provider_event(server, {:error, error})

    refute_receive {:realtime, %{type: "error"}}, 50
    assert SessionServer.openai_pid(server) == openai
    assert :ok = SessionServer.audio_chunk(server, "still-live")
  end

  test "cancelled provider response stops queued playback but keeps call live", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert_receive {:realtime, %{type: "state", state: "listening"}}

    assert :ok = SessionServer.handle_provider_event(server, {:audio_delta, "item-7", "audio"})
    assert_receive {:realtime, %{type: "state", state: "speaking"}}
    assert_receive {:realtime, %{type: "audio_delta", audio: "audio"}}

    assert :ok =
             SessionServer.handle_provider_event(
               server,
               {:response_done, %{"status" => "cancelled"}}
             )

    assert_receive {:realtime, %{type: "playback_stop"}}
    assert_receive {:realtime, %{type: "state", state: "listening"}}
    assert is_pid(SessionServer.openai_pid(server))
  end

  test "call_stop closes the provider session and rejects later audio", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)

    assert :ok = SessionServer.call_stop(server)

    assert Agent.get(openai, & &1.closed?)
    assert SessionServer.openai_pid(server) == nil
    # audio_chunk is fire-and-forget now: after the session drops it is silently
    # discarded (logged, not acked with an error). The barrier call confirms the
    # cast did not revive the session.
    assert :ok = SessionServer.audio_chunk(server, "after-stop")
    assert SessionServer.openai_pid(server) == nil
    assert_receive {:realtime, %{type: "state", state: "idle"}}
  end

  test "audio streaming has no local monotonic buffer cap during a live call" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(pid)

    for idx <- 1..25 do
      assert :ok = SessionServer.audio_chunk(pid, "chunk-#{idx}")
    end
  end

  test "call stays live across local idle periods" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(pid)
    openai = SessionServer.openai_pid(pid)

    refute_receive {:realtime, %{type: "error", reason: "idle_timeout"}}, 50
    refute Agent.get(openai, & &1.closed?)
  end

  test "interrupt sends response.cancel before more audio" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(pid)
    assert :ok = SessionServer.interrupt(pid)

    openai = SessionServer.openai_pid(pid)
    assert Enum.member?(FakeOpenAIClient.events(openai), OpenAIClient.cancel_response_event())
  end

  test "interrupt with audio_end_ms sends conversation.item.truncate before response.cancel" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(pid)
    # Simulate an assistant audio_delta so SessionServer learns the item_id.
    assert :ok = SessionServer.handle_provider_event(pid, {:audio_delta, "item-7", "audio-bytes"})

    assert :ok = SessionServer.interrupt(pid, 1_750)

    openai = SessionServer.openai_pid(pid)
    events = FakeOpenAIClient.events(openai)

    truncate = OpenAIClient.truncate_item_event("item-7", 1_750)
    cancel = OpenAIClient.cancel_response_event()

    truncate_index = Enum.find_index(events, &(&1 == truncate))
    cancel_index = Enum.find_index(events, &(&1 == cancel))

    assert is_integer(truncate_index), "expected truncate event in #{inspect(events)}"
    assert is_integer(cancel_index), "expected cancel event in #{inspect(events)}"
    assert truncate_index < cancel_index
  end

  test "interrupt with audio_end_ms but no known item_id only sends cancel" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(pid)
    assert :ok = SessionServer.interrupt(pid, 500)

    openai = SessionServer.openai_pid(pid)
    events = FakeOpenAIClient.events(openai)

    refute Enum.any?(events, &match?(%{type: "conversation.item.truncate"}, &1))
    assert Enum.member?(events, OpenAIClient.cancel_response_event())
  end

  test "provider audio and transcript deltas are forwarded to companion", %{server: server} do
    assert :ok = SessionServer.handle_provider_event(server, {:audio_delta, "item-1", "abc"})

    assert :ok =
             SessionServer.handle_provider_event(server, {:assistant_transcript_delta, "hello"})

    assert_receive {:realtime, %{type: "audio_delta", audio: "abc"}}
    assert_receive {:realtime, %{type: "assistant_text_delta", text: "hello"}}
  end

  test "provider function calls execute through ToolBridge and resume response", %{server: server} do
    assert :ok = SessionServer.call_start(server)

    assert :ok =
             SessionServer.handle_provider_event(server, {
               :function_call,
               %{"call_id" => "call-1", "name" => "echo", "arguments" => ~s({"text":"hi"})}
             })

    # The tool now runs off the loop; wait for completion before reading events.
    assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}

    openai = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)

    assert Enum.any?(events, &(&1.type == "conversation.item.create"))
    assert Enum.any?(events, &(&1.type == "response.create"))
  end

  test "provider function call errors are sent back as function output", %{server: server} do
    assert :ok = SessionServer.call_start(server)

    assert :ok =
             SessionServer.handle_provider_event(server, {
               :function_call,
               %{"call_id" => "call-err", "name" => "missing_tool", "arguments" => "{}"}
             })

    assert_receive {:realtime, %{type: "tool_event", status: "error", name: "missing_tool"}}

    openai = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)

    assert Enum.any?(events, fn
             %{
               type: "conversation.item.create",
               item: %{type: "function_call_output", call_id: "call-err", output: output}
             } ->
               assert %{"error" => error} = Jason.decode!(output)
               error =~ "unknown_tool"

             _other ->
               false
           end)

    assert Enum.any?(events, &(&1.type == "response.create"))
  end

  test "a slow tool runs off the session loop so audio and interrupt are never blocked" do
    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :sleepy_task_sup)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [sleepy_capability()],
        task_supervisor: task_supervisor,
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(server)

    # Deliver the function call via the production provider path (an async
    # handle_info, exactly how OpenAIClient forwards events), NOT the synchronous
    # `handle_provider_event` GenServer.call. Under the old inline design that
    # call absorbed the full 2s tool sleep before returning, so the interrupt
    # timer below started AFTER the tool was already done and could never trip.
    # The async send lets a still-running tool block the mailbox if it is inline.
    send(
      server,
      {:openai_realtime_event,
       {:function_call,
        %{
          "call_id" => "call-slow",
          "name" => "sleepy",
          "arguments" => ~s({"sleep_ms":2000})
        }}}
    )

    assert_receive {:realtime, %{type: "tool_event", status: "running", name: "sleepy"}}

    # While the tool sleeps, an audio cast is absorbed and an interrupt call
    # round-trips promptly. Under the old inline design the tool blocked the
    # session mailbox for its full ~2s, so BOTH of these would have queued behind
    # it — time the whole window so any inline execution trips the bound.
    started = System.monotonic_time(:millisecond)
    assert :ok = SessionServer.audio_chunk(server, "mid-tool-audio")
    assert :ok = SessionServer.interrupt(server)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000, "audio+interrupt were blocked #{elapsed}ms behind the running tool"

    # When the tool finishes, its function output reaches OpenAI and the
    # companion sees completion.
    assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "sleepy"}}, 5_000

    openai = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)

    assert Enum.any?(events, fn
             %{
               type: "conversation.item.create",
               item: %{type: "function_call_output", call_id: "call-slow"}
             } ->
               true

             _other ->
               false
           end)

    assert Enum.any?(events, &(&1.type == "response.create"))
  end

  @tag capture_log: true
  test "a tool task that raises still answers OpenAI with an error function output" do
    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :boomer_task_sup)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [raising_capability()],
        task_supervisor: task_supervisor,
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(server)

    assert :ok =
             SessionServer.handle_provider_event(server, {
               :function_call,
               %{"call_id" => "call-boom", "name" => "boomer", "arguments" => "{}"}
             })

    # The raising tool crashes its task; the :DOWN path must still answer OpenAI
    # so the turn is not left hanging.
    assert_receive {:realtime, %{type: "tool_event", status: "error", name: "boomer"}}, 5_000

    openai = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)

    assert Enum.any?(events, fn
             %{
               type: "conversation.item.create",
               item: %{type: "function_call_output", call_id: "call-boom", output: output}
             } ->
               match?(%{"error" => _reason}, Jason.decode!(output))

             _other ->
               false
           end)

    assert Enum.any?(events, &(&1.type == "response.create"))
  end

  test "response completion records final transcripts when transcript persistence is enabled" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true, persist_transcripts: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        device_id: "device-1",
        recorder_module: FakeRecorder,
        recorder_opts: [test_pid: self()],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.handle_provider_event(pid, {:user_transcript_done, "hello"})
    assert :ok = SessionServer.handle_provider_event(pid, {:assistant_transcript_done, "hi"})
    assert :ok = SessionServer.handle_provider_event(pid, {:response_done, %{}})

    assert_receive {:record_exchange, config, "device-1", "hello", "hi", opts}
    assert config.persist_transcripts?
    assert Keyword.get(opts, :test_pid) == self()
  end

  describe "reconnect" do
    setup do
      ProgrammableOpenAIClient.configure([:ok, :ok, :ok, :ok], self())
      on_exit(&ProgrammableOpenAIClient.reset/0)
      :ok
    end

    test "disconnect notifies reconnecting and reopens session on next attempt" do
      {:ok, server} =
        SessionServer.start_link(
          companion: self(),
          config: Config.normalize(enabled: true),
          openai_client: ProgrammableOpenAIClient,
          api_key: "sk-test",
          safety_identifier: "safe-id",
          capabilities: [],
          reconnect_backoff_ms: [10, 10, 10],
          prompt_loader: fn _opts ->
            {:ok, %{messages: [%{role: "system", content: "p"}], parts: [], accounting: []}}
          end
        )

      assert :ok = SessionServer.call_start(server)
      assert_receive {:start_link_called, _opts}, 200
      assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      original = SessionServer.openai_pid(server)
      send(server, {:openai_realtime_disconnect, :network})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 100
      assert_receive {:start_link_called, _opts}, 500
      assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}, 500

      reconnected = SessionServer.openai_pid(server)
      assert is_pid(reconnected)
      assert reconnected != original

      [event] = ProgrammableOpenAIClient.events(reconnected)
      assert event.type == "session.update"

      GenServer.stop(server)
    end

    test "exhausting reconnect attempts surfaces error and drops session" do
      ProgrammableOpenAIClient.reset()
      ProgrammableOpenAIClient.configure([:ok, {:error, :nxdomain}, {:error, :nxdomain}], self())

      {:ok, server} =
        SessionServer.start_link(
          companion: self(),
          config: Config.normalize(enabled: true),
          openai_client: ProgrammableOpenAIClient,
          api_key: "sk-test",
          safety_identifier: "safe-id",
          capabilities: [],
          reconnect_backoff_ms: [10, 10],
          prompt_loader: fn _opts ->
            {:ok, %{messages: [%{role: "system", content: "p"}], parts: [], accounting: []}}
          end
        )

      assert :ok = SessionServer.call_start(server)
      send(server, {:openai_realtime_disconnect, :network})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 100
      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 500
      assert_receive {:realtime, %{type: "error", reason: "reconnect_failed"}}, 500

      assert ProgrammableOpenAIClient.attempts() == 3
      assert SessionServer.openai_pid(server) == nil

      GenServer.stop(server)
    end

    test "call_stop during reconnect cancels timer and drops session" do
      {:ok, server} =
        SessionServer.start_link(
          companion: self(),
          config: Config.normalize(enabled: true),
          openai_client: ProgrammableOpenAIClient,
          api_key: "sk-test",
          safety_identifier: "safe-id",
          capabilities: [],
          # 1 second backoff so we have time to call call_stop before it fires
          reconnect_backoff_ms: [1_000, 1_000, 1_000],
          prompt_loader: fn _opts ->
            {:ok, %{messages: [%{role: "system", content: "p"}], parts: [], accounting: []}}
          end
        )

      assert :ok = SessionServer.call_start(server)
      assert_receive {:start_link_called, _opts}, 200
      send(server, {:openai_realtime_disconnect, :network})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 100

      assert :ok = SessionServer.call_stop(server)
      assert_receive {:realtime, %{type: "state", state: "idle"}}

      refute_receive {:start_link_called, _opts}, 200
      assert SessionServer.openai_pid(server) == nil

      GenServer.stop(server)
    end
  end

  test "response_done with token usage updates reported cost and notifies companion" do
    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        device_id: "device-1",
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    response = %{
      "usage" => %{
        "output_token_details" => %{"audio_tokens" => 1_000}
      }
    }

    assert :ok = SessionServer.handle_provider_event(pid, {:response_done, response})

    assert_receive {:realtime, %{type: "usage", status: "reported", cost_cents: cost}}
    # 1_000 audio output tokens * $64/M = $0.064 = 6.4 cents
    assert_in_delta cost, 6.4, 0.001

    usage = SessionServer.usage(pid)
    assert_in_delta usage.reported.cost_cents, 6.4, 0.001
  end

  defp capability do
    Capability.new(%{
      name: "echo",
      description: "Echo text.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {FakeTool, :execute, []},
      policy_class: :read_only
    })
  end

  defp capability(name, category) do
    Capability.new(%{
      name: name,
      description: "Test tool.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {FakeTool, :execute, []},
      policy_class: :read_only,
      metadata: %{category: category}
    })
  end

  defp sleepy_capability do
    Capability.new(%{
      name: "sleepy",
      description: "Sleeps, then returns.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {SleepyTool, :execute, []},
      policy_class: :read_only
    })
  end

  defp raising_capability do
    Capability.new(%{
      name: "boomer",
      description: "Raises.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {RaisingTool, :execute, []},
      policy_class: :read_only
    })
  end

  defp runtime_session_fixture(skill_names) when is_list(skill_names) do
    suffix = System.unique_integer([:positive, :monotonic])
    skills_dir = Path.join(System.tmp_dir!(), "fermix-realtime-skills-#{suffix}")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-realtime-prompt-#{suffix}")
    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-realtime-bootstrap-#{suffix}")
    capability_registry = :"realtime_capability_registry_#{suffix}"
    skill_registry = :"realtime_skill_registry_#{suffix}"
    previous_memory = Application.get_env(:fermix_core, :memory, [])
    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])

    File.mkdir_p!(skills_dir)
    File.mkdir_p!(prompt_dir)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory, prompt_base_dir: prompt_dir, agent_id: "realtime")
    )

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: bootstrap_dir,
      accounting_enabled: true
    )

    {:ok, _} = start_supervised({CapabilityRegistry, [name: capability_registry]})
    seed_skill_lifecycle_tools(capability_registry)
    Enum.each(skill_names, &write_skill(skills_dir, &1))

    {:ok, _} =
      start_supervised(
        {SkillRegistry,
         name: skill_registry,
         skills_dir: skills_dir,
         core_dir: nil,
         seed_defaults: false,
         capability_registry: capability_registry}
      )

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_memory)
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      FermixTestSupport.SafeRm.rm_rf!(skills_dir)
      FermixTestSupport.SafeRm.rm_rf!(prompt_dir)
      FermixTestSupport.SafeRm.rm_rf!(bootstrap_dir)
    end)

    %{
      capability_registry: capability_registry,
      skill_registry: skill_registry,
      skills_dir: skills_dir
    }
  end

  defp seed_skill_lifecycle_tools(registry) do
    [FermixCore.Tools.SkillView, FermixCore.Tools.SkillRun]
    |> Enum.each(fn tool_module ->
      :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(tool_module))
    end)
  end

  defp write_skill(skills_dir, name) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: Use #{name} in realtime tests.
      allowed_tools: []
      ---
      Realtime skill body.
      """
    )
  end
end
