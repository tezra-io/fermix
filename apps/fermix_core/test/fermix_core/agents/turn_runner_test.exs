defmodule FermixCore.Agents.TurnRunnerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Agents.VoiceCall
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerHistory.Taint
  alias FermixCore.ComputerUse.Safety
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Realtime.LivePrompt
  alias FermixTestSupport.ComputerHistoryCanary

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

  # Hands back the prompt AND the adapter opts. The correlation ids a real
  # adapter passes to `Providers.Telemetry.emit_call/3` arrive as adapter opts
  # (`AgentLoop.bind_route`), so asserting on them here is asserting on exactly
  # what a provider call would carry.
  defmodule CaptureTurnAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:captured_turn, messages, capabilities, opts})

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

  # Replies with whatever the replay actually showed it, so the reply carries
  # activity bytes exactly when the history reached the model unmasked — the
  # model-paraphrase path MILESTONE_32 §13.6 has to taint transitively.
  defmodule ParaphraseAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:captured_prompt, messages})

      {:ok,
       %{
         content:
           "Recapping what I saw: " <> Enum.map_join(messages, " ", &Map.get(&1, :content, "")),
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

    test "a Live voice delegation is :voice and passes the host gate" do
      msg = voice_msg("open my calendar")

      assert TurnRunner.computer_use_origin(msg) == :voice
      assert Safety.host_start_allowed?(TurnRunner.computer_use_origin(msg))
    end

    test "a forged voice_call on a chat message stays interactive" do
      # The trust gate, read through the origin: a crafted `voice_call` on a
      # remote channel must not relabel the turn's surface.
      forged = %{voice_msg("open my calendar") | channel: "telegram"}

      assert TurnRunner.computer_use_origin(forged) == :interactive
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

  # MILESTONE_32 §13.6 / inv. 20 — a reply the model generated from an UNMASKED
  # tainted replay is itself activity-derived and must inherit the stamp. Before
  # this, `/history off` on an all-local chain left the earlier tainted turns
  # unmasked (local chains may carry history), the model paraphrased them, and
  # the new reply was persisted clean — so a later switch to an ungranted-remote
  # provider masked the original and sent the paraphrase.
  describe "commit/4 — the reply inherits the taint of what it replayed" do
    setup do
      original = Application.get_env(:fermix_core, :computer_history)
      # History DISABLED: the reproduction posture. The stamp must NOT depend on
      # the feature being on — the taint is a property of the message's origin.
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      Application.put_env(:fermix_core, :compaction, enabled: false)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:fermix_core, :computer_history)
          value -> Application.put_env(:fermix_core, :computer_history, value)
        end
      end)

      :ok
    end

    test "a reply generated from an unmasked tainted replay is stamped (local chain)" do
      canary = ComputerHistoryCanary.token("replay")
      {history, prompt} = taint_turn(local_routes(), prior: canary)

      # The replay reached the model unmasked, so the reply carries the bytes.
      assert ComputerHistoryCanary.present?(prompt, canary)
      assert ComputerHistoryCanary.present?(List.last(history).content, canary)
      assert List.last(history).history_tainted == true
    end

    test "an ungranted-remote chain masks the prior, so the reply is NOT stamped" do
      canary = ComputerHistoryCanary.token("masked")
      {history, prompt} = taint_turn(remote_routes(), prior: canary)

      assert ComputerHistoryCanary.absent?(prompt, canary)
      assert ComputerHistoryCanary.absent?(List.last(history).content, canary)
      refute Map.has_key?(List.last(history), :history_tainted)
    end

    test "no tainted history and no section — the reply is not stamped" do
      {history, _prompt} = taint_turn(local_routes(), prior: nil)
      assert List.last(history).role == "assistant"
      refute Enum.any?(history, &Map.has_key?(&1, :history_tainted))
    end

    # Drives one real turn (run + commit) on `routes`, optionally seeding a
    # prior activity-derived assistant message carrying `prior`. Returns the
    # persisted history and the message list the adapter actually received.
    defp taint_turn(routes, prior: prior) do
      suffix = System.unique_integer([:positive])
      registry_name = :"tr_taint_reg_#{suffix}"
      store_name = :"tr_taint_store_#{suffix}"

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

      main_agent =
        start_supervised!(
          Supervisor.child_spec({MainAgentStub, test_pid: self()},
            id: :"tr_taint_agent_#{suffix}"
          )
        )

      chat_id = "taint_#{suffix}"
      conversation_key = {"telegram", chat_id, :root}
      seed_prior_activity_reply(conversation_key, store, prior)

      msg = %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "what was I doing?",
        source_trust: :operator
      }

      turn_state =
        turn_state(
          adapter: ParaphraseAdapter,
          adapter_opts: [model: "mock-model", test_pid: self()],
          capability_registry: registry_name,
          conversation_store: store,
          ordered_routes: routes,
          main_agent_server: main_agent,
          memory_reviewer: NoopReviewer,
          review_interval_hours: 24,
          review_max_messages: 50,
          review_input_token_budget: 4_000,
          review_failure_backoff_ms: 60_000,
          compaction_failures: %{}
        )

      assert {:ok, reply, tokens} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)
      assert :ok = TurnRunner.commit(msg, turn_state, reply, tokens)
      assert_receive {:captured_prompt, prompt}, 5_000

      {ConversationStore.get_history(conversation_key, server: store), prompt}
    end

    defp seed_prior_activity_reply(_key, _store, nil), do: :ok

    defp seed_prior_activity_reply(conversation_key, store, canary) do
      ConversationStore.add_message(
        conversation_key,
        "assistant",
        "You were reading #{canary} in Numbers.",
        server: store,
        metadata: Taint.metadata()
      )
    end

    defp local_routes,
      do: [{%{provider: :ollama, model: "llama3", base_url: "http://127.0.0.1:11434/v1"}, []}]

    defp remote_routes,
      do: [{%{provider: :openai, model: "gpt-x", base_url: "https://api.openai.com/v1"}, []}]
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

    # A 404 with a zero-byte body (Codex, 2026-09-15) rendered "returned HTTP 404.
    # Check provider logs and retry." — and the log line it pointed at read
    # `404 - ""`. The reply states what is actually known and sends nobody after
    # a log that holds nothing.
    test "maps an empty-bodied HTTP error to a reply saying no reason was given" do
      reply = TurnRunner.error_reply(ProviderError.api(:openai_codex, :codex, 404, ""))

      assert reply =~ "returned HTTP 404"
      assert reply =~ "gave no reason"
      refute reply =~ "Check provider logs"
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

  # In-loop compaction: an overflow inside a turn is not fixed by /new or
  # /compact (resending repeats it), and a scheduled job has no "message" and no
  # chat to type a command into, so the surface picks the advice.
  describe "error_reply/2" do
    test "a summarizer refusal inside a failed compression names it instead of the generic reply" do
      reply = TurnRunner.error_reply({:context_recovery_failed, :empty_summary}, surface: :job)
      assert reply =~ "couldn't compress earlier results"
      assert reply =~ "empty_summary"
      refute reply =~ "The run failed with an error"
    end

    test "the chat surface is the default" do
      assert TurnRunner.error_reply(:context_length_exceeded, surface: :chat) ==
               TurnRunner.error_reply(:context_length_exceeded)

      assert TurnRunner.error_reply(:context_length_exceeded, []) ==
               TurnRunner.error_reply(:context_length_exceeded)
    end

    test "an overflow after compaction on chat asks for a narrower slice, not /new" do
      reply = TurnRunner.error_reply(:context_overflow_after_compaction, surface: :chat)

      assert reply ==
               "That request produced more tool output than the model's context window can " <>
                 "hold, even after I compressed earlier results. Ask for a narrower slice, " <>
                 "or split the request."

      refute reply =~ "/new"
      refute reply =~ "/compact"
    end

    test "an overflow after compaction on a job asks to narrow or split the job" do
      reply = TurnRunner.error_reply(:context_overflow_after_compaction, surface: :job)

      assert reply ==
               "The run's tool results grew larger than the model's context window, even " <>
                 "after earlier results were compressed. Narrow the task or split it into " <>
                 "smaller jobs."
    end

    test "a context-length overflow on a job carries job advice, not chat commands" do
      reply = TurnRunner.error_reply(:context_length_exceeded, surface: :job)

      assert reply ==
               "This run's conversation grew larger than the model's context window. " <>
                 "Narrow the task or split it into smaller jobs."

      assert TurnRunner.error_reply("maximum context length exceeded", surface: :job) == reply
    end

    test "the generic fallback on a job names the run, not a message" do
      assert TurnRunner.error_reply("some unexpected failure", surface: :job) ==
               "The run failed with an error."

      assert TurnRunner.error_reply("some unexpected failure", surface: :chat) ==
               "Sorry, I encountered an error processing your message."
    end

    test "a failed compression carries the provider's own sentence on both surfaces" do
      inner =
        ProviderError.api(:openai, :openai, 429, %{"error" => %{"message" => "slow down"}})

      for surface <- [:chat, :job] do
        reply = TurnRunner.error_reply({:context_recovery_failed, inner}, surface: surface)

        assert reply ==
                 "The context filled and I couldn't compress earlier results: " <>
                   TurnRunner.error_reply(inner, surface: surface)

        assert reply =~ "rate-limited"
      end
    end

    test "a failed compression threads the surface into the inner reason" do
      assert TurnRunner.error_reply({:context_recovery_failed, "boom"}, surface: :job) ==
               "The context filled and I couldn't compress earlier results: " <>
                 "The run failed with an error."

      assert TurnRunner.error_reply({:context_recovery_failed, "boom"}) ==
               "The context filled and I couldn't compress earlier results: " <>
                 "Sorry, I encountered an error processing your message."
    end

    test "an unknown surface or option fails loudly" do
      assert_raise ArgumentError, fn ->
        TurnRunner.error_reply(:context_length_exceeded, surface: :voice)
      end

      assert_raise ArgumentError, fn ->
        TurnRunner.error_reply(:context_length_exceeded, channel: :job)
      end
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

  # --- Voice delegations (MILESTONE_41_OPENAI_LIVE_VOICE.md §7) ---

  @voice_addendum "This task comes from an ongoing voice conversation."

  describe "voice delegations" do
    test "the turn carries the session's turn id and the call as parent_session" do
      {_messages, opts} = run_voice_turn()

      assert Keyword.fetch!(opts, :session_id) == "voice_delegation_7"
      assert Keyword.fetch!(opts, :parent_session) == "voice_live_42"
    end

    test "an ordinary turn carries a main- session id and no parent_session" do
      {_messages, opts} = run_chat_turn()

      assert "main-" <> _rest = Keyword.fetch!(opts, :session_id)
      refute Keyword.has_key?(opts, :parent_session)
    end

    test "the turn's telemetry names the session the Live call minted" do
      handler_id = "voice-turn-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :agent, :message],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:agent_message, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      run_voice_turn()

      assert_receive {:agent_message, %{session_id: "voice_delegation_7", channel: "voice"}},
                     5_000
    end

    test "the backend addendum sits directly after the runtime contract" do
      {messages, _opts} = run_voice_turn()

      # A voice turn builds its own profile (the voice capability boundary), so
      # the runtime message is the generated section rather than the cached
      # fixture's — the addendum's POSITION relative to it is what is pinned.
      assert [base, runtime, addendum | _rest] = messages
      assert base.content == "base prompt"
      assert runtime.role == "system"
      assert runtime.content =~ "## Runtime Contract"
      assert addendum.role == "system"
      assert addendum.content == @voice_addendum
    end

    test "an ordinary chat turn carries no addendum" do
      {messages, _opts} = run_chat_turn()

      refute Enum.any?(messages, &(Map.get(&1, :content) == @voice_addendum))
    end

    test "a forged voice_call on a chat message reaches no seam" do
      {messages, opts} = run_chat_turn(forged_voice_call())

      refute Enum.any?(messages, &(Map.get(&1, :content) == @voice_addendum))
      refute Keyword.has_key?(opts, :parent_session)
      assert "main-" <> _rest = Keyword.fetch!(opts, :session_id)
    end

    test "the turn's history lands in the store the snapshot names" do
      store = start_voice_store()
      key = {"voice", "voice_live_42", :root}

      run_voice_turn(store: store)

      assert [%{role: "user", content: "what is on my calendar"}] =
               ConversationStore.get_history(key, server: store)
    end

    test "the delegation is built without the categories a call cannot deliver" do
      registry = boundary_registry()
      categories = boundary_categories(voice_msg("what is on my calendar"), registry)

      for excluded <- VoiceCall.excluded_categories() do
        refute excluded in categories,
               "a voice delegation must not advertise a #{excluded} capability"
      end

      # The boundary excludes categories, not the whole surface.
      assert :system in categories
    end

    test "a text turn on the same registry still carries every category" do
      registry = boundary_registry()

      msg = %{
        channel: "telegram",
        chat_id: "chat-boundary",
        sender: "user123",
        content: "what is on my calendar",
        source_trust: :operator,
        metadata: %{}
      }

      categories = boundary_categories(msg, registry)

      for category <- [:system | VoiceCall.excluded_categories()] do
        assert category in categories, "a text turn must still advertise #{category}"
      end
    end

    test "the voice prompt and the delegation read one exclusion list" do
      # The M28 lesson, pinned: what the voice model is told about and what its
      # delegation is given come from the same list, so they cannot drift.
      registry = boundary_registry()

      advertised =
        registry
        |> LivePrompt.eligible_capabilities()
        |> Enum.map(& &1.metadata[:category])
        |> Enum.uniq()

      delegated = boundary_categories(voice_msg("what is on my calendar"), registry)

      assert Enum.sort(advertised) == Enum.sort(delegated)
      assert VoiceCall.excluded_categories() == [:channel, :media, :delegation, :harness]
    end

    test "commit skips memory review when the snapshot disables it" do
      assert_review(%{memory_review?: false}, :refute)
    end

    test "commit starts memory review when the snapshot does not disable it" do
      assert_review(%{}, :assert)
    end
  end

  defmodule ReviewSpy do
    @state :turn_runner_review_spy

    def init(test_pid \\ self()) do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> test_pid end, name: @state)
      :ok
    end

    # The agent is linked to the test process that started it, so by the time
    # the next test's `init/1` (or `on_exit`) looks it up it may be mid-exit:
    # `Agent.stop/1` on a name whose process is already gone raises `:noproc`
    # (one CI failure on 2026-09-13). Stop it by pid and wait for the exit
    # instead of trusting the name to stay alive across the call.
    def cleanup do
      case Process.whereis(@state) do
        nil -> :ok
        pid -> stop_and_wait(pid)
      end
    end

    defp stop_and_wait(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> raise "review spy #{inspect(pid)} did not stop"
      end
    end

    def start_background(opts) do
      send(Agent.get(@state, & &1), {:review_started, opts})
      :ok
    end
  end

  defp assert_review(turn_state_overrides, expectation) do
    # Establish the compaction posture this commit runs under rather than
    # inheriting whatever an earlier module left in app env; the module setup
    # restores it.
    Application.put_env(:fermix_core, :compaction, enabled: false)
    :ok = ReviewSpy.init()
    on_exit(&ReviewSpy.cleanup/0)

    store = start_voice_store()
    registry_name = :"tr_review_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry_name}, id: registry_name)

    turn_state =
      [
        adapter: CaptureTurnAdapter,
        adapter_opts: [model: "mock-model", test_pid: self()],
        capability_registry: registry_name,
        conversation_store: store,
        memory_reviewer: ReviewSpy,
        main_agent_server: nil,
        review_interval_hours: 24,
        review_max_messages: 50,
        review_input_token_budget: 1_000,
        review_failure_backoff_ms: 60_000
      ]
      |> turn_state()
      |> Map.merge(turn_state_overrides)

    TurnRunner.commit(
      voice_msg("what is on my calendar"),
      turn_state,
      "the calendar is clear",
      10
    )

    case expectation do
      :assert -> assert_receive {:review_started, _opts}, 5_000
      :refute -> refute_receive {:review_started, _opts}, 200
    end
  end

  # One capability per category the voice boundary names, plus one it keeps, so
  # a turn's advertised categories say exactly which side of the boundary it ran
  # on. Both profiles are built by the REAL builder the cache uses, so the text
  # comparison is the cached path, not a fixture that flatters it.
  defp boundary_registry do
    name = :"tr_boundary_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name}, id: name)

    for category <- [:system | VoiceCall.excluded_categories()] do
      :ok = CapabilityRegistry.register(name, boundary_capability(category))
    end

    name
  end

  defp boundary_capability(category) do
    Capability.new(%{
      name: "boundary_#{category}",
      description: "a #{category} capability",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {CwdRecorder, :execute, [self()]},
      policy_class: :read_only,
      metadata: %{category: category}
    })
  end

  defp boundary_categories(msg, registry) do
    turn_state =
      turn_state(
        adapter: CaptureTurnAdapter,
        adapter_opts: [model: "mock-model", test_pid: self()],
        capability_registry: registry,
        conversation_store: start_voice_store(),
        runtime_context: boundary_runtime_context(registry)
      )

    assert {:ok, "captured", _tokens} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)
    assert_receive {:captured_turn, _messages, capabilities, _opts}, 5_000

    capabilities |> Enum.map(& &1.metadata[:category]) |> Enum.uniq()
  end

  defp boundary_runtime_context(registry) do
    operator = RuntimeContext.build_profile(:operator, [], registry)
    guest = RuntimeContext.build_profile(:guest, [], registry)

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: operator,
      guest_profile: guest,
      harness_free_profiles: %{operator: operator, guest: guest}
    }
  end

  defp run_voice_turn(opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &start_voice_store/0)
    run_capture_turn(voice_msg("what is on my calendar"), store)
  end

  defp run_chat_turn(extra_metadata \\ %{}) do
    msg = %{
      channel: "telegram",
      chat_id: "chat-1",
      sender: "user123",
      content: "what is on my calendar",
      source_trust: :operator,
      metadata: extra_metadata
    }

    run_capture_turn(msg, start_voice_store())
  end

  defp run_capture_turn(msg, store) do
    registry_name = :"tr_voice_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry_name}, id: registry_name)

    turn_state =
      turn_state(
        adapter: CaptureTurnAdapter,
        adapter_opts: [model: "mock-model", test_pid: self()],
        capability_registry: registry_name,
        conversation_store: store
      )

    assert {:ok, "captured", _tokens} = TurnRunner.run(msg, turn_state, fn _part -> :ok end)
    assert_receive {:captured_turn, messages, _capabilities, opts}, 5_000
    {messages, opts}
  end

  defp start_voice_store do
    name = :"tr_voice_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ConversationStore, name: name, max_messages: 128, repo: nil},
      id: name
    )
  end

  defp voice_msg(content) do
    %{
      channel: "voice",
      chat_id: "voice_live_42",
      sender: "voice",
      content: content,
      source_trust: :operator,
      metadata: %{source: :voice, user_id: "voice", chat_type: "private"}
    }
    |> put_in([:metadata, :voice_call], voice_call())
  end

  defp forged_voice_call, do: %{source: :telegram, voice_call: voice_call()}

  defp voice_call do
    %{
      call_id: "voice_live_42",
      delegation_id: "d-1",
      revision: 1,
      turn_session_id: "voice_delegation_7",
      conversation_store: ConversationStore,
      prompt_addendum: @voice_addendum,
      persist?: false
    }
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
