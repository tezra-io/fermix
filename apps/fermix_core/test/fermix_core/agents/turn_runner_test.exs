defmodule FermixCore.Agents.TurnRunnerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Memory.ConversationStore

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

  setup do
    compaction = Application.get_env(:fermix_core, :compaction, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :compaction, compaction)
    end)

    :ok
  end

  describe "commit/4" do
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

    test "falls back to the generic message for unrelated errors" do
      reply = TurnRunner.error_reply("some unexpected failure")

      assert reply =~ "Sorry"
      refute reply =~ "/new"
    end
  end
end
