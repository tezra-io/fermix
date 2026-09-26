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
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.ComputerUse
  alias FermixCore.Tools.ScheduleJob
  alias FermixTestSupport.RealtimeSocket

  defmodule FakeOpenAIClient do
    def start_link(opts) do
      Agent.start_link(fn -> %{opts: opts, events: [], closed?: false, fail_sends?: false} end)
    end

    def send_event(pid, event) do
      Agent.get_and_update(pid, fn
        %{fail_sends?: true} = state -> {{:error, %WebSockex.ConnError{original: :closed}}, state}
        state -> {:ok, %{state | events: state.events ++ [event]}}
      end)
    end

    def close(pid), do: Agent.update(pid, &%{&1 | closed?: true})
    def events(pid), do: Agent.get(pid, & &1.events)

    # The connection is gone, but the socket process has not noticed yet: every
    # send fails the way WebSockex reports it, and the process lives on.
    def fail_sends(pid), do: Agent.update(pid, &%{&1 | fail_sends?: true})
  end

  defmodule ProgrammableOpenAIClient do
    @moduledoc """
    Test fake whose `start_link/1` consults a pre-set queue of behaviors.
    Each call dequeues one entry: `:ok` returns a fresh Agent pid;
    `:update_fails` returns one whose `session.update` send fails, as on a
    connection that died right after its handshake; `{:error, reason}` returns
    that error tuple. A started socket is announced to the test as
    `{:socket_started, pid, behavior}`, and a close as `{:socket_closed, pid}`.
    The close leaves the process alive, like a socket still in its close
    handshake: `RealtimeSocket.finish_close/2` ends it.
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

      test_pid = Agent.get(__MODULE__, & &1.test_pid)
      send(test_pid, {:start_link_called, opts})

      case action do
        behavior when behavior in [:ok, :update_fails] -> start_socket(opts, behavior, test_pid)
        {:error, _reason} = err -> err
      end
    end

    defp start_socket(opts, behavior, test_pid) do
      {:ok, pid} =
        Agent.start_link(fn ->
          %{opts: opts, events: [], closed?: false, behavior: behavior, test_pid: test_pid}
        end)

      send(test_pid, {:socket_started, pid, behavior})
      {:ok, pid}
    end

    def send_event(pid, event), do: Agent.get_and_update(pid, &record_or_refuse(&1, event))

    defp record_or_refuse(%{behavior: :update_fails} = state, %{type: "session.update"}),
      do: {{:error, %WebSockex.ConnError{original: :closed}}, state}

    defp record_or_refuse(state, event), do: {:ok, %{state | events: state.events ++ [event]}}

    def close(pid) do
      Agent.update(pid, fn state ->
        send(state.test_pid, {:socket_closed, pid})
        %{state | closed?: true}
      end)
    end

    def closed?(pid), do: Agent.get(pid, & &1.closed?)
    def events(pid), do: Agent.get(pid, & &1.events)
    def attempts, do: Agent.get(__MODULE__, & &1.attempts)
  end

  defmodule FakeTool do
    def execute(%{"text" => text}, context) do
      {:ok, %{success: true, output: "#{context.agent_name}:#{text}", error: nil}}
    end
  end

  defmodule HiddenTool do
    def advertise?(_context), do: false

    def dynamic_parameters(_context),
      do: raise("hidden tools must be filtered before schema refresh")

    def execute(_args, context) do
      {:ok, %{success: true, output: "#{context.agent_name}:hidden", error: nil}}
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

  defmodule BlockingTool do
    @moduledoc """
    Announces itself and then blocks until the test releases it. A tool that
    merely sleeps makes inline execution slow; a tool the test holds open makes
    "the session served me while a tool was running" a fact rather than a window
    the test hopes to win.
    """
    def execute(_args, _context, test_pid) do
      send(test_pid, {:blocking_tool_running, self()})

      receive do
        :release -> {:ok, %{success: true, output: "released", error: nil}}
      after
        30_000 -> raise "the test never released the blocking tool"
      end
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

  test "call_start advertises live dynamic capability parameters" do
    previous = Application.get_env(:fermix_core, :sandbox)
    Application.put_env(:fermix_core, :sandbox, %{SandboxConfig.default() | mode: :strict})

    on_exit(fn -> restore_app_env(:sandbox, previous) end)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [Builtin.from_tool_module(ComputerUse)],
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)
    [tool] = event.session.tools

    assert tool.name == "computer_use"
    assert tool.parameters["properties"]["action"]["description"] =~ "ACCESS=strict"
  end

  test "call_start hides context-gated capabilities without removing dispatchability" do
    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :hidden_tool_task_sup)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [hidden_capability()],
        task_supervisor: task_supervisor,
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)
    assert event.session.tools == []

    assert :ok =
             SessionServer.handle_provider_event(server, {
               :function_call,
               %{"call_id" => "call-hidden", "name" => "hidden", "arguments" => "{}"}
             })

    assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "hidden"}}
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

  # REALTIME.md is the ONLY place the voice rules live (speech length, pacing, and the
  # act-in-silence rule). The production path builds its own RuntimeContext with no
  # `prompt_loader`, and it omitted `realtime?: true` — so the loader dropped the file
  # and every voice call ran without those rules from 2026-05-23 until this test.
  # Deliberately uses the fixture WITHOUT a prompt_loader: the injected-loader tests
  # above carry the flag themselves and are exactly why this shipped unnoticed.
  test "the production voice prompt includes REALTIME.md" do
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

    assert :ok = SessionServer.call_start(server)

    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)

    assert event.session.instructions =~ "REALTIME.md — Live Voice Rules"
    assert event.session.instructions =~ "act in silence"

    # A reconnect/reload rebuilds the context through the same clause; it must not
    # silently drop the rules again.
    assert {:ok, _summary} = SessionServer.reload_runtime(server)
    assert :sys.get_state(server).session_update_event.session.instructions =~ "act in silence"
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
    assert :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_started, %{}})
    assert :ok = SessionServer.audio_chunk(server, "1234")

    openai = SessionServer.openai_pid(server)
    [_session_update, append] = FakeOpenAIClient.events(openai)

    assert append == OpenAIClient.audio_append_event("1234")
    assert SessionServer.usage(server).estimated.input_audio_ms > 0
    assert_receive {:realtime, %{type: "usage", status: "estimated"}}
  end

  # An open microphone streams silence continuously, and metering it as
  # conversational input inflated the estimate the cost ceiling is measured
  # against — a quiet call could be torn down for audio nobody was billed for.
  # VAD-filtered silence is not billed upstream, so the estimate must not count
  # it. The chunks still go out: the provider's own VAD needs the quiet to find
  # where speech begins.
  test "audio before the provider reports speech is sent but never estimated", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.audio_chunk(server, :binary.copy(<<0>>, 4800))

    openai = SessionServer.openai_pid(server)

    assert OpenAIClient.audio_append_event(:binary.copy(<<0>>, 4800)) in FakeOpenAIClient.events(
             openai
           )

    usage = SessionServer.usage(server)
    assert usage.estimated.input_audio_ms == 0
    assert usage.estimated.input_audio_tokens == 0
    assert usage.estimated.transcription_ms == 0
    refute_receive {:realtime, %{type: "usage", status: "estimated"}}, 50
  end

  test "audio between the provider's speech start and stop is estimated", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_started, %{}})

    # 4800 bytes of PCM16 @ 48 bytes/ms = 100 ms of speech.
    assert :ok = SessionServer.audio_chunk(server, :binary.copy(<<0>>, 4800))

    assert_receive {:realtime, %{type: "usage", status: "estimated"}}
    usage = SessionServer.usage(server)
    assert usage.estimated.input_audio_ms == 100
    assert usage.estimated.transcription_ms == 100

    assert :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_stopped, %{}})
    assert :ok = SessionServer.audio_chunk(server, :binary.copy(<<0>>, 4800))

    # the quiet after the turn adds nothing
    assert SessionServer.usage(server).estimated.input_audio_ms == 100
  end

  # Gating the estimate on speech must not disarm it: the estimate is what ends a
  # long call the provider has not reported usage for yet.
  test "the cost ceiling still fires from estimated speech audio" do
    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true, max_estimated_cost_cents_per_session: 1),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    Process.unlink(server)
    ref = Process.monitor(server)
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_started, %{}})

    # 25 s of PCM16 @ 48 bytes/ms: 250 input-audio tokens (0.8 cents) plus 25 s
    # of whisper-1 transcription (0.25 cents), past the 1-cent ceiling.
    SessionServer.audio_chunk(server, :binary.copy(<<0>>, 48 * 25_000))

    assert_receive {:realtime, %{type: "usage", status: "limit_reached"}}
    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :cost_limit}}
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

  # The barge-in gap: the Realtime API streams audio faster than realtime, so a long
  # reply is often fully delivered — and therefore uncancellable — before the operator
  # starts speaking. Nothing flushed the companion's buffer, so it talked over them to
  # the end and only afterwards answered what was said. A COMMITTED turn is the
  # provider's own decision that the conversation moved on.
  test "a committed user turn flushes stale playback", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:audio_delta, "item-9", "audio"})

    assert :ok = SessionServer.handle_provider_event(server, {:input_audio_committed, %{}})

    assert_receive {:realtime, %{type: "playback_stop"}}
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

  # A call that ends ENDS THE PROCESS. It used to return state instead, which left
  # a session alive with no provider — and because both reconnect clauses are
  # guarded on the fields that teardown nils, every later disconnect was swallowed
  # and the call streamed audio into a void until the operator gave up.
  # THE regression test for the live freeze (2026-07-25): the cost ceiling tore the
  # provider connection down and RETURNED STATE, leaving the session alive with no
  # provider. Both reconnect clauses are guarded on the fields that teardown nils,
  # so every later signal was swallowed and the call streamed audio into a void for
  # 43 seconds while the companion sat frozen. A terminal reason must END the call.
  test "a cost-limit teardown ends the process, it does not leave a live session" do
    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true, max_estimated_cost_cents_per_session: 1),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    Process.unlink(server)
    ref = Process.monitor(server)
    assert :ok = SessionServer.call_start(server)

    # One response whose reported usage blows through the 1-cent ceiling.
    :ok =
      SessionServer.handle_provider_event(
        server,
        {:response_done,
         %{
           "id" => "resp_1",
           "usage" => %{"output_token_details" => %{"audio_tokens" => 1_000_000}}
         }}
      )

    # The next audio chunk is what notices; it must end the call, not be discarded.
    SessionServer.audio_chunk(server, <<0, 0, 0, 0>>)

    assert_receive {:realtime, %{type: "usage", status: "limit_reached"}}
    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :cost_limit}}
  end

  # The invariant, not one bug: `openai_pid == nil` is legal ONLY inside the
  # bounded reconnect window. Any other route to it must end the session.
  test "audio with no provider and no reconnect pending stops the session", %{server: server} do
    Process.unlink(server)
    assert :ok = SessionServer.call_start(server)
    ref = Process.monitor(server)

    # The exact frozen shape: no socket, no timer, still being fed.
    :sys.replace_state(server, &%{&1 | openai_pid: nil, reconnect_timer: nil})
    SessionServer.audio_chunk(server, <<0, 0, 0, 0>>)

    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :provider_session_missing}}
  end

  # A failed send must not disarm the one connection owner. Before the fix it ran
  # the full teardown, so the socket's own EXIT then fell through to the silent
  # catch-all and no reconnect ever happened.
  test "a failed provider send leaves the session able to reconnect" do
    scope = "session:send-fails-#{System.unique_integer([:positive])}"
    test_pid = self()
    handler = {__MODULE__, :provider_error, scope}

    :telemetry.attach(
      handler,
      [:fermix, :realtime, :provider_error],
      fn _event, _measurements, meta, _config -> send(test_pid, {:provider_error, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        session_scope: scope,
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)

    # A send that fails while the socket process lives on.
    :ok = FakeOpenAIClient.fail_sends(openai)
    SessionServer.audio_chunk(server, <<0, 0, 0, 0>>)

    assert_receive {:provider_error, %{session_id: ^scope}}

    assert SessionServer.openai_pid(server) == openai,
           "one dropped event must not end a live call"

    # The socket then dies, and its EXIT is what reconnects.
    :ok = RealtimeSocket.finish_close(openai, {:remote, :closed})
    assert_receive {:realtime, %{type: "state", state: "reconnecting"}}
  end

  test "call_stop ends the session process and releases the socket", %{server: server} do
    Process.unlink(server)
    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)
    ref = Process.monitor(server)

    assert :ok = SessionServer.call_stop(server)

    assert_receive {:realtime, %{type: "state", state: "idle"}}
    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :call_stop}}
    refute Process.alive?(openai), "the provider socket is released with the call"
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
    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :blocking_task_sup)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [blocking_capability(self())],
        task_supervisor: task_supervisor,
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert :ok = SessionServer.call_start(server)
    openai = SessionServer.openai_pid(server)

    # Deliver the function call via the production provider path (the socket's
    # own `OpenAIClient.handle_frame/2` sending an async handle_info), NOT the
    # synchronous `handle_provider_event` GenServer.call. Under the old inline
    # design that call absorbed the whole tool execution before returning, so the
    # verbs below would have been issued AFTER the tool was already done, against
    # a session that had nothing left to be blocked by.
    :ok =
      RealtimeSocket.deliver(openai, %{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call-slow",
        "name" => "blocking",
        "arguments" => "{}"
      })

    assert_receive {:realtime, %{type: "tool_event", status: "running", name: "blocking"}}
    assert_receive {:blocking_tool_running, tool}

    # The tool is parked inside `execute/3` and only this process can let it out,
    # so both verbs below provably run WHILE a tool is running. That is the
    # contract, and it is what the stopwatch here could only approximate: an
    # inline tool would make `interrupt/1` wait on a tool that waits on this
    # test, which the call timeout turns into a loud failure instead of a
    # millisecond budget that a loaded CI box can blow on its own.
    assert :ok = SessionServer.audio_chunk(server, "mid-tool-audio")
    assert :ok = SessionServer.interrupt(server)

    appended = Base.encode64("mid-tool-audio")

    # The cast was enqueued before the call, so a returned interrupt proves the
    # session had already handled the audio — the cast was absorbed mid-tool
    # rather than merely returning, which a cast does either way.
    assert Enum.any?(FakeOpenAIClient.events(openai), fn event ->
             match?(%{type: "input_audio_buffer.append", audio: ^appended}, event)
           end)

    # Released, the tool finishes: its function output reaches OpenAI and the
    # companion sees completion.
    send(tool, :release)

    assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "blocking"}}

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
      assert_receive {:start_link_called, _opts}
      assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      original = SessionServer.openai_pid(server)
      :ok = RealtimeSocket.finish_close(original, {:remote, :closed})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}
      assert_receive {:start_link_called, _opts}
      assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}
      reconnected = SessionServer.openai_pid(server)
      assert is_pid(reconnected)
      assert reconnected != original

      [event] = ProgrammableOpenAIClient.events(reconnected)
      assert event.type == "session.update"

      GenServer.stop(server)
    end

    # `speech_active?` mirrors the OLD provider session's VAD. The reconnect
    # opens a fresh conversation with its own detection, so carrying the flag
    # across would meter the new session's silence until its first
    # `speech_stopped` — the exact defect the gate exists to prevent.
    test "a reconnect forgets the old session's speech state" do
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
      assert_receive {:start_link_called, _opts}
      assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}
      assert :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_started, %{}})

      :ok = RealtimeSocket.finish_close(SessionServer.openai_pid(server), {:remote, :closed})
      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}
      assert_receive {:start_link_called, _opts}
      assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      assert :ok = SessionServer.audio_chunk(server, :binary.copy(<<0>>, 4800))
      assert SessionServer.usage(server).estimated.input_audio_ms == 0

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

      Process.unlink(server)
      ref = Process.monitor(server)
      assert :ok = SessionServer.call_start(server)
      assert_receive {:socket_started, first, :ok}
      :ok = RealtimeSocket.finish_close(first, {:remote, :closed})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}
      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}
      # Exhausted reconnect is terminal: the session ENDS rather than lingering with
      # no provider and no timer, which is unrecoverable by construction.
      assert_receive {:realtime, %{type: "error", reason: "provider_disconnected"}}
      assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :provider_disconnected}}
      assert ProgrammableOpenAIClient.attempts() == 3
    end

    test "call_stop during reconnect cancels the timer and ends the session" do
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

      Process.unlink(server)
      ref = Process.monitor(server)
      assert :ok = SessionServer.call_start(server)
      assert_receive {:start_link_called, _opts}
      assert_receive {:socket_started, first, :ok}
      :ok = RealtimeSocket.finish_close(first, {:remote, :closed})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}

      assert :ok = SessionServer.call_stop(server)
      assert_receive {:realtime, %{type: "state", state: "idle"}}
      assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :call_stop}}
      # The pending reconnect died with the session — no attempt fires afterwards.
      refute_receive {:start_link_called, _opts}, 200
    end

    # RT-2 (tla/specs/realtime_session check 12). A socket the session closed dies
    # only after its close handshake or WebSockex's 5 s timeout, which can be after
    # the next attempt has connected. Its death is not the current socket's.
    test "a closed socket's late exit leaves the socket that replaced it alone" do
      configure_sockets([:ok, :update_fails, :ok, :ok])
      server = start_reconnecting_server([10, 10, 10])
      {_first, closed, current} = reconnect_past_a_failed_update(server)

      :ok = RealtimeSocket.deliver(current, %{"type" => "session.updated", "session" => %{}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      :sys.suspend(server)
      :ok = RealtimeSocket.finish_close(closed, {:local, :normal})
      await_queued(server, &match?({:EXIT, ^closed, _reason}, &1))
      :sys.resume(server)

      assert SessionServer.openai_pid(server) == current
      refute ProgrammableOpenAIClient.closed?(current)
      refute_received {:realtime, %{type: "state", state: "reconnecting"}}
      refute_receive {:socket_started, _pid, _behavior}, 100

      # The current socket's own death still reconnects, through its EXIT alone,
      # even when OpenAI closes it cleanly and the socket exits :normal.
      :ok = RealtimeSocket.finish_close(current, {:remote, 1000, ""})
      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}
      assert_receive {:socket_started, next, :ok}
      assert SessionServer.openai_pid(server) == next
      refute_received {:realtime, %{type: "state", state: "reconnecting"}}
    end

    # RT-2's freeze. The stale death armed a reconnect timer; the new socket's
    # session.updated, still on its way, then ran start_timers -> cancel_timers and
    # disarmed it. No socket and no timer: the next audio chunk ended the call.
    test "a closed socket's late exit cannot leave the call with no socket and no timer" do
      configure_sockets([:ok, :update_fails, :ok, :ok])
      server = start_reconnecting_server([10, 10, 10])
      Process.unlink(server)
      ref = Process.monitor(server)
      {_first, closed, current} = reconnect_past_a_failed_update(server)

      # Staged in this order: the closed socket's exit, the new socket's
      # session.updated, an audio chunk.
      :sys.suspend(server)
      :ok = RealtimeSocket.finish_close(closed, {:local, :normal})
      await_queued(server, &match?({:EXIT, ^closed, _reason}, &1))
      :ok = RealtimeSocket.deliver(current, %{"type" => "session.updated", "session" => %{}})
      await_queued(server, &provider_event?(&1, :session_updated))
      SessionServer.audio_chunk(server, <<0, 0, 0, 0>>)
      :sys.resume(server)

      refute_receive {:DOWN, ^ref, :process, ^server, _reason}, 100
      assert SessionServer.openai_pid(server) == current

      assert OpenAIClient.audio_append_event(<<0, 0, 0, 0>>) in ProgrammableOpenAIClient.events(
               current
             )

      GenServer.stop(server)
    end

    # RT-2 (check 14): what a closed socket read before its close took effect
    # belongs to a conversation the call no longer has.
    test "a closed socket's late events are dropped", %{task_supervisor: task_supervisor} do
      configure_sockets([:ok, :update_fails, :ok, :ok])

      server =
        start_reconnecting_server([10, 10, 10],
          capabilities: [capability()],
          task_supervisor: task_supervisor
        )

      {_first, closed, current} = reconnect_past_a_failed_update(server)
      call = echo_call_event("call-stale")

      :sys.suspend(server)
      :ok = RealtimeSocket.deliver(closed, call)
      await_queued(server, &provider_event?(&1, :function_call))
      :sys.resume(server)

      # Served after the staged event, so the refute below is ordered behind it.
      assert :sys.get_state(server).pending_tool_calls == %{}
      refute_received {:realtime, %{type: "tool_event"}}

      # The same call from the current socket runs, and its output goes there.
      :ok = RealtimeSocket.deliver(current, call)
      assert_receive {:realtime, %{type: "tool_event", status: "running", name: "echo"}}
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
      assert [_output] = outputs_for(ProgrammableOpenAIClient.events(current), "call-stale")
      refute_received {:realtime, %{type: "tool_event"}}
    end

    # RT-2's second route (it was check 13's witness). The closed socket's death
    # and the next attempt's tick queued together: the stale death armed a second
    # timer, the tick's success forgot it, and it later opened a socket into the
    # connected call.
    test "a closed socket's exit queued ahead of the next tick arms no second timer" do
      configure_sockets([:ok, :update_fails, :ok, :ok])
      # The second delay only has to outlast the step from the failed attempt to
      # the suspend below. The third is short, so a second timer armed by the
      # stale exit would fire inside the refute window.
      server = start_reconnecting_server([10, 1_000, 50])
      assert :ok = SessionServer.call_start(server)
      assert_receive {:socket_started, first, :ok}
      :ok = RealtimeSocket.finish_close(first, {:remote, :closed})
      assert_receive {:socket_started, closed, :update_fails}
      assert_receive {:socket_closed, ^closed}

      :sys.suspend(server)
      :ok = RealtimeSocket.finish_close(closed, {:local, :normal})
      await_queued(server, &match?({:EXIT, ^closed, _reason}, &1))
      mailbox = await_queued(server, &(&1 == :reconnect_attempt))

      assert Enum.find_index(mailbox, &match?({:EXIT, ^closed, _reason}, &1)) <
               Enum.find_index(mailbox, &(&1 == :reconnect_attempt)),
             "the route is staged only when the closed socket's exit is ahead of the tick"

      :sys.resume(server)

      assert_receive {:socket_started, current, :ok}
      refute_receive {:socket_started, _pid, _behavior}, 300
      assert SessionServer.openai_pid(server) == current
      refute ProgrammableOpenAIClient.closed?(current)
    end

    # RT-3 (check 15). The closed socket's prompt death used to run a second
    # schedule_reconnect for the same failure: two attempts for one, and with this
    # budget the call ended before its last attempt ran.
    test "a failed session.update costs one reconnect attempt" do
      configure_sockets([:ok, :update_fails, :ok])
      server = start_reconnecting_server([10, 300])
      Process.unlink(server)
      ref = Process.monitor(server)
      assert :ok = SessionServer.call_start(server)
      assert_receive {:socket_started, first, :ok}
      :ok = RealtimeSocket.finish_close(first, {:remote, :closed})
      assert_receive {:socket_started, closed, :update_fails}
      assert_receive {:socket_closed, ^closed}

      # The closed socket's death lands before the 300 ms timer its failure armed.
      :sys.suspend(server)
      :ok = RealtimeSocket.finish_close(closed, {:local, :normal})
      mailbox = await_queued(server, &match?({:EXIT, ^closed, _reason}, &1))

      assert ProgrammableOpenAIClient.attempts() == 2,
             "the failed attempt's timer was handled before the closed socket's death"

      ahead_of_exit = Enum.take_while(mailbox, &(not match?({:EXIT, ^closed, _reason}, &1)))

      refute :reconnect_attempt in ahead_of_exit,
             "the failed attempt's timer is queued ahead of the closed socket's death"

      :sys.resume(server)

      assert_receive {:socket_started, current, :ok}
      assert SessionServer.openai_pid(server) == current
      assert ProgrammableOpenAIClient.attempts() == 3
      assert_received {:realtime, %{type: "state", state: "reconnecting"}}
      assert_received {:realtime, %{type: "state", state: "reconnecting"}}
      refute_received {:realtime, %{type: "state", state: "reconnecting"}}
      refute_received {:realtime, %{type: "error"}}
      refute_received {:DOWN, ^ref, :process, ^server, _reason}

      GenServer.stop(server)
    end

    # RT-1's re-armed trigger is owed to the conversation that rejected it. A
    # reconnect opens a fresh one that never saw those outputs.
    test "a trigger re-armed by a rejection is not sent into the next conversation", %{
      task_supervisor: task_supervisor
    } do
      server =
        start_reconnecting_server([10, 10, 10],
          capabilities: [capability()],
          task_supervisor: task_supervisor
        )

      assert :ok = SessionServer.call_start(server)
      assert_receive {:socket_started, first, :ok}
      :ok = SessionServer.handle_provider_event(server, {:function_call, echo_call("c1")})
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      :ok = SessionServer.handle_provider_event(server, {:error, active_response_error()})

      :ok = RealtimeSocket.finish_close(first, {:remote, :closed})
      assert_receive {:socket_started, current, :ok}
      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})

      assert Enum.map(ProgrammableOpenAIClient.events(current), & &1.type) == ["session.update"]
    end
  end

  # RT-1 (tla/specs/realtime_session check 10). `response_active?` learns of a
  # response only from its response.created, so a trigger sent while server VAD's
  # response is already running (its response.created still on the wire) is
  # rejected, and that response may have begun before the outputs joined.
  describe "a response.create rejected by an active response" do
    test "is sent again when that response ends (the immediate send)", %{server: server} do
      assert :ok = SessionServer.call_start(server)
      openai = SessionServer.openai_pid(server)

      # No response is known to be active, so the output and its trigger go at once.
      :ok = SessionServer.handle_provider_event(server, {:function_call, echo_call("c1")})
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
      assert creates(openai) == 1

      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      :ok = SessionServer.handle_provider_event(server, {:error, active_response_error()})
      assert creates(openai) == 1, "the rejection itself sends nothing"

      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})

      events = FakeOpenAIClient.events(openai)
      assert creates(openai) == 2
      assert %{type: "response.create"} = List.last(events)
      assert [_output] = outputs_for(events, "c1")
    end

    test "is sent again when that response ends (the deferred send)", %{server: server} do
      assert :ok = SessionServer.call_start(server)
      openai = SessionServer.openai_pid(server)

      # The response that calls the tool is still running, so the trigger waits
      # for its response.done.
      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      :ok = SessionServer.handle_provider_event(server, {:function_call, echo_call("c1")})
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
      assert creates(openai) == 0

      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})
      assert creates(openai) == 1

      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      :ok = SessionServer.handle_provider_event(server, {:error, active_response_error()})
      assert creates(openai) == 1, "the rejection itself sends nothing"

      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})

      events = FakeOpenAIClient.events(openai)
      assert creates(openai) == 2
      assert %{type: "response.create"} = List.last(events)
      assert [_output] = outputs_for(events, "c1")
    end

    # The rejection can beat the rejecting response's own response.created. A
    # re-send from the error itself would only be rejected again.
    test "is not sent again before the rejecting response ends", %{server: server} do
      assert :ok = SessionServer.call_start(server)
      openai = SessionServer.openai_pid(server)

      :ok = SessionServer.handle_provider_event(server, {:function_call, echo_call("c1")})
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
      assert creates(openai) == 1

      :ok = SessionServer.handle_provider_event(server, {:error, active_response_error()})
      assert creates(openai) == 1, "the rejection itself sends nothing"

      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      assert creates(openai) == 1

      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})

      events = FakeOpenAIClient.events(openai)
      assert creates(openai) == 2
      assert %{type: "response.create"} = List.last(events)
      assert [_output] = outputs_for(events, "c1")
    end

    # The rejecting response may call a tool itself. One trigger, after the last
    # output, covers both that call and the re-armed one.
    test "waits for a call the rejecting response made", %{task_supervisor: task_supervisor} do
      {:ok, server} =
        SessionServer.start_link(
          companion: self(),
          config: Config.normalize(enabled: true),
          openai_client: FakeOpenAIClient,
          api_key: "sk-test",
          safety_identifier: "safe-id",
          capabilities: [capability(), blocking_capability(self())],
          task_supervisor: task_supervisor,
          prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
        )

      assert :ok = SessionServer.call_start(server)
      openai = SessionServer.openai_pid(server)

      :ok = SessionServer.handle_provider_event(server, {:function_call, echo_call("c1")})
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      :ok = SessionServer.handle_provider_event(server, {:error, active_response_error()})

      blocking = %{"call_id" => "c2", "name" => "blocking", "arguments" => "{}"}
      :ok = SessionServer.handle_provider_event(server, {:function_call, blocking})
      assert_receive {:blocking_tool_running, tool}
      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})
      assert creates(openai) == 1, "no trigger while a call is still in flight"

      send(tool, :release)
      assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "blocking"}}

      events = FakeOpenAIClient.events(openai)
      assert creates(openai) == 2
      assert %{type: "response.create"} = List.last(events)
      assert [_output] = outputs_for(events, "c2")

      # Nothing is owed any more: the next response ends without a trigger.
      :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})
      :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})
      assert creates(openai) == 2
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

  defp hidden_capability do
    Capability.new(%{
      name: "hidden",
      description: "Hidden test tool.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {HiddenTool, :execute, []},
      policy_class: :read_only
    })
  end

  defp echo_call(call_id),
    do: %{"call_id" => call_id, "name" => "echo", "arguments" => ~s({"text":"hi"})}

  # The same call as OpenAI sends it on the socket.
  defp echo_call_event(call_id),
    do: Map.put(echo_call(call_id), "type", "response.function_call_arguments.done")

  defp active_response_error do
    %{
      "type" => "invalid_request_error",
      "code" => "conversation_already_has_active_response",
      "message" => "Conversation already has an active response in progress"
    }
  end

  defp creates(openai),
    do: openai |> FakeOpenAIClient.events() |> Enum.count(&(&1.type == "response.create"))

  defp outputs_for(events, call_id),
    do:
      Enum.filter(
        events,
        &match?(%{item: %{type: "function_call_output", call_id: ^call_id}}, &1)
      )

  defp configure_sockets(behaviors) do
    ProgrammableOpenAIClient.reset()
    ProgrammableOpenAIClient.configure(behaviors, self())
  end

  defp start_reconnecting_server(backoff_ms, opts \\ []) do
    defaults = [
      companion: self(),
      config: Config.normalize(enabled: true),
      openai_client: ProgrammableOpenAIClient,
      api_key: "sk-test",
      safety_identifier: "safe-id",
      capabilities: [],
      reconnect_backoff_ms: backoff_ms,
      prompt_loader: fn _opts ->
        {:ok, %{messages: [%{role: "system", content: "p"}], parts: [], accounting: []}}
      end
    ]

    {:ok, server} = SessionServer.start_link(Keyword.merge(defaults, opts))
    server
  end

  # The first socket drops. The reconnect opens a second, whose session.update
  # fails, so the session closes it; its close handshake is still running. The
  # next attempt opens a third, which becomes openai_pid.
  defp reconnect_past_a_failed_update(server) do
    assert :ok = SessionServer.call_start(server)
    assert_receive {:socket_started, first, :ok}
    :ok = RealtimeSocket.finish_close(first, {:remote, :closed})
    assert_receive {:socket_started, closed, :update_fails}
    assert_receive {:socket_closed, ^closed}
    assert_receive {:socket_started, current, :ok}
    assert SessionServer.openai_pid(server) == current
    assert_received {:realtime, %{type: "state", state: "reconnecting"}}
    assert_received {:realtime, %{type: "state", state: "reconnecting"}}
    {first, closed, current}
  end

  # A socket event of `kind` waiting in a mailbox, whichever socket sent it.
  defp provider_event?(message, kind)
       when is_tuple(message) and elem(message, 0) == :openai_realtime_event,
       do: match?({^kind, _event}, elem(message, tuple_size(message) - 1))

  defp provider_event?(_message, _kind), do: false

  # Polls `server`'s mailbox until it holds a message `queued?` accepts, and returns
  # the mailbox. For staging an interleaving while `server` is suspended: messages
  # from different processes (sockets, timers, this test) are ordered only per
  # sender, so a staged order is waited for, never assumed.
  @mailbox_polls 200

  defp await_queued(server, queued?, polls \\ @mailbox_polls)

  defp await_queued(server, _queued?, 0),
    do: flunk("the staged message never reached #{inspect(server)}'s mailbox")

  defp await_queued(server, queued?, polls) do
    {:messages, mailbox} = Process.info(server, :messages)

    if Enum.any?(mailbox, queued?) do
      mailbox
    else
      Process.sleep(10)
      await_queued(server, queued?, polls - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_app_env(key, value), do: Application.put_env(:fermix_core, key, value)

  defp blocking_capability(test_pid) do
    Capability.new(%{
      name: "blocking",
      description: "Blocks until the test releases it.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {BlockingTool, :execute, [test_pid]},
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
