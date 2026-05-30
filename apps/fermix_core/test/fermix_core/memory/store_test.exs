defmodule FermixCore.Memory.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
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

    test "isolates memories across thread-aware conversation keys", %{store: store} do
      root_key = {"discord", "channel_1", :root}
      thread_key = {"discord", "channel_1", "message_1"}

      Store.store(root_key, "topic", "root", server: store)
      Store.store(thread_key, "topic", "thread", server: store)

      assert {:ok, "root"} = Store.recall(root_key, "topic", server: store)
      assert {:ok, "thread"} = Store.recall(thread_key, "topic", server: store)
    end

    test "keeps legacy and thread-aware root keys in separate namespaces", %{store: store} do
      legacy_key = {"telegram", "chat_1"}
      root_key = {"telegram", "chat_1", :root}

      Store.store(legacy_key, "topic", "legacy", server: store)
      Store.store(root_key, "topic", "root", server: store)

      assert {:ok, "legacy"} = Store.recall(legacy_key, "topic", server: store)
      assert {:ok, "root"} = Store.recall(root_key, "topic", server: store)
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

  test "falls back to ETS when configured repo name is no longer registered", %{store: store} do
    repo_name = :"missing_store_repo_#{System.unique_integer([:positive])}"

    :sys.replace_state(store, fn state -> %{state | repo: repo_name} end)

    assert :ok = Store.store({"telegram", "chat_1"}, "name", "Alice", server: store)
    assert {:ok, "Alice"} = Store.recall({"telegram", "chat_1"}, "name", server: store)
    assert %{"name" => "Alice"} = Store.recall_all({"telegram", "chat_1"}, server: store)
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

  describe "durable persistence" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-store-#{unique}.db")
      repo_name = :"store_repo_#{unique}"
      store_name = :"store_durable_#{unique}"

      start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

      start_supervised!(%{
        id: store_name,
        start: {Store, :start_link, [[name: store_name, repo: repo_name]]}
      })

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
          FermixTestSupport.SafeRm.rm(path)
        end)
      end)

      %{repo: repo_name, store: store_name}
    end

    test "reloads memories from sqlite after the store restarts", %{repo: repo, store: store} do
      conv_key = {"telegram", "chat_1", :root}

      assert :ok = Store.store(conv_key, "user_name", "Alice", server: store)
      assert :ok = GenServer.stop(store)

      restarted = :"store_restarted_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: restarted,
        start: {Store, :start_link, [[name: restarted, repo: repo]]}
      })

      assert {:ok, "Alice"} = Store.recall(conv_key, "user_name", server: restarted)
      assert %{"user_name" => "Alice"} = Store.recall_all(conv_key, server: restarted)
    end

    test "recall/3 reloads a single key from sqlite after cache eviction", %{store: store} do
      conv_key = {"telegram", "chat_1", :root}

      assert :ok = Store.store(conv_key, "user_name", "Alice", server: store)

      evict_store_cache(store)

      assert {:ok, "Alice"} = Store.recall(conv_key, "user_name", server: store)
    end

    test "persists owner and agent scoped memories across restart", %{repo: repo, store: store} do
      assert :ok = Store.store({:owner, "default"}, "timezone", "UTC", server: store)
      assert :ok = Store.store({:agent, "main"}, "workspace", "/tmp/fermix", server: store)
      assert :ok = GenServer.stop(store)

      restarted = :"store_scoped_restarted_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: restarted,
        start: {Store, :start_link, [[name: restarted, repo: repo]]}
      })

      assert {:ok, "UTC"} = Store.recall({:owner, "default"}, "timezone", server: restarted)

      assert {:ok, "/tmp/fermix"} =
               Store.recall({:agent, "main"}, "workspace", server: restarted)
    end

    test "keeps legacy and thread-aware root namespaces distinct in sqlite", %{
      repo: repo,
      store: store
    } do
      legacy_key = {"telegram", "chat_1"}
      root_key = {"telegram", "chat_1", :root}

      assert :ok = Store.store(legacy_key, "topic", "legacy", server: store)
      assert :ok = Store.store(root_key, "topic", "root", server: store)
      assert :ok = GenServer.stop(store)

      restarted = :"store_namespace_restarted_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: restarted,
        start: {Store, :start_link, [[name: restarted, repo: repo]]}
      })

      assert {:ok, "legacy"} = Store.recall(legacy_key, "topic", server: restarted)
      assert {:ok, "root"} = Store.recall(root_key, "topic", server: restarted)
    end

    test "migrates TEZ-374 legacy rows into the new legacy namespace", %{repo: repo, store: store} do
      legacy_key = {"telegram", "chat_legacy"}
      root_key = {"telegram", "chat_legacy", :root}
      root_scope_id = "telegram:chat_legacy:root"
      legacy_scope_id = "legacy:telegram:chat_legacy"

      assert {:ok, _memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "conversation",
                   scope_id: root_scope_id,
                   category: "fact",
                   key: "topic",
                   value: "historic"
                 },
                 server: repo
               )

      assert {:ok, "historic"} = Store.recall(legacy_key, "topic", server: store)
      assert {:error, :not_found} = Store.recall(root_key, "topic", server: store)

      assert {:error, :not_found} =
               Repo.get_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "conversation",
                   scope_id: root_scope_id,
                   key: "topic"
                 },
                 server: repo
               )

      assert {:ok, migrated} =
               Repo.get_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "conversation",
                   scope_id: legacy_scope_id,
                   key: "topic"
                 },
                 server: repo
               )

      assert migrated.value == "historic"

      assert :ok = Store.store(root_key, "topic", "fresh-root", server: store)
      assert {:ok, "historic"} = Store.recall(legacy_key, "topic", server: store)
      assert {:ok, "fresh-root"} = Store.recall(root_key, "topic", server: store)
    end

    test "recall_all prefers sqlite values when ETS diverges", %{repo: repo, store: store} do
      conv_key = {"telegram", "chat_1", :root}
      scope_id = "telegram:chat_1:root"

      assert :ok = Store.store(conv_key, "topic", "cached", server: store)

      assert {:ok, _memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "conversation",
                   scope_id: scope_id,
                   category: "fact",
                   key: "topic",
                   value: "persisted"
                 },
                 server: repo
               )

      assert %{"topic" => "persisted"} = Store.recall_all(conv_key, server: store)
    end

    test "recall prefers cached values when ETS diverges from sqlite", %{repo: repo, store: store} do
      conv_key = {"telegram", "chat_1", :root}
      scope_id = "telegram:chat_1:root"

      assert :ok = Store.store(conv_key, "topic", "cached", server: store)

      assert {:ok, _memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "conversation",
                   scope_id: scope_id,
                   category: "fact",
                   key: "topic",
                   value: "persisted"
                 },
                 server: repo
               )

      assert {:ok, "cached"} = Store.recall(conv_key, "topic", server: store)
    end

    test "owner and agent scopes stay namespaced by both agent_id and owner_id", %{repo: repo} do
      main_store = start_repo_backed_store(repo, agent_id: "main", owner_id: "default")
      side_agent_store = start_repo_backed_store(repo, agent_id: "sidecar", owner_id: "default")
      side_owner_store = start_repo_backed_store(repo, agent_id: "main", owner_id: "secondary")

      assert :ok = Store.store({:owner, "default"}, "timezone", "UTC", server: main_store)
      assert {:ok, "UTC"} = Store.recall({:owner, "default"}, "timezone", server: main_store)

      assert {:error, :not_found} =
               Store.recall({:owner, "default"}, "timezone", server: side_agent_store)

      assert :ok = Store.store({:agent, "main"}, "workspace", "/tmp/fermix", server: main_store)

      assert {:ok, "/tmp/fermix"} =
               Store.recall({:agent, "main"}, "workspace", server: main_store)

      assert {:error, :not_found} =
               Store.recall({:agent, "main"}, "workspace", server: side_owner_store)
    end
  end

  defp start_repo_backed_store(repo, opts) do
    store_name = :"store_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: store_name,
      start: {Store, :start_link, [[name: store_name, repo: repo] ++ opts]}
    })
  end

  defp evict_store_cache(store) do
    :sys.replace_state(store, fn state ->
      previous_table = state.table
      next_table = :ets.new(:fermix_memory, [:set, :private])
      true = :ets.delete(previous_table)

      %{state | table: next_table}
    end)
  end
end
