defmodule FermixCore.Memory.ConversationStoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @key {"telegram", "chat_123", :root}
  @key2 {"discord", "chat_456", :root}

  setup do
    name = :"conv_store_#{System.unique_integer([:positive])}"
    start_supervised!({ConversationStore, name: name, max_messages: 5})
    %{store: name}
  end

  defp sync(store), do: :sys.get_state(store)

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
          File.rm(path)
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
      store: store
    } do
      for i <- 1..8 do
        ConversationStore.add_message(@key, "user", "msg_#{i}", server: store)
      end

      sync(store)

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
  end
end
