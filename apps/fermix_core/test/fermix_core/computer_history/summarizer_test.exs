defmodule FermixCore.ComputerHistory.SummarizerTest do
  @moduledoc """
  MILESTONE_32 §10 — the on-device summarizer. Proves raw events reach only the
  intended provider (inv. 1 / 1b), the pinned route never failovers, a
  non-loopback local route refuses (inv. 17), the output contract validates
  verbatim field text out, and new memories supersede the overlapping window.

  A fake adapter records every call in the process dictionary (run_cycle is
  synchronous and in-process). The provider/model/base_url are injected via
  `:route_opts`, so no global provider config is mutated (hermetic).
  """
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Locality
  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.Memory.Repo

  # --- fake adapter (records calls, canned response) ----------------------

  defmodule FakeAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      call = %{
        messages: messages,
        base_url: opts[:base_url],
        model: opts[:model],
        session_id: opts[:session_id],
        agent: opts[:agent]
      }

      Process.put(:ch_calls, [call | Process.get(:ch_calls, [])])

      case Process.get(:ch_behavior, :ok) do
        :error ->
          {:error, :provider_unavailable}

        :ok ->
          content = Process.get(:ch_content, "The owner used Safari and read a page.")
          {:ok, turn(content, opts[:model])}
      end
    end

    @impl true
    def continue(_state, _results, _opts), do: {:error, :not_supported}
    @impl true
    def to_provider_tools(_caps), do: []
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response

    defp turn(content, model) do
      %{
        content: content,
        tool_calls: [],
        provider_state: nil,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: model
      }
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-summarizer-#{unique}.db")
    repo_name = :"ch_summarizer_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    original = Application.get_env(:fermix_core, :computer_history)
    Process.delete(:ch_calls)
    Process.delete(:ch_behavior)
    Process.delete(:ch_content)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp enable(kw), do: Application.put_env(:fermix_core, :computer_history, [enabled: true] ++ kw)

  defp insert(repo, events),
    do: {:ok, _} = Repo.computer_history_insert_events(events, server: repo)

  defp event(seq, ts, text),
    do: %{
      boot_id: "b1",
      source_seq: seq,
      ts: ts,
      type: "field.value",
      bundle_id: "com.apple.Safari",
      text: text
    }

  defp calls, do: Process.get(:ch_calls, [])

  defp local_opts(repo),
    do: [repo: repo, macos?: true, adapter: FakeAdapter, route_opts: [model: "llama3"]]

  # --- inv. 1: local summarizer, raw reaches the loopback route -----------

  test "local summarizer sends raw events to the loopback route only (inv. 1)", %{repo: repo} do
    enable(summarizer: :local)
    canary = FermixTestSupport.ComputerHistoryCanary.token("raw")
    insert(repo, [event(1, 1_000, "typed #{canary}")])

    assert {:ok, %{memory_written: true, events: 1}} = Summarizer.run_cycle(local_opts(repo))

    assert [call] = calls()
    assert Locality.loopback?(call.base_url)
    assert FermixTestSupport.ComputerHistoryCanary.present?(call.messages, canary)
    assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)
  end

  # --- inv. 1b: Tier-3 pins to the named vendor, never failovers ----------

  test "Tier-3 sends raw only to the named provider (inv. 1b)", %{repo: repo} do
    enable(summarizer: :anthropic)
    canary = FermixTestSupport.ComputerHistoryCanary.token("raw")
    insert(repo, [event(1, 1_000, "typed #{canary}")])

    opts = [
      repo: repo,
      macos?: true,
      adapter: FakeAdapter,
      route_opts: [model: "claude-x", api_key: "test-key"]
    ]

    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(opts)

    assert [call] = calls()
    assert call.base_url == "https://api.anthropic.com/v1"
    assert FermixTestSupport.ComputerHistoryCanary.present?(call.messages, canary)
  end

  test "a Tier-3 route down refuses without failing over to another vendor (inv. 1b)", %{
    repo: repo
  } do
    enable(summarizer: :anthropic)
    insert(repo, [event(1, 1_000, "some text")])
    Process.put(:ch_behavior, :error)

    opts = [
      repo: repo,
      macos?: true,
      adapter: FakeAdapter,
      route_opts: [model: "claude-x", api_key: "k"]
    ]

    assert {:error, :provider_unavailable} = Summarizer.run_cycle(opts)

    # Exactly one call — no failover to a second vendor.
    assert length(calls()) == 1
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.paused_reason == "route_down"
  end

  # --- inv. 17: a non-loopback local route refuses ------------------------

  test "a local route repointed off-loopback refuses and emits no request (inv. 17)", %{
    repo: repo
  } do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "text")])

    opts = [
      repo: repo,
      macos?: true,
      adapter: FakeAdapter,
      route_opts: [model: "llama3", base_url: "http://10.0.0.5:11434/v1"]
    ]

    assert {:paused, :route_not_permitted} = Summarizer.run_cycle(opts)
    assert calls() == []
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)
  end

  # --- output contract: verbatim field text is validated out --------------

  test "a summary that echoes verbatim field text is rejected (summarized_empty)", %{repo: repo} do
    enable(summarizer: :local)
    secret_field = "my-private-note-abcdefghijklmnop"
    insert(repo, [event(1, 1_000, secret_field)])
    # Force the model to echo the field value verbatim.
    Process.put(:ch_content, "The owner typed #{secret_field} into a field.")

    assert {:ok, %{memory_written: false}} = Summarizer.run_cycle(local_opts(repo))
    assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)

    # The cursor still advanced — the window is not reprocessed forever.
    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.last_summarized_id > 0
    assert state.last_status == "summarized_empty"
  end

  # --- supersede + cursor -------------------------------------------------

  test "a new summary supersedes the overlapping window", %{repo: repo} do
    enable(summarizer: :local)

    insert(repo, [event(1, 1_000, "a"), event(2, 2_000, "b")])
    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    # New events whose ts window overlaps the first memory's provenance.
    insert(repo, [event(3, 1_500, "c"), event(4, 2_500, "d")])
    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    # The first memory is superseded; only the second is active.
    assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)
  end

  test "a cycle with no new events writes nothing", %{repo: repo} do
    enable(summarizer: :local)
    insert(repo, [event(1, 1_000, "a")])
    assert {:ok, %{memory_written: true}} = Summarizer.run_cycle(local_opts(repo))

    # Second cycle: cursor is past every event.
    assert {:ok, %{memory_written: false, events: 0}} = Summarizer.run_cycle(local_opts(repo))
  end
end
