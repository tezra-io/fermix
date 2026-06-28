defmodule FermixCore.Memory.ConversationStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  defmodule FlakyRepo do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         failures_remaining: Keyword.get(opts, :failures_remaining, 0)
       }}
    end

    @impl true
    def handle_call(:enabled?, _from, state), do: {:reply, true, state}

    def handle_call({:insert_message, attrs}, _from, state) do
      send(state.test_pid, {:insert_attempt, attrs.role, attrs.content})

      if state.failures_remaining > 0 do
        {:reply, {:error, :disk_busy},
         %{state | failures_remaining: state.failures_remaining - 1}}
      else
        {:reply, {:ok, Map.put(attrs, :id, state.failures_remaining)}, state}
      end
    end
  end

  defmodule BlockingRepo do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), next_id: 0}}
    end

    @impl true
    def handle_call(:enabled?, _from, state), do: {:reply, true, state}

    def handle_call({:delete_messages, selector}, _from, state) do
      send(state.test_pid, {:delete_started, self(), selector})

      receive do
        :continue_delete -> :ok
      end

      {:reply, :ok, state}
    end

    def handle_call({:insert_message, attrs}, _from, state) do
      next_id = state.next_id + 1
      send(state.test_pid, {:insert_message, attrs.content})
      {:reply, {:ok, Map.put(attrs, :id, next_id)}, %{state | next_id: next_id}}
    end
  end

  @key {"telegram", "chat_123", :root}
  @key2 {"discord", "chat_456", :root}

  setup do
    name = :"conv_store_#{System.unique_integer([:positive])}"
    start_supervised!({ConversationStore, name: name, max_messages: 5, repo: nil})
    %{store: name}
  end

  defp sync(store), do: :sys.get_state(store)

  defp wait_for_message_count(repo, selector, expected, attempts \\ 50)

  defp wait_for_message_count(repo, selector, expected, attempts) when attempts > 0 do
    case Repo.message_count(selector, server: repo) do
      {:ok, ^expected} ->
        :ok

      _other ->
        Process.sleep(10)
        wait_for_message_count(repo, selector, expected, attempts - 1)
    end
  end

  defp wait_for_message_count(repo, selector, expected, 0) do
    flunk("timed out waiting for #{expected} persisted messages: #{inspect({repo, selector})}")
  end

  defp chat_selector(key) do
    %{
      agent_id: "main",
      channel: elem(key, 0),
      chat_id: elem(key, 1),
      thread_scope: elem(key, 2),
      kind: "chat_message"
    }
  end

  # --- add_message + get_history ---

  test "stores a message and retrieves it", %{store: store} do
    ConversationStore.add_message(@key, "user", "hello", server: store)
    sync(store)

    history = ConversationStore.get_history(@key, server: store)
    assert [%{role: "user", content: "hello", timestamp: %DateTime{}}] = history
  end

  test "returns messages in chronological order (oldest first)", %{store: store} do
    ConversationStore.add_message(@key, "user", "first", server: store)
    ConversationStore.add_message(@key, "assistant", "second", server: store)
    ConversationStore.add_message(@key, "user", "third", server: store)
    sync(store)

    history = ConversationStore.get_history(@key, server: store)
    assert ["first", "second", "third"] == Enum.map(history, & &1.content)
  end

  test "drops a content-less turn of any role instead of storing it", %{store: store} do
    ConversationStore.add_message(@key, "user", "are you there?", server: store)
    # An empty model completion...
    assert :ok = ConversationStore.add_message(@key, "assistant", "", server: store)
    assert :ok = ConversationStore.add_message(@key, "assistant", "   \n  ", server: store)
    # ...and a captionless image upload (image rides transiently, content is "").
    assert :ok = ConversationStore.add_message(@key, "user", "", server: store)
    ConversationStore.add_message(@key, "user", "still there?", server: store)
    sync(store)

    # No blank turn enters history (replayed, an empty text block 400s Anthropic
    # with "text content blocks must be non-empty"); the real turns remain.
    history = ConversationStore.get_history(@key, server: store)
    assert ["are you there?", "still there?"] == Enum.map(history, & &1.content)
  end

  test "returns empty list for unknown conversation", %{store: store} do
    assert [] == ConversationStore.get_history({"unknown", "key", :root}, server: store)
  end

  test "isolates conversations by key", %{store: store} do
    ConversationStore.add_message(@key, "user", "msg1", server: store)
    ConversationStore.add_message(@key2, "user", "msg2", server: store)
    sync(store)

    assert [%{content: "msg1"}] = ConversationStore.get_history(@key, server: store)
    assert [%{content: "msg2"}] = ConversationStore.get_history(@key2, server: store)
  end

  # --- append_stopped_marker (stopped-turn marker) ---

  test "append_stopped_marker closes an orphaned user turn with an assistant marker",
       %{store: store} do
    ConversationStore.add_message(@key, "user", "the stopped question", server: store)
    sync(store)

    assert :marked = ConversationStore.append_stopped_marker(@key, "[stopped]", server: store)
    sync(store)

    history = ConversationStore.get_history(@key, server: store)

    assert [
             %{role: "user", content: "the stopped question"},
             %{role: "assistant", content: "[stopped]"}
           ] = history
  end

  test "append_stopped_marker skips when the last message is not a user turn",
       %{store: store} do
    ConversationStore.add_message(@key, "user", "answered question", server: store)
    ConversationStore.add_message(@key, "assistant", "the answer", server: store)
    sync(store)

    assert :skipped = ConversationStore.append_stopped_marker(@key, "[stopped]", server: store)
    sync(store)

    history = ConversationStore.get_history(@key, server: store)
    assert ["answered question", "the answer"] == Enum.map(history, & &1.content)
  end

  test "append_stopped_marker skips when the conversation has no history", %{store: store} do
    assert :skipped = ConversationStore.append_stopped_marker(@key, "[stopped]", server: store)
    assert [] == ConversationStore.get_history(@key, server: store)
  end

  # --- Rolling window / compaction ---

  test "compacts messages when over max_messages limit", %{store: store} do
    for i <- 1..8 do
      ConversationStore.add_message(@key, "user", "msg_#{i}", server: store)
    end

    sync(store)

    history = ConversationStore.get_history(@key, server: store)
    assert length(history) == 5
    # Oldest dropped, newest kept
    assert "msg_4" == hd(history).content
    assert "msg_8" == List.last(history).content
  end

  test "replace_history swaps the cached conversation atomically", %{store: store} do
    ConversationStore.add_message(@key, "user", "old one", server: store)
    ConversationStore.add_message(@key, "assistant", "old two", server: store)

    assert :ok =
             ConversationStore.replace_history(
               @key,
               [
                 %{role: "system", content: "Conversation checkpoint summary:\nold one/two"},
                 %{role: "user", content: "latest question"}
               ],
               server: store
             )

    history = ConversationStore.get_history(@key, server: store)

    assert Enum.map(history, & &1.content) == [
             "Conversation checkpoint summary:\nold one/two",
             "latest question"
           ]
  end

  # --- get_history with limit ---

  test "get_history respects limit parameter", %{store: store} do
    for i <- 1..5 do
      ConversationStore.add_message(@key, "user", "msg_#{i}", server: store)
    end

    sync(store)

    history = ConversationStore.get_history(@key, 3, server: store)
    assert length(history) == 3
    # Returns the 3 most recent
    assert ["msg_3", "msg_4", "msg_5"] == Enum.map(history, & &1.content)
  end

  # --- clear ---

  test "clear removes conversation history", %{store: store} do
    ConversationStore.add_message(@key, "user", "hello", server: store)
    sync(store)

    ConversationStore.clear(@key, server: store)
    sync(store)

    assert [] == ConversationStore.get_history(@key, server: store)
  end

  test "clear does not affect other conversations", %{store: store} do
    ConversationStore.add_message(@key, "user", "msg1", server: store)
    ConversationStore.add_message(@key2, "user", "msg2", server: store)
    sync(store)

    ConversationStore.clear(@key, server: store)
    sync(store)

    assert [] == ConversationStore.get_history(@key, server: store)
    assert [%{content: "msg2"}] = ConversationStore.get_history(@key2, server: store)
  end

  # --- list_conversations ---

  test "list_conversations returns active keys", %{store: store} do
    ConversationStore.add_message(@key, "user", "hi", server: store)
    ConversationStore.add_message(@key2, "user", "hey", server: store)
    sync(store)

    keys = ConversationStore.list_conversations(server: store)
    assert Enum.sort(keys) == Enum.sort([@key, @key2])
  end

  test "list_conversations returns empty when no conversations", %{store: store} do
    assert [] == ConversationStore.list_conversations(server: store)
  end

  test "cleared conversation removed from list", %{store: store} do
    ConversationStore.add_message(@key, "user", "hi", server: store)
    sync(store)

    ConversationStore.clear(@key, server: store)
    sync(store)

    assert [] == ConversationStore.list_conversations(server: store)
  end

  # --- Telemetry ---

  test "emits telemetry on add_message", %{store: store} do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:fermix, :memory, :message]
      ])

    ConversationStore.add_message(@key, "user", "hello", server: store)
    sync(store)

    assert_received {[:fermix, :memory, :message], ^ref, %{count: 1},
                     %{channel: "telegram", chat_id: "chat_123"}}
  end

  test "telemetry includes synchronous write latency", %{store: store} do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:fermix, :memory, :message]
      ])

    ConversationStore.add_message(@key, "user", "hello", server: store)

    assert_received {[:fermix, :memory, :message], ^ref, measurements, metadata}
    assert measurements.count == 1
    assert is_integer(measurements.duration_us)
    assert measurements.duration_us >= 0
    assert measurements.durable_write_us == 0
    assert metadata.durable? == false
  end

  test "falls back to memory when configured repo name is no longer registered", %{store: store} do
    repo_name = :"missing_conversation_repo_#{System.unique_integer([:positive])}"

    :sys.replace_state(store, fn state -> %{state | repo: repo_name} end)

    ConversationStore.add_message(@key, "user", "hello", server: store)
    assert [%{content: "hello"}] = ConversationStore.get_history(@key, server: store)
  end

  # --- Guards ---

  test "rejects non-tuple conversation key", %{store: store} do
    assert_raise FunctionClauseError, fn ->
      apply(ConversationStore, :add_message, ["bad_key", "user", "hi", [server: store]])
    end
  end

  test "rejects non-string role", %{store: store} do
    assert_raise FunctionClauseError, fn ->
      ConversationStore.add_message(@key, :user, "hi", server: store)
    end
  end

  test "rejects non-string content", %{store: store} do
    assert_raise FunctionClauseError, fn ->
      ConversationStore.add_message(@key, "user", 123, server: store)
    end
  end

  describe "durable persistence" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-conversation-store-#{unique}.db")
      repo_name = :"conversation_repo_#{unique}"
      store_name = :"conversation_store_#{unique}"

      start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

      start_supervised!(%{
        id: store_name,
        start:
          {ConversationStore, :start_link, [[name: store_name, max_messages: 5, repo: repo_name]]}
      })

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
          FermixTestSupport.SafeRm.rm(path)
        end)
      end)

      %{repo: repo_name, store: store_name}
    end

    test "reloads conversation history from sqlite after the store restarts", %{
      repo: repo,
      store: store
    } do
      ConversationStore.add_message(@key, "user", "hello", server: store)
      ConversationStore.add_message(@key, "assistant", "hi there", server: store)
      sync(store)
      wait_for_message_count(repo, chat_selector(@key), 2)

      assert :ok = GenServer.stop(store)

      restarted = :"conversation_store_restarted_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: restarted,
        start: {ConversationStore, :start_link, [[name: restarted, max_messages: 5, repo: repo]]}
      })

      history = ConversationStore.get_history(@key, server: restarted)
      assert ["hello", "hi there"] == Enum.map(history, & &1.content)
    end

    test "backfills persisted history after cache eviction while keeping a rolling hot window", %{
      repo: repo,
      store: store
    } do
      for i <- 1..8 do
        ConversationStore.add_message(@key, "user", "msg_#{i}", server: store)
      end

      sync(store)
      wait_for_message_count(repo, chat_selector(@key), 8)

      :sys.replace_state(store, fn state ->
        %{state | conversations: %{}}
      end)

      history = ConversationStore.get_history(@key, 8, server: store)
      assert Enum.map(history, & &1.content) == Enum.map(1..8, &"msg_#{&1}")

      cached = :sys.get_state(store).conversations[@key]
      assert length(cached) == 5
      assert Enum.map(Enum.reverse(cached), & &1.content) == Enum.map(4..8, &"msg_#{&1}")
    end

    test "excludes checkpoint summaries from chat history backfill", %{
      repo: repo,
      store: store
    } do
      ConversationStore.add_message(@key, "user", "visible chat", server: store)
      wait_for_message_count(repo, chat_selector(@key), 1)

      assert {:ok, _checkpoint} =
               Repo.insert_message(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   channel: elem(@key, 0),
                   chat_id: elem(@key, 1),
                   thread_scope: elem(@key, 2),
                   sender: "compactor",
                   role: "system",
                   kind: "checkpoint_summary",
                   content: "hidden checkpoint"
                 },
                 server: repo
               )

      :sys.replace_state(store, fn state ->
        %{state | conversations: %{}}
      end)

      history = ConversationStore.get_history(@key, 5, server: store)
      assert Enum.map(history, & &1.content) == ["visible chat"]
    end

    test "excludes content-less turns persisted before the write guard", %{
      repo: repo,
      store: store
    } do
      ConversationStore.add_message(@key, "user", "before", server: store)
      wait_for_message_count(repo, chat_selector(@key), 1)

      # Simulate poisoned rows written by an older build (the write guard would
      # reject them today): a blank assistant completion AND a captionless image
      # user turn. On backfill both must be dropped, not replayed.
      for {sender, role} <- [{"main", "assistant"}, {"Sujeeth", "user"}] do
        assert {:ok, _blank} =
                 Repo.insert_message(
                   %{
                     agent_id: "main",
                     owner_id: "default",
                     channel: elem(@key, 0),
                     chat_id: elem(@key, 1),
                     thread_scope: elem(@key, 2),
                     sender: sender,
                     role: role,
                     kind: "chat_message",
                     content: ""
                   },
                   server: repo
                 )
      end

      ConversationStore.add_message(@key, "user", "after", server: store)
      wait_for_message_count(repo, chat_selector(@key), 4)

      :sys.replace_state(store, fn state ->
        %{state | conversations: %{}}
      end)

      history = ConversationStore.get_history(@key, 5, server: store)
      assert Enum.map(history, & &1.content) == ["before", "after"]
    end

    test "telemetry marks durable enqueue and async sqlite persistence", %{
      store: store
    } do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:fermix, :memory, :message],
          [:fermix, :memory, :message_persist]
        ])

      ConversationStore.add_message(@key, "user", "hello", server: store)

      assert_received {[:fermix, :memory, :message], ^ref, measurements, metadata}
      assert measurements.count == 1
      assert is_integer(measurements.duration_us)
      assert measurements.durable_write_us == 0
      assert metadata.durable? == true

      assert_receive {[:fermix, :memory, :message_persist], ^ref, persist_measurements,
                      persist_metadata}

      assert persist_measurements.count == 1
      assert is_integer(persist_measurements.duration_us)
      assert persist_metadata.status == :ok
      assert persist_metadata.attempt == 1
    end

    test "replace_history swaps sqlite-backed chat history", %{repo: repo, store: store} do
      ConversationStore.add_message(@key, "user", "old", server: store)
      wait_for_message_count(repo, chat_selector(@key), 1)

      assert :ok =
               ConversationStore.replace_history(
                 @key,
                 [
                   %{role: "system", content: "Conversation checkpoint summary:\nold"},
                   %{role: "user", content: "new"}
                 ],
                 server: store
               )

      assert Enum.map(ConversationStore.get_history(@key, server: store), & &1.content) == [
               "Conversation checkpoint summary:\nold",
               "new"
             ]

      wait_for_message_count(repo, chat_selector(@key), 2)

      assert {:ok, rows} = Repo.get_messages(chat_selector(@key), server: repo, limit: 10)
      assert Enum.map(rows, & &1.content) == ["Conversation checkpoint summary:\nold", "new"]
    end

    test "replace_history returns after cache update while durable replacement runs async" do
      repo = start_supervised!({BlockingRepo, test_pid: self()})
      store = :"conversation_store_async_replace_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: store,
        start:
          {ConversationStore, :start_link,
           [[name: store, max_messages: 5, repo: repo, durable_task_supervisor: nil]]}
      })

      task =
        Task.async(fn ->
          ConversationStore.replace_history(
            @key,
            [
              %{role: "system", content: "Conversation checkpoint summary:\nold"},
              %{role: "user", content: "new"}
            ],
            server: store
          )
        end)

      assert_receive {:delete_started, ^repo, _selector}

      result_before_release = Task.yield(task, 100)

      assert Enum.map(ConversationStore.get_history(@key, server: store), & &1.content) == [
               "Conversation checkpoint summary:\nold",
               "new"
             ]

      send(repo, :continue_delete)
      _result_after_release = result_before_release || Task.await(task, 1_000)

      assert_receive {:insert_message, "Conversation checkpoint summary:\nold"}
      assert_receive {:insert_message, "new"}

      assert result_before_release == {:ok, :ok}
    end

    test "keeps in-memory history and returns when durable write fails", %{store: _store} do
      repo = start_supervised!({FlakyRepo, test_pid: self(), failures_remaining: 10})
      store = :"conversation_store_flaky_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: store,
        start:
          {ConversationStore, :start_link,
           [
             [
               name: store,
               max_messages: 5,
               repo: repo,
               durable_max_attempts: 1,
               durable_retry_initial_ms: 0
             ]
           ]}
      })

      log =
        capture_log(fn ->
          assert :ok =
                   ConversationStore.add_message(@key, "user", "do not block reply",
                     server: store
                   )

          assert [%{content: "do not block reply"}] =
                   ConversationStore.get_history(@key, server: store)

          assert_receive {:insert_attempt, "user", "do not block reply"}
          Process.sleep(10)
        end)

      assert log =~ "conversation durable write failed after 1 attempts"
    end

    test "supervisor-start failure surfaces as durable? false + error log + no fallback insert",
         %{store: _store} do
      repo = start_supervised!({FlakyRepo, test_pid: self(), failures_remaining: 0})
      store = :"conversation_store_no_sup_#{System.unique_integer([:positive])}"
      chat_id = "chat_no_sup_#{System.unique_integer([:positive])}"
      key = {"telegram", chat_id, :root}

      # Pass a non-existent supervisor atom so Task.Supervisor.start_child/2
      # exits and start_persist_task/2 has to surface the failure.
      missing_supervisor = :"conversation_store_missing_sup_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: store,
        start:
          {ConversationStore, :start_link,
           [
             [
               name: store,
               max_messages: 5,
               repo: repo,
               durable_max_attempts: 1,
               durable_retry_initial_ms: 0,
               durable_task_supervisor: missing_supervisor
             ]
           ]}
      })

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:fermix, :memory, :message]])

      log =
        capture_log(fn ->
          assert :ok =
                   ConversationStore.add_message(key, "user", "no sup here", server: store)
        end)

      assert_receive {[:fermix, :memory, :message], ^ref, _measurements,
                      %{channel: "telegram", chat_id: ^chat_id, durable?: false}}

      assert log =~ "failed to start conversation durable write task"
      assert log =~ "task_supervisor_exit"

      # No async task should have run, so FlakyRepo never received an insert.
      refute_received {:insert_attempt, "user", "no sup here"}
    end

    test "retries async durable writes after transient failure", %{store: _store} do
      repo = start_supervised!({FlakyRepo, test_pid: self(), failures_remaining: 1})
      store = :"conversation_store_retry_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: store,
        start:
          {ConversationStore, :start_link,
           [
             [
               name: store,
               max_messages: 5,
               repo: repo,
               durable_max_attempts: 2,
               durable_retry_initial_ms: 0
             ]
           ]}
      })

      log =
        capture_log(fn ->
          assert :ok = ConversationStore.add_message(@key, "assistant", "retry me", server: store)
          assert_receive {:insert_attempt, "assistant", "retry me"}
          assert_receive {:insert_attempt, "assistant", "retry me"}
        end)

      assert log =~ "conversation durable write failed; retrying attempt 2/2"
    end
  end
end
