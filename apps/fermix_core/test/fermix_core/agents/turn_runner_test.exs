defmodule FermixCore.Agents.TurnRunnerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
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

  setup do
    compaction = Application.get_env(:fermix_core, :compaction, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :compaction, compaction)
    end)

    :ok
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
        extraction_timeout_ms: 1_000,
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
        extraction_timeout_ms: 1_000,
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
          conversation_store: store
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

      assert reply =~ "xAI"
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

  defp runtime_context do
    operator_profile = runtime_profile(:operator)
    guest_profile = runtime_profile(:guest)

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      base_accounting: [],
      available_skills: [],
      operator_profile: operator_profile,
      guest_profile: guest_profile
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
