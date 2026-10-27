defmodule FermixCore.Memory.GuestMessagesTest do
  @moduledoc """
  What a guest says is stored as the guest's, a finished coding run's notice
  (the vendor CLI's text, stored as a user message) as the run's
  (`harness_continuation`), and a message the owner forwarded as someone
  else's (`forwarded`), so the memory review — which reads a conversation's
  user messages — never distils any of them into the owner's memory.
  The marker has to survive every path a message takes: the in-memory hot
  window, the durable row, compaction's history replace, and a reload.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  # The turn stores its user message before the model call; this model fails,
  # so the stored row is all the turn leaves.
  defmodule FailingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts), do: {:error, "adapter failed"}

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

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

  describe "a coding run's continuation notice" do
    @notice "[coding run hr_000000000001 finished]\ncodex · completed\nI am allergic to peanuts"

    test "the marker rides the hot window and the review never selects the row", %{
      repo: repo,
      store: store
    } do
      add(store, "user", "owner says: I work from Lisbon")
      add(store, "user", @notice, harness_continuation: true)
      wait_for_message_count(repo, 2)

      assert [owner, notice] = ConversationStore.get_history(@key, server: store)
      assert notice.harness_continuation == true
      refute Map.has_key?(owner, :harness_continuation)

      assert reviewed(repo) == ["owner says: I work from Lisbon"]
    end

    test "compaction's history replace keeps a retained notice marked", %{
      repo: repo,
      store: store
    } do
      add(store, "user", "owner says: I work from Lisbon")
      add(store, "user", @notice, harness_continuation: true)
      wait_for_message_count(repo, 2)

      retained = ConversationStore.get_history(@key, server: store)

      :ok =
        ConversationStore.replace_history(
          @key,
          [%{role: "system", content: "Conversation checkpoint summary:\nearlier"} | retained],
          server: store
        )

      wait_for_message_count(repo, 3)
      assert reviewed(repo) == ["owner says: I work from Lisbon"]
    end

    # A notice re-run after the owner's `/confirm` carries only the chain's
    # depth and run in its metadata; the turn still stores it as the run's.
    test "a resumed notice the turn stores is never reviewed", %{repo: repo, store: store} do
      registry = :"guest_messages_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry}, id: registry)

      msg = %{
        channel: "telegram",
        chat_id: "shared_chat",
        sender: "fermix",
        content: @notice,
        source_trust: :operator,
        metadata: %{
          harness_continuation_depth: 2,
          harness_run_id: "hr_1",
          resumed_from_grant: "T"
        }
      }

      assert {:error, "adapter failed"} =
               TurnRunner.run(msg, turn_state(registry, store), fn _part -> :ok end)

      wait_for_message_count(repo, 1)
      assert reviewed(repo) == []
    end

    test "a reload from sqlite restores the marker", %{repo: repo, store: store} do
      add(store, "user", @notice, harness_continuation: true)
      wait_for_message_count(repo, 1)
      assert :ok = GenServer.stop(store)

      reloaded = :"guest_messages_reloaded_#{System.unique_integer([:positive])}"
      start_store(reloaded, repo)

      assert [%{harness_continuation: true}] =
               ConversationStore.get_history(@key, server: reloaded)
    end
  end

  describe "a forwarded message" do
    test "the marker rides the hot window and the review never selects the row", %{
      repo: repo,
      store: store
    } do
      add(store, "user", "owner says: I work from Lisbon")
      add(store, "user", "[forwarded message]\nI am allergic to peanuts", forwarded: true)
      wait_for_message_count(repo, 2)

      assert [owner, forwarded] = ConversationStore.get_history(@key, server: store)
      assert forwarded.forwarded == true
      refute Map.has_key?(owner, :forwarded)

      assert reviewed(repo) == ["owner says: I work from Lisbon"]
    end

    test "compaction's history replace keeps a retained forwarded message marked", %{
      repo: repo,
      store: store
    } do
      add(store, "user", "owner says: I work from Lisbon")
      add(store, "user", "[forwarded message]\nI am allergic to peanuts", forwarded: true)
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
               &(&1[:forwarded] == true)
             )

      assert reviewed(repo) == ["owner says: I work from Lisbon"]
    end

    test "a reload from sqlite restores the marker", %{repo: repo, store: store} do
      add(store, "user", "[forwarded message]\nI am allergic to peanuts", forwarded: true)
      wait_for_message_count(repo, 1)
      assert :ok = GenServer.stop(store)

      reloaded = :"guest_messages_reloaded_#{System.unique_integer([:positive])}"
      start_store(reloaded, repo)

      assert [%{forwarded: true}] = ConversationStore.get_history(@key, server: reloaded)
    end
  end

  defp turn_state(registry, store) do
    profile = fn trust ->
      %{
        trust: trust,
        capabilities: [],
        runtime_message: %{role: "system", content: "runtime contract"},
        runtime_accounting: %{part: :runtime}
      }
    end

    %{
      adapter: FailingAdapter,
      adapter_opts: [model: "mock-model"],
      provider: nil,
      adapter_overrides: [],
      capability_registry: registry,
      conversation_store: store,
      runtime_context: %RuntimeContext{
        agent_id: "main",
        built_at_ms: 0,
        base_messages: [%{role: "system", content: "base prompt"}],
        stable_messages: [%{role: "system", content: "base prompt"}],
        volatile_messages: [],
        base_accounting: [],
        available_skills: [],
        operator_profile: profile.(:operator),
        guest_profile: profile.(:guest)
      },
      memory_agent_id: "main",
      memory_owner_id: "default",
      skill_registry: nil,
      agent_supervisor: nil,
      task_supervisor: self(),
      journal_base_dir: nil,
      memory_store: nil,
      memory_repo: nil
    }
  end

  defp start_store(name, repo) do
    start_supervised!(%{
      id: name,
      start: {ConversationStore, :start_link, [[name: name, max_messages: 20, repo: repo]]}
    })
  end

  defp add(store, role, content, flags \\ []) do
    metadata =
      cond do
        flags[:guest] -> %{guest: true}
        flags[:harness_continuation] -> %{harness_continuation: true}
        flags[:forwarded] -> %{forwarded: true}
        true -> nil
      end

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
