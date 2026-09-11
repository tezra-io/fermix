defmodule FermixCore.ComputerHistory.PersistenceTest do
  @moduledoc """
  MILESTONE_32 §7 — the three new tables round-trip on the shared single-writer
  connection: idempotent spool ingest, the 48h sweep, and the summarizer
  singleton state row. Plus §24.1: migration 28's kinds, threads, the FTS
  companion and the two new state marks.
  """
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql

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

  # Per-app coverage states (§8.4a, paired with the native driver): the distinct
  # {app, reason} pairs the operator has to be told about, so `/history status` can
  # name the apps where only titles are observable.
  describe "coverage gaps" do
    test "returns the distinct app/reason pairs inside the window", %{repo: repo} do
      events = [
        event("b1", 1, 1_000, %{
          type: "observer.gap",
          bundle_id: "com.microsoft.VSCode",
          gap_reason: "title_only"
        }),
        event("b1", 2, 1_500, %{
          type: "observer.gap",
          bundle_id: "com.microsoft.VSCode",
          gap_reason: "title_only"
        }),
        event("b1", 3, 2_000, %{
          type: "observer.gap",
          bundle_id: "com.docker.docker",
          gap_reason: "ax_refused:AXValueChanged,AXFocusedUIElementChanged"
        }),
        # A machine-wide gap is not a per-app coverage state.
        event("b1", 4, 2_100, %{type: "observer.gap", gap_reason: "sleep"}),
        # A plain event of the same app is not a coverage state either.
        event("b1", 5, 2_200, %{bundle_id: "com.microsoft.VSCode"})
      ]

      assert {:ok, 5} = Repo.computer_history_insert_events(events, server: repo)

      assert {:ok, pairs} = Repo.computer_history_coverage_gaps(0, server: repo)

      assert Enum.sort(pairs) == [
               {"com.docker.docker", "ax_refused:AXValueChanged,AXFocusedUIElementChanged"},
               {"com.microsoft.VSCode", "title_only"}
             ]
    end

    test "excludes rows older than the window", %{repo: repo} do
      events = [
        event("b1", 1, 1_000, %{
          type: "observer.gap",
          bundle_id: "com.microsoft.VSCode",
          gap_reason: "title_only"
        })
      ]

      assert {:ok, 1} = Repo.computer_history_insert_events(events, server: repo)

      assert {:ok, []} = Repo.computer_history_coverage_gaps(1_001, server: repo)
      assert {:ok, [_pair]} = Repo.computer_history_coverage_gaps(1_000, server: repo)
    end

    test "an empty spool reports no coverage gaps", %{repo: repo} do
      assert {:ok, []} = Repo.computer_history_coverage_gaps(0, server: repo)
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

  # --- MILESTONE_32 §24.1 — kinds, threads, the FTS companion -------------

  defp session_memory(repo, attrs) do
    base = %{
      created_at: 1_000,
      provenance_from_ts: 500,
      provenance_to_ts: 1_000,
      summary: "read the plan",
      model: "ollama",
      event_count: 3
    }

    {:ok, id} = Repo.computer_history_insert_memory(Map.merge(base, attrs), server: repo)
    id
  end

  defp thread_row(subject, ids, last_touched_ts, attrs \\ %{}) do
    Map.merge(
      %{
        kind: "thread",
        subject: subject,
        source_ids: Jason.encode!(ids),
        last_touched_ts: last_touched_ts,
        created_at: last_touched_ts,
        provenance_from_ts: last_touched_ts - 1_000,
        provenance_to_ts: last_touched_ts,
        summary: "state of #{subject}",
        model: "ollama",
        event_count: 0
      },
      attrs
    )
  end

  describe "migration 28" do
    # A store written by the previous release: the four CH tables at migration 27
    # with one memory row. Proves the upgrade path, not only a fresh file.
    defp seed_v27_database!(path) do
      {:ok, conn} = Sqlite3.open(path, mode: :readwrite)

      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );
        """)

      :ok = Sqlite3.execute(conn, ComputerHistorySql.events_schema_sql())
      :ok = Sqlite3.execute(conn, ComputerHistorySql.memories_schema_sql())
      :ok = Sqlite3.execute(conn, ComputerHistorySql.state_schema_sql())
      :ok = Sqlite3.execute(conn, ComputerHistorySql.access_schema_sql())

      :ok =
        Sqlite3.execute(conn, """
        INSERT INTO computer_history_memories
          (created_at, provenance_from_ts, provenance_to_ts, summary, titles, model, event_count)
        VALUES (1000, 500, 1000, 'read the Apollo migration plan',
                '["Apollo migration plan"]', 'ollama', 3);
        """)

      Enum.each(1..27, fn version ->
        :ok = Sqlite3.execute(conn, "INSERT INTO schema_migrations(version) VALUES (#{version});")
      end)

      :ok = Sqlite3.close(conn)
    end

    defp start_upgraded_repo!(label) do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-ch-#{label}-#{unique}.db")

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      seed_v27_database!(db_path)
      repo_name = :"ch_upgrade_repo_#{unique}"

      start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path},
        id: :upgraded
      )

      {repo_name, db_path}
    end

    test "a store already at 27 gains the columns and reads old rows as session notes" do
      {repo, _path} = start_upgraded_repo!("v27")

      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert 28 in versions

      assert {:ok, [memory]} = Repo.computer_history_recent_memories(0, 10, server: repo)
      assert memory.kind == "session"
      assert memory.subject == nil
      assert memory.source_ids == nil
      assert memory.last_touched_ts == nil
    end

    test "the FTS companion is rebuilt over rows that existed before it" do
      {repo, _path} = start_upgraded_repo!("v27fts")

      assert {:ok, [found]} = Repo.computer_history_search_memories("apollo", 10, server: repo)
      assert found.summary == "read the Apollo migration plan"
    end

    # Every column of 28 arrives by ALTER, which is not idempotent: the version
    # check in the runner is the only thing standing between a second open and a
    # "duplicate column name" that would take the whole store down at boot.
    test "a second open of the same store re-runs no migration" do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-ch-reopen-#{unique}.db")

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      first = :"ch_reopen_a_#{unique}"
      start_supervised!({Repo, name: first, enabled: true, database_path: db_path}, id: :first)
      assert {:ok, versions} = Repo.migration_versions(server: first)
      assert 28 in versions
      :ok = stop_supervised(:first)

      second = :"ch_reopen_b_#{unique}"
      start_supervised!({Repo, name: second, enabled: true, database_path: db_path}, id: :second)
      assert {:ok, ^versions} = Repo.migration_versions(server: second)
      assert {:ok, 0} = Repo.computer_history_count_memories(server: second)
    end
  end

  describe "memory kinds" do
    test "the window readers and recent_memories read session notes by default", %{repo: repo} do
      session_memory(repo, %{summary: "a session note"})
      session_memory(repo, thread_row("Apollo", [1], 1_000))

      assert {:ok, [only]} = Repo.computer_history_recent_memories(0, 10, server: repo)
      assert only.summary == "a session note"

      assert {:ok, [^only]} =
               Repo.computer_history_memories_in_window(0, 9_999, 10, server: repo)

      assert {:ok, 1} = Repo.computer_history_count_memories_in_window(0, 9_999, server: repo)
    end

    test "the window readers can select threads instead", %{repo: repo} do
      session_memory(repo, %{summary: "a session note"})
      session_memory(repo, thread_row("Apollo", [1], 1_000))

      assert {:ok, [thread]} =
               Repo.computer_history_memories_in_window(0, 9_999, 10, server: repo, kind: :thread)

      assert thread.subject == "Apollo"
      assert Jason.decode!(thread.source_ids) == [1]

      assert {:ok, 1} =
               Repo.computer_history_count_memories_in_window(0, 9_999,
                 server: repo,
                 kind: :thread
               )

      assert {:ok, [^thread]} =
               Repo.computer_history_recent_memories(0, 10, server: repo, kind: :thread)
    end

    test "count_memories counts both kinds unless asked for one", %{repo: repo} do
      session_memory(repo, %{summary: "a session note"})
      session_memory(repo, thread_row("Apollo", [1], 1_000))

      assert {:ok, 2} = Repo.computer_history_count_memories(server: repo)
      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo, kind: :session)
      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo, kind: :thread)
    end
  end

  describe "active threads" do
    test "returns non-superseded threads, most recently touched first", %{repo: repo} do
      session_memory(repo, thread_row("Older", [1], 1_000))
      session_memory(repo, thread_row("Newer", [2], 5_000))
      session_memory(repo, thread_row("Retired", [3], 9_000, %{superseded_at: 9_500}))

      assert {:ok, threads} = Repo.computer_history_active_threads(8, server: repo)
      assert Enum.map(threads, & &1.subject) == ["Newer", "Older"]
    end

    test "honours the limit and ignores session notes", %{repo: repo} do
      session_memory(repo, %{summary: "a session note"})
      session_memory(repo, thread_row("Older", [1], 1_000))
      session_memory(repo, thread_row("Newer", [2], 5_000))

      assert {:ok, [one]} = Repo.computer_history_active_threads(1, server: repo)
      assert one.subject == "Newer"
    end
  end

  describe "session notes since" do
    test "returns only session notes created after the mark, newest first", %{repo: repo} do
      session_memory(repo, %{created_at: 1_000, summary: "before the mark"})
      session_memory(repo, %{created_at: 3_000, summary: "after the mark"})
      session_memory(repo, %{created_at: 4_000, summary: "later still"})
      session_memory(repo, thread_row("Apollo", [1], 5_000))

      assert {:ok, notes} = Repo.computer_history_session_notes_since(2_000, 10, server: repo)
      assert Enum.map(notes, & &1.summary) == ["later still", "after the mark"]
    end

    # S3: the limit must keep the NEWEST notes — the oldest ones are the least
    # likely to describe current work, and they stay in the journal either way.
    test "the limit keeps the newest notes, and the count says how many there were", %{repo: repo} do
      for index <- 1..10 do
        session_memory(repo, %{created_at: 1_000 + index, summary: "note-#{index}"})
      end

      assert {:ok, notes} = Repo.computer_history_session_notes_since(0, 3, server: repo)
      assert Enum.map(notes, & &1.summary) == ["note-10", "note-9", "note-8"]

      assert {:ok, 10} = Repo.computer_history_count_session_notes_since(0, server: repo)
      assert {:ok, 2} = Repo.computer_history_count_session_notes_since(1_008, server: repo)
    end

    test "a zero mark returns every session note", %{repo: repo} do
      session_memory(repo, %{created_at: 1_000, summary: "first"})
      assert {:ok, [_note]} = Repo.computer_history_session_notes_since(0, 10, server: repo)
    end
  end

  describe "roll-up write" do
    test "supersedes the previous threads, inserts the new set and stamps the mark", %{repo: repo} do
      note_id = session_memory(repo, %{summary: "a session note"})
      session_memory(repo, thread_row("Retiring", [note_id], 1_000))

      threads = [
        %{
          subject: "Apollo migration",
          summary: "Waiting on the restore check.",
          source_ids: Jason.encode!([note_id]),
          last_touched_ts: 1_000,
          created_at: 7_000,
          provenance_from_ts: 500,
          provenance_to_ts: 1_000,
          titles: Jason.encode!(["Apollo migration plan"]),
          model: "ollama",
          event_count: 0
        }
      ]

      assert {:ok, %{written: 1, retired: 1, purged: 0, subjects: ["Apollo migration"]}} =
               Repo.computer_history_write_rollup(threads, 7_000, server: repo)

      assert {:ok, [thread]} = Repo.computer_history_active_threads(8, server: repo)
      assert thread.subject == "Apollo migration"
      assert thread.kind == "thread"

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_rollup_ts == 7_000

      # The journal underneath is untouched: threads never supersede session notes.
      assert {:ok, [note]} = Repo.computer_history_recent_memories(0, 10, server: repo)
      assert note.id == note_id
    end

    # S1: a purge issued while the roll-up call was in flight. The watermark is
    # the only thing standing between a thread built from a note the owner just
    # erased and a stored row citing a deleted id.
    test "a thread whose window was purged during the call is not written", %{repo: repo} do
      note_id = session_memory(repo, %{provenance_from_ts: 500, provenance_to_ts: 1_000})
      # The prior thread sits OUTSIDE the purge window, so it must survive intact.
      session_memory(repo, thread_row("Still current", [note_id], 9_000))

      assert {:ok, _counts} = Repo.computer_history_purge_window(0, 5_000, server: repo)

      proposed = [
        %{
          subject: "Apollo migration",
          summary: "Built from a note the owner just purged.",
          source_ids: Jason.encode!([note_id]),
          last_touched_ts: 1_000,
          created_at: 7_000,
          provenance_from_ts: 500,
          provenance_to_ts: 1_000,
          model: "ollama",
          event_count: 0
        }
      ]

      assert {:ok, %{written: 0, retired: 0, purged: 1, subjects: []}} =
               Repo.computer_history_write_rollup(proposed, 7_000, server: repo)

      assert {:ok, [survivor]} = Repo.computer_history_active_threads(8, server: repo)
      assert survivor.subject == "Still current"

      {:ok, state} = Repo.computer_history_ensure_state(server: repo)
      assert state.last_rollup_ts == nil
    end

    test "the threads the purge did not reach are still written", %{repo: repo} do
      purged_note = session_memory(repo, %{provenance_from_ts: 500, provenance_to_ts: 1_000})
      kept_note = session_memory(repo, %{provenance_from_ts: 8_000, provenance_to_ts: 9_000})

      assert {:ok, _counts} = Repo.computer_history_purge_window(0, 5_000, server: repo)

      proposed = [
        %{
          subject: "Purged work",
          summary: "Drawn from the erased window.",
          source_ids: Jason.encode!([purged_note]),
          last_touched_ts: 1_000,
          created_at: 7_000,
          provenance_from_ts: 500,
          provenance_to_ts: 1_000,
          model: "ollama",
          event_count: 0
        },
        %{
          subject: "Surviving work",
          summary: "Drawn from outside it.",
          source_ids: Jason.encode!([kept_note]),
          last_touched_ts: 9_000,
          created_at: 7_000,
          provenance_from_ts: 8_000,
          provenance_to_ts: 9_000,
          model: "ollama",
          event_count: 0
        }
      ]

      assert {:ok, %{written: 1, purged: 1, subjects: ["Surviving work"]}} =
               Repo.computer_history_write_rollup(proposed, 10_000, server: repo)

      assert {:ok, [thread]} = Repo.computer_history_active_threads(8, server: repo)
      assert thread.subject == "Surviving work"

      {:ok, state} = Repo.computer_history_ensure_state(server: repo)
      assert state.last_rollup_ts == 10_000
    end

    test "refuses an empty thread set instead of superseding everything", %{repo: repo} do
      session_memory(repo, thread_row("Still current", [1], 1_000))

      assert {:error, :no_threads} = Repo.computer_history_write_rollup([], 7_000, server: repo)
      assert {:ok, [_still_there]} = Repo.computer_history_active_threads(8, server: repo)

      {:ok, state} = Repo.computer_history_ensure_state(server: repo)
      assert state.last_rollup_ts == nil
    end
  end

  describe "topic search" do
    test "matches a session note's summary and a thread's subject", %{repo: repo} do
      session_memory(repo, %{summary: "reviewed the quarterly revenue deck"})
      session_memory(repo, thread_row("Apollo migration", [1], 5_000))

      assert {:ok, [note]} = Repo.computer_history_search_memories("quarterly", 10, server: repo)
      assert note.summary == "reviewed the quarterly revenue deck"

      assert {:ok, [thread]} = Repo.computer_history_search_memories("apollo", 10, server: repo)
      assert thread.subject == "Apollo migration"
    end

    test "matches stored titles and urls", %{repo: repo} do
      session_memory(repo, %{
        summary: "read a doc",
        titles: Jason.encode!(["Q3 Report — Docs"]),
        urls: Jason.encode!(["https://docs.example.com/q3"])
      })

      assert {:ok, [_by_title]} = Repo.computer_history_search_memories("Q3", 10, server: repo)

      assert {:ok, [_by_url]} =
               Repo.computer_history_search_memories("docs.example.com", 10, server: repo)
    end

    test "every token must match (AND, never OR)", %{repo: repo} do
      session_memory(repo, %{summary: "reviewed the quarterly revenue deck"})

      assert {:ok, [_both]} =
               Repo.computer_history_search_memories("quarterly deck", 10, server: repo)

      assert {:ok, []} =
               Repo.computer_history_search_memories("quarterly pancake", 10, server: repo)
    end

    test "user text is never FTS syntax", %{repo: repo} do
      session_memory(repo, %{summary: "reviewed the quarterly revenue deck"})
      session_memory(repo, %{summary: "unrelated note about bicycles"})

      # `OR` is a literal token here, so this ANDs three words and matches
      # nothing; as FTS5 syntax it would have returned both rows.
      assert {:ok, []} =
               Repo.computer_history_search_memories("quarterly OR bicycles", 10, server: repo)

      # A stray quote neither errors nor changes what the word matches.
      assert {:ok, [quoted]} =
               Repo.computer_history_search_memories(~s(bicycles" ), 10, server: repo)

      assert quoted.summary == "unrelated note about bicycles"

      # A column filter and a NEAR call are literal text, not FTS5 operators.
      assert {:ok, []} =
               Repo.computer_history_search_memories("summary:bicycles", 10, server: repo)

      assert {:ok, []} = Repo.computer_history_search_memories("NEAR(a b)", 10, server: repo)
    end

    test "counts every match, not only the page returned", %{repo: repo} do
      for index <- 1..5 do
        session_memory(repo, %{created_at: 1_000 + index, summary: "apollo note-#{index}"})
      end

      assert {:ok, rows} = Repo.computer_history_search_memories("apollo", 2, server: repo)
      assert length(rows) == 2
      assert {:ok, 5} = Repo.computer_history_count_search_memories("apollo", server: repo)

      assert {:error, :empty_query} =
               Repo.computer_history_count_search_memories("***", server: repo)
    end

    test "a query with no searchable token is refused, never run", %{repo: repo} do
      assert {:error, :empty_query} =
               Repo.computer_history_search_memories("  ", 10, server: repo)

      assert {:error, :empty_query} =
               Repo.computer_history_search_memories("-- ***", 10, server: repo)
    end

    test "superseded rows and purged rows leave the index", %{repo: repo} do
      note_id = session_memory(repo, %{summary: "reviewed the quarterly revenue deck"})
      session_memory(repo, thread_row("Retiring subject", [note_id], 1_000))

      assert {:ok, [_thread]} =
               Repo.computer_history_search_memories("retiring", 10, server: repo)

      threads = [
        %{
          subject: "Apollo migration",
          summary: "Waiting on the restore check.",
          source_ids: Jason.encode!([note_id]),
          last_touched_ts: 1_000,
          created_at: 7_000,
          provenance_from_ts: 500,
          provenance_to_ts: 1_000,
          model: "ollama",
          event_count: 0
        }
      ]

      assert {:ok, _counts} = Repo.computer_history_write_rollup(threads, 7_000, server: repo)

      # The superseded thread is gone from search; the new one is found.
      assert {:ok, []} = Repo.computer_history_search_memories("retiring", 10, server: repo)
      assert {:ok, [_new]} = Repo.computer_history_search_memories("apollo", 10, server: repo)

      # Purge removes the row AND its index entry.
      assert {:ok, _purged} = Repo.computer_history_purge_window(0, 9_999, server: repo)
      assert {:ok, []} = Repo.computer_history_search_memories("quarterly", 10, server: repo)
    end
  end

  describe "roll-up attempt marker" do
    # S5: the attempt mark is what rate-limits a roll-up whose reply is unusable.
    # It is a separate column from `last_rollup_ts`, which still moves only on a
    # real write (it is the notes cursor).
    test "records the attempt without touching the write mark", %{repo: repo} do
      assert :ok = Repo.computer_history_stamp_rollup_attempt(7_000, server: repo)

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.last_rollup_attempt_ts == 7_000
      assert state.last_rollup_ts == nil
    end
  end

  describe "session open marker" do
    test "records and clears the open-session mark", %{repo: repo} do
      assert :ok = Repo.computer_history_set_session_open_since(4_200, server: repo)
      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.session_open_since_ts == 4_200

      assert :ok = Repo.computer_history_set_session_open_since(nil, server: repo)
      {:ok, cleared} = Repo.computer_history_fetch_state(server: repo)
      assert cleared.session_open_since_ts == nil
    end
  end
end
