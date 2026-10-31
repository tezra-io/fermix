defmodule FermixCore.Memory.RepoCuesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
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
  @retention_indexes ~w(cues_payload_terminal_at cues_snapshot_received_at
                        cues_unrouted_terminal_at)
  @delivery_window_index "cue_deliveries_watcher_received"

  setup do
    start_repo("repo")
  end

  defp table_names(conn) do
    conn
    |> rows("SELECT name FROM sqlite_master WHERE type = 'table'")
    |> List.flatten()
  end

  defp index_names(conn, table \\ "cues") do
    conn
    |> rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [table])
    |> List.flatten()
  end

  defp retention_plan(conn, step) do
    {sql, params} = CuesSql.retention_sql(step, @now)

    conn
    |> rows("EXPLAIN QUERY PLAN " <> sql, params ++ [1_000])
    |> Enum.map(&List.last/1)
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

  describe "migration 45" do
    test "adds cue_sources.stop_reason to a database that has the cue tables, keeping their rows",
         ctx do
      %{repo: repo, db_path: db_path, conn: conn} = ctx
      ref = "before-45-#{System.unique_integer([:positive])}"
      {:ok, _row} = Repo.cues_call(CuesSql, {:source_touch, ref, %{}, @now}, server: repo)
      assert "stop_reason" in source_columns(conn)

      # The database as it stood before 45.
      exec!(conn, "ALTER TABLE cue_sources DROP COLUMN stop_reason")
      exec!(conn, "DELETE FROM schema_migrations WHERE version = 45")
      :ok = stop_supervised(Repo)
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == 45)) == 1
      assert "stop_reason" in source_columns(conn)

      assert {:ok, %{source_ref: ^ref, stop_reason: nil}} =
               Repo.cues_call(CuesSql, {:get_source, ref}, server: repo)
    end
  end

  describe "migration 47" do
    test "gives watchers words, drops their own model, lets a call have no delivery, adds counts",
         ctx do
      %{repo: repo, db_path: db_path, conn: conn} = ctx
      id = insert_watcher(conn, %{name: "w47", filter: "llm", sources: ["s47"]})

      exec!(
        conn,
        "INSERT INTO cue_filter_calls (id, watcher_id, delivery_id, session_id, started_at, " <>
          "result) VALUES ('cfc_47', ?, 7, 's', '2026-10-10T12:00:00Z', 'drop')",
        [id]
      )

      # The database as it stood before 47.
      exec!(conn, "DROP TABLE cue_counts")
      exec!(conn, "ALTER TABLE cue_watchers DROP COLUMN listen_for")
      exec!(conn, "ALTER TABLE cue_watchers ADD COLUMN filter_provider TEXT")
      exec!(conn, "ALTER TABLE cue_watchers ADD COLUMN filter_model TEXT")

      exec!(
        conn,
        "UPDATE cue_watchers SET filter_provider = 'openai', filter_model = 'gpt-5-mini'"
      )

      exec!(conn, "DELETE FROM schema_migrations WHERE version = 47")
      :ok = stop_supervised(Repo)
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == 47)) == 1

      columns =
        conn |> rows("SELECT name FROM pragma_table_info('cue_watchers')") |> List.flatten()

      assert "listen_for" in columns
      refute "filter_provider" in columns
      refute "filter_model" in columns

      assert {:ok, %{listen_for: []}} =
               Repo.cues_call(CuesWatchersSql, {:get_watcher, {:id, id}}, server: repo)

      assert [["cfc_47", 7, "drop"]] =
               rows(conn, "SELECT id, delivery_id, result FROM cue_filter_calls")

      # A stream item's call is judged before the item is stored: no delivery.
      exec!(
        conn,
        "INSERT INTO cue_filter_calls (id, watcher_id, session_id, started_at) " <>
          "VALUES ('cfc_live', ?, 's', '2026-10-10T12:00:00Z')",
        [id]
      )

      assert "cue_counts" in table_names(conn)
    end
  end

  describe "migration 48" do
    test "adds the retention indexes to a database that has the cue tables", ctx do
      %{repo: repo, db_path: db_path, conn: conn} = ctx
      assert @retention_indexes -- index_names(conn) == []

      # The database as it stood before 48.
      Enum.each(@retention_indexes, &exec!(conn, "DROP INDEX #{&1}"))
      exec!(conn, "DELETE FROM schema_migrations WHERE version = 48")
      :ok = stop_supervised(Repo)
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == 48)) == 1
      assert @retention_indexes -- index_names(conn) == []
    end
  end

  describe "migration 55" do
    test "adds the delivery window index to a database that has the cue tables", ctx do
      %{repo: repo, db_path: db_path, conn: conn} = ctx
      assert @delivery_window_index in index_names(conn, "cue_deliveries")

      # The database as it stood before 55.
      exec!(conn, "DROP INDEX #{@delivery_window_index}")
      exec!(conn, "DELETE FROM schema_migrations WHERE version = 55")
      :ok = stop_supervised(Repo)
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == 55)) == 1
      assert @delivery_window_index in index_names(conn, "cue_deliveries")
    end
  end

  # A receipt stays in cues until retention deletes it, up to 30 days after its
  # deliveries settle, so a step that walked the table read every stored row
  # once a minute to find the few it changes.
  describe "retention reads" do
    test "drop_payloads searches only the cues that still hold a payload", %{conn: conn} do
      details = retention_plan(conn, :drop_payloads)

      assert Enum.any?(details, &(&1 =~ ~r/^SEARCH \w+ USING INDEX cues_payload_terminal_at\b/)),
             inspect(details)

      refute Enum.any?(details, &(&1 =~ ~r/^SCAN /)), inspect(details)
    end

    test "drop_snapshots searches only the cues that still hold a snapshot", %{conn: conn} do
      details = retention_plan(conn, :drop_snapshots)

      assert Enum.any?(details, &(&1 =~ ~r/^SEARCH \w+ USING INDEX cues_snapshot_received_at\b/)),
             inspect(details)

      refute Enum.any?(details, &(&1 =~ ~r/^SCAN /)), inspect(details)
    end

    test "delete_receipts searches unrouted receipts by their own index", %{conn: conn} do
      details = retention_plan(conn, :delete_receipts)

      assert Enum.any?(details, &(&1 =~ ~r/^SEARCH \w+ USING INDEX cues_unrouted_terminal_at\b/)),
             inspect(details)

      assert Enum.any?(details, &(&1 =~ ~r/^SEARCH \w+ USING INDEX cues_terminal_at\b/)),
             inspect(details)

      refute Enum.any?(details, &(&1 =~ ~r/^SCAN /)), inspect(details)
    end

    test "the follow-up steps search only the rows that ended, by their state index", ctx do
      for {step, index} <- [prune_follow_up_triggers: "cue_follow_up_triggers_state"] do
        details = retention_plan(ctx.conn, step)

        assert Enum.any?(details, &(&1 =~ ~r/^SEARCH \w+ USING INDEX #{index}\b/)),
               inspect(details)

        refute Enum.any?(details, &(&1 =~ ~r/^SCAN |TEMP B-TREE/)), inspect(details)
      end
    end
  end

  describe "counts" do
    test "a flush replaces its incarnation's totals, incarnations sum, old hours fall out",
         %{repo: repo} do
      call = &Repo.cues_call(CuesSql, &1, server: repo)
      hour = ~U[2026-10-10 12:00:00Z]

      row = fn incarnation, counts ->
        %{scope: "source", ref: "s", hour: hour, incarnation: incarnation, counts: counts}
      end

      assert {:ok, 1} = call.({:counts_put, [row.("a", %{"received" => 5})], @now})
      # The same flush sent again after a timeout replaces, never adds.
      assert {:ok, 1} = call.({:counts_put, [row.("a", %{"received" => 9})], @now})

      assert {:ok, 1} =
               call.({:counts_put, [row.("b", %{"received" => 2, "unmatched" => 1})], @now})

      old = %{row.("a", %{"received" => 100}) | hour: ~U[2026-10-09 10:00:00Z]}
      assert {:ok, 1} = call.({:counts_put, [old], @now})

      assert {:ok, %{"s" => %{"received" => 11, "unmatched" => 1}}} =
               call.({:counts_window, "source", ~U[2026-10-09 12:30:00Z]})

      assert {:ok, %{}} = call.({:counts_window, "watcher", ~U[2026-10-09 12:30:00Z]})

      assert {:error, {:invalid, :counts}} =
               call.({:counts_put, [row.("a", %{"received" => -1})], @now})

      assert {:ok, 1} = call.({:prune_counts, ~U[2026-10-11 11:00:00Z], 100})
    end
  end

  describe "store_item" do
    test "keeps an item as a receipt with its snapshot, once; its identity answers after", ctx do
      %{repo: repo, conn: conn} = ctx
      {:ok, item} = Item.new(%{item_id: "s-1", data: %{"text" => "x"}}, @now)
      call = &Repo.cues_call(CuesSql, &1, server: repo)

      assert {:ok, id} = call.({:store_item, "stream-a", item, @now})
      assert {:ok, ^id} = call.({:store_item, "stream-a", item, @now})

      assert [[nil, 0, snapshot]] =
               rows(conn, "SELECT payload, routed_count, snapshot FROM cues WHERE id = ?", [id])

      assert is_binary(snapshot)
    end
  end

  describe "pass_live (M60_CUE_INTAKE_AT_SCALE.md §3.2)" do
    setup %{conn: conn} do
      ref = "live-#{System.unique_integer([:positive])}"
      words = ["orbit"]
      one = insert_watcher(conn, %{filter: "llm", sources: [ref], listen_for: words})
      two = insert_watcher(conn, %{filter: "llm", sources: [ref], listen_for: words})
      item = item!(%{item_id: "p-1", subject: "launch", data: %{"text" => "Orbit reached"}}, @now)
      %{ref: ref, one: one, two: two, item: item}
    end

    defp live_call(id),
      do: %{id: id, session_id: "s-#{id}", started_at: @now, provider: "openai", model: "m-1"}

    defp pass_live(ctx, watcher, call_id) do
      call = live_call(call_id)
      request = {:pass_live, ctx.ref, ctx.item, watcher, "On topic.", "launch", call, @now}
      Repo.cues_call(CuesSql, request, server: ctx.repo)
    end

    # `n` passed deliveries of the watcher from the source, written in one
    # transaction on the test's own connection.
    defp seed_passed(ctx, watcher, n) do
      at = CuesSql.stamp(@now)
      exec!(ctx.conn, "BEGIN", [])

      for i <- 1..n do
        [[cue_id]] =
          rows(
            ctx.conn,
            "INSERT INTO cues (source_ref, item_id, received_at, content_hash, payload, " <>
              "routed_count, last_seen_at) VALUES (?, ?, ?, ?, '{}', 1, ?) RETURNING id",
            [ctx.ref, "cap-#{i}", at, "hash-#{i}", at]
          )

        exec!(
          ctx.conn,
          "INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, received_at, state, " <>
            "ready_at, valid_until) VALUES (?, ?, ?, ?, 'passed', ?, ?)",
          [cue_id, watcher, ctx.ref, at, at, "2026-10-17T12:00:00.000000Z"]
        )
      end

      exec!(ctx.conn, "COMMIT", [])
    end

    defp live_rows(ctx) do
      %{
        cues:
          rows(ctx.conn, "SELECT id, payload IS NOT NULL, routed_count, terminal_at FROM cues"),
        deliveries:
          rows(
            ctx.conn,
            "SELECT cue_id, watcher_id, state, decision_reason, hint, filter_call_id " <>
              "FROM cue_deliveries ORDER BY id"
          ),
        calls:
          rows(
            ctx.conn,
            "SELECT id, watcher_id, delivery_id, provider, model, result, finished_at " <>
              "FROM cue_filter_calls ORDER BY id"
          )
      }
    end

    test "stores the new cue with its payload, the watcher's passed delivery and the call's " <>
           "ledger row in one write",
         ctx do
      assert {:ok, %{cue_id: cue_id, delivery_id: delivery_id, result: :passed}} =
               pass_live(ctx, ctx.one, "cfc_a")

      assert is_integer(delivery_id)
      one = ctx.one

      assert %{
               cues: [[^cue_id, 1, 1, nil]],
               deliveries: [[^cue_id, ^one, "passed", "On topic.", "launch", "cfc_a"]],
               calls: [["cfc_a", ^one, nil, "openai", "m-1", "pass", finished]]
             } = live_rows(ctx)

      assert finished == CuesSql.stamp(@now)
    end

    test "two watchers passing one item each get a delivery on one cue, and a retried write " <>
           "changes nothing",
         ctx do
      {:ok, %{cue_id: cue_id, delivery_id: first}} = pass_live(ctx, ctx.one, "cfc_a")
      {:ok, %{cue_id: ^cue_id, delivery_id: second}} = pass_live(ctx, ctx.two, "cfc_b")
      assert first != second

      # The first write timed out, still ran, and is sent again: it answers the
      # delivery it stored. A repeat of the item, judged again, stores none.
      assert {:ok, %{cue_id: ^cue_id, delivery_id: ^first}} = pass_live(ctx, ctx.one, "cfc_a")
      assert {:ok, %{cue_id: ^cue_id, delivery_id: nil}} = pass_live(ctx, ctx.one, "cfc_c")

      %{cues: cues, deliveries: deliveries, calls: calls} = live_rows(ctx)
      assert [[^cue_id, 1, 2, nil]] = cues
      assert Enum.map(deliveries, &Enum.at(&1, 1)) == [ctx.one, ctx.two]
      assert Enum.map(calls, &hd/1) == ["cfc_a", "cfc_b", "cfc_c"]
    end

    test "a pass on a stored receipt keeps that cue, gives it back the item's payload, counts " <>
           "the delivery and opens it",
         ctx do
      {:ok, cue_id} =
        Repo.cues_call(CuesSql, {:store_item, ctx.ref, ctx.item, @now}, server: ctx.repo)

      exec!(ctx.conn, "UPDATE cues SET payload_bytes = 0 WHERE id = ?", [cue_id])

      assert {:ok, %{cue_id: ^cue_id, delivery_id: id}} = pass_live(ctx, ctx.one, "cfc_a")
      assert is_integer(id)
      assert [[^cue_id, 1, 1, nil]] = live_rows(ctx).cues

      assert [[payload, bytes]] =
               rows(ctx.conn, "SELECT payload, payload_bytes FROM cues WHERE id = ?", [cue_id])

      assert {payload, bytes} == {ctx.item.payload, ctx.item.payload_bytes}
    end

    test "a pass on a stored item of other content is an identity conflict: a gap, no " <>
           "delivery, and the call's ledger row",
         ctx do
      other = item!(%{item_id: "p-1", subject: "launch", data: %{"text" => "Other text"}}, @now)

      {:ok, cue_id} =
        Repo.cues_call(CuesSql, {:store_item, ctx.ref, other, @now}, server: ctx.repo)

      assert {:ok, %{cue_id: ^cue_id, delivery_id: nil, conflict?: true, gaps: [gap]}} =
               pass_live(ctx, ctx.one, "cfc_a")

      assert %{reason: "identity_conflict", watcher_id: nil, count: 1} = gap
      one = ctx.one

      assert %{cues: [[^cue_id, 0, 0, _terminal]], deliveries: [], calls: [["cfc_a", ^one | _]]} =
               live_rows(ctx)

      assert {:ok, [%{reason: "identity_conflict", count: 1}]} =
               Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ctx.ref}}, server: ctx.repo)
    end

    test "the inbox cap holds for passes: past 250 waiting, the oldest is evicted", ctx do
      seed_passed(ctx, ctx.one, 250)

      assert {:ok, %{evicted: [%{delivery_id: evicted}], gaps: [%{reason: "inbox_full"}]}} =
               pass_live(ctx, ctx.one, "cfc_last")

      assert [["expired", "inbox_full", "cap-1"]] =
               rows(
                 ctx.conn,
                 "SELECT d.state, d.outcome, c.item_id FROM cue_deliveries d " <>
                   "JOIN cues c ON c.id = d.cue_id WHERE d.id = ?",
                 [evicted]
               )
    end

    test "a call that is not a live call is refused", ctx do
      request = {:pass_live, ctx.ref, ctx.item, ctx.one, "On topic.", nil, %{id: "x"}, @now}
      assert {:error, {:invalid, :call}} = Repo.cues_call(CuesSql, request, server: ctx.repo)
    end
  end

  defp source_columns(conn),
    do: conn |> rows("SELECT name FROM pragma_table_info('cue_sources')") |> List.flatten()

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
      watcher = insert_watcher(conn, %{filter: "llm", sources: [ref], listen_for: ["release"]})
      item = item!(%{item_id: "cas-1", type: "t", data: "Release notes"}, @now)

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

    test "a stream writes its day's count of matched items", %{repo: repo, ref: ref} do
      touch = &Repo.cues_call(CuesSql, {:source_touch, ref, &1, @now}, server: repo)

      assert {:ok, %{items_today: 12, items_day: "2026-10-10"}} =
               touch.(%{items_today: 12, items_day: "2026-10-10"})

      assert {:error, {:invalid, :items_day}} = touch.(%{items_day: "yesterday"})
      assert {:error, {:invalid, :items_today}} = touch.(%{items_today: -1})
    end

    test "a stop reason is written with its status and cleared by the next status", %{
      repo: repo,
      ref: ref
    } do
      touch = &Repo.cues_call(CuesSql, {:source_touch, ref, &1, @now}, server: repo)

      assert {:ok, %{status: "unavailable", stop_reason: "too_large"}} =
               touch.(%{status: "unavailable", stop_reason: "too_large"})

      # A write without a status leaves both as they are.
      assert {:ok, %{status: "unavailable", stop_reason: "too_large"}} = touch.(%{cursor: "c2"})
      assert {:ok, %{status: "polling", stop_reason: nil}} = touch.(%{status: "polling"})

      assert {:error, {:invalid, :stop_reason}} = touch.(%{stop_reason: "too_large"})

      assert {:error, {:invalid, :stop_reason}} =
               touch.(%{status: "unavailable", stop_reason: "tired"})
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
