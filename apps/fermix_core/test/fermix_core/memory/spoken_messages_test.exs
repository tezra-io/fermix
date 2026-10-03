defmodule FermixCore.Memory.SpokenMessagesTest do
  @moduledoc """
  A request asked aloud on a Live call is stored in the chat's conversation
  marked `spoken`, with the call it came from (M56 §4.1, D10). History and
  compaction read it like any other message; the memory review never does, so
  a possibly misheard fragment is not distilled into the owner's memory. The
  marker and the call have to survive every path a message takes: the
  in-memory hot window, the durable row, compaction's history replace, and a
  reload.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @key {"companion", "main", :root}
  @call_uuid "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
  @review_selector %{
    agent_id: "main",
    owner_id: "default",
    channel: "companion",
    chat_id: "main",
    thread_scope: "root"
  }
  @chat_selector Map.merge(Map.delete(@review_selector, :owner_id), %{kind: "chat_message"})

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-spoken-messages-#{unique}.db")
    repo = :"spoken_messages_repo_#{unique}"
    store = :"spoken_messages_store_#{unique}"

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
    add(store, "user", "typed: https://example.com/brief")
    add(store, "user", "user: open the link I just sent", spoken: true)
    add(store, "assistant", "It is the project brief.")
    wait_for_message_count(repo, 3)

    assert [typed, spoken, assistant] = ConversationStore.get_history(@key, server: store)
    assert %{spoken: true, call_uuid: @call_uuid} = spoken
    refute Map.has_key?(typed, :spoken)
    refute Map.has_key?(assistant, :spoken)

    assert reviewed(repo) == ["typed: https://example.com/brief"]
  end

  test "the durable row is a chat message carrying the marker and the call", %{
    repo: repo,
    store: store
  } do
    add(store, "user", "user: open the link I just sent", spoken: true)
    wait_for_message_count(repo, 1)

    assert {:ok, [row]} = Repo.get_messages(@chat_selector, server: repo)
    assert row.kind == "chat_message"
    assert row.metadata == %{"spoken" => true, "call_uuid" => @call_uuid}
  end

  test "compaction's history replace keeps a retained spoken request marked", %{
    repo: repo,
    store: store
  } do
    add(store, "user", "typed: https://example.com/brief")
    add(store, "user", "user: open the link I just sent", spoken: true)
    wait_for_message_count(repo, 2)

    retained = ConversationStore.get_history(@key, server: store)

    :ok =
      ConversationStore.replace_history(
        @key,
        [%{role: "system", content: "Conversation checkpoint summary:\nearlier"} | retained],
        server: store
      )

    wait_for_message_count(repo, 3)

    assert Enum.any?(
             ConversationStore.get_history(@key, server: store),
             &match?(%{spoken: true, call_uuid: @call_uuid}, &1)
           )

    assert {:ok, rows} = Repo.get_messages(@chat_selector, server: repo)

    assert Enum.any?(
             rows,
             &(&1.metadata == %{"spoken" => true, "call_uuid" => @call_uuid})
           )

    # The retained rows were deleted and re-inserted under new ids, which makes
    # them new to the review. The spoken one is still not one of them.
    assert reviewed(repo) == ["typed: https://example.com/brief"]
  end

  test "a reload from sqlite restores the marker and the call", %{repo: repo, store: store} do
    add(store, "user", "user: open the link I just sent", spoken: true)
    wait_for_message_count(repo, 1)
    assert :ok = GenServer.stop(store)

    reloaded = :"spoken_messages_reloaded_#{System.unique_integer([:positive])}"
    start_store(reloaded, repo)

    assert [%{spoken: true, call_uuid: @call_uuid, content: "user: open the link I just sent"}] =
             ConversationStore.get_history(@key, server: reloaded)
  end

  defp start_store(name, repo) do
    start_supervised!(%{
      id: name,
      start: {ConversationStore, :start_link, [[name: name, max_messages: 20, repo: repo]]}
    })
  end

  defp add(store, role, content, flags \\ []) do
    metadata = if flags[:spoken], do: %{spoken: true, call_uuid: @call_uuid}, else: nil
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
