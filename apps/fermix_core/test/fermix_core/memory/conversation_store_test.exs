defmodule FermixCore.Memory.ConversationStoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore

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
end
