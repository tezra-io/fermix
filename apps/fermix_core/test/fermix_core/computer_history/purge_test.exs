defmodule FermixCore.ComputerHistory.PurgeTest do
  @moduledoc "MILESTONE_32 §12 — owner purge (inv. 9)."
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Memory.Repo

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("ch-purge")
    db_path = Path.join(dir, "memory.db")
    spool_path = Path.join([dir, "device", "history.db"])
    repo_name = :"ch_purge_repo_#{System.unique_integer([:positive])}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})
    spool = start_supervised!({Spool, name: nil, path: spool_path})
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)

    %{repo: repo_name, spool: spool, db_path: db_path, spool_path: spool_path}
  end

  # The recorded intervals, read straight from a store: the home's
  # `[from, to, issued_at, computer_id, kind]`, a machine's `[from, to, issued_at]`.
  defp intervals(db_path, columns) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readonly)

    try do
      sql = "SELECT #{columns} FROM computer_history_purges ORDER BY id"
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end

  defp home_intervals(db_path),
    do: intervals(db_path, "from_ts, to_ts, issued_at, computer_id, kind")

  defp machine_intervals(path), do: intervals(path, "from_ts, to_ts, issued_at")

  defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

  defp memory(from_ts, to_ts, extra \\ %{}) do
    Map.merge(
      %{
        created_at: to_ts,
        provenance_from_ts: from_ts,
        provenance_to_ts: to_ts,
        summary: "worked in an app",
        model: "ollama",
        event_count: 1
      },
      extra
    )
  end

  # A machine store that answers every request with an error.
  defmodule FailingStore do
    @moduledoc false
    use GenServer

    def start_link(_arg), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :injected}, state}
  end

  defp purge(window, now, ctx, opts \\ []),
    do: Purge.purge(window, [now: now, repo: ctx.repo, spool: ctx.spool] ++ opts)

  describe "parse_window/1" do
    test "accepts minutes, hours, and all" do
      assert Purge.parse_window("10m") == {:ok, {:last, 600_000}}
      assert Purge.parse_window("1h") == {:ok, {:last, 3_600_000}}
      assert Purge.parse_window("24h") == {:ok, {:last, 86_400_000}}
      assert Purge.parse_window("all") == {:ok, :all}
    end

    test "rejects anything else" do
      assert Purge.parse_window("yesterday") == {:error, :invalid_window}
      assert Purge.parse_window("10s") == {:error, :invalid_window}
      assert Purge.parse_window("") == {:error, :invalid_window}
    end
  end

  describe "purge/2" do
    test "removes in-window events + intersecting notes, keeps the rest, records the interval",
         %{repo: repo, spool: spool} = ctx do
      assert {:ok, 2} = Spool.insert_events([event(1, 1_000), event(2, 5_000)], server: spool)

      {:ok, _} = Repo.computer_history_insert_memory(memory(900, 1_100), server: repo)
      {:ok, _} = Repo.computer_history_insert_memory(memory(4_000, 6_000), server: repo)

      # Window [0, 2000]: catches the ts=1000 event and the [900,1100] note.
      assert {:ok, %{events: 1, memories: 1, from_ts: 0, to_ts: 2_000, interval: id}} =
               purge({:last, 2_000}, 2_000, ctx)

      assert is_integer(id)
      assert {:ok, 1} = Spool.count_events(server: spool)
      assert {:ok, 5_000} = Spool.oldest_event_ts(server: spool)
      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)

      # The home records it for every machine; this machine fences its own raw events.
      assert home_intervals(ctx.db_path) == [[0, 2_000, 2_000, nil, "purge"]]
      assert machine_intervals(ctx.spool_path) == [[0, 2_000, 2_000]]
      assert {:ok, %{home_mark: ^id}} = Spool.link(server: spool)
    end

    test "purge all clears everything", %{repo: repo, spool: spool} = ctx do
      assert {:ok, 3} =
               Spool.insert_events([event(1, 1_000), event(2, 5_000), event(3, 9_000)],
                 server: spool
               )

      {:ok, _} = Repo.computer_history_insert_memory(memory(1_000, 2_000), server: repo)

      assert {:ok, %{events: 3, memories: 1}} = purge(:all, 10_000, ctx)
      assert {:ok, 0} = Spool.count_events(server: spool)
      assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)
    end

    # CH-5: `all` ends at now. A far-future ceiling would fence every later event
    # and refuse every later note for good.
    test "purge all records [0, now] and later capture is still stored",
         %{spool: spool} = ctx do
      assert {:ok, %{from_ts: 0, to_ts: 10_000}} = purge(:all, 10_000, ctx)
      assert home_intervals(ctx.db_path) == [[0, 10_000, 10_000, nil, "purge"]]
      assert machine_intervals(ctx.spool_path) == [[0, 10_000, 10_000]]

      assert {:ok, 1} = Spool.insert_events([event(1, 10_001)], server: spool)
    end

    # M97 §8.5: a purge of one computer's notes takes that computer's notes and
    # every thread that reaches the window, never another machine's notes, and
    # leaves this machine's own raw events alone.
    test "a purge for one computer takes its notes and the threads, and no other machine's",
         %{repo: repo, spool: spool} = ctx do
      {:ok, 1} = Spool.insert_events([event(1, 1_000)], server: spool)

      {:ok, _} =
        Repo.computer_history_insert_memory(memory(900, 1_100, %{computer_id: "studio"}),
          server: repo
        )

      {:ok, _} = Repo.computer_history_insert_memory(memory(900, 1_100), server: repo)

      {:ok, _} =
        Repo.computer_history_insert_memory(memory(900, 1_100, %{kind: "thread"}), server: repo)

      assert {:ok, %{events: 0, memories: 2}} =
               purge({:last, 2_000}, 2_000, ctx, computer: "studio")

      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)
      assert {:ok, 1} = Spool.count_events(server: spool)
      assert home_intervals(ctx.db_path) == [[0, 2_000, 2_000, "studio", "purge"]]
      assert machine_intervals(ctx.spool_path) == []
    end

    test "a home that keeps no machine store purges its notes alone", %{repo: repo} = ctx do
      {:ok, _} = Repo.computer_history_insert_memory(memory(900, 1_100), server: repo)

      assert {:ok, %{events: 0, memories: 1, here: :none}} =
               Purge.purge({:last, 2_000}, now: 2_000, repo: repo, spool: nil)

      assert home_intervals(ctx.db_path) == [[0, 2_000, 2_000, nil, "purge"]]
    end

    # history_submit HS-2 (check 14): an interval the home recorded that this
    # machine never applied (a second command ran beside it, or its own apply
    # failed after the home's transaction) is applied before the mark moves past
    # it, so the mark never says this machine applied what it did not.
    test "a purge here first applies every earlier interval this machine has not applied",
         %{repo: repo, spool: spool} = ctx do
      {:ok, 2} = Spool.insert_events([event(1, 1_000), event(2, 5_000)], server: spool)

      {:ok, %{interval: earlier}} =
        Repo.computer_history_home(:purge_notes, [900, 1_100, 3_000, :all], server: repo)

      assert {:ok, %{events: 1, interval: later, here: :ok}} = purge({:last, 100}, 6_000, ctx)
      assert later > earlier

      assert {:ok, [%{ts: 5_000}]} = Spool.events_after(0, 10, server: spool)
      assert machine_intervals(ctx.spool_path) == [[900, 1_100, 3_000], [5_900, 6_000, 6_000]]
      assert {:ok, %{home_mark: ^later}} = Spool.link(server: spool)
      assert {:ok, 0} = Spool.insert_events([event(3, 1_050)], server: spool)
    end

    # Two stores, no shared transaction: once the home's commits, the purge
    # stands, and the result says this machine has not applied it yet.
    test "a purge whose apply here fails stands on the home and says so", %{repo: repo} = ctx do
      {:ok, _} = Repo.computer_history_insert_memory(memory(900, 1_100), server: repo)
      failing = start_supervised!(FailingStore)

      assert {:ok, %{memories: 1, events: 0, here: {:failed, :injected}}} =
               Purge.purge({:last, 2_000}, now: 2_000, repo: repo, spool: failing)

      assert home_intervals(ctx.db_path) == [[0, 2_000, 2_000, nil, "purge"]]
      assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)
    end

    test "a purge the home cannot record changes nothing", %{repo: repo, spool: spool} = ctx do
      {:ok, 1} = Spool.insert_events([event(1, 1_000)], server: spool)

      assert {:error, :invalid_window} =
               Purge.purge({:last, -5}, now: 2_000, repo: repo, spool: spool)

      assert home_intervals(ctx.db_path) == []
      assert {:ok, 1} = Spool.count_events(server: spool)
    end
  end

  # CH-2: a row stamped inside a purged window can reach the insert after the purge
  # committed (a batch in flight, or still buffered). The insert refuses it.
  describe "the spool fence" do
    test "a row stamped inside a purged window that lands after the purge stays out",
         %{spool: spool} = ctx do
      assert {:ok, %{events: 0}} = purge({:last, 2_000}, 2_000, ctx)

      # Both bounds are inside the window, as in the purge's own DELETE.
      late = [event(1, 1_500), event(2, 0), event(3, 2_000), event(4, 2_001)]
      assert {:ok, 1} = Spool.insert_events(late, server: spool)

      assert {:ok, 1} = Spool.count_events(server: spool)
      assert {:ok, 2_001} = Spool.oldest_event_ts(server: spool)
    end

    test "every recorded window fences, not only the latest", %{spool: spool} = ctx do
      assert {:ok, _first} = purge({:last, 1_000}, 2_000, ctx)
      assert {:ok, _second} = purge({:last, 1_000}, 9_000, ctx)

      assert {:ok, 1} = Spool.insert_events([event(1, 1_500), event(2, 5_000)], server: spool)

      assert {:ok, 5_000} = Spool.oldest_event_ts(server: spool)
    end
  end
end
