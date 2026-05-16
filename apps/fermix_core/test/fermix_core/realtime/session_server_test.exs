defmodule FermixCore.Realtime.SessionServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.OpenAIClient
  alias FermixCore.Realtime.SessionServer

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

  setup do
    config = Config.normalize(enabled: true)
    capability = capability()

    {:ok, pid} =
      SessionServer.start_link(
        companion: self(),
        config: config,
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [capability],
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    %{server: pid}
  end

  test "call_start opens OpenAI session and sends filtered session.update", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert_receive {:realtime, %{type: "state", state: "listening"}}

    openai = SessionServer.openai_pid(server)
    [event] = FakeOpenAIClient.events(openai)

    assert event.type == "session.update"
    assert event.session.instructions == "prompt"
    assert [%{name: "echo"}] = event.session.tools
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
    assert {:error, :not_connected} = SessionServer.audio_chunk(server, "after-stop")
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

    openai = SessionServer.openai_pid(server)
    events = FakeOpenAIClient.events(openai)

    assert Enum.any?(events, &(&1.type == "conversation.item.create"))
    assert Enum.any?(events, &(&1.type == "response.create"))
    assert_receive {:realtime, %{type: "tool_event", status: "completed", name: "echo"}}
  end

  test "provider function call errors are sent back as function output", %{server: server} do
    assert :ok = SessionServer.call_start(server)

    assert :ok =
             SessionServer.handle_provider_event(server, {
               :function_call,
               %{"call_id" => "call-err", "name" => "missing_tool", "arguments" => "{}"}
             })

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
    assert_receive {:realtime, %{type: "tool_event", status: "error", name: "missing_tool"}}
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
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      original = SessionServer.openai_pid(server)
      send(server, {:openai_realtime_disconnect, :network})

      assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 100
      assert_receive {:start_link_called, _opts}, 500
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
end
