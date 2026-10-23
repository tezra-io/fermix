defmodule FermixCore.Memory.RepoCuesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Ingest
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesDeliveriesSql
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Memory.Repo.CuesMandateSql
  alias FermixCore.Memory.Repo.CuesRunsSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Memory.Repo.CuesWatchersSql

  @now ~U[2026-10-10 12:00:00Z]
  @tables ~w(cues cue_sources cue_watchers cue_watcher_sources cue_watcher_instructions
             cue_watcher_examples cue_deliveries cue_gaps cue_filter_calls cue_mandate_calls
             cue_proposals cue_mandate_approvals)

  setup do
    start_repo("repo")
  end

  defp table_names(conn) do
    conn
    |> rows("SELECT name FROM sqlite_master WHERE type = 'table'")
    |> List.flatten()
  end

  describe "migration 42" do
    test "creates every cue table and the two job_runs columns", %{repo: repo, conn: conn} do
      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert 42 in versions
      assert @tables -- table_names(conn) == []

      columns = conn |> rows("SELECT name FROM pragma_table_info('job_runs')") |> List.flatten()
      assert "tools_started_at" in columns
      assert "cue_delivery_id" in columns
    end

    test "opening the same database again runs it once and keeps the rows", ctx do
      %{repo: repo, db_path: db_path, conn: conn} = ctx
      ref = "reopen-#{System.unique_integer([:positive])}"
      {:ok, _row} = Repo.cues_call(CuesSql, {:source_touch, ref, %{}, @now}, server: repo)

      :ok = stop_supervised(Repo)
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == 42)) == 1
      assert [[^ref]] = rows(conn, "SELECT source_ref FROM cue_sources")
    end
  end

  describe "dispatch" do
    test "routes a request to its SQL module", %{repo: repo} do
      assert {:ok, []} = Repo.cues_call(CuesSql, {:list_sources}, server: repo)
    end

    test "every lane's module answers an unknown request with an error", %{repo: repo} do
      for module <- [
            CuesSql,
            CuesWatchersSql,
            CuesFilterSql,
            CuesRunsSql,
            CuesDeliveriesSql,
            CuesMandateSql
          ] do
        assert {:error, {:unknown_request, {:nope}}} =
                 Repo.cues_call(module, {:nope}, server: repo)
      end
    end

    test "a module outside the cue SQL list is refused in the caller", %{repo: repo} do
      assert_raise FunctionClauseError, fn ->
        Repo.cues_call(String, {:list_sources}, server: repo)
      end
    end
  end

  describe "transition/6" do
    setup %{conn: conn, repo: repo} do
      ref = "cas-#{System.unique_integer([:positive])}"
      watcher = insert_watcher(conn, %{filter: "llm", sources: [ref]})
      item = item!(%{item_id: "cas-1", type: "t", data: "x"}, @now)

      {:ok, [:accepted]} =
        Ingest.accept(%{ref: ref, daily_budget: 0}, [item], now: @now, repo: repo)

      [[delivery_id]] =
        rows(conn, "SELECT id FROM cue_deliveries WHERE watcher_id = ?", [watcher])

      %{delivery_id: delivery_id}
    end

    defp state_of(conn, id) do
      [[state, call_id, attempts]] =
        rows(
          conn,
          "SELECT state, filter_call_id, filter_attempts FROM cue_deliveries WHERE id = ?",
          [id]
        )

      {state, call_id, attempts}
    end

    test "moves a row from its expected state and fence", %{conn: conn, delivery_id: id} do
      assert :ok =
               CuesSql.transition(conn, id, "pending", :none, "filtering", %{
                 filter_call_id: "cfc_1"
               })

      assert state_of(conn, id) == {"filtering", "cfc_1", 0}

      assert :ok =
               CuesSql.transition(conn, id, "filtering", {:filter_call_id, "cfc_1"}, "pending", %{
                 filter_call_id: nil,
                 filter_attempts: {:add, 1}
               })

      assert state_of(conn, id) == {"pending", nil, 1}
    end

    test "a moved row or a wrong fence is stale and changes nothing", %{
      conn: conn,
      delivery_id: id
    } do
      :ok =
        CuesSql.transition(conn, id, "pending", :none, "filtering", %{filter_call_id: "cfc_1"})

      log =
        capture_log(fn ->
          assert {:error, :stale} =
                   CuesSql.transition(conn, id, "pending", :none, "filtering", %{
                     filter_call_id: "cfc_2"
                   })

          assert {:error, :stale} =
                   CuesSql.transition(
                     conn,
                     id,
                     "filtering",
                     {:filter_call_id, "cfc_other"},
                     "dropped",
                     %{settled_at: @now}
                   )
        end)

      assert log =~ "stale"
      assert state_of(conn, id) == {"filtering", "cfc_1", 0}
    end

    test "a terminal state needs settled_at; an unknown column is refused", %{
      conn: conn,
      delivery_id: id
    } do
      assert {:error, {:invalid_transition, _detail}} =
               CuesSql.transition(conn, id, "pending", :none, "expired", %{outcome: "lifetime"})

      assert {:error, {:invalid_transition, _detail}} =
               CuesSql.transition(conn, id, "pending", :none, "passed", %{watcher_id: "x"})

      assert state_of(conn, id) == {"pending", nil, 0}
    end
  end

  describe "source state" do
    setup do
      %{ref: "src-#{System.unique_integer([:positive])}"}
    end

    test "touch upserts the given fields only", %{repo: repo, ref: ref} do
      good = ~U[2026-10-10 11:00:00Z]

      assert {:ok, row} =
               Repo.cues_call(
                 CuesSql,
                 {:source_touch, ref, %{status: "connected", last_good_at: good, cursor: "c1"},
                  @now},
                 server: repo
               )

      assert row.status == "connected"
      assert DateTime.compare(row.last_good_at, good) == :eq
      assert row.cursor == "c1"

      assert {:ok, row} =
               Repo.cues_call(CuesSql, {:source_touch, ref, %{status: "polling"}, @now},
                 server: repo
               )

      assert row.status == "polling"
      assert row.cursor == "c1"
      assert {:ok, ^row} = Repo.cues_call(CuesSql, {:get_source, ref}, server: repo)
      assert {:ok, nil} = Repo.cues_call(CuesSql, {:get_source, "absent"}, server: repo)

      assert {:error, {:invalid, :status}} =
               Repo.cues_call(CuesSql, {:source_touch, ref, %{status: "asleep"}, @now},
                 server: repo
               )
    end

    test "rejects are coalesced per reason", %{repo: repo, ref: ref} do
      reject = fn counts ->
        Repo.cues_call(CuesSql, {:source_reject, ref, counts, @now}, server: repo)
      end

      assert {:ok, %{"rate_limited" => 3}} = reject.(%{"rate_limited" => 3})

      assert {:ok, %{"rate_limited" => 4, "unauthorized" => 2}} =
               reject.(%{"rate_limited" => 1, "unauthorized" => 2})

      assert {:error, {:invalid, :reason}} = reject.(%{"Not A Reason" => 1})
      assert {:error, {:invalid, :reason}} = reject.(%{"rate_limited" => 0})

      assert {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ref}, server: repo)
      assert row.reject_counts == %{"rate_limited" => 4, "unauthorized" => 2}
      assert DateTime.compare(row.last_rejected_at, @now) == :eq
      assert {:ok, [listed]} = Repo.cues_call(CuesSql, {:list_sources}, server: repo)
      assert listed.source_ref == ref
    end
  end

  # Code Rule 4 and the single writer: a corrupt row is an error tuple, a raise
  # (a bug) stays loud, and neither leaves the Repo's connection inside an open
  # transaction.
  describe "corrupt rows and raises" do
    test "a source row that does not decode is an error, and the Repo stays up", ctx do
      %{repo: repo, conn: conn} = ctx
      pid = GenServer.whereis(repo)
      at = CuesSql.stamp(@now)

      exec!(
        conn,
        "INSERT INTO cue_sources (source_ref, status, reject_counts, updated_at) " <>
          "VALUES ('bad-json', 'idle', 'not json', ?)",
        [at]
      )

      exec!(
        conn,
        "INSERT INTO cue_sources (source_ref, status, last_good_at, updated_at) " <>
          "VALUES ('bad-stamp', 'idle', 'yesterday', ?)",
        [at]
      )

      get = fn ref -> Repo.cues_call(CuesSql, {:get_source, ref}, server: repo) end

      assert {:error, {:corrupt, "cue_sources", {:json_object, :reject_counts}}} =
               get.("bad-json")

      assert {:error, {:corrupt, "cue_sources", {:stamp, :last_good_at}}} = get.("bad-stamp")

      assert {:error, {:corrupt, "cue_sources", _detail}} =
               Repo.cues_call(CuesSql, {:list_sources}, server: repo)

      assert {:error, {:corrupt, "cue_sources", _detail}} =
               Repo.cues_call(CuesSql, {:source_touch, "bad-json", %{status: "polling"}, @now},
                 server: repo
               )

      # The touch's transaction rolled back, and the Repo still serves.
      assert [["idle"]] =
               rows(conn, "SELECT status FROM cue_sources WHERE source_ref = 'bad-json'")

      assert GenServer.whereis(repo) == pid
      assert {:ok, nil} = get.("absent")
    end

    test "a raise inside a cue transaction rolls it back and is raised again", %{conn: conn} do
      ref = "raise-#{System.unique_integer([:positive])}"

      assert_raise RuntimeError, "boom", fn ->
        CuesSql.with_immediate_transaction(conn, fn ->
          :ok =
            CuesSql.execute(
              conn,
              "INSERT INTO cue_sources (source_ref, updated_at) VALUES (?, ?)",
              [ref, CuesSql.stamp(@now)]
            )

          raise "boom"
        end)
      end

      assert [[0]] = rows(conn, "SELECT count(*) FROM cue_sources WHERE source_ref = ?", [ref])
      assert {:ok, :again} = CuesSql.with_immediate_transaction(conn, fn -> {:ok, :again} end)
    end
  end

  describe "gaps" do
    setup do
      %{ref: "gap-#{System.unique_integer([:positive])}"}
    end

    test "one open row per source, watcher and reason, extended and widened", %{
      repo: repo,
      ref: ref
    } do
      extend = fn watcher, count, range, now ->
        Repo.cues_call(CuesSql, {:extend_gap, ref, watcher, "disconnect", count, range, now},
          server: repo
        )
      end

      assert {:ok, gap_id} =
               extend.(nil, 2, {"2026-10-10T10:00:00Z", "2026-10-10T10:05:00Z"}, @now)

      later = DateTime.add(@now, 60, :second)
      assert {:ok, ^gap_id} = extend.(nil, 3, {"2026-10-10T09:55:00Z", nil}, later)
      assert {:ok, other_id} = extend.("cwt_a", 1, nil, @now)
      refute other_id == gap_id

      assert {:ok, [gap]} =
               Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ref, watcher_id: nil}},
                 server: repo
               )

      assert gap.id == gap_id
      assert gap.count == 5
      assert gap.range_from == "2026-10-10T09:55:00Z"
      assert gap.range_to == "2026-10-10T10:05:00Z"
      assert DateTime.compare(gap.last_at, later) == :eq
      assert gap.closed_at == nil
    end

    test "closing a gap lets the next extension open a new row", %{repo: repo, ref: ref} do
      extend = fn ->
        Repo.cues_call(CuesSql, {:extend_gap, ref, nil, "budget", 1, nil, @now}, server: repo)
      end

      {:ok, first} = extend.()

      assert {:ok, 1} =
               Repo.cues_call(CuesSql, {:close_gap, ref, nil, "budget", @now}, server: repo)

      {:ok, second} = extend.()
      refute first == second

      assert {:ok, [open]} =
               Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ref, open: true}}, server: repo)

      assert open.id == second
      assert {:ok, all} = Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ref}}, server: repo)
      assert length(all) == 2

      assert {:error, {:invalid, :reason}} =
               Repo.cues_call(CuesSql, {:extend_gap, ref, nil, "boredom", 1, nil, @now},
                 server: repo
               )
    end
  end
end
