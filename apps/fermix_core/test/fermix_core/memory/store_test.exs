defmodule FermixCore.Memory.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Store

  setup do
    {:ok, pid} = Store.start_link(name: :"store_#{System.unique_integer([:positive])}")
    %{store: pid}
  end

  describe "store/4 and recall/3" do
    test "stores and recalls a value", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      assert :ok = Store.store(conv_key, "user_name", "Alice", server: store)
      assert {:ok, "Alice"} = Store.recall(conv_key, "user_name", server: store)
    end

    test "overwrites existing key", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      Store.store(conv_key, "lang", "en", server: store)
      Store.store(conv_key, "lang", "fr", server: store)
      assert {:ok, "fr"} = Store.recall(conv_key, "lang", server: store)
    end

    test "returns error for missing key", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      assert {:error, :not_found} = Store.recall(conv_key, "missing", server: store)
    end

    test "isolates memories across conversations", %{store: store} do
      conv_a = {"telegram", "chat_a"}
      conv_b = {"telegram", "chat_b"}

      Store.store(conv_a, "key", "value_a", server: store)
      Store.store(conv_b, "key", "value_b", server: store)

      assert {:ok, "value_a"} = Store.recall(conv_a, "key", server: store)
      assert {:ok, "value_b"} = Store.recall(conv_b, "key", server: store)
    end
  end

  describe "recall_all/2" do
    test "returns all memories for a conversation", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      Store.store(conv_key, "name", "Alice", server: store)
      Store.store(conv_key, "lang", "en", server: store)

      memories = Store.recall_all(conv_key, server: store)
      assert is_map(memories)
      assert memories["name"] == "Alice"
      assert memories["lang"] == "en"
    end

    test "returns empty map for unknown conversation", %{store: store} do
      assert %{} = Store.recall_all({"telegram", "unknown"}, server: store)
    end

    test "does not leak memories across conversations", %{store: store} do
      conv_a = {"telegram", "chat_a"}
      conv_b = {"telegram", "chat_b"}
      Store.store(conv_a, "secret", "a_val", server: store)
      Store.store(conv_b, "other", "b_val", server: store)

      memories_a = Store.recall_all(conv_a, server: store)
      assert Map.keys(memories_a) == ["secret"]
    end
  end

  describe "delete/3" do
    test "removes a stored key", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      Store.store(conv_key, "key", "value", server: store)
      assert :ok = Store.delete(conv_key, "key", server: store)
      assert {:error, :not_found} = Store.recall(conv_key, "key", server: store)
    end

    test "is a no-op for missing key", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      assert :ok = Store.delete(conv_key, "nonexistent", server: store)
    end

    test "does not affect other keys", %{store: store} do
      conv_key = {"telegram", "chat_1"}
      Store.store(conv_key, "keep", "yes", server: store)
      Store.store(conv_key, "remove", "no", server: store)

      Store.delete(conv_key, "remove", server: store)

      assert {:ok, "yes"} = Store.recall(conv_key, "keep", server: store)
      assert {:error, :not_found} = Store.recall(conv_key, "remove", server: store)
    end
  end
end
