defmodule FermixCore.Memory.SearchTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Search

  defmodule FakeSearchRepo do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call({:search_memories, _query, _selector, limit}, _from, state) do
      send(state.test_pid, {:search_call, :memories, limit})
      {:reply, {:ok, Enum.take(state.memories, limit)}, state}
    end

    def handle_call({:search_messages, _query, _selector, limit}, _from, state) do
      send(state.test_pid, {:search_call, :messages, limit})
      {:reply, {:ok, Enum.take(state.messages, limit)}, state}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-search-#{unique}.db")
    repo_name = :"memory_search_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
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

  test "source all expands only candidate windows that can still affect the final limit" do
    {:ok, repo} =
      FakeSearchRepo.start_link(
        test_pid: self(),
        memories: search_rows(:updated_at, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]),
        messages: search_rows(:created_at, [9.1, 9.2, 9.3, 9.4, 9.5, 9.6])
      )

    results =
      Search.query(
        "timezone",
        repo: repo,
        source: :all,
        scope: :all,
        limit: 6,
        agent_id: "main"
      )

    assert Enum.map(results, & &1.source) == List.duplicate(:memories, 6)
    assert_receive {:search_call, :memories, 3}
    assert_receive {:search_call, :messages, 3}
    assert_receive {:search_call, :memories, 6}
    refute_receive {:search_call, :messages, 6}
  end

  test "source all expands a non-exhausted window when the split window underfills the limit" do
    {:ok, repo} =
      FakeSearchRepo.start_link(
        test_pid: self(),
        memories: search_rows(:updated_at, [0.1, 0.2, 0.3, 0.4]),
        messages: []
      )

    results =
      Search.query(
        "timezone",
        repo: repo,
        source: :all,
        scope: :all,
        limit: 4,
        agent_id: "main"
      )

    assert Enum.map(results, & &1.source) == List.duplicate(:memories, 4)
    assert_receive {:search_call, :memories, 2}
    assert_receive {:search_call, :messages, 2}
    assert_receive {:search_call, :memories, 4}
    refute_receive {:search_call, :messages, 4}
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

  defp search_rows(timestamp_field, ranks) do
    now = DateTime.utc_now()

    ranks
    |> Enum.with_index(1)
    |> Enum.map(fn {rank, id} ->
      %{id: id, rank: rank}
      |> Map.put(timestamp_field, DateTime.add(now, -id, :second))
    end)
  end
end
