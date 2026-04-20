defmodule FermixCore.Memory.SearchTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Search

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-search-#{unique}.db")
    repo_name = :"memory_search_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "filters memory search to the requested scope and returns ranked results", %{repo: repo} do
    insert_memory(repo, "owner", "default", "timezone", "UTC timezone preference")

    insert_memory(
      repo,
      "conversation",
      "telegram:chat-1:root",
      "timezone",
      "Current chat timezone"
    )

    insert_memory(repo, "conversation", "telegram:chat-2:root", "timezone", "Other chat timezone")

    results =
      Search.query(
        "timezone",
        repo: repo,
        source: :memories,
        scope: :current_conversation,
        conversation_key: {"telegram", "chat-1", :root},
        agent_id: "main",
        owner_id: "default"
      )

    assert [%{source: :memories, scope_type: "conversation", scope_id: "telegram:chat-1:root"}] =
             results

    assert results == Enum.sort_by(results, & &1.rank)
  end

  test "returns an empty list for blank queries", %{repo: repo} do
    assert [] =
             Search.query(
               "   ",
               repo: repo,
               source: :memories,
               scope: :current_conversation,
               conversation_key: {"telegram", "chat-1", :root},
               agent_id: "main",
               owner_id: "default"
             )
  end

  test "raises for invalid source, scope, and limit options", %{repo: repo} do
    assert_raise ArgumentError, ~r/invalid search source/, fn ->
      Search.query("timezone", repo: repo, source: :bogus)
    end

    assert_raise ArgumentError, ~r/invalid search scope/, fn ->
      Search.query("timezone", repo: repo, scope: :bogus)
    end

    assert_raise ArgumentError, ~r/positive integer/, fn ->
      Search.query("timezone", repo: repo, limit: 0)
    end
  end

  test "falls back to the historical root namespace for 2-tuple current conversation searches", %{
    repo: repo
  } do
    insert_memory(
      repo,
      "conversation",
      "telegram:chat-legacy:root",
      "timezone",
      "Root-only legacy value"
    )

    results =
      Search.query(
        "timezone",
        repo: repo,
        source: :memories,
        scope: :current_conversation,
        conversation_key: {"telegram", "chat-legacy"},
        agent_id: "main",
        owner_id: "default"
      )

    assert [%{source: :memories, scope_id: "telegram:chat-legacy:root"}] = results
  end

  test "can search across memories and history with source metadata and limits", %{repo: repo} do
    insert_memory(repo, "owner", "default", "timezone", "UTC timezone preference")

    insert_message(repo, "telegram", "chat-1", "root", "timezone handling in the current chat")
    insert_message(repo, "telegram", "chat-2", "root", "another timezone discussion elsewhere")

    results =
      Search.query(
        "timezone",
        repo: repo,
        source: :all,
        scope: :owner,
        limit: 3,
        conversation_key: {"telegram", "chat-1", :root},
        agent_id: "main",
        owner_id: "default"
      )

    assert length(results) == 3
    assert Enum.any?(results, &(&1.source == :memories))
    assert Enum.any?(results, &(&1.source == :messages))
    assert results == Enum.sort_by(results, & &1.rank)
  end

  defp insert_memory(repo, scope_type, scope_id, key, value) do
    assert {:ok, _memory} =
             Repo.upsert_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: scope_type,
                 scope_id: scope_id,
                 category: "fact",
                 key: key,
                 value: value
               },
               server: repo
             )
  end

  defp insert_message(repo, channel, chat_id, thread_scope, content) do
    assert {:ok, _message} =
             Repo.insert_message(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 channel: channel,
                 chat_id: chat_id,
                 thread_scope: thread_scope,
                 sender: "alice",
                 role: "user",
                 kind: "chat_message",
                 content: content
               },
               server: repo
             )
  end
end
