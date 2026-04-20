defmodule FermixCore.Memory.RepoTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-repo-#{unique}.db")
    repo_name = :"memory_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    %{repo: repo_name, db_path: db_path}
  end

  test "opens sqlite, enables wal mode, and runs the base migration", %{repo: repo} do
    assert {:ok, "wal"} = Repo.journal_mode(server: repo)
    assert {:ok, [1, 2]} = Repo.migration_versions(server: repo)
  end

  test "rerunning migrations is idempotent", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, [1, 2]} = Repo.migration_versions(server: repo)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, [1, 2]} = Repo.migration_versions(server: repo)
  end

  test "supports message CRUD through the repo API", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root",
      sender: "alice",
      role: "user",
      kind: "chat_message",
      content: "hello world",
      metadata: %{"source" => "test"}
    }

    assert {:ok, inserted} = Repo.insert_message(attrs, server: repo)
    assert inserted.id > 0
    assert inserted.metadata == %{"source" => "test"}

    selector = %{
      agent_id: "main",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root"
    }

    assert {:ok, 1} = Repo.message_count(selector, server: repo)
    assert {:ok, [stored]} = Repo.get_messages(selector, server: repo)
    assert stored.id == inserted.id
    assert stored.sender == "alice"
    assert stored.content == "hello world"

    assert :ok = Repo.delete_messages(selector, server: repo)
    assert {:ok, 0} = Repo.message_count(selector, server: repo)
    assert {:ok, []} = Repo.get_messages(selector, server: repo)
  end

  test "supports memory upsert, lookup, listing, and delete", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-1:root",
      category: "preference",
      key: "language",
      value: "en"
    }

    assert {:ok, first} = Repo.upsert_memory(attrs, server: repo)
    assert first.value == "en"

    assert {:ok, updated} =
             Repo.upsert_memory(Map.merge(attrs, %{value: "fr", confidence: 0.9}), server: repo)

    assert updated.id == first.id
    assert updated.value == "fr"
    assert updated.confidence == 0.9

    selector = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-1:root",
      key: "language"
    }

    assert {:ok, stored} = Repo.get_memory(selector, server: repo)
    assert stored.value == "fr"

    assert {:ok, [memory]} =
             Repo.get_memories(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-1:root"
               },
               server: repo
             )

    assert memory.id == updated.id

    assert :ok = Repo.delete_memory(selector, server: repo)
    assert {:error, :not_found} = Repo.get_memory(selector, server: repo)
  end

  test "keeps memory fts results in sync across upserts and deletes", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-search:root",
      category: "preference",
      key: "timezone",
      value: "UTC timezone preference"
    }

    assert {:ok, inserted} = Repo.upsert_memory(attrs, server: repo)

    assert {:ok, [match]} =
             Repo.search_memories(
               "utc",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )

    assert match.id == inserted.id
    assert match.key == "timezone"
    assert is_float(match.rank)

    assert {:ok, _updated} =
             Repo.upsert_memory(Map.put(attrs, :value, "calendar preference"), server: repo)

    assert {:ok, []} =
             Repo.search_memories(
               "utc",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )

    assert {:ok, [updated]} =
             Repo.search_memories(
               "calendar",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )

    assert updated.id == inserted.id

    assert :ok =
             Repo.delete_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root",
                 key: "timezone"
               },
               server: repo
             )

    assert {:ok, []} =
             Repo.search_memories(
               "calendar",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )
  end

  test "keeps message fts results in sync across inserts and deletes", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-search",
      thread_scope: "root",
      sender: "alice",
      role: "user",
      kind: "chat_message",
      content: "timezone preferences came up in chat"
    }

    assert {:ok, inserted} = Repo.insert_message(attrs, server: repo)

    assert {:ok, [match]} =
             Repo.search_messages(
               "timezone",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 channel: "telegram",
                 chat_id: "chat-search",
                 thread_scope: "root"
               },
               server: repo
             )

    assert match.id == inserted.id
    assert match.content =~ "timezone"
    assert is_float(match.rank)

    assert :ok =
             Repo.delete_messages(
               %{
                 agent_id: "main",
                 channel: "telegram",
                 chat_id: "chat-search",
                 thread_scope: "root"
               },
               server: repo
             )

    assert {:ok, []} =
             Repo.search_messages(
               "timezone",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 channel: "telegram",
                 chat_id: "chat-search",
                 thread_scope: "root"
               },
               server: repo
             )
  end
end
