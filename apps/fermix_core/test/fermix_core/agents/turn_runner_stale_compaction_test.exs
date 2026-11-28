defmodule FermixCore.Agents.TurnRunnerStaleCompactionTest do
  @moduledoc """
  An auto-compaction reads the conversation, spends seconds on a model call,
  then replaces the history with what it made of that read. A message written
  into the conversation in that window, outside any turn (an open-loop
  check-in, M106 §5.8), must still be there afterwards, in memory and in the
  database: a compaction whose read is stale is never committed. It is dropped,
  said in the log and in `[:fermix, :compaction, :auto_skipped]`, and the next
  reply's check compacts again.

  The window is driven by injection: the compaction's model call writes the
  message before it answers. Both auto-compaction paths are covered, the one
  after delivery (`commit/4`) and the preflight one before the main call
  (`run/3`).
  """

  # Sets the global `:compaction` app env, so no other test may run beside it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.TelemetryCapture

  @check_in "A check-in: did the Port Alder ferry work out on Saturday?"
  @stale_log "auto-compaction was not committed"

  # SQLite work behind a loaded runner's file-server queue.
  @durable_write_wait_ms 10_000

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

    def handle_call({:record_auto_compaction_failure, key, _failed_at_ms}, _from, state) do
      send(state.test_pid, {:compaction_failure_recorded, key})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:clear_auto_compaction_failure, key}, state) do
      send(state.test_pid, {:compaction_failure_cleared, key})
      {:noreply, state}
    end

    def handle_cast({:record_context_tokens, _key, _tokens}, state), do: {:noreply, state}
  end

  # The compaction's model call writes `@check_in` into the conversation once,
  # the way `OpenLoops.CheckIn` does, before it answers; any other call is the
  # turn's main call.
  defmodule InterleavingAdapter do
    @behaviour FermixCore.Providers.Adapter

    alias FermixCore.Memory.ConversationStore

    @impl true
    def chat(messages, _capabilities, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      text = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

      if String.contains?(text, "Older messages:") do
        send(test_pid, {:summary_call, text})
        write_once(Keyword.get(opts, :interleave))
        turn("Summary: the owner is planning a Saturday ferry from Port Alder.", 12)
      else
        send(test_pid, {:main_call, text})
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

    defp write_once(nil), do: :ok

    defp write_once(%{once: once, store: store, key: key, text: text}) do
      if :atomics.compare_exchange(once, 1, 0, 1) == :ok do
        :ok =
          ConversationStore.add_message(key, "assistant", text,
            kind: "chat_message",
            metadata: %{open_loop_checkin: 7},
            server: store
          )
      end

      :ok
    end

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

  setup do
    previous = Application.fetch_env(:fermix_core, :compaction)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_core, :compaction, value)
        :error -> Application.delete_env(:fermix_core, :compaction)
      end
    end)

    # mock-model's window is 100_000 tokens, so 0.1 puts the trigger at 10_000.
    Application.put_env(:fermix_core, :compaction,
      enabled: true,
      threshold: 0.1,
      reasoning_effort: :medium
    )

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-stale-compaction-#{unique}.db")
    repo = :"stale_compaction_repo_#{unique}"
    tasks = :"stale_compaction_tasks_#{unique}"
    store = :"stale_compaction_store_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    start_supervised!(
      {ConversationStore,
       name: store,
       max_messages: :infinity,
       repo: repo,
       durable_task_supervisor: tasks,
       agent_id: "main",
       owner_id: "default"},
      id: store
    )

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    chat_id = "stale_compaction_#{unique}"
    key = {"telegram", chat_id, :root}

    TelemetryCapture.attach(
      [[:fermix, :compaction, :auto], [:fermix, :compaction, :auto_skipped]],
      conversation_key: key
    )

    %{repo: repo, tasks: tasks, store: store, chat_id: chat_id, key: key}
  end

  test "a message written while the post-delivery compaction runs is still there after it",
       ctx do
    older = String.duplicate("older harbour planning ", 25_000)
    :ok = ConversationStore.add_message(ctx.key, "user", older, server: ctx.store)
    main_agent = start_supervised!({MainAgentStub, test_pid: self()})

    {result, log} =
      with_log(fn ->
        TurnRunner.commit(
          message(ctx.chat_id, "latest question"),
          commit_state(ctx, main_agent, interleave(ctx)),
          "assistant reply",
          50_000
        )
      end)

    assert_receive {:summary_call, _text}

    assert contents(ConversationStore.get_history(ctx.key, server: ctx.store)) ==
             [older, "assistant reply", @check_in]

    await_durable_writes(ctx.tasks)
    assert durable_contents(ctx) == [older, "assistant reply", @check_in]

    assert result == :ok
    assert_receive {:telemetry, [:fermix, :compaction, :auto_skipped], _, %{reason: reason}}
    assert reason == :stale_history
    refute_received {:telemetry, [:fermix, :compaction, :auto], _, _}
    assert log =~ @stale_log

    # A stale read is not a failure: no backoff is recorded, nothing was
    # compacted, so the runtime context stands.
    refute_received {:compaction_failure_recorded, _key}
    refute_received {:runtime_invalidated, :compaction}

    # The next reply's check compacts again, and its read has the message.
    assert :compacted =
             TurnRunner.commit(
               message(ctx.chat_id, "and the return trip?"),
               commit_state(ctx, main_agent, nil),
               "second reply",
               50_000
             )

    assert_receive {:summary_call, _second_text}
    assert_receive {:telemetry, [:fermix, :compaction, :auto], _, _}
    history = contents(ConversationStore.get_history(ctx.key, server: ctx.store))
    refute older in history
    assert Enum.take(history, -2) == [@check_in, "second reply"]
  end

  test "a message written while the preflight compaction runs is still there after it", ctx do
    old = String.duplicate("old harbour context ", 25_000)
    :ok = ConversationStore.add_message(ctx.key, "user", old, server: ctx.store)
    :ok = ConversationStore.add_message(ctx.key, "assistant", "old answer", server: ctx.store)

    registry = :"stale_compaction_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)
    test_pid = self()
    deliver = fn {:text, text} -> send(test_pid, {:delivered, text}) end

    {result, log} =
      with_log(fn ->
        TurnRunner.run(
          message(ctx.chat_id, "latest question"),
          run_state(ctx, registry, interleave(ctx)),
          deliver
        )
      end)

    assert {:ok, "assistant after preflight", _context_tokens} = result
    assert_receive {:summary_call, _text}

    assert contents(ConversationStore.get_history(ctx.key, server: ctx.store)) ==
             [old, "old answer", @check_in, "latest question"]

    await_durable_writes(ctx.tasks)
    assert durable_contents(ctx) == [old, "old answer", @check_in, "latest question"]

    assert_receive {:telemetry, [:fermix, :compaction, :auto_skipped], _, %{reason: reason}}
    assert reason == :stale_history
    refute_received {:telemetry, [:fermix, :compaction, :auto], _, _}
    assert log =~ @stale_log

    # Nothing was trimmed, so the owner is not told it was; the turn ran on
    # the history it read.
    assert_receive {:main_call, main_text}
    assert main_text =~ old
    refute_received {:delivered, "Trimmed older conversation history" <> _rest}
  end

  defp interleave(ctx) do
    %{once: :atomics.new(1, []), store: ctx.store, key: ctx.key, text: @check_in}
  end

  defp message(chat_id, content) do
    %{
      channel: "telegram",
      chat_id: chat_id,
      sender: "user",
      content: content,
      source_trust: :operator
    }
  end

  defp adapter_opts(interleave) do
    [model: "mock-model", test_pid: self(), interleave: interleave]
  end

  defp commit_state(ctx, main_agent, interleave) do
    %{
      adapter: InterleavingAdapter,
      adapter_opts: adapter_opts(interleave),
      provider: nil,
      adapter_overrides: [],
      conversation_store: ctx.store,
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
  end

  defp run_state(ctx, registry, interleave) do
    %{
      adapter: InterleavingAdapter,
      adapter_opts: adapter_opts(interleave),
      provider: nil,
      adapter_overrides: [],
      capability_registry: registry,
      conversation_store: ctx.store,
      runtime_context: runtime_context(),
      memory_agent_id: "main",
      memory_owner_id: "default",
      skill_registry: nil,
      agent_supervisor: nil,
      task_supervisor: self(),
      journal_base_dir: nil,
      memory_store: nil,
      memory_repo: nil,
      # The prior turn's real peak, over the 10_000 trigger.
      last_context_tokens: 50_000
    }
  end

  defp runtime_context do
    profile = %{
      trust: :operator,
      capabilities: [],
      runtime_message: %{role: "system", content: "runtime contract"},
      runtime_accounting: %{part: :runtime}
    }

    guest = %{profile | trust: :guest}

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: profile,
      guest_profile: guest,
      harness_free_profiles: %{operator: profile, guest: guest}
    }
  end

  # Every durable write starts as a child of the test's task supervisor inside
  # the store's own call, so once that call returns, its write is listed there
  # or has already finished.
  defp await_durable_writes(tasks) do
    Enum.each(Task.Supervisor.children(tasks), fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @durable_write_wait_ms
    end)
  end

  defp durable_contents(ctx) do
    {channel, chat_id, thread_scope} = ctx.key

    selector = %{
      agent_id: "main",
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope,
      kind: "chat_message"
    }

    {:ok, rows} = Repo.get_messages(selector, limit: 100, server: ctx.repo)
    contents(rows)
  end

  defp contents(messages), do: Enum.map(messages, & &1.content)
end
