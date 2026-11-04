defmodule FermixCore.Home.Archive.ScreenHistoryTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Home.Archive.ScreenHistory
  alias FermixCore.Memory.Repo.ComputerHistorySql
  alias FermixTestSupport.SafeRm

  @now 1_793_083_733_000

  setup do
    tmp = SafeRm.make_tmp_dir!("screen_history")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{db: Path.join(tmp, "memory.db")}
  end

  test "removes every screen-history row of a restored database and counts them", %{db: db} do
    seed!(db, events: 3, memories: 2)

    assert ScreenHistory.clear(db, @now) == {:ok, 5}

    conn = open!(db)
    assert ComputerHistorySql.count_events(conn) == {:ok, 0}
    assert ComputerHistorySql.count_memories(conn, :all, :all) == {:ok, 0}
    assert query!(conn, "SELECT COUNT(*) FROM computer_history_access") == [[0]]
    assert query!(conn, "SELECT COUNT(*) FROM unrelated") == [[1]]
    :ok = Sqlite3.close(conn)
  end

  test "a database that never had the feature has nothing to remove", %{db: db} do
    conn = open!(db)
    :ok = Sqlite3.execute(conn, "CREATE TABLE unrelated (id INTEGER)")
    :ok = Sqlite3.close(conn)

    assert ScreenHistory.clear(db, @now) == {:ok, 0}
  end

  test "a row stamped after the clear's bound is refused by name, not left behind quietly",
       %{db: db} do
    seed!(db, events: 1, memories: 0, ts: @now + 60_000)

    assert ScreenHistory.clear(db, @now) == {:error, {:screen_history_remaining, 1}}
  end

  test "a missing database is an error, never a new empty file", %{db: db} do
    assert {:error, {:screen_history, _reason}} = ScreenHistory.clear(db, @now)
    refute File.exists?(db)
  end

  defp seed!(db, opts) do
    conn = open!(db)
    ts = Keyword.get(opts, :ts, @now - 3_600_000)

    for sql <- [
          ComputerHistorySql.events_schema_sql(),
          ComputerHistorySql.memories_schema_sql(),
          ComputerHistorySql.state_schema_sql(),
          ComputerHistorySql.access_schema_sql(),
          ComputerHistorySql.purges_schema_sql(@now - 86_400_000),
          "CREATE TABLE unrelated (id INTEGER); INSERT INTO unrelated VALUES (1);"
        ] do
      :ok = Sqlite3.execute(conn, sql)
    end

    for n <- 1..opts[:events]//1 do
      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO computer_history_events (boot_id, source_seq, ts, type) " <>
            "VALUES ('invented-boot', #{n}, #{ts}, 'app_switch')"
        )
    end

    for _n <- 1..opts[:memories]//1 do
      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO computer_history_memories " <>
            "(created_at, provenance_from_ts, provenance_to_ts, summary, model) " <>
            "VALUES (#{ts}, #{ts - 1_000}, #{ts}, 'invented summary', 'invented-model')"
        )
    end

    :ok =
      Sqlite3.execute(
        conn,
        "INSERT INTO computer_history_access (ts, sink) VALUES (#{ts}, 'recall')"
      )

    :ok = Sqlite3.close(conn)
  end

  defp open!(db) do
    {:ok, conn} = Sqlite3.open(db)
    conn
  end

  defp query!(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end
end
