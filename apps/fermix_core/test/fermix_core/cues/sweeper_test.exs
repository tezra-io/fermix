defmodule FermixCore.Cues.SweeperTest do
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Sweeper
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @t0 ~U[2026-09-01 12:00:00Z]

  setup do
    ctx = start_repo("sweeper")
    Map.put(ctx, :ref, "src-#{System.unique_integer([:positive])}")
  end

  defp accept(ctx, ids, now, ref \\ nil) do
    items = Enum.map(ids, &item!(%{item_id: &1, type: "t", data: %{"id" => &1}}, now))

    {:ok, results} =
      Ingest.accept(%{ref: ref || ctx.ref, daily_budget: 0}, items,
        now: now,
        repo: ctx.repo,
        wake_filters: fn -> :ok end,
        wake_scheduler: fn -> :ok end
      )

    true = Enum.all?(results, &(&1 == :accepted))
    :ok
  end

  defp step(ctx, name, now, limit \\ 1_000) do
    Repo.cues_call(CuesSql, {name, now, limit}, server: ctx.repo)
  end

  defp later(at, days, seconds \\ 0), do: at |> DateTime.add(days, :day) |> DateTime.add(seconds)

  defp delivery(conn, item_id) do
    [[id, state, outcome, settled_at]] =
      rows(
        conn,
        "SELECT d.id, d.state, d.outcome, d.settled_at FROM cue_deliveries d " <>
          "JOIN cues c ON c.id = d.cue_id WHERE c.item_id = ?",
        [item_id]
      )

    %{id: id, state: state, outcome: outcome, settled_at: settled_at}
  end

  defp cue(conn, item_id) do
    case rows(conn, "SELECT payload, snapshot, terminal_at FROM cues WHERE item_id = ?", [item_id]) do
      [] ->
        nil

      [[payload, snapshot, terminal_at]] ->
        %{payload: payload, snapshot: snapshot, terminal_at: terminal_at}
    end
  end

  defp settle(conn, item_id, state, at) do
    exec!(
      conn,
      "UPDATE cue_deliveries SET state = ?, settled_at = ? WHERE cue_id = " <>
        "(SELECT id FROM cues WHERE item_id = ?)",
      [state, CuesSql.stamp(at), item_id]
    )
  end

  test "expire: undecided and passed deliveries past their lifetime expire with a gap", ctx do
    FermixTestSupport.TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], source_ref: ctx.ref)
    llm = insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
    none = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
    :ok = accept(ctx, ["a"], @t0)
    :ok = accept(ctx, ["busy"], @t0)

    exec!(
      ctx.conn,
      "UPDATE cue_deliveries SET state = CASE watcher_id WHEN ? THEN 'filtering' ELSE 'claimed' END " <>
        "WHERE cue_id = (SELECT id FROM cues WHERE item_id = 'busy')",
      [llm]
    )

    assert {:ok, %{count: 0}} = step(ctx, :expire_lifetime, later(@t0, 7, -1))
    now = later(@t0, 7, 1)
    # The Sweeper's step emits the telemetry the SQL request returns ids for.
    assert {:ok, 2} = Sweeper.expire_lifetime([server: ctx.repo], now, 1_000)

    assert [[2]] =
             rows(
               ctx.conn,
               "SELECT count(*) FROM cue_deliveries WHERE state = 'expired' AND outcome = 'lifetime' " <>
                 "AND settled_at = ?",
               [CuesSql.stamp(now)]
             )

    assert [["claimed"], ["filtering"]] =
             rows(
               ctx.conn,
               "SELECT state FROM cue_deliveries WHERE cue_id = (SELECT id FROM cues WHERE item_id = 'busy') " <>
                 "ORDER BY state"
             )

    {:ok, gaps} = Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ctx.ref}}, server: ctx.repo)

    assert gaps |> Enum.map(&{&1.watcher_id, &1.reason, &1.count}) |> Enum.sort() ==
             Enum.sort([{llm, "expired", 1}, {none, "expired", 1}])

    assert_receive {:telemetry, _e, _m, %{phase: :expired, reason: "lifetime", watcher_id: _w}}
    assert_receive {:telemetry, _e, _m, %{phase: :gap, reason: "expired"}}
  end

  test "terminal_at: set from the last settle once every delivery is terminal", ctx do
    insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
    :ok = accept(ctx, ["done", "open"], @t0)
    settled = later(@t0, 0, 600)
    settle(ctx.conn, "done", "acked", settled)

    assert {:ok, 1} = step(ctx, :mark_terminal, later(@t0, 1))
    assert cue(ctx.conn, "done").terminal_at == CuesSql.stamp(settled)
    assert cue(ctx.conn, "open").terminal_at == nil
    assert {:ok, 0} = step(ctx, :mark_terminal, later(@t0, 1))
  end

  test "payloads: dropped 24 hours after the cue became terminal", ctx do
    insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
    :ok = accept(ctx, ["a"], @t0)
    settle(ctx.conn, "a", "dropped", @t0)
    {:ok, 1} = step(ctx, :mark_terminal, @t0)

    assert {:ok, 0} = step(ctx, :drop_payloads, later(@t0, 0, 23 * 3600))
    refute cue(ctx.conn, "a").payload == nil
    assert {:ok, 1} = step(ctx, :drop_payloads, later(@t0, 1, 1))
    assert cue(ctx.conn, "a").payload == nil
  end

  test "receipts: deleted 7 days after payload drop and last sighting, never under a delivery",
       ctx do
    :ok = accept(ctx, ["quiet", "seen"], @t0)

    {:ok, [:duplicate]} =
      Ingest.accept(
        %{ref: ctx.ref, daily_budget: 0},
        [item!(%{item_id: "seen", type: "t", data: %{"id" => "seen"}}, later(@t0, 5))],
        now: later(@t0, 5),
        repo: ctx.repo
      )

    insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
    :ok = accept(ctx, ["routed"], @t0)
    settle(ctx.conn, "routed", "dropped", @t0)
    {:ok, _count} = step(ctx, :mark_terminal, @t0)
    {:ok, _count} = step(ctx, :drop_payloads, later(@t0, 1, 1))

    assert {:ok, 0} = step(ctx, :delete_receipts, later(@t0, 7, 23 * 3600))
    assert {:ok, 1} = step(ctx, :delete_receipts, later(@t0, 8, 1))
    assert cue(ctx.conn, "quiet") == nil
    refute cue(ctx.conn, "seen") == nil
    refute cue(ctx.conn, "routed") == nil

    assert {:ok, 1} = step(ctx, :delete_receipts, later(@t0, 12, 1))
    assert cue(ctx.conn, "seen") == nil
    refute cue(ctx.conn, "routed") == nil
  end

  test "deliveries: terminal ones pruned after 30 days, live ones never", ctx do
    insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
    :ok = accept(ctx, ["old", "live"], @t0)
    settle(ctx.conn, "old", "dropped", @t0)

    exec!(ctx.conn, "UPDATE cue_deliveries SET settled_at = ? WHERE state = 'pending'", [
      CuesSql.stamp(@t0)
    ])

    assert {:ok, 0} = step(ctx, :prune_deliveries, later(@t0, 29))
    assert {:ok, 1} = step(ctx, :prune_deliveries, later(@t0, 30, 1))
    assert delivery(ctx.conn, "live").state == "pending"
    assert [] = rows(ctx.conn, "SELECT id FROM cue_deliveries WHERE state = 'dropped'")
  end

  test "gaps, filter calls and snapshots age out after 30 days", ctx do
    insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
    :ok = accept(ctx, ["a"], @t0)

    {:ok, _gap} =
      Repo.cues_call(CuesSql, {:extend_gap, ctx.ref, nil, "disconnect", 1, nil, @t0},
        server: ctx.repo
      )

    started = CuesSql.stamp(@t0)

    exec!(
      ctx.conn,
      "INSERT INTO cue_filter_calls (id, watcher_id, delivery_id, session_id, started_at, finished_at, result) " <>
        "VALUES ('cfc_done', 'w', 1, 's1', ?, ?, 'drop'), ('cfc_open', 'w', 2, 's2', ?, NULL, NULL)",
      [started, started, started]
    )

    assert {:ok, 0} = step(ctx, :prune_gaps, later(@t0, 29))
    assert {:ok, 1} = step(ctx, :prune_gaps, later(@t0, 30, 1))
    # A call left open (a settle that never came) is pruned with the rest.
    assert {:ok, 0} = step(ctx, :prune_filter_calls, later(@t0, 29))
    assert {:ok, 2} = step(ctx, :prune_filter_calls, later(@t0, 30, 1))
    assert [] = rows(ctx.conn, "SELECT id FROM cue_filter_calls")
    assert {:ok, 0} = step(ctx, :drop_snapshots, later(@t0, 29))
    assert {:ok, 1} = step(ctx, :drop_snapshots, later(@t0, 30, 1))
    assert cue(ctx.conn, "a").snapshot == nil
  end

  describe "the Sweeper process" do
    defp start_sweeper(ctx, opts) do
      name = :"cue_sweeper_#{System.unique_integer([:positive])}"
      start_supervised!({Sweeper, [name: name, repo: ctx.repo, timer?: false] ++ opts})
      name
    end

    test "runs every step in chunks when driven by hand", ctx do
      insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
      :ok = accept(ctx, Enum.map(1..5, &"e#{&1}"), @t0)
      # A clock that never moves: on the real one a busy runner spends the
      # 250 ms budget before the last steps run (the next test covers it).
      server = start_sweeper(ctx, chunk: 2, monotonic_ms: fn -> 0 end)

      assert {:ok, counts} = Sweeper.sweep(server, later(@t0, 7, 1))
      assert counts.expire_lifetime == 5
      assert counts.mark_terminal == 5
      assert Map.keys(counts) |> Enum.sort() == Sweeper.step_names() |> Enum.sort()
    end

    test "stops a pass when its time budget is spent", ctx do
      insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref]})
      :ok = accept(ctx, Enum.map(1..5, &"e#{&1}"), @t0)
      ticks = :counters.new(1, [])

      clock = fn ->
        :counters.add(ticks, 1, 300)
        :counters.get(ticks, 1)
      end

      server = start_sweeper(ctx, chunk: 2, monotonic_ms: clock)

      assert {:ok, %{expire_lifetime: 2} = counts} = Sweeper.sweep(server, later(@t0, 7, 1))
      assert map_size(counts) == 1
    end
  end
end
