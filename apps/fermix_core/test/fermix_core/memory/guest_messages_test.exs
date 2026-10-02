defmodule FermixCore.Memory.GuestMessagesTest do
  @moduledoc """
  What a guest says is stored as the guest's, so the memory review — which
  reads a conversation's user messages — never distils it into the owner's
  memory. The marker has to survive every path a message takes: the in-memory
  hot window, the durable row, compaction's history replace, and a reload.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @key {"telegram", "shared_chat", :root}
  @review_selector %{
    agent_id: "main",
    owner_id: "default",
    channel: "telegram",
    chat_id: "shared_chat",
    thread_scope: "root"
  }
  @chat_selector Map.merge(Map.delete(@review_selector, :owner_id), %{kind: "chat_message"})

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-guest-messages-#{unique}.db")
    repo = :"guest_messages_repo_#{unique}"
    store = :"guest_messages_store_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_store(store, repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, store: store}
  end

  test "the marker rides the hot window and the review never selects the row", %{
    repo: repo,
    store: store
  } do
    add(store, "user", "owner says: I work from Lisbon")
    add(store, "user", "guest says: I am vegetarian", guest: true)
    add(store, "assistant", "noted")
    wait_for_message_count(repo, 3)

    assert [owner, guest, assistant] = ConversationStore.get_history(@key, server: store)
    assert guest.guest == true
    refute Map.has_key?(owner, :guest)
    refute Map.has_key?(assistant, :guest)

    assert reviewed(repo) == ["owner says: I work from Lisbon"]
  end

  test "compaction's history replace keeps a retained guest message marked", %{
    repo: repo,
    store: store
  } do
    add(store, "user", "owner says: I work from Lisbon")
    add(store, "user", "guest says: I am vegetarian", guest: true)
    wait_for_message_count(repo, 2)

    retained = ConversationStore.get_history(@key, server: store)

    :ok =
      ConversationStore.replace_history(
        @key,
        [%{role: "system", content: "Conversation checkpoint summary:\nearlier"} | retained],
        server: store
      )

    wait_for_message_count(repo, 3)

    assert Enum.any?(ConversationStore.get_history(@key, server: store), &(&1[:guest] == true))

    # The retained rows were deleted and re-inserted under new ids, which makes
    # them new to the review. The guest's is still not one of them.
    assert reviewed(repo) == ["owner says: I work from Lisbon"]
  end

  test "a reload from sqlite restores the marker", %{repo: repo, store: store} do
    add(store, "user", "guest says: I am vegetarian", guest: true)
    wait_for_message_count(repo, 1)
    assert :ok = GenServer.stop(store)

    reloaded = :"guest_messages_reloaded_#{System.unique_integer([:positive])}"
    start_store(reloaded, repo)

    assert [%{guest: true}] = ConversationStore.get_history(@key, server: reloaded)
  end

  defp start_store(name, repo) do
    start_supervised!(%{
      id: name,
      start: {ConversationStore, :start_link, [[name: name, max_messages: 20, repo: repo]]}
    })
  end

  defp add(store, role, content, flags \\ []) do
    metadata = if flags[:guest], do: %{guest: true}, else: nil
    :ok = ConversationStore.add_message(@key, role, content, server: store, metadata: metadata)
  end

  defp reviewed(repo) do
    assert {:ok, rows} = Repo.get_user_messages_after(@review_selector, 0, 40, server: repo)
    Enum.map(rows, & &1.content)
  end

  defp wait_for_message_count(repo, expected, attempts \\ 100)

  defp wait_for_message_count(repo, expected, attempts) when attempts > 0 do
    case Repo.message_count(@chat_selector, server: repo) do
      {:ok, ^expected} ->
        :ok

      _other ->
        Process.sleep(10)
        wait_for_message_count(repo, expected, attempts - 1)
    end
  end

  defp wait_for_message_count(repo, expected, 0) do
    flunk("timed out waiting for #{expected} persisted messages in #{inspect(repo)}")
  end
end
