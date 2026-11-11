defmodule FermixCore.Memory.RepoComputerHistoryMachinesMigrationTest do
  # M97 §8.1, §8.4, §8.6: migration 59 moves the raw spool out of memory.db into
  # this machine's own store and makes every note name its machine. The tables
  # as migrations 23 to 32 left them are rebuilt from the module's own DDL for
  # those versions, seeded with rows of today's shape, and the store is then
  # booted through the migration. Membership, never list equality, for the
  # version.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql
  alias FermixTestSupport.SafeRm

  @version 59
  @t0 1_793_000_000_000

  setup do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "fermix-history-machines-#{unique}")
    File.mkdir_p!(dir)
    on_exit(fn -> SafeRm.rm_rf(dir) end)

    %{
      dir: dir,
      db_path: Path.join(dir, "memory.db"),
      spool_path: Path.join([dir, "home", "device", "history.db"]),
      repo: :"memory_repo_history_machines_#{unique}"
    }
  end

  test "a fresh database carries the version and writes no machine store", ctx do
    start_repo(ctx, :fresh)
    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions
    refute File.exists?(ctx.spool_path)
    refute "computer_history_events" in tables(ctx.db_path)
  end

  test "a Mac's raw spool moves to its machine store, ids, fence, cursor and pause kept", ctx do
    old_home(ctx)
    seed_spool(ctx.db_path)
    start_repo(ctx, :upgraded)

    refute "computer_history_events" in tables(ctx.db_path)
    assert count(ctx.db_path, "computer_history_purges") == 0

    {:ok, spool} = Spool.start_link(path: ctx.spool_path, name: nil)
    assert {:ok, events} = Spool.events_after(0, 10, server: spool)
    assert Enum.map(events, & &1.id) == [7, 8, 9]
    assert Enum.map(events, & &1.text) == ["draft one", "draft two", "draft three"]

    assert {:ok, %{last_summarized_id: 8, pause_until: "2031-01-01T00:00:00Z"}} =
             Spool.state(server: spool)

    # The carried fence still refuses a late event stamped inside it.
    assert {:ok, 0} = Spool.insert_events([event(40, @t0 - 500, "late")], server: spool)
    # A new event's id follows the old sequence: the cursor never skips it.
    assert {:ok, 1} = Spool.insert_events([event(41, @t0 + 9_000, "new")], server: spool)
    assert {:ok, [%{id: id}]} = Spool.events_after(9, 10, server: spool)
    assert id > 9
  end

  test "notes, reads and purges name their machine; old notes are the home's own", ctx do
    old_home(ctx)
    seed_note(ctx.db_path)
    start_repo(ctx, :upgraded)

    assert {:ok, [note]} = Repo.computer_history_recent_memories(0, 5, server: ctx.repo)
    assert note.computer_id == ""
    assert note.sitting == nil

    assert {:ok, [_note]} =
             Repo.computer_history_recent_memories(0, 5, server: ctx.repo, computer: "")

    assert {:ok, []} =
             Repo.computer_history_recent_memories(0, 5, server: ctx.repo, computer: "studio-x")

    assert {:ok, []} = Repo.computer_history_home(:computer_rows, [], server: ctx.repo)

    assert {:ok, %{interval: _id}} =
             Repo.computer_history_home(:purge_notes, [0, 1, 2, "studio-x"], server: ctx.repo)
  end

  test "the cursor of a spool with no events left still moves the sequence past it", ctx do
    old_home(ctx)

    raw(
      ctx.db_path,
      "INSERT INTO computer_history_state (id, last_summarized_id) VALUES (1, 5000);"
    )

    start_repo(ctx, :upgraded)

    {:ok, spool} = Spool.start_link(path: ctx.spool_path, name: nil)
    assert {:ok, %{last_summarized_id: 5000}} = Spool.state(server: spool)
    assert {:ok, 1} = Spool.insert_events([event(1, @t0, "after")], server: spool)
    assert {:ok, [%{id: id}]} = Spool.events_after(5000, 10, server: spool)
    assert id > 5000
  end

  # An Always On server's memory.db came from the Mac it moved from, cleared by
  # the restore of the day: a purge over all of time, a stale cursor and pause.
  # None of it is the server's, so nothing is carried and all of it goes.
  test "an Always On server carries nothing and clears what the move left", ctx do
    old_home(ctx)
    seed_spool(ctx.db_path)
    start_repo(ctx, :upgraded, server?: true)

    refute File.exists?(ctx.spool_path)
    refute "computer_history_events" in tables(ctx.db_path)
    assert count(ctx.db_path, "computer_history_purges") == 0

    assert [[0, nil, nil]] =
             query(
               ctx.db_path,
               "SELECT last_summarized_id, pause_until, session_open_since_ts " <>
                 "FROM computer_history_state WHERE id = 1"
             )
  end

  # A home restored from an archive made before migration 59 onto a system with
  # no recorder (a Linux install): no store is made, since nothing here would
  # ever sweep it, and the raw rows go (M97 §8.3).
  test "a system with no recorder carries nothing and makes no store", ctx do
    old_home(ctx)
    seed_spool(ctx.db_path)
    start_repo(ctx, :upgraded, recorder?: false)

    refute File.exists?(ctx.spool_path)
    refute "computer_history_events" in tables(ctx.db_path)
    assert @version in versions(ctx.db_path)
  end

  # Stopped between the two steps: the carry committed, memory.db did not. The
  # next boot carries again (nothing twice) and finishes.
  test "a boot stopped after the carry and before memory.db's step finishes it", ctx do
    old_home(ctx)
    seed_spool(ctx.db_path)
    before = File.read!(ctx.db_path)
    start_repo(ctx, :upgraded)
    stop_supervised!(:upgraded)

    File.write!(ctx.db_path, before)
    Enum.each(["-wal", "-shm"], &SafeRm.rm(ctx.db_path <> &1))
    start_repo(ctx, :again)

    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert @version in versions
    {:ok, spool} = Spool.start_link(path: ctx.spool_path, name: nil)
    assert {:ok, 3} = Spool.count_events(server: spool)
  end

  # Stopped inside the carry: its transaction is undone, memory.db keeps every
  # row, the boot fails loudly, and the next one carries.
  test "a carry that cannot finish leaves memory.db as it was", ctx do
    old_home(ctx)
    seed_spool(ctx.db_path)
    blocked = Path.join(ctx.dir, "blocked")
    File.write!(blocked, "a file where a folder must be")

    assert {:error, _reason} =
             start_supervised(
               {Repo,
                name: ctx.repo,
                enabled: true,
                database_path: ctx.db_path,
                history_spool_path: Path.join([blocked, "device", "history.db"]),
                history_server?: false,
                history_recorder?: true},
               id: :blocked
             )

    assert "computer_history_events" in tables(ctx.db_path)
    assert count(ctx.db_path, "computer_history_events") == 3
    refute @version in versions(ctx.db_path)

    start_repo(ctx, :fixed)
    {:ok, spool} = Spool.start_link(path: ctx.spool_path, name: nil)
    assert {:ok, 3} = Spool.count_events(server: spool)
  end

  # -- the database of today ----------------------------------------------------------

  defp start_repo(ctx, id, opts \\ []) do
    start_supervised!(
      {Repo,
       name: ctx.repo,
       enabled: true,
       database_path: ctx.db_path,
       history_spool_path: ctx.spool_path,
       history_server?: Keyword.get(opts, :server?, false),
       history_recorder?: Keyword.get(opts, :recorder?, true)},
      id: id
    )
  end

  # The history tables as migrations 23 to 32 built them, from the same DDL,
  # in a store otherwise at today's version, with 59 and every later history
  # migration not yet run (60 adds columns to the table 59 makes).
  defp old_home(ctx) do
    start_repo(ctx, :current)
    stop_supervised!(:current)

    raw(ctx.db_path, """
    DROP TRIGGER IF EXISTS computer_history_memories_ai;
    DROP TRIGGER IF EXISTS computer_history_memories_ad;
    DROP TRIGGER IF EXISTS computer_history_memories_au;
    DROP TABLE IF EXISTS computer_history_memories_fts;
    DROP TABLE IF EXISTS computer_history_memories;
    DROP TABLE IF EXISTS computer_history_access;
    DROP TABLE IF EXISTS computer_history_purges;
    DROP TABLE IF EXISTS computer_history_state;
    DROP TABLE IF EXISTS computer_history_computers;
    DROP TABLE IF EXISTS computer_history_events;
    #{ComputerHistorySql.events_schema_sql()}
    #{ComputerHistorySql.memories_schema_sql()}
    #{ComputerHistorySql.state_schema_sql()}
    #{ComputerHistorySql.access_schema_sql()}
    #{ComputerHistorySql.sessions_schema_sql()}
    #{ComputerHistorySql.purges_schema_sql(@t0)}
    DELETE FROM schema_migrations WHERE version IN (#{@version}, #{@version + 1});
    """)
  end

  defp seed_spool(db_path) do
    raw(db_path, """
    INSERT INTO computer_history_events (id, boot_id, source_seq, ts, type, bundle_id, text)
      VALUES (7, 'b', 1, #{@t0 + 1_000}, 'field.value', 'com.example.notes', 'draft one'),
             (8, 'b', 2, #{@t0 + 2_000}, 'field.value', 'com.example.notes', 'draft two'),
             (9, 'b', 3, #{@t0 + 3_000}, 'field.value', 'com.example.notes', 'draft three');
    INSERT INTO computer_history_purges (from_ts, to_ts, issued_at)
      VALUES (#{@t0 - 1_000}, #{@t0}, #{@t0});
    INSERT INTO computer_history_state (id, last_summarized_id, pause_until, session_open_since_ts)
      VALUES (1, 8, '2031-01-01T00:00:00Z', #{@t0 + 3_000});
    """)
  end

  defp seed_note(db_path) do
    raw(db_path, """
    INSERT INTO computer_history_memories
      (created_at, provenance_from_ts, provenance_to_ts, summary, event_count, model, kind)
      VALUES (#{@t0}, #{@t0 - 60_000}, #{@t0}, 'Edited the lease notes.', 4, 'model-x', 'session');
    INSERT INTO computer_history_access (ts, sink, result_count) VALUES (#{@t0}, 'recall_activity', 1);
    """)
  end

  defp event(seq, ts, text) do
    %{
      boot_id: "after-upgrade",
      source_seq: seq,
      ts: ts,
      type: "field.value",
      bundle_id: "com.example.notes",
      text: text
    }
  end

  # -- reading the file directly ----------------------------------------------------------

  defp tables(db_path) do
    db_path
    |> query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    |> List.flatten()
  end

  defp versions(db_path),
    do: db_path |> query("SELECT version FROM schema_migrations") |> List.flatten()

  defp count(db_path, table) do
    [[count]] = query(db_path, "SELECT count(*) FROM #{table}")
    count
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      :ok = Sqlite3.execute(conn, sql)
    after
      :ok = Sqlite3.close(conn)
    end
  end

  defp query(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      :ok = Sqlite3.close(conn)
    end
  end
end
