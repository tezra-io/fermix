defmodule FermixCore.Tools.VoiceCallContextTest do
  @moduledoc """
  M56 §4.4: `voice_call_context`, what a turn reads of the Live call in the
  chat. The call is a fake session holding the claim in a registry of this
  test's own, answering what a `LiveSessionServer` answers.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Tools.VoiceCallContext

  @started_at ~U[2026-10-03 14:05:00Z]

  defmodule ActiveBridge do
    def call_active?, do: true
  end

  defmodule IdleBridge do
    def call_active?, do: false
  end

  # A Live session's stand-in: it claims the call and answers `call_context`
  # with what the test gives it, or never, when told to stall.
  defmodule FakeSession do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      call = %{
        call_uuid: "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
        conversation: Keyword.fetch!(opts, :conversation),
        started_at: ~U[2026-10-03 14:05:00Z]
      }

      :ok = CallRegistry.claim(Keyword.fetch!(opts, :registry), call)
      {:ok, Map.new(opts)}
    end

    @impl true
    def handle_call(:call_context, _from, %{stall?: true} = state), do: {:noreply, state}
    def handle_call(:call_context, _from, state), do: {:reply, {:ok, state.context}, state}
  end

  setup do
    registry = :"voice_call_context_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CallRegistry, name: registry})
    %{registry: registry}
  end

  test "is a registered, classified, owner-only memory read" do
    assert VoiceCallContext.name() == "voice_call_context"
    assert VoiceCallContext in BuiltinSeeder.builtin_tool_modules()
    assert "voice_call_context" in Builtin.classified_names()
    assert Builtin.owner_only_declared?("voice_call_context")

    capability = Builtin.from_tool_module(VoiceCallContext)
    assert capability.owner_only? == true
    assert capability.policy_class == :read_only
    assert capability.metadata.category == :memory
  end

  test "is offered only while a call in the chat is up" do
    assert VoiceCallContext.advertise?(context(voice_bridge: ActiveBridge))
    refute VoiceCallContext.advertise?(context(voice_bridge: IdleBridge))
  end

  # The catalog is cached per profile, so it cannot follow a call that starts
  # and ends between turns: the tool is never named there, and the line a
  # typed turn is told during a call names it instead (M56 §4.4).
  test "is never named in the capability catalog" do
    name = :"voice_call_catalog_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(VoiceCallContext))
    :ok = Registry.register(name, Builtin.from_tool_module(FermixCore.Tools.MemoryRecall))

    summary = RuntimeSections.capability_summary(name)

    assert summary =~ "`memory_recall`"
    refute summary =~ "voice_call_context"
  end

  test "answers the start, the time since, the tasks and the newest speech, framed", ctx do
    speech =
      CallSpeech.new()
      |> CallSpeech.append(:user, "book the room for three")
      |> CallSpeech.append(:assistant, "On it.")

    start_session(ctx, "chat",
      context: call_context(speech, [completed_task(), running_task()], 372_000)
    )

    assert {:ok, %{success: true, output: output}} =
             VoiceCallContext.execute(%{}, context(call_registry: ctx.registry))

    assert output =~ "started at 2026-10-03 14:05 UTC"
    assert output =~ "6 min 12 s"
    assert output =~ "- dg_1 (revision 1): completed. The room is booked for 10am."
    assert output =~ "- dg_2 (revision 1): running."
    assert output =~ "possibly misheard"
    assert output =~ ~s(<untrusted_tool_result source="voice_call_context">)
    assert output =~ "user: book the room for three\nassistant: On it."
  end

  test "says so when no task was handed off and nothing was said yet", ctx do
    start_session(ctx, "chat", context: call_context(CallSpeech.new(), [], 4_000))

    assert {:ok, %{success: true, output: output}} =
             VoiceCallContext.execute(%{}, context(call_registry: ctx.registry))

    assert output =~ "No task has been handed off on this call."
    assert output =~ "Nothing has been said on the call yet."
    refute output =~ "untrusted_tool_result"
  end

  # The call's whole speech can be 32 KB; the answer carries its newest 4 KB,
  # cut from the front, since the newest speech is what a typed turn refers to.
  test "carries the newest speech, about 4 KB of it, cut from the front", ctx do
    speech =
      Enum.reduce(1..300, CallSpeech.new(), fn index, speech ->
        speaker = if rem(index, 2) == 0, do: :assistant, else: :user
        CallSpeech.append(speech, speaker, "line #{index} " <> String.duplicate("x", 90))
      end)

    start_session(ctx, "chat", context: call_context(speech, [], 1_000))

    assert {:ok, %{output: output}} =
             VoiceCallContext.execute(%{}, context(call_registry: ctx.registry))

    [_head, framed] = String.split(output, ~s(source="voice_call_context">\n), parts: 2)
    [_preamble, said] = String.split(framed, "the system prompt carry instructions.\n", parts: 2)
    said = String.replace_suffix(said, "\n</untrusted_tool_result>", "")

    assert byte_size(said) <= 4_096
    assert String.starts_with?(said, LiveText.cut_marker())
    assert String.ends_with?(said, "line 300 " <> String.duplicate("x", 90))
    refute said =~ "line 1 "
  end

  test "with no call up, it says so", ctx do
    assert {:ok, %{success: false, error: error}} =
             VoiceCallContext.execute(%{}, context(call_registry: ctx.registry))

    assert error =~ "No voice call is in progress in this chat"
  end

  # The chat does not know a private call exists (M56 §4.4).
  test "a private call is no call in the chat", ctx do
    start_session(ctx, "private", context: call_context(CallSpeech.new(), [], 1_000))

    assert {:ok, %{success: false, error: error}} =
             VoiceCallContext.execute(%{}, context(call_registry: ctx.registry))

    assert error =~ "No voice call is in progress in this chat"
  end

  # M56 §8: a session that cannot answer, a call still settling, is an error
  # result within a second, never a turn left waiting.
  test "a call that does not answer within a second is an error, not a wait", ctx do
    start_session(ctx, "chat", stall?: true, context: nil)

    {elapsed_us, result} =
      :timer.tc(fn -> VoiceCallContext.execute(%{}, context(call_registry: ctx.registry)) end)

    assert {:ok, %{success: false, error: error}} = result
    assert error =~ "did not answer"
    assert elapsed_us < 1_500_000
  end

  # Telemetry through the one tool emitter, carrying sizes and never what was
  # said: spoken content reaches no telemetry field.
  test "emits one tool event that carries no speech", ctx do
    speech = CallSpeech.append(CallSpeech.new(), :user, "my bank pin is in the drawer")
    start_session(ctx, "chat", context: call_context(speech, [completed_task()], 1_000))

    handler = "voice-call-context-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata.tool == "voice_call_context" and metadata[:session_id] == "vcc-telemetry",
          do: send(test_pid, {:tool_exec, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    VoiceCallContext.execute(
      %{},
      context(call_registry: ctx.registry, session_id: "vcc-telemetry")
    )

    assert_receive {:tool_exec, metadata}
    assert metadata.success == true
    assert metadata.tasks == 1
    assert metadata.speech_bytes > 0
    refute inspect(metadata) =~ "drawer"
    refute inspect(metadata) =~ "room is booked"
  end

  defp start_session(ctx, conversation, opts) do
    start_supervised!({FakeSession, [registry: ctx.registry, conversation: conversation] ++ opts})
  end

  defp call_context(speech, tasks, elapsed_ms) do
    %{
      call_uuid: "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      started_at: @started_at,
      elapsed_ms: elapsed_ms,
      tasks: tasks,
      speech: speech
    }
  end

  defp completed_task do
    %{
      "task_id" => "dg_1",
      "revision" => 1,
      "state" => "completed",
      "request" => "user: book the room",
      "summary" => "The room is booked for 10am."
    }
  end

  defp running_task do
    %{
      "task_id" => "dg_2",
      "revision" => 1,
      "state" => "running",
      "request" => "user: and email Sam",
      "summary" => nil
    }
  end

  defp context(overrides) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"companion", "main", :root},
        source_trust: :operator
      },
      Map.new(overrides)
    )
  end
end
