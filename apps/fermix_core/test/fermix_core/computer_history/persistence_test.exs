defmodule FermixCore.ComputerHistory.PersistenceTest do
  @moduledoc """
  MILESTONE_32 §7 — the three new tables round-trip on the shared single-writer
  connection: idempotent spool ingest, the 48h sweep, and the summarizer
  singleton state row.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-computer-history-#{unique}.db")
    repo_name = :"computer_history_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp event(boot_id, seq, ts, extra \\ %{}) do
    Map.merge(%{boot_id: boot_id, source_seq: seq, ts: ts, type: "app.activated"}, extra)
  end

  describe "spool events" do
    test "insert a batch, then count and oldest reflect it", %{repo: repo} do
      events = [event("b1", 1, 5_000), event("b1", 2, 3_000, %{bundle_id: "com.apple.Safari"})]

      assert {:ok, 2} = Repo.computer_history_insert_events(events, server: repo)
      assert {:ok, 2} = Repo.computer_history_count_events(server: repo)
      assert {:ok, 3_000} = Repo.computer_history_oldest_event_ts(server: repo)
    end

    test "re-delivering the same (boot_id, source_seq) does not double-insert", %{repo: repo} do
      events = [event("b1", 1, 5_000)]

      assert {:ok, 1} = Repo.computer_history_insert_events(events, server: repo)
      # Idempotent: the UNIQUE(boot_id, source_seq) ignores the duplicate.
      assert {:ok, 0} = Repo.computer_history_insert_events(events, server: repo)
      assert {:ok, 1} = Repo.computer_history_count_events(server: repo)
    end

    test "boolean content_withheld is coerced to an integer", %{repo: repo} do
      events = [event("b1", 1, 5_000, %{content_withheld: true, char_len: 42})]
      assert {:ok, 1} = Repo.computer_history_insert_events(events, server: repo)
      assert {:ok, 1} = Repo.computer_history_count_events(server: repo)
    end

    test "empty spool reports a nil oldest", %{repo: repo} do
      assert {:ok, nil} = Repo.computer_history_oldest_event_ts(server: repo)
      assert {:ok, 0} = Repo.computer_history_count_events(server: repo)
    end
  end

  describe "retention sweep" do
    test "deletes events strictly older than the cutoff, keeps the rest", %{repo: repo} do
      events = [
        event("b1", 1, 500),
        event("b1", 2, 1_000),
        event("b1", 3, 2_000)
      ]

      assert {:ok, 3} = Repo.computer_history_insert_events(events, server: repo)

      # ts < 1000 ⇒ only the ts=500 row goes; ts=1000 (== cutoff) survives.
      assert {:ok, 1} = Repo.computer_history_sweep_expired_events(1_000, server: repo)
      assert {:ok, 2} = Repo.computer_history_count_events(server: repo)
      assert {:ok, 1_000} = Repo.computer_history_oldest_event_ts(server: repo)
    end

    test "sweeping an empty spool removes nothing", %{repo: repo} do
      assert {:ok, 0} = Repo.computer_history_sweep_expired_events(9_999, server: repo)
    end
  end

  describe "byte-ceiling backstop (§22.8)" do
    # Each row's estimated bytes = LENGTH(text) + LENGTH(window_title) +
    # LENGTH(page_title) + LENGTH(url) + 160 overhead. A 1 KiB text ⇒ ~1184.
    defp fat_event(seq, ts), do: event("b1", seq, ts, %{text: String.duplicate("x", 1_024)})

    test "deletes the oldest rows beyond the ceiling, keeps the newest", %{repo: repo} do
      events = Enum.map(1..10, fn seq -> fat_event(seq, seq * 1_000) end)
      assert {:ok, 10} = Repo.computer_history_insert_events(events, server: repo)

      # Ceiling of ~3 rows (3 * 1184 = 3552 fits; the 4th crosses): the 6
      # oldest rows plus the crossing row go, newest 3 stay.
      assert {:ok, 7} = Repo.computer_history_sweep_spool_over_bytes(3_600, server: repo)
      assert {:ok, 3} = Repo.computer_history_count_events(server: repo)
      # The survivors are the NEWEST rows (ids/ts 8..10), not the oldest.
      assert {:ok, 8_000} = Repo.computer_history_oldest_event_ts(server: repo)
    end

    test "a spool under the ceiling is untouched", %{repo: repo} do
      assert {:ok, 2} =
               Repo.computer_history_insert_events([fat_event(1, 1_000), fat_event(2, 2_000)],
                 server: repo
               )

      assert {:ok, 0} = Repo.computer_history_sweep_spool_over_bytes(1_000_000, server: repo)
      assert {:ok, 2} = Repo.computer_history_count_events(server: repo)
    end

    test "an empty spool is a no-op", %{repo: repo} do
      assert {:ok, 0} = Repo.computer_history_sweep_spool_over_bytes(1, server: repo)
    end
  end

  describe "access audit (§22.8)" do
    defp access(ts, sink, count) do
      %{ts: ts, sink: sink, window_from_ts: nil, window_to_ts: nil, result_count: count}
    end

    test "records reads and reports {count, last_ts}", %{repo: repo} do
      assert {:ok, {0, nil}} = Repo.computer_history_access_stats(server: repo)

      assert :ok =
               Repo.computer_history_record_access(access(1_000, "recall_activity", 3),
                 server: repo
               )

      assert :ok =
               Repo.computer_history_record_access(access(2_000, "recent_activity", 8),
                 server: repo
               )

      assert {:ok, {2, 2_000}} = Repo.computer_history_access_stats(server: repo)
    end

    test "cap keeps the newest rows only", %{repo: repo} do
      for ts <- 1..5 do
        assert :ok =
                 Repo.computer_history_record_access(access(ts * 1_000, "recall_activity", 1),
                   server: repo
                 )
      end

      assert {:ok, 3} = Repo.computer_history_cap_access_rows(2, server: repo)
      assert {:ok, {2, 5_000}} = Repo.computer_history_access_stats(server: repo)
    end

    test "purge erases access rows recorded inside the window", %{repo: repo} do
      assert :ok =
               Repo.computer_history_record_access(access(1_000, "recall_activity", 1),
                 server: repo
               )

      assert :ok =
               Repo.computer_history_record_access(access(9_000, "recall_activity", 1),
                 server: repo
               )

      assert {:ok, _counts} = Repo.computer_history_purge_window(0, 5_000, server: repo)
      # Only the read recorded outside the purge window survives.
      assert {:ok, {1, 9_000}} = Repo.computer_history_access_stats(server: repo)
    end
  end

  describe "summarizer singleton state" do
    test "ensure creates the idle row with a zero cursor; fetch reads it", %{repo: repo} do
      assert {:ok, state} = Repo.computer_history_ensure_state(server: repo)
      assert state.id == 1
      assert state.status == "idle"
      assert state.last_summarized_id == 0

      # Idempotent ensure.
      assert {:ok, ^state} = Repo.computer_history_ensure_state(server: repo)
      assert {:ok, fetched} = Repo.computer_history_fetch_state(server: repo)
      assert fetched.status == "idle"
    end

    test "fetch before ensure reports not_found", %{repo: repo} do
      assert {:error, :not_found} = Repo.computer_history_fetch_state(server: repo)
    end
  end

  describe "activity memories table" do
    test "exists and starts empty", %{repo: repo} do
      assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)
    end
  end
end
