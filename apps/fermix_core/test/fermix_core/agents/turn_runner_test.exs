defmodule FermixCore.Agents.TurnRunnerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerUse.Safety
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Providers.Error, as: ProviderError

  defmodule NoopReviewer do
    def start_background(_opts), do: :ok
  end

  defmodule MainAgentStub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_call({:invalidate_runtime_context, reason}, _from, state) do
      send(state.test_pid, {:runtime_invalidated, reason})
      {:reply, :ok, state}
    end

    @impl true
    def handle_call({:record_auto_compaction_failure, key, _failed_at_ms}, _from, state) do
      send(state.test_pid, {:compaction_failure_recorded, key})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:clear_auto_compaction_failure, key}, state) do
      send(state.test_pid, {:compaction_failure_cleared, key})
      {:noreply, state}
    end

    def handle_cast({:record_context_tokens, key, tokens}, state) do
      send(state.test_pid, {:context_tokens_recorded, key, tokens})
      {:noreply, state}
    end
  end

  defmodule SummaryAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:summary_chat, messages, opts})

      {:ok,
       %{
         content: "summary from commit",
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 12, completion_tokens: 4, total_tokens: 16},
         model: Keyword.get(opts, :model, "mock-model")
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(_capabilities), do: []

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defmodule LoopingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts), do: next_turn(opts)

    @impl true
    def continue(_provider_state, _tool_results, opts), do: next_turn(opts)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp next_turn(opts) do
      step = Process.get(:looping_adapter_step, 0) + 1
      Process.put(:looping_adapter_step, step)

      terminal_step = Keyword.fetch!(opts, :terminal_step)

      if step >= terminal_step do
        turn("finished at #{step}", [], step)
      else
        tool_call = %{
          id: "call_#{step}",
          call_id: "call_#{step}",
          name: "missing_tool",
          arguments: Jason.encode!(%{"step" => step})
        }

        turn("", [tool_call], step)
      end
    end

    defp turn(content, tool_calls, step) do
      {:ok,
       %{
         content: content,
         tool_calls: tool_calls,
         provider_state: %{step: step},
         usage: %{prompt_tokens: 10, completion_tokens: 1, total_tokens: 11},
         model: "mock-model"
       }}
    end
  end

  # Hands the assembled prompt back to the test and finishes the turn, so the
  # per-turn system-note splices can be asserted on the real request path.
  defmodule CapturePromptAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:captured_prompt, messages})

      {:ok,
       %{
         content: "captured",
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 10, completion_tokens: 1, total_tokens: 11},
         model: "mock-model"
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defmodule FailingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts), do: {:error, "adapter failed"}

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defmodule PreflightAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      text = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

      if String.contains?(text, "Older messages:") do
        send(test_pid, {:preflight_summary_call, text})
        turn("preflight summary", 12)
      else
        send(test_pid, {:preflight_main_call, text})
        turn("assistant after preflight", 20)
      end
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp turn(content, prompt_tokens) do
      {:ok,
       %{
         content: content,
         tool_calls: [],
         provider_state: %{},
         usage: %{
           prompt_tokens: prompt_tokens,
           completion_tokens: 1,
           total_tokens: prompt_tokens + 1
         },
         model: "mock-model"
       }}
    end
  end

  defmodule TimeoutCompactAdapter do
    def chat(_messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:compact_chat, :primary})
      {:error, ProviderError.transport(:anthropic, __MODULE__, :timeout)}
    end
  end

  # Emits one tool call to `record_cwd`, then finishes — so a real turn executes
  # the recording capability and the test can inspect the tool-execution context.
  defmodule RecordCwdAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts), do: step(opts)

    @impl true
    def continue(_provider_state, _tool_results, opts), do: step(opts)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp step(_opts) do
      n = Process.get(:record_cwd_step, 0) + 1
      Process.put(:record_cwd_step, n)

      tool_calls =
        if n == 1 do
          [%{id: "c1", call_id: "c1", name: "record_cwd", arguments: "{}"}]
        else
          []
        end

      {:ok,
       %{
         content: if(n == 1, do: "", else: "done"),
         tool_calls: tool_calls,
         provider_state: %{},
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "mock-model"
       }}
    end
  end

  defmodule CwdRecorder do
    def execute(_args, context, test_pid) do
      send(test_pid, {:tool_context, context})
      {:ok, %{success: true, output: "recorded"}}
    end
  end

  setup do
    compaction = Application.get_env(:fermix_core, :compaction, [])
    telemetry = Application.get_env(:fermix_core, :telemetry, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :compaction, compaction)
      Application.put_env(:fermix_core, :telemetry, telemetry)
    end)

    :ok
  end

  describe "computer_use_origin/1 — attended-origin derivation" do
    test "a detached /background run is unattended and fails closed at the host gate" do
      # BackgroundRun.run/1 issues its turn on the "background" channel with no
      # live reply surface, so it must NOT be labelled attended — otherwise a
      # host computer-use session could start with no owner present to abort.
      assert TurnRunner.computer_use_origin(%{channel: "background"}) == :unattended
      refute Safety.host_start_allowed?(TurnRunner.computer_use_origin(%{channel: "background"}))
    end

    test "a foreground chat / `fermix ask` turn is interactive and passes the host gate" do
      for channel <- ["telegram", "discord", "slack", "cli"] do
        assert TurnRunner.computer_use_origin(%{channel: channel}) == :interactive
        assert Safety.host_start_allowed?(TurnRunner.computer_use_origin(%{channel: channel}))
      end
    end
  end

  describe "commit/4" do
    test "auto-compaction fails over past an eligible provider error with the real reason_kind" do
      Application.put_env(:fermix_core, :compaction,
        enabled: true,
        threshold: 0.1,
        reasoning_effort: :medium
      )

      handler_id = "compaction-failover-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :failover],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:failover_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      store_name = :"turn_runner_failover_store_#{System.unique_integer([:positive])}"

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      main_agent = start_supervised!({MainAgentStub, test_pid: self()})
      chat_id = "compaction_failover_#{System.unique_integer([:positive])}"
      conversation_key = {"telegram", chat_id, :root}
      older_content = String.duplicate("older context ", 25_000)

      ConversationStore.add_message(conversation_key, "user", older_content, server: store)
      :sys.get_state(store)

      msg = %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "latest question",
        source_trust: :operator
      }

      routes = [
        {%{
           provider: :anthropic,
           model: "claude-x",
           auth_mode: :api_key,
           base_url: "https://a/v1"
         }, [adapter: TimeoutCompactAdapter, model: "claude-x", test_pid: self()]},
        {%{provider: :openai, model: "gpt-x", auth_mode: :api_key, base_url: "https://o/v1"},
         [adapter: SummaryAdapter, model: "gpt-x", test_pid: self()]}
      ]

      turn_state = %{
        adapter: nil,
        adapter_opts: [],
        provider: nil,
        adapter_overrides: [],
        ordered_routes: routes,
        conversation_store: store,
        memory_agent_id: "main",
        memory_owner_id: "default",
        memory_reviewer: NoopReviewer,
        memory_repo: nil,
        task_supervisor: self(),
        main_agent_server: main_agent,
        review_interval_hours: 24,
        review_max_messages: 50,
        review_input_token_budget: 4_000,
        review_failure_backoff_ms: 60_000,
        compaction_failures: %{}
      }

      assert :compacted = TurnRunner.commit(msg, turn_state, "assistant reply", 50_000)

      assert_receive {:compact_chat, :primary}, 5_000
      assert_receive {:summary_chat, _messages, _opts}, 5_000

      # The Compactor's {:compaction_failed, _} wrapper is unwrapped before
      # classification, so telemetry carries the real provider reason.
      assert_receive {:failover_telemetry, metadata}
      assert metadata.reason_kind == :timeout
      assert metadata.from_provider == :anthropic
      assert metadata.to_provider == :openai
      assert metadata.surface == :compaction
    end

    test "returns :compacted when post-delivery auto-compaction rewrites history" do
      Application.put_env(:fermix_core, :compaction,
        enabled: true,
        threshold: 0.1,
        reasoning_effort: :medium
      )

      store_name = :"turn_runner_store_#{System.unique_integer([:positive])}"

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      main_agent = start_supervised!({MainAgentStub, test_pid: self()})
      chat_id = "commit_compacts_#{System.unique_integer([:positive])}"
      conversation_key = {"telegram", chat_id, :root}
      older_content = String.duplicate("older context ", 25_000)

      ConversationStore.add_message(conversation_key, "user", older_content, server: store)
      :sys.get_state(store)

      msg = %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "latest question",
        source_trust: :operator
      }

      turn_state = %{
        adapter: SummaryAdapter,
        adapter_opts: [model: "mock-model", reasoning_effort: :xhigh, test_pid: self()],
        provider: nil,
        adapter_overrides: [],
        conversation_store: store,
        memory_agent_id: "main",
        memory_owner_id: "default",
        memory_reviewer: NoopReviewer,
        memory_repo: nil,
        task_supervisor: self(),
        main_agent_server: main_agent,
        review_interval_hours: 24,
        review_max_messages: 50,
        review_input_token_budget: 4_000,
        review_failure_backoff_ms: 60_000,
        compaction_failures: %{}
      }

      assert :compacted = TurnRunner.commit(msg, turn_state, "assistant reply", 50_000)

      assert_receive {:summary_chat, _messages, summary_opts}, 5_000
      assert Keyword.get(summary_opts, :reasoning_effort) == :medium
      assert_receive {:runtime_invalidated, :compaction}, 5_000
      assert_receive {:compaction_failure_cleared, ^conversation_key}, 5_000

      # The real peak is carried to MainAgent for the next turn's preflight gate.
      assert_receive {:context_tokens_recorded, ^conversation_key, 50_000}, 5_000

      history = ConversationStore.get_history(conversation_key, server: store)
      assert Enum.any?(history, &String.contains?(&1.content, "summary from commit"))
      assert List.last(history).content == "assistant reply"
      refute Enum.any?(history, &(&1.content == older_content))
    end
  end

  describe "run/3" do
    test "main interactive turns have enough iterations for deeper investigations" do
      Process.put(:looping_adapter_step, 0)

      registry_name = :"turn_runner_capability_registry_#{System.unique_integer([:positive])}"
      store_name = :"turn_runner_conversation_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      msg = %{
        channel: "telegram",
        chat_id: "deep_turn",
        sender: "user",
        content: "investigate a complex failure",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter_opts: [model: "mock-model", terminal_step: 100],
          capability_registry: registry_name,
          conversation_store: store
        )

      assert {:ok, "finished at 100", _context_tokens} =
               TurnRunner.run(msg, turn_state, fn _part -> :ok end)

      assert Process.get(:looping_adapter_step) == 100
    end

    test "an operator turn threads request_cwd into the tool-execution context :cwd" do
      Process.put(:record_cwd_step, 0)
      %{context: context} = run_record_cwd_turn(:operator, "/tmp/fermix-op-cwd")

      assert context.cwd == "/tmp/fermix-op-cwd"
    end

    test "a guest turn leaves the tool-execution context :cwd nil despite a request_cwd" do
      Process.put(:record_cwd_step, 0)
      %{context: context} = run_record_cwd_turn(:guest, "/tmp/fermix-guest-cwd")

      assert context.cwd == nil
    end

    test "surfaces the message's approval_fn in the tool-execution context" do
      Process.put(:record_cwd_step, 0)
      approval_fn = fn _request -> {:ok, "TKN", :new} end

      %{context: context} =
        run_record_cwd_turn(:operator, "/tmp/fermix-approval", %{approval_fn: approval_fn})

      assert context.approval_fn == approval_fn
    end

    test "leaves the tool-execution context approval_fn nil when the message carries none" do
      Process.put(:record_cwd_step, 0)
      %{context: context} = run_record_cwd_turn(:operator, "/tmp/fermix-no-approval")

      assert context.approval_fn == nil
    end

    # CODING_HARNESS_ORCHESTRATION §23.2: a coding run launched from a
    # continuation turn must inherit depth+1, which only works if the notice's
    # metadata depth reaches the tool-execution context. A reset to 0 here would
    # make the chain unbounded.
    test "threads a continuation notice's chain depth into the tool-execution context" do
      Process.put(:record_cwd_step, 0)

      %{context: context} =
        run_record_cwd_turn(:operator, "/tmp/fermix-continuation", %{
          metadata: %{harness_continuation: true, harness_continuation_depth: 2}
        })

      assert context.harness_continuation_depth == 2
    end

    test "an ordinary turn carries continuation depth 0" do
      Process.put(:record_cwd_step, 0)
      %{context: context} = run_record_cwd_turn(:operator, "/tmp/fermix-plain-turn")

      assert context.harness_continuation_depth == 0
    end

    # MILESTONE_29_ACP_AGENT_SURFACE §8.3: the ACP session's spawn env reaches
    # the sandbox command env through the turn context, and the two secret
    # values ride alongside it as the telemetry redaction list.
    test "an operator turn threads session_env and derives its redaction list" do
      Process.put(:record_cwd_step, 0)

      session_env = %{
        "BUZZ_PRIVATE_KEY" => "nsec1fakebuzzkeyvalue",
        "NOSTR_PRIVATE_KEY" => "nsec1fakenostrkeyvalue",
        "BUZZ_RELAY_URL" => "wss://relay.example",
        "PATH" => "/fake/bin"
      }

      %{context: context} =
        run_record_cwd_turn(:operator, "/tmp/fermix-session-env", %{session_env: session_env})

      assert context.session_env == session_env

      assert Enum.sort(context.redact_values) ==
               Enum.sort(["nsec1fakebuzzkeyvalue", "nsec1fakenostrkeyvalue"])
    end

    test "a guest turn drops session_env and its redaction list" do
      Process.put(:record_cwd_step, 0)

      %{context: context} =
        run_record_cwd_turn(:guest, "/tmp/fermix-guest-session-env", %{
          session_env: %{"BUZZ_PRIVATE_KEY" => "nsec1fakebuzzkeyvalue"}
        })

      assert context.session_env == nil
      assert context.redact_values == []
    end

    test "a turn without a session env still carries both keys at their defaults" do
      Process.put(:record_cwd_step, 0)
      %{context: context} = run_record_cwd_turn(:operator, "/tmp/fermix-no-session-env")

      assert Map.has_key?(context, :session_env)
      assert context.session_env == nil
      assert context.redact_values == []
    end

    test "run/4 threads the stream callback into adapter_opts; run/3 stays callback-free" do
      registry_name = :"turn_runner_stream_registry_#{System.unique_integer([:positive])}"
      store_name = :"turn_runner_stream_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      msg = %{
        channel: "telegram",
        chat_id: "streamed_turn",
        sender: "user",
        content: "stream this",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter: SummaryAdapter,
          adapter_opts: [model: "mock-model", test_pid: self()],
          capability_registry: registry_name,
          conversation_store: store
        )

      test_pid = self()
      cb = fn event -> send(test_pid, {:stream, event}) end

      assert {:ok, "summary from commit", _tokens} =
               TurnRunner.run(msg, turn_state, fn _part -> :ok end, cb)

      assert_receive {:summary_chat, _messages, opts}

      # The loop wraps the callback (emitted? failover gate) — assert
      # forwarding rather than function identity.
      injected = Keyword.fetch!(opts, :stream_callback)
      assert is_function(injected, 1)
      injected.({:text_delta, "partial"})
      assert_received {:stream, {:text_delta, "partial"}}
      # The loop emits the bootstrap events through the same callback.
      assert_received {:stream, {:session_started, "main-" <> _}}
      assert_received {:stream, {:iteration_started, 1}}

      # 3-arity path threads no callback.
      assert {:ok, "summary from commit", _tokens} =
               TurnRunner.run(msg, turn_state, fn _part -> :ok end)

      assert_receive {:summary_chat, _messages, plain_opts}
      refute Keyword.has_key?(plain_opts, :stream_callback)
    end

    test "run/5 threads the activity callback into the loop; run/3 threads none" do
      registry_name = :"turn_runner_activity_registry_#{System.unique_integer([:positive])}"
      store_name = :"turn_runner_activity_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      msg = %{
        channel: "acp",
        chat_id: "activity_turn",
        sender: "user",
        content: "use a tool",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter: LoopingAdapter,
          adapter_opts: [model: "mock-model", terminal_step: 2],
          capability_registry: registry_name,
          conversation_store: store
        )

      test_pid = self()
      activity = fn event -> send(test_pid, {:activity, event}) end

      # 3-arity path threads nothing (asserted first, so no event from the
      # 5-arity run below can be mistaken for one it produced).
      Process.put(:looping_adapter_step, 0)

      assert {:ok, "finished at 2", _tokens} =
               TurnRunner.run(msg, turn_state, fn _part -> :ok end)

      refute_received {:activity, _event}

      Process.put(:looping_adapter_step, 0)

      assert {:ok, "finished at 2", _tokens} =
               TurnRunner.run(msg, turn_state, fn _part -> :ok end, nil, activity)

      # `missing_tool` never reaches a capability, so the loop reports the
      # failed outcome on the finish event.
      assert_received {:activity, {:tool_start, "missing_tool"}}
      assert_received {:activity, {:tool_finish, "missing_tool", %{status: :error}}}
    end

    test "persists the accepted user message when the agent loop fails" do
      registry_name = :"turn_runner_failure_registry_#{System.unique_integer([:positive])}"
      store_name = :"turn_runner_failure_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      msg = %{
        channel: "telegram",
        chat_id: "failed_turn",
        sender: "user",
        content: "keep this failed request",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter: FailingAdapter,
          adapter_opts: [model: "mock-model"],
          capability_registry: registry_name,
          conversation_store: store
        )

      assert {:error, "adapter failed"} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)

      history = ConversationStore.get_history({"telegram", "failed_turn", :root}, server: store)
      assert Enum.map(history, & &1.role) == ["user"]
      assert List.first(history).content == "keep this failed request"
    end

    # The M29/Buzz duplicate-reply incident was diagnosed blind: the FAILED turn
    # dropped the very message that produced it while a successful turn kept it —
    # exactly backwards. Both outcomes carry the same identity, and the same
    # `capture_content?` gate decides whether the prompt rides along.
    test "a failed turn's error event carries the input and sender when content capture is on" do
      set_capture_content(true)

      metadata = run_failing_turn("failed_turn_capture_on")

      assert metadata.channel == "telegram"
      assert metadata.chat_id == "failed_turn_capture_on"
      assert metadata.sender == "user"
      assert metadata.reason == "adapter failed"
      assert metadata.input == "keep this failed request"
      # The turn produced no reply, so it carries no output key at all.
      refute Map.has_key?(metadata, :output)
    end

    test "a failed turn's error event carries no content when capture is off" do
      set_capture_content(false)

      metadata = run_failing_turn("failed_turn_capture_off")

      # Identity and the reason are not content — they always ride.
      assert metadata.channel == "telegram"
      assert metadata.sender == "user"
      assert metadata.reason == "adapter failed"
      refute Map.has_key?(metadata, :input)
      refute Map.has_key?(metadata, :output)
    end

    test "auto-compacts oversized history before the main provider call" do
      Application.put_env(:fermix_core, :compaction,
        enabled: true,
        threshold: 0.1,
        reasoning_effort: :medium
      )

      registry_name = :"turn_runner_preflight_registry_#{System.unique_integer([:positive])}"
      store_name = :"turn_runner_preflight_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      chat_id = "preflight_compaction"
      conversation_key = {"telegram", chat_id, :root}
      old_content = String.duplicate("old context ", 25_000)

      ConversationStore.add_message(conversation_key, "user", old_content, server: store)
      ConversationStore.add_message(conversation_key, "assistant", "old answer", server: store)

      msg = %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "latest question",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter: PreflightAdapter,
          adapter_opts: [model: "mock-model", test_pid: self()],
          capability_registry: registry_name,
          conversation_store: store,
          # Real provider-reported peak from the prior turn (mock-model context
          # window is 100_000; threshold 0.1 => 10_000). 50_000 is over.
          last_context_tokens: 50_000
        )

      deliver = fn {:text, text} -> send(self(), {:reply, text}) end

      assert {:ok, "assistant after preflight", _context_tokens} =
               TurnRunner.run(msg, turn_state, deliver)

      assert_receive {:preflight_summary_call, summary_text}, 5_000
      assert summary_text =~ old_content

      assert_receive {:reply, notice}, 5_000
      assert notice =~ "Trimmed older conversation history"

      assert_receive {:preflight_main_call, main_text}, 5_000
      assert main_text =~ "preflight summary"
      assert main_text =~ "latest question"
      refute main_text =~ old_content
    end

    test "preflight skips when the carried context_tokens is under threshold, despite large history" do
      Application.put_env(:fermix_core, :compaction,
        enabled: true,
        threshold: 0.1,
        reasoning_effort: :medium
      )

      registry_name =
        :"turn_runner_preflight_under_registry_#{System.unique_integer([:positive])}"

      store_name = :"turn_runner_preflight_under_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      chat_id = "preflight_under_threshold"
      conversation_key = {"telegram", chat_id, :root}
      # Large enough that a byte-estimate trigger WOULD compact — proving the
      # gate now reads the carried real token count, not the history bytes.
      old_content = String.duplicate("old context ", 25_000)

      ConversationStore.add_message(conversation_key, "user", old_content, server: store)
      ConversationStore.add_message(conversation_key, "assistant", "old answer", server: store)

      msg = %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "latest question",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter: PreflightAdapter,
          adapter_opts: [model: "mock-model", test_pid: self()],
          capability_registry: registry_name,
          conversation_store: store,
          # 5_000 / 100_000 = 0.05, under the 0.1 threshold.
          last_context_tokens: 5_000
        )

      deliver = fn {:text, text} -> send(self(), {:reply, text}) end

      assert {:ok, "assistant after preflight", _context_tokens} =
               TurnRunner.run(msg, turn_state, deliver)

      refute_receive {:preflight_summary_call, _text}, 200
      refute_receive {:reply, _notice}, 200

      assert_receive {:preflight_main_call, main_text}, 5_000
      # History was NOT trimmed — the big old content still reaches the model.
      assert main_text =~ old_content
    end

    test "preflight skips cleanly when no prior context_tokens was measured (cold turn)" do
      Application.put_env(:fermix_core, :compaction,
        enabled: true,
        threshold: 0.1,
        reasoning_effort: :medium
      )

      registry_name = :"turn_runner_preflight_cold_registry_#{System.unique_integer([:positive])}"
      store_name = :"turn_runner_preflight_cold_store_#{System.unique_integer([:positive])}"

      start_supervised!({CapabilityRegistry, name: registry_name})

      store =
        start_supervised!(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil}
        )

      chat_id = "preflight_cold_turn"
      conversation_key = {"telegram", chat_id, :root}
      old_content = String.duplicate("old context ", 25_000)

      ConversationStore.add_message(conversation_key, "user", old_content, server: store)
      ConversationStore.add_message(conversation_key, "assistant", "old answer", server: store)

      msg = %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "latest question",
        source_trust: :operator
      }

      # No last_context_tokens set: a cold conversation (or first turn after a
      # daemon restart) has no prior real measurement and must skip preflight.
      turn_state =
        turn_state(
          adapter: PreflightAdapter,
          adapter_opts: [model: "mock-model", test_pid: self()],
          capability_registry: registry_name,
          conversation_store: store
        )

      deliver = fn {:text, text} -> send(self(), {:reply, text}) end

      assert {:ok, "assistant after preflight", _context_tokens} =
               TurnRunner.run(msg, turn_state, deliver)

      refute_receive {:preflight_summary_call, _text}, 200
      refute_receive {:reply, _notice}, 200
      assert_receive {:preflight_main_call, _main_text}, 5_000
    end
  end

  describe "error_reply/1" do
    test "maps a context-length overflow to an actionable /new or /compact message" do
      reply = TurnRunner.error_reply(:context_length_exceeded)

      assert reply =~ "context window"
      assert reply =~ "/new"
      assert reply =~ "/compact"
    end

    test "maps a context-length message string (non-OpenAI fallback) the same way" do
      reply = TurnRunner.error_reply("Request exceeded the maximum context length for this model")

      assert reply =~ "/new"
      assert reply =~ "/compact"
    end

    test "maps auth failures to the re-login hint" do
      assert TurnRunner.error_reply(:no_auth_file) =~ "fermix auth login"
    end

    test "rate-limit reply names the reset window when the body carried resets_at" do
      resets_at = System.system_time(:second) + 1800

      reply =
        TurnRunner.error_reply(
          ProviderError.api(:openai_codex, :codex, 429, %{
            "error" => %{
              "code" => "usage_limit_reached",
              "plan_type" => "Plus",
              "resets_at" => resets_at
            }
          })
        )

      assert reply =~ "usage limit"
      assert reply =~ "plus plan"
      assert reply =~ ~r/~\d+ min/
    end

    test "rate-limit reply falls back to generic text without a reset time" do
      reply =
        TurnRunner.error_reply(
          ProviderError.api(:openai, :openai, 429, %{"error" => %{"message" => "slow down"}})
        )

      assert reply =~ "rate-limited"
      refute reply =~ "usage limit"
    end

    test "maps API-key provider auth failures to a check-your-key hint" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :anthropic,
             adapter: :messages,
             status: 401,
             kind: :auth,
             message: "invalid x-api-key"
           }}
        )

      assert reply =~ "Anthropic"
      assert reply =~ "API key"
      refute reply =~ "fermix auth login"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps Anthropic OAuth auth failures to a subscription reconnect hint" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :anthropic,
             adapter: :messages,
             status: 401,
             kind: :auth,
             auth_mode: :oauth,
             message: "OAuth token expired"
           }}
        )

      assert reply =~ "Claude subscription"
      assert reply =~ "fermix auth login --provider anthropic"
      refute reply =~ "API key"
    end

    test "maps xAI API-key auth failures to a check-your-key hint" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :xai,
             adapter: :responses,
             status: 401,
             kind: :auth,
             auth_mode: :api_key,
             message: "invalid api key"
           }}
        )

      assert reply =~ "SpaceXAI"
      assert reply =~ "API key"
      refute reply =~ "fermix auth login"
    end

    test "maps xAI OAuth 403 to an entitlement message, not a re-login hint" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :xai,
             adapter: :responses,
             status: 403,
             kind: :auth,
             auth_mode: :oauth,
             message: "no api access"
           }}
        )

      assert reply =~ "access denied"
      assert reply =~ "API key"
      refute reply =~ "fermix auth login"
    end

    test "maps xAI OAuth 401 to a reconnect hint" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :xai,
             adapter: :responses,
             status: 401,
             kind: :auth,
             auth_mode: :oauth,
             message: "expired"
           }}
        )

      assert reply =~ "fermix auth login --provider xai"
    end

    test "keeps the re-login hint for Codex OAuth auth failures" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :openai_codex,
             adapter: :codex,
             status: 401,
             kind: :auth,
             message: "token expired"
           }}
        )

      assert reply =~ "fermix auth login"
    end

    test "maps provider rate limits to an actionable retry message" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :openai,
             adapter: :responses,
             status: 429,
             kind: :rate_limit,
             message: "Too many requests"
           }}
        )

      assert reply =~ "OpenAI"
      assert reply =~ "rate-limited"
      assert reply =~ "retry"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps provider outages to an actionable provider message" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :openai,
             adapter: :responses,
             status: 503,
             kind: :provider_unavailable,
             message: "service overloaded"
           }}
        )

      assert reply =~ "OpenAI"
      assert reply =~ "unavailable"
      assert String.downcase(reply) =~ "retry"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps provider transport errors to an actionable network message" do
      reply =
        TurnRunner.error_reply(
          {:provider_transport_error,
           %{provider: :openai, adapter: :responses, reason: :timeout, kind: :timeout}}
        )

      assert reply =~ "OpenAI"
      assert reply =~ "timeout"
      assert reply =~ "provider"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps scaffolded provider errors to an actionable provider message" do
      reply =
        TurnRunner.error_reply(
          {:provider_error,
           %{
             provider: :anthropic,
             adapter: :messages,
             kind: :not_implemented,
             message: "Anthropic provider is selectable but runtime calls are not implemented yet"
           }}
        )

      assert reply =~ "Anthropic"
      assert reply =~ "not implemented"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps unsupported image input to the explicit routing message" do
      reply = TurnRunner.error_reply({:image_unsupported, :ollama, "qwen3:32b"})

      assert reply =~ "ollama/qwen3:32b"
      assert reply =~ "vision-capable"
      refute reply =~ "HTTP"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps max iteration exhaustion to an actionable step-limit message" do
      reply = TurnRunner.error_reply("Maximum iterations (50) reached")

      assert reply =~ "step limit"
      assert reply =~ "narrow"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps a structured Codex mid-stream closure to an actionable provider message" do
      reply =
        TurnRunner.error_reply(
          ProviderError.transport(:openai_codex, :codex, :closed, stage: :mid_stream)
        )

      assert reply =~ "Codex"
      assert reply =~ "closed"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    # MILESTONE_29 §17 phase 1 minted `code: "empty_response"` for a 200 the
    # server declared terminal that carried nothing. Left on the `%{status: …}`
    # floor clause it reads "returned HTTP 200", which sends the operator after a
    # transport fault that did not happen — the vendor's own sentence is the
    # diagnosis, so the clause keys on the code and keeps the words.
    test "maps an undelivered Codex response to an empty-turn sentence, not an HTTP status" do
      reply =
        TurnRunner.error_reply(
          ProviderError.api(:openai_codex, :codex, 200, %{
            "error" => %{
              "code" => "empty_response",
              "message" =>
                "The response was reported completed carrying 2 output item(s), " <>
                  "and delivered no text and no tool call."
            }
          })
        )

      assert reply =~ "Codex"
      assert reply =~ "without producing a reply"
      assert reply =~ "delivered no text and no tool call"
      refute reply =~ "HTTP 200"
      refute reply =~ "empty_response"
      refute reply == "Sorry, I encountered an error processing your message."
    end

    test "maps an exhausted failover chain to a reply naming the attempted providers" do
      last = ProviderError.transport(:openai, :responses, :timeout)

      reply =
        TurnRunner.error_reply({:all_routes_failed, [{:anthropic, :ignored}, {:openai, last}]})

      assert reply =~ "All configured providers failed"
      assert reply =~ "anthropic"
      assert reply =~ "openai"
      assert reply =~ "network timeout"
    end

    test "falls back to the generic message for unrelated errors" do
      reply = TurnRunner.error_reply("some unexpected failure")

      assert reply =~ "Sorry"
      refute reply =~ "/new"
    end
  end

  # CHANNEL_LONGFORM_PRESENTATION §7: the presentation note rides the same
  # per-turn seam as the date note, spliced ahead of it.
  describe "channel presentation note" do
    test "a chat-channel turn carries the note in the leading system run, before the date" do
      messages = capture_prompt(%{channel: "telegram", chat_id: "presentation_telegram"})

      system_run = Enum.take_while(messages, &(&1.role == "system"))

      presentation_index =
        Enum.find_index(system_run, &(&1.content =~ "phone-width chat surface"))

      date_index = Enum.find_index(system_run, &(&1.content =~ "Current date:"))

      assert is_integer(presentation_index)
      assert is_integer(date_index)
      assert presentation_index < date_index
      assert Enum.at(system_run, presentation_index).content =~ "Telegram renders a quote block"
    end

    test "a machine-surface turn carries no presentation note" do
      messages = capture_prompt(%{channel: "acp", chat_id: "presentation_acp"})

      refute Enum.any?(messages, &(&1.content =~ "phone-width chat surface"))
      assert Enum.any?(messages, &(&1.content =~ "Current date:"))
    end

    test "a shared-chat turn adds the addressing line from the message metadata" do
      messages =
        capture_prompt(%{
          channel: "telegram",
          chat_id: "presentation_group",
          metadata: %{chat_type: "supergroup"}
        })

      assert Enum.any?(messages, &(&1.content =~ "This is a shared chat"))
    end

    test "two consecutive turns of one conversation produce byte-identical note blocks" do
      msg = %{channel: "discord", chat_id: "presentation_stable", metadata: %{chat_type: "guild"}}

      first = presentation_note(capture_prompt(msg))
      second = presentation_note(capture_prompt(msg))

      assert first == second
      assert first =~ "Discord caps a single message"
    end
  end

  # Drive one real turn through TurnRunner and return the message list the
  # provider adapter actually received.
  defp capture_prompt(msg_overrides) do
    registry_name = :"tr_prompt_reg_#{System.unique_integer([:positive])}"
    store_name = :"tr_prompt_store_#{System.unique_integer([:positive])}"

    # Unique child ids: byte-stability is proven by driving the SAME conversation
    # twice, so two capture turns coexist under one test's supervisor.
    start_supervised!(
      Supervisor.child_spec({CapabilityRegistry, name: registry_name}, id: registry_name)
    )

    store =
      start_supervised!(
        Supervisor.child_spec(
          {ConversationStore, name: store_name, max_messages: :infinity, repo: nil},
          id: store_name
        )
      )

    msg =
      Map.merge(
        %{sender: "user", content: "how does this render?", source_trust: :operator},
        msg_overrides
      )

    turn_state =
      turn_state(
        adapter: CapturePromptAdapter,
        adapter_opts: [model: "mock-model", test_pid: self()],
        capability_registry: registry_name,
        conversation_store: store
      )

    assert {:ok, "captured", _tokens} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)
    assert_receive {:captured_prompt, messages}, 5_000
    messages
  end

  defp presentation_note(messages) do
    Enum.find_value(messages, fn message ->
      if message.content =~ "phone-width chat surface", do: message.content
    end)
  end

  defp runtime_context do
    operator_profile = runtime_profile(:operator)
    guest_profile = runtime_profile(:guest)

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: operator_profile,
      guest_profile: guest_profile,
      # A client-owned channel (acp) runs on the harness-free variant; these
      # fixtures carry no capabilities, so it is the same profile here. Selection
      # by channel is pinned in `HarnessChannelProfileTest`.
      harness_free_profiles: %{operator: operator_profile, guest: guest_profile}
    }
  end

  defp runtime_profile(trust) do
    %{
      trust: trust,
      capabilities: [],
      runtime_message: %{role: "system", content: "runtime contract"},
      runtime_accounting: %{part: :runtime}
    }
  end

  # Establish the content-capture precondition explicitly (never inherit it from
  # whatever an earlier module leaked); the module setup restores it on exit.
  defp set_capture_content(value) when is_boolean(value) do
    Application.put_env(:fermix_core, :telemetry, capture_content: value)
  end

  # Drive one turn that fails inside the agent loop and return the metadata of
  # the `[:fermix, :agent, :message_error]` event it emitted.
  defp run_failing_turn(chat_id) do
    registry_name = :"turn_runner_error_registry_#{System.unique_integer([:positive])}"
    store_name = :"turn_runner_error_store_#{System.unique_integer([:positive])}"

    start_supervised!({CapabilityRegistry, name: registry_name})

    store =
      start_supervised!({ConversationStore, name: store_name, max_messages: :infinity, repo: nil})

    handler_id = "turn-runner-message-error-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :agent, :message_error],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:message_error, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    msg = %{
      channel: "telegram",
      chat_id: chat_id,
      sender: "user",
      content: "keep this failed request",
      source_trust: :operator
    }

    turn_state =
      turn_state(
        adapter: FailingAdapter,
        adapter_opts: [model: "mock-model"],
        capability_registry: registry_name,
        conversation_store: store
      )

    assert {:error, "adapter failed"} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)
    assert_receive {:message_error, metadata}, 5_000
    metadata
  end

  defp run_record_cwd_turn(trust, request_cwd, extra_msg \\ %{}) do
    registry_name = :"tr_cwd_reg_#{System.unique_integer([:positive])}"
    store_name = :"tr_cwd_store_#{System.unique_integer([:positive])}"

    start_supervised!({CapabilityRegistry, name: registry_name})

    store =
      start_supervised!({ConversationStore, name: store_name, max_messages: :infinity, repo: nil})

    msg =
      Map.merge(
        %{
          channel: "cli",
          chat_id: "cwd_#{trust}",
          sender: "user",
          content: "hi",
          source_trust: trust,
          request_cwd: request_cwd
        },
        extra_msg
      )

    turn_state =
      turn_state(
        adapter: RecordCwdAdapter,
        adapter_opts: [model: "mock-model"],
        capability_registry: registry_name,
        conversation_store: store,
        runtime_context: record_cwd_runtime_context(self())
      )

    assert {:ok, "done", _tokens} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)
    assert_receive {:tool_context, context}
    %{context: context}
  end

  # A runtime context whose operator and guest profiles both advertise (and
  # dispatch) the `record_cwd` capability, so a driven turn actually executes it
  # regardless of the turn's trust level.
  defp record_cwd_runtime_context(test_pid) do
    cap = record_cwd_capability(test_pid)

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: record_cwd_profile(:operator, cap),
      guest_profile: record_cwd_profile(:guest, cap)
    }
  end

  defp record_cwd_profile(trust, cap) do
    %{
      trust: trust,
      capabilities: [cap],
      runtime_message: %{role: "system", content: "runtime contract"},
      runtime_accounting: %{part: :runtime}
    }
  end

  defp record_cwd_capability(test_pid) do
    Capability.new(%{
      name: "record_cwd",
      description: "records the tool-execution context for assertions",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {CwdRecorder, :execute, [test_pid]},
      policy_class: :read_only
    })
  end

  defp turn_state(overrides) do
    base = %{
      adapter: LoopingAdapter,
      adapter_opts: [model: "mock-model", terminal_step: 30],
      provider: nil,
      adapter_overrides: [],
      capability_registry: Keyword.fetch!(overrides, :capability_registry),
      conversation_store: Keyword.fetch!(overrides, :conversation_store),
      runtime_context: runtime_context(),
      memory_agent_id: "main",
      memory_owner_id: "default",
      skill_registry: nil,
      agent_supervisor: nil,
      task_supervisor: self(),
      journal_base_dir: nil,
      memory_store: nil,
      memory_repo: nil
    }

    Enum.reduce(overrides, base, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end
end
