defmodule FermixCore.Cues.IngestTest do
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @now ~U[2026-10-10 12:00:00Z]
  # Words every item below carries in its text (`item/2`).
  @words ["disk"]
  # A 250-item transaction on a runner busy with the rest of the suite's
  # SQLite work: the test is about what it writes, not how fast.
  @busy_repo_ms 30_000

  setup do
    ctx = start_repo("ingest")
    test = self()

    opts = [
      now: @now,
      repo: ctx.repo,
      repo_timeout_ms: @busy_repo_ms,
      wake_filters: fn -> send(test, :woke_filters) end,
      wake_scheduler: fn -> send(test, :woke_scheduler) end
    ]

    Map.merge(ctx, %{ref: "src-#{System.unique_integer([:positive])}", opts: opts})
  end

  defp source(ref, budget \\ 0), do: %{ref: ref, daily_budget: budget}

  defp item(id, overrides \\ %{}) do
    data = %{"id" => id, "text" => "Disk alert on host #{id}"}
    item!(Map.merge(%{item_id: id, type: "com.example.alert", data: data}, overrides), @now)
  end

  defp llm_watcher(ctx, attrs \\ %{}) do
    defaults = %{filter: "llm", sources: [ctx.ref], listen_for: @words}
    insert_watcher(ctx.conn, Map.merge(defaults, attrs))
  end

  defp deliveries(conn, watcher) do
    rows(
      conn,
      """
      SELECT d.id, d.state, d.decision_reason, d.ready_at, d.valid_until, d.received_at, c.item_id
      FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id
      WHERE d.watcher_id = ? ORDER BY d.id
      """,
      [watcher]
    )
  end

  defp cue_rows(conn, ref) do
    rows(
      conn,
      "SELECT item_id, revision, payload, routed_count, terminal_at, last_seen_at FROM cues " <>
        "WHERE source_ref = ? ORDER BY id",
      [ref]
    )
  end

  defp items_today(ctx) do
    case Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo) do
      {:ok, nil} -> 0
      {:ok, row} -> row.items_today
    end
  end

  defp open_gaps(repo, ref) do
    {:ok, gaps} =
      Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ref, open: true}}, server: repo)

    Map.new(gaps, &{{&1.watcher_id, &1.reason}, &1.count})
  end

  describe "C01: stored and routed with no provider" do
    test "an llm watcher's delivery waits pending and the filters are woken", ctx do
      watcher = llm_watcher(ctx)

      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)

      assert [[_id, "pending", nil, ready_at, valid_until, received_at, "a"]] =
               deliveries(ctx.conn, watcher)

      assert ready_at == received_at
      assert received_at == "2026-10-10T12:00:00.000000Z"
      assert valid_until == "2026-10-17T12:00:00.000000Z"
      assert_receive :woke_filters
      refute_received :woke_scheduler
    end

    test "a none watcher's delivery passes with no filter and wakes the scheduler", ctx do
      watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})

      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)
      assert [[_id, "passed", "no filter", _r, _v, _rc, "a"]] = deliveries(ctx.conn, watcher)
      assert_receive :woke_scheduler
      refute_received :woke_filters
    end
  end

  describe "routing by words (M60_CUE_INTAKE_AT_SCALE.md §3.1)" do
    test "an llm watcher gets an item only when one of its words matches; a none watcher " <>
           "gets every item",
         ctx do
      disks = llm_watcher(ctx)
      fans = llm_watcher(ctx, %{listen_for: ["cooling fan", "風扇"]})
      everything = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})

      fan = item("f", %{data: %{"id" => "f", "text" => "The cooling fan on rack 4 stopped"}})
      cjk = item("z", %{data: %{"id" => "z", "text" => "機房風扇停了"}})

      assert {:ok, [:accepted, :accepted, :accepted]} =
               Ingest.accept(source(ctx.ref), [item("a"), fan, cjk], ctx.opts)

      assert ctx.conn |> deliveries(disks) |> Enum.map(&List.last/1) == ["a"]
      assert ctx.conn |> deliveries(fans) |> Enum.map(&List.last/1) == ["f", "z"]
      assert ctx.conn |> deliveries(everything) |> Enum.map(&List.last/1) == ["a", "f", "z"]
    end

    test "an llm watcher with no words gets nothing, and an item no watcher took is a receipt",
         ctx do
      silent = llm_watcher(ctx, %{listen_for: []})
      fans = llm_watcher(ctx, %{listen_for: ["cooling fan"]})

      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)

      assert deliveries(ctx.conn, silent) == []
      assert deliveries(ctx.conn, fans) == []
      assert [["a", "1", nil, 0, terminal_at, _seen]] = cue_rows(ctx.conn, ctx.ref)
      assert terminal_at == "2026-10-10T12:00:00.000000Z"
      refute_received :woke_filters
    end
  end

  describe "a decision model as the screen" do
    test "every llm watcher with words gets every item for its filter call to screen; " <>
           "one with none still waits for its update",
         ctx do
      disks = llm_watcher(ctx)
      silent = llm_watcher(ctx, %{listen_for: []})
      opts = Keyword.put(ctx.opts, :words?, false)

      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("q")], opts)

      assert ctx.conn |> deliveries(disks) |> Enum.map(&List.last/1) == ["q"]
      assert deliveries(ctx.conn, silent) == []
      assert_received :woke_filters
    end
  end

  describe "C02: identity" do
    test "the same item twice is a duplicate that refreshes last_seen_at", ctx do
      llm_watcher(ctx)
      later = DateTime.add(@now, 3600, :second)

      {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)

      assert {:ok, [:duplicate]} =
               Ingest.accept(source(ctx.ref), [item("a")], Keyword.put(ctx.opts, :now, later))

      assert [["a", "1", _payload, 1, nil, "2026-10-10T13:00:00.000000Z"]] =
               cue_rows(ctx.conn, ctx.ref)
    end

    test "same id with new content is a conflict and a gap; a new revision is a new cue", ctx do
      llm_watcher(ctx)
      {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)

      changed = item("a", %{data: %{"id" => "a", "edited" => true}})

      assert {:ok, [:conflict, :conflict]} =
               Ingest.accept(source(ctx.ref), [changed, changed], ctx.opts)

      assert open_gaps(ctx.repo, ctx.ref) == %{{nil, "identity_conflict"} => 2}

      revised = item("a", %{revision: "2", data: %{"id" => "a", "edited" => true}})
      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [revised], ctx.opts)
      assert [["a", "1" | _], ["a", "2" | _]] = cue_rows(ctx.conn, ctx.ref)
    end

    test "an item with a huge integer is reported invalid and counted", ctx do
      huge = Item.new(%{item_id: "h", data: %{"n" => 9_007_199_254_740_993}}, @now)
      assert {:error, {:invalid, message}} = huge

      assert {:ok, [{:invalid, ^message}, :accepted]} =
               Ingest.accept(source(ctx.ref), [huge, item("ok")], ctx.opts)

      {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
      assert row.reject_counts == %{"invalid" => 1}
      assert [["ok" | _]] = cue_rows(ctx.conn, ctx.ref)
    end
  end

  describe "C23: inbox full" do
    test "the oldest pending from the flooding source expires; other sources are unaffected",
         ctx do
      other = "#{ctx.ref}-b"
      watcher = llm_watcher(ctx, %{sources: [ctx.ref, other]})
      flood = for n <- 1..250, do: item("f#{n}", %{occurred_at: DateTime.add(@now, -n, :second)})

      {:ok, results} = Ingest.accept(source(ctx.ref), flood, ctx.opts)
      assert Enum.all?(results, &(&1 == :accepted))
      {:ok, [:accepted]} = Ingest.accept(source(other), [item("b1")], ctx.opts)

      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("f251")], ctx.opts)

      [[oldest_state, outcome]] =
        rows(
          ctx.conn,
          "SELECT d.state, d.outcome FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id " <>
            "WHERE c.item_id = 'f250'"
        )

      assert {oldest_state, outcome} == {"expired", "inbox_full"}

      assert [[250]] =
               rows(
                 ctx.conn,
                 "SELECT count(*) FROM cue_deliveries WHERE watcher_id = ? AND source_ref = ? " <>
                   "AND state IN ('pending', 'passed')",
                 [watcher, ctx.ref]
               )

      assert [["pending"]] =
               rows(ctx.conn, "SELECT state FROM cue_deliveries WHERE source_ref = ?", [other])

      assert open_gaps(ctx.repo, ctx.ref) == %{{watcher, "inbox_full"} => 1}
    end

    test "with none pending the oldest passed goes; filtering and claimed are never taken",
         ctx do
      watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})

      flood =
        for n <- 1..250, do: item("f#{n}", %{occurred_at: DateTime.add(@now, n - 300, :second)})

      {:ok, _results} = Ingest.accept(source(ctx.ref), flood, ctx.opts)

      [[first], [second], [third]] =
        rows(ctx.conn, "SELECT id FROM cue_deliveries WHERE watcher_id = ? ORDER BY id LIMIT 3", [
          watcher
        ])

      exec!(
        ctx.conn,
        "UPDATE cue_deliveries SET state = 'filtering', filter_call_id = 'c' WHERE id = ?",
        [first]
      )

      exec!(
        ctx.conn,
        "UPDATE cue_deliveries SET state = 'claimed', claimed_run_id = 'r' WHERE id = ?",
        [second]
      )

      # 248 passed remain; the third new item takes the inbox past 250.
      {:ok, [:accepted, :accepted, :accepted]} =
        Ingest.accept(source(ctx.ref), [item("n1"), item("n2"), item("n3")], ctx.opts)

      states =
        ctx.conn
        |> rows("SELECT id, state FROM cue_deliveries WHERE watcher_id = ? ORDER BY id", [watcher])
        |> Map.new(fn [id, state] -> {id, state} end)

      assert states[first] == "filtering"
      assert states[second] == "claimed"
      assert states[third] == "expired"
      assert states |> Map.values() |> Enum.count(&(&1 == "expired")) == 1
    end
  end

  test "C24: two watchers on one source get independent deliveries", ctx do
    one = llm_watcher(ctx)
    two = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
    _off = llm_watcher(ctx, %{enabled: false})

    {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)

    assert [[one_id, "pending" | _]] = deliveries(ctx.conn, one)
    assert [[_two_id, "passed" | _]] = deliveries(ctx.conn, two)
    assert [["a", "1", _payload, 2, nil, _seen]] = cue_rows(ctx.conn, ctx.ref)

    :ok = CuesSql.transition(ctx.conn, one_id, "pending", :none, "dropped", %{settled_at: @now})
    assert [[_two_id, "passed" | _]] = deliveries(ctx.conn, two)
    assert_receive :woke_filters
    assert_receive :woke_scheduler
  end

  test "C37: an item past the horizon is stale, stored nowhere, counted and a gap", ctx do
    stale = Item.new(%{item_id: "old", occurred_at: DateTime.add(@now, -9, :day)}, @now)
    assert {:error, :stale} = stale

    assert {:ok, [:stale]} = Ingest.accept(source(ctx.ref), [stale], ctx.opts)
    assert cue_rows(ctx.conn, ctx.ref) == []
    assert open_gaps(ctx.repo, ctx.ref) == %{{nil, "stale"} => 1}
    {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
    assert row.reject_counts == %{"stale" => 1}
  end

  test "C38: a body replayed under a new delivery id is a duplicate", ctx do
    llm_watcher(ctx)
    first = item("delivery-1", %{body_hash: "b0dy"})
    replay = item("delivery-2", %{body_hash: "b0dy"})

    assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [first], ctx.opts)
    assert {:ok, [:duplicate]} = Ingest.accept(source(ctx.ref), [replay], ctx.opts)
    assert {:ok, [:accepted]} = Ingest.accept(source("#{ctx.ref}-x"), [replay], ctx.opts)
  end

  describe "receipts" do
    test "a cue no watcher listens to is a receipt with no payload, still deduplicated", ctx do
      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)
      assert [["a", "1", nil, 0, terminal_at, _seen]] = cue_rows(ctx.conn, ctx.ref)
      assert terminal_at == "2026-10-10T12:00:00.000000Z"
      assert {:ok, [:duplicate]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)
      refute_received :woke_filters
    end

    test "a self-caused item is stored and not routed", ctx do
      watcher = llm_watcher(ctx)

      assert {:ok, [:accepted]} =
               Ingest.accept(source(ctx.ref), [item("mine", %{self_caused?: true})], ctx.opts)

      assert deliveries(ctx.conn, watcher) == []
      assert [["mine", "1", nil, 0 | _]] = cue_rows(ctx.conn, ctx.ref)
    end

    test "a receipt-only item is accepted without a delivery; its repeat is a duplicate", ctx do
      watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      undated = item("u", %{receipt_only?: true})

      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [undated], ctx.opts)
      assert {:ok, [:duplicate]} = Ingest.accept(source(ctx.ref), [item("u")], ctx.opts)
      assert deliveries(ctx.conn, watcher) == []
      refute_received :woke_scheduler
    end
  end

  test "items are inserted oldest first, undated last in input order; results keep input order",
       ctx do
    watcher = llm_watcher(ctx)

    batch = [
      item("u1", %{occurred_at: nil}),
      item("new", %{occurred_at: DateTime.add(@now, -10, :second)}),
      item("old", %{occurred_at: DateTime.add(@now, -60, :second)}),
      item("u2", %{occurred_at: nil})
    ]

    stale = {:error, :stale}

    assert {:ok, [:accepted, :stale, :accepted, :accepted, :accepted]} =
             Ingest.accept(source(ctx.ref), List.insert_at(batch, 1, stale), ctx.opts)

    assert ctx.conn |> deliveries(watcher) |> Enum.map(&List.last/1) == ~w(old new u1 u2)
  end

  describe "budget and rate" do
    test "past the daily budget items are over_budget, a gap, and the source over_budget", ctx do
      llm_watcher(ctx)
      batch = [item("a"), item("b"), item("c")]

      assert {:ok, [:accepted, :accepted, :over_budget]} =
               Ingest.accept(source(ctx.ref, 2), batch, ctx.opts)

      assert open_gaps(ctx.repo, ctx.ref) == %{{nil, "budget"} => 1}
      {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
      assert row.status == "over_budget"
      assert row.reject_counts == %{"over_budget" => 1}

      next_day = Keyword.put(ctx.opts, :now, ~U[2026-10-11 00:00:01Z])
      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref, 2), [item("c")], next_day)
    end

    test "the budget counts accepted items only: a re-read page spends nothing", ctx do
      assert {:ok, [:accepted, :accepted]} =
               Ingest.accept(source(ctx.ref, 3), [item("a"), item("b")], ctx.opts)

      assert {:ok, [:duplicate, :duplicate, :accepted]} =
               Ingest.accept(source(ctx.ref, 3), [item("a"), item("b"), item("c")], ctx.opts)

      assert items_today(ctx) == 3

      assert {:ok, [:over_budget, :over_budget]} =
               Ingest.accept(source(ctx.ref, 3), [item("d"), item("e")], ctx.opts)

      assert items_today(ctx) == 3
      assert open_gaps(ctx.repo, ctx.ref) == %{{nil, "budget"} => 2}

      # The count is per UTC day: the next day starts from nothing.
      next_day = Keyword.put(ctx.opts, :now, ~U[2026-10-11 00:00:01Z])
      assert {:ok, [:accepted]} = Ingest.accept(source(ctx.ref, 3), [item("d")], next_day)
      assert items_today(ctx) == 1
    end

    test "an accept that fails spends no budget", ctx do
      opts = Keyword.put(ctx.opts, :source_state, %{status: "asleep"})

      assert {:error, {:invalid, :status}} =
               Ingest.accept(source(ctx.ref, 3), [item("a")], opts)

      assert items_today(ctx) == 0
    end

    test "items the admit function refuses are rate_limited and counted", ctx do
      opts = Keyword.put(ctx.opts, :admit, fn 3 -> 1 end)

      assert {:ok, [:accepted, :rate_limited, :rate_limited]} =
               Ingest.accept(source(ctx.ref), [item("a"), item("b"), item("c")], opts)

      assert open_gaps(ctx.repo, ctx.ref) == %{{nil, "rate_limited"} => 2}
      {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
      assert row.reject_counts == %{"rate_limited" => 2}
    end
  end

  describe "source state" do
    test "is written in the accept transaction, with items or without", ctx do
      good = ~U[2026-10-10 11:59:00Z]
      state = %{cursor: "1728561540000000", last_good_at: good, status: "connected"}
      opts = Keyword.put(ctx.opts, :source_state, state)

      assert {:ok, []} = Ingest.accept(source(ctx.ref), [], opts)
      {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)

      assert {row.cursor, row.status, row.last_accepted_at} ==
               {"1728561540000000", "connected", nil}

      {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], opts)
      {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
      assert DateTime.compare(row.last_accepted_at, @now) == :eq
      assert DateTime.compare(row.last_good_at, good) == :eq
    end
  end

  test "lifecycle telemetry carries ids and counts for each result", ctx do
    FermixTestSupport.TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], :emitter)
    watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})

    {:ok, [:accepted]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)

    assert_receive {:telemetry, [:fermix, :cue, :lifecycle], %{count: 1, accept_ms: ms},
                    %{phase: :accepted, source_ref: ref, cue_id: cue_id} = accepted}

    assert ref == ctx.ref
    assert is_integer(ms) and ms >= 0
    refute Map.has_key?(accepted, :content)

    assert_receive {:telemetry, _event, _m,
                    %{phase: :routed, cue_id: ^cue_id, watcher_id: ^watcher, delivery_id: id}}

    assert_receive {:telemetry, _event, _m,
                    %{phase: :passed, delivery_id: ^id, reason: "no filter"}}

    {:ok, [:duplicate]} = Ingest.accept(source(ctx.ref), [item("a")], ctx.opts)
    assert_receive {:telemetry, _event, _m, %{phase: :duplicate, cue_id: ^cue_id}}
  end

  test "a Repo failure is traced and returned", ctx do
    FermixTestSupport.TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], :emitter)
    :ok = stop_supervised(Repo)
    disabled = :"disabled_repo_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: disabled, enabled: false})

    assert {:error, :disabled} =
             Ingest.accept(source(ctx.ref), [item("a")], Keyword.put(ctx.opts, :repo, disabled))

    assert_receive {:telemetry, _event, _m,
                    %{phase: :ingest_error, source_ref: ref, error_class: "disabled"}}

    assert ref == ctx.ref
  end
end
