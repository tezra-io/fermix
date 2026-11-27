defmodule FermixCore.Memory.PhoneCallResultMessagesTest do
  @moduledoc """
  A finished phone call's report is stored in the owner's chat as a user
  message carrying, besides the continuation marker every follow-up notice
  carries, a flag of its own (`phone_call_result: true`, never the call's id),
  so the owner's message that answers it can tell from the history it replays
  that it answers a call's report (M94 D26). The flag has to survive every path
  a message takes: the in-memory hot window, the durable row, a history
  replace, the tail a compaction keeps, and a reload. No other message carries
  it, a coding run's notice included.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Compactor
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

  # Every name, number and id here is invented.
  @key {"telegram", "phone_report_chat", :root}
  @chat_selector %{
    agent_id: "main",
    channel: "telegram",
    chat_id: "phone_report_chat",
    thread_scope: "root",
    kind: "chat_message"
  }
  @report "[phone call pc_0a1b2c3d4e5f] The call ended.\nOutcome: needs_owner"
  @coding_notice "[coding run hr_000000000001 finished]\ncodex · completed"
  @report_metadata %{
    harness_continuation: true,
    harness_continuation_depth: 1,
    phone_call_result: true
  }
  # SQLite work behind a loaded runner's file-server queue, polled every
  # `@poll_ms` until it lands.
  @durable_write_wait_ms 10_000
  @poll_ms 10

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-report-messages-#{unique}.db")
    repo = :"phone_report_messages_repo_#{unique}"
    store = :"phone_report_messages_store_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_store(store, repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, store: store}
  end

  test "the flag rides the hot window on a call's report and on nothing else", %{
    repo: repo,
    store: store
  } do
    add(store, "user", "Call Calloway Bistro and book a table for two.")
    add(store, "user", @coding_notice, %{harness_continuation: true})
    add(store, "user", @report, @report_metadata)
    add(store, "assistant", "The bistro only has 9:15 PM.")
    wait_for_rows(repo, 4)

    assert [owner, coding, report, reply] = ConversationStore.get_history(@key, server: store)
    assert %{phone_call_result: true, harness_continuation: true} = report
    refute Map.has_key?(owner, :phone_call_result)
    refute Map.has_key?(coding, :phone_call_result)
    refute Map.has_key?(reply, :phone_call_result)
  end

  test "a reload from sqlite restores the flag, and only on the report", %{
    repo: repo,
    store: store
  } do
    add(store, "user", @coding_notice, %{harness_continuation: true})
    add(store, "user", @report, @report_metadata)
    wait_for_rows(repo, 2)

    assert {:ok, rows} = Repo.get_messages(@chat_selector, server: repo)
    assert Enum.count(rows, &(&1.metadata["phone_call_result"] == true)) == 1

    assert [coding, report] = reloaded(store, repo)
    assert %{phone_call_result: true, content: @report} = report
    refute Map.has_key?(coding, :phone_call_result)
  end

  # A report stored before the flag was its own holds the call's id under the
  # same key, beside the continuation's. An id on a message that is no
  # continuation notice marks nothing.
  test "a reload reads a report stored with the call's id as the report", %{
    repo: repo,
    store: store
  } do
    stored_before = %{harness_continuation: true, phone_call_result: "pc_0a1b2c3d4e5f"}
    add(store, "user", @report, stored_before)
    add(store, "user", "hi", %{phone_call_result: "pc_0a1b2c3d4e5f"})
    wait_for_rows(repo, 2)

    assert [report, typed] = reloaded(store, repo)
    assert %{phone_call_result: true, content: @report} = report
    refute Map.has_key?(typed, :phone_call_result)
  end

  test "a history replace keeps the report flagged, in memory and on disk", %{
    repo: repo,
    store: store
  } do
    add(store, "user", "Call Calloway Bistro and book a table for two.")
    add(store, "user", @report, @report_metadata)
    wait_for_rows(repo, 2)

    retained = ConversationStore.get_history(@key, server: store)

    :ok =
      ConversationStore.replace_history(
        @key,
        [%{role: "system", content: "Conversation checkpoint summary:\nearlier"} | retained],
        server: store
      )

    wait_for_rows(repo, 3)

    assert [_summary, _owner, %{phone_call_result: true}] =
             ConversationStore.get_history(@key, server: store)

    flagged = store |> reloaded(repo) |> Enum.filter(&Map.has_key?(&1, :phone_call_result))
    assert [%{phone_call_result: true, content: @report}] = flagged
  end

  # What auto-compaction writes back: the checkpoint summary, then the tail it
  # kept verbatim. A report in that tail is still the report, flagged.
  test "a compaction's retained tail keeps the report flagged", %{repo: repo, store: store} do
    add(store, "user", String.duplicate("plan the dinner for Saturday ", 120))
    add(store, "assistant", String.duplicate("here is the plan for Saturday ", 120))
    add(store, "user", @report, @report_metadata)
    add(store, "assistant", "The bistro only has 9:15 PM.")
    wait_for_rows(repo, 4)

    history = ConversationStore.get_history(@key, server: store)

    assert {:ok, %{compacted?: true, messages: compacted}} =
             Compactor.compact(history,
               enabled: true,
               token_budget: 400,
               cache: %{summary: "The owner is planning dinner for Saturday."}
             )

    assert [%{role: "system"}, %{phone_call_result: true}, %{role: "assistant"}] = compacted

    :ok = ConversationStore.replace_history(@key, compacted, server: store)
    wait_for_rows(repo, 3)

    flagged = store |> reloaded(repo) |> Enum.filter(&Map.has_key?(&1, :phone_call_result))
    assert [%{phone_call_result: true, content: @report}] = flagged
  end

  # The turn that reports a call stores its message flagged: the flag, never
  # the call's id the notice carried in.
  test "the report's own turn stores the flag, not the call's id", %{repo: repo, store: store} do
    registry = :"phone_report_messages_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)

    msg = %{
      channel: "telegram",
      chat_id: "phone_report_chat",
      sender: "fermix",
      content: @report,
      source_trust: :operator,
      metadata: %{
        harness_continuation: true,
        harness_continuation_depth: 1,
        phone_call_result: "pc_0a1b2c3d4e5f"
      }
    }

    assert {:error, "adapter failed"} =
             TurnRunner.run(msg, turn_state(registry, store), fn _part -> :ok end)

    wait_for_rows(repo, 1)
    assert {:ok, [row]} = Repo.get_messages(@chat_selector, server: repo)
    assert row.metadata["phone_call_result"] == true
    assert row.metadata["harness_continuation"] == true
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

  defp add(store, role, content, metadata \\ nil) do
    :ok = ConversationStore.add_message(@key, role, content, server: store, metadata: metadata)
  end

  # What the next start of the engine reads: the store stopped, a new one over
  # the same database.
  defp reloaded(store, repo) do
    assert :ok = GenServer.stop(store)
    restarted = :"phone_report_messages_reloaded_#{System.unique_integer([:positive])}"
    start_store(restarted, repo)
    ConversationStore.get_history(@key, server: restarted)
  end

  defp wait_for_rows(repo, expected),
    do: wait_for_rows(repo, expected, div(@durable_write_wait_ms, @poll_ms))

  defp wait_for_rows(repo, expected, polls_left) when polls_left > 0 do
    case Repo.message_count(@chat_selector, server: repo) do
      {:ok, ^expected} ->
        :ok

      _other ->
        Process.sleep(@poll_ms)
        wait_for_rows(repo, expected, polls_left - 1)
    end
  end

  defp wait_for_rows(repo, expected, 0) do
    flunk("timed out waiting for #{expected} persisted messages in #{inspect(repo)}")
  end
end
