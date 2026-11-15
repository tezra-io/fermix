defmodule FermixCore.ComputerHistory.SpoolApplyTest do
  # M97 §8.5: how a machine applies its home's purge and pause intervals. The
  # pause horizon only ever rises, in one write, whoever applies a pause; a
  # machine with no store answers that it applied nothing; a mark belongs to
  # one home store, and one under another store is replaced, never raised.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory.Spool
  alias FermixTestSupport.HistorySpool
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 09:00:00.000Z]
  @home "4f2a9c1e7b3d5a60.1"

  setup do
    dir = SafeRm.make_tmp_dir!("ch-spool-apply")
    on_exit(fn -> SafeRm.rm_rf(dir) end)
    path = Path.join([dir, "device", "history.db"])
    spool = start_supervised!({Spool, name: nil, path: path})
    %{dir: dir, path: path, spool: spool}
  end

  defp pause(id, until),
    do: %{id: id, from_ts: ms(@now), to_ts: ms(until), issued_at: ms(@now), kind: "pause"}

  defp ms(at), do: DateTime.to_unix(at, :millisecond)

  defp horizon(spool) do
    {:ok, %{pause_until: until}} = Spool.state(server: spool)
    until
  end

  test "a pause applied after a later one never lowers the horizon", %{spool: spool} do
    later = ~U[2031-05-04 11:00:00.000Z]
    earlier = ~U[2031-05-04 10:00:00.000Z]

    assert :ok = Spool.apply_intervals([pause(2, later)], @home, @now, server: spool)
    assert :ok = Spool.apply_intervals([pause(1, earlier)], @home, @now, server: spool)

    assert horizon(spool) == DateTime.to_iso8601(later)
  end

  # Horizons are times, not strings: a horizon written without a fraction of a
  # second is earlier than one half a second later, though it sorts after it.
  test "a later horizon replaces an earlier one however its seconds are written", ctx do
    HistorySpool.put_pause_until(ctx.spool, "2031-05-04T10:00:00Z")

    assert :ok =
             Spool.apply_intervals([pause(1, ~U[2031-05-04 10:00:00.500Z])], @home, @now,
               server: ctx.spool
             )

    assert horizon(ctx.spool) == "2031-05-04T10:00:00.500Z"
  end

  # Ingest keeps capture paused on a horizon it cannot read, until it is
  # cleared; a pause from chat must not turn that into a finite one.
  test "a horizon that cannot be read is kept", ctx do
    HistorySpool.put_pause_until(ctx.spool, "not-a-time")

    assert :ok =
             Spool.apply_intervals([pause(1, ~U[2031-05-04 10:00:00.000Z])], @home, @now,
               server: ctx.spool
             )

    assert horizon(ctx.spool) == "not-a-time"
  end

  test "applied on a connection of its own, the store answers its mark", %{path: path} do
    assert {:ok, 3} = Spool.apply_at(path, @home, [pause(3, ~U[2031-05-04 10:00:00.000Z])], @now)
    assert {:ok, 3} = Spool.apply_at(path, @home, [pause(2, ~U[2031-05-04 10:30:00.000Z])], @now)
  end

  # Interval ids start again where the home's store does: a mark of another
  # store says nothing about this one, so it is replaced, even by a lower one.
  test "a mark under another home store is replaced, never raised", %{path: path, spool: spool} do
    assert {:ok, 7} = Spool.apply_at(path, @home, [pause(7, ~U[2031-05-04 10:00:00.000Z])], @now)

    other = "9e8d7c6b5a493827.1"
    assert {:ok, 2} = Spool.apply_at(path, other, [pause(2, ~U[2031-05-04 10:00:00.000Z])], @now)
    assert {:ok, %{home_mark: 2, home: ^other}} = Spool.link(server: spool)

    # Nothing to apply from a store it has not heard from still starts it at 0.
    assert :ok = Spool.apply_intervals([], @home, @now, server: spool)
    assert {:ok, %{home_mark: 0, home: @home}} = Spool.link(server: spool)
  end

  # A machine with no store applied nothing, so its home must not record the
  # intervals as applied there: a store it opens later starts from the first.
  test "a machine with no store answers that it applied nothing, and creates none", %{dir: dir} do
    absent = Path.join([dir, "elsewhere", "device", "history.db"])

    assert {:ok, 0} =
             Spool.apply_at(absent, @home, [pause(4, ~U[2031-05-04 10:00:00.000Z])], @now)

    refute File.exists?(absent)
  end

  # The store's second version: a store of the first gains the column that
  # names its home's store, and keeps what it holds.
  test "a store of the first version gains its home column and keeps its mark", %{dir: dir} do
    old = Path.join([dir, "old", "device", "history.db"])
    File.mkdir_p!(Path.dirname(old))
    {:ok, conn} = Sqlite3.open(old)

    try do
      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY);
        CREATE TABLE computer_history_link (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          home_mark INTEGER NOT NULL DEFAULT 0,
          expired_unsent INTEGER NOT NULL DEFAULT 0,
          last_answer TEXT,
          last_reason TEXT,
          last_answer_at INTEGER
        );
        INSERT INTO computer_history_link (id, home_mark) VALUES (1, 5);
        INSERT INTO schema_migrations (version) VALUES (1);
        """)
    after
      Sqlite3.close(conn)
    end

    spool = start_supervised!({Spool, name: nil, path: old}, id: :old_spool)
    assert {:ok, %{home_mark: 5, home: nil}} = Spool.link(server: spool)
  end
end
