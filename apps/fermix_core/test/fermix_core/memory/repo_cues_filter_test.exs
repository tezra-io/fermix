defmodule FermixCore.Memory.RepoCuesFilterTest do
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Ingest
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Memory.Repo.CuesSql

  @now ~U[2026-10-10 12:00:00.000000Z]
  # Every item below is of type `feed.item`, so this word offers it to a watcher.
  @words ["feed"]

  setup do
    ctx = start_repo("filter_sql")
    Map.put(ctx, :ref, "src-#{System.unique_integer([:positive])}")
  end

  defp call(ctx, request), do: Repo.cues_call(CuesFilterSql, request, server: ctx.repo)

  defp watcher(ctx, attrs \\ %{}) do
    defaults = %{filter: "llm", sources: [ctx.ref], listen_for: @words}
    id = insert_watcher(ctx.conn, Map.merge(defaults, attrs))

    exec!(
      ctx.conn,
      "UPDATE cue_watchers SET purpose = 'Releases.', filter_budget = ? WHERE id = ?",
      [Map.get(attrs, :budget, 0), id]
    )

    id
  end

  defp push(ctx, ids, now \\ @now) do
    items = Enum.map(ids, &item!(%{item_id: &1, type: "feed.item", data: %{"title" => &1}}, now))

    {:ok, _results} =
      Ingest.accept(%{ref: ctx.ref, daily_budget: 0}, items,
        now: now,
        repo: ctx.repo,
        wake_filters: fn -> :ok end,
        wake_scheduler: fn -> :ok end
      )

    :ok
  end

  defp claim(ctx, now \\ @now, free \\ 4, exclude \\ []) do
    {:ok, result} = call(ctx, {:claim, now, free, exclude})
    result
  end

  defp delivery(ctx, id) do
    [row] =
      rows(
        ctx.conn,
        "SELECT state, filter_attempts, ready_at, filter_call_id, decision_reason, hint, " <>
          "outcome, settled_at FROM cue_deliveries WHERE id = ?",
        [id]
      )

    Enum.zip([:state, :attempts, :ready_at, :call_id, :reason, :hint, :outcome, :settled_at], row)
    |> Map.new()
  end

  defp watcher_row(ctx, id) do
    [[failures, retry_at]] =
      rows(ctx.conn, "SELECT filter_failures, filter_retry_at FROM cue_watchers WHERE id = ?", [
        id
      ])

    %{failures: failures, retry_at: retry_at}
  end

  defp call_row(ctx, call_id) do
    [row] =
      rows(
        ctx.conn,
        "SELECT watcher_id, delivery_id, session_id, provider, model, started_at, finished_at, " <>
          "result, error FROM cue_filter_calls WHERE id = ?",
        [call_id]
      )

    Enum.zip(
      [:watcher_id, :delivery_id, :session_id, :provider, :model, :started_at, :finished_at] ++
        [:result, :error],
      row
    )
    |> Map.new()
  end

  defp provider_down, do: {:provider_failure, %{kind: :network, message: "connection refused"}}
  defp invalid, do: {:content_failure, %{kind: :invalid_answer, message: "No JSON object."}}

  describe "claim" do
    test "the oldest due pending delivery, one per watcher, moved to filtering with its call",
         ctx do
      w = watcher(ctx)
      push(ctx, ["a", "b", "c"])

      assert %{claims: [claim]} = claim(ctx)
      assert claim.watcher.id == w
      assert claim.cue.item_id == "a"
      assert claim.watcher.purpose == "Releases."
      assert claim.session_id =~ ~r/^cue_filter_#{w}_20261010_120000_[0-9a-f]{6}$/
      assert claim.call_id =~ ~r/^cfc_[0-9a-f]{24}$/

      assert %{state: "filtering", call_id: call_id} = delivery(ctx, claim.delivery.id)
      assert call_id == claim.call_id

      row = call_row(ctx, claim.call_id)
      assert row.session_id == claim.session_id
      assert row.delivery_id == claim.delivery.id
      # Every call uses the one Cues filter model, which the task resolves.
      assert {row.provider, row.model} == {nil, nil}
      assert row.finished_at == nil

      # The watcher is busy: no second claim while its call is open.
      assert %{claims: []} = claim(ctx)
    end

    test "watchers are taken by their oldest due delivery; free slots and exclusions bound it",
         ctx do
      first = watcher(ctx)
      push(ctx, ["a"])
      second = watcher(ctx, %{sources: [ctx.ref]})
      push(ctx, ["b"])

      assert %{claims: [only]} = claim(ctx, @now, 1)
      assert only.watcher.id == first

      assert %{claims: [next]} = claim(ctx, @now, 4, [first])
      assert next.watcher.id == second
    end

    # Design §7.4: past its lifetime a delivery expires, even when the
    # dispatcher asks before the retention sweep has run.
    test "a delivery past its lifetime is not claimed", ctx do
      _w = watcher(ctx)
      push(ctx, ["old"])
      push(ctx, ["new"], DateTime.add(@now, 2 * 86_400, :second))
      at = DateTime.add(@now, 8 * 86_400, :second)

      assert %{claims: [claim]} = claim(ctx, at)
      assert claim.cue.item_id == "new"
    end

    test "disabled, none and backing-off watchers are not claimed", ctx do
      disabled = watcher(ctx)
      _none = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      backing_off = watcher(ctx)
      push(ctx, ["a"])

      # Disabled after its delivery arrived: the claim itself must skip it.
      exec!(ctx.conn, "UPDATE cue_watchers SET enabled = 0 WHERE id = ?", [disabled])

      exec!(ctx.conn, "UPDATE cue_watchers SET filter_retry_at = ? WHERE id = ?", [
        "2026-10-10T12:00:30.000000Z",
        backing_off
      ])

      assert %{claims: [], next_at: next_at} = claim(ctx)
      assert next_at == ~U[2026-10-10 12:00:30.000000Z]

      assert %{claims: [claim]} = claim(ctx, ~U[2026-10-10 12:00:30.000000Z])
      assert claim.watcher.id == backing_off
    end

    test "a filter budget counts the watcher's calls of the last 24 hours", ctx do
      w = watcher(ctx, %{budget: 1})
      push(ctx, ["a", "b"])

      assert %{claims: [claim], over_budget: []} = claim(ctx)
      {:ok, _} = call(ctx, {:settle, claim.call_id, {:drop, "No."}, @now})

      assert %{claims: [], over_budget: [over]} = claim(ctx)
      assert %{watcher_id: ^w, budget: 1, waiting: 1} = over

      later = DateTime.add(@now, 86_401, :second)
      assert %{claims: [_claim], over_budget: []} = claim(ctx, later)
    end

    test "the active instructions in number order and the 20 most recent examples", ctx do
      w = watcher(ctx)
      push(ctx, ["a"])

      for {number, text, removed} <- [{3, "Third.", nil}, {1, "First.", nil}, {2, "Gone.", "x"}] do
        exec!(
          ctx.conn,
          "INSERT INTO cue_watcher_instructions (id, watcher_id, number, text, added_at, removed_at) " <>
            "VALUES (?, ?, ?, ?, '2026-10-01T00:00:00.000000Z', ?)",
          ["cwi_#{number}#{w}", w, number, text, removed]
        )
      end

      for n <- 1..22 do
        exec!(
          ctx.conn,
          "INSERT INTO cue_watcher_examples (id, watcher_id, cue_id, label, note, snapshot, created_at) " <>
            "VALUES (?, ?, 1, 'drop', ?, '{}', ?)",
          [
            "cwe_#{n}#{w}",
            w,
            "note #{n}",
            "2026-10-01T00:00:#{String.pad_leading("#{n}", 2, "0")}.000000Z"
          ]
        )
      end

      assert %{claims: [claim]} = claim(ctx)
      assert Enum.map(claim.instructions, & &1.number) == [1, 3]
      assert length(claim.examples) == 20
      assert List.first(claim.examples).note == "note 3"
      assert List.last(claim.examples).note == "note 22"
    end

    test "a delivery not yet due waits while a later one of the watcher goes ahead", ctx do
      watcher(ctx)
      push(ctx, ["a", "b"])

      %{claims: [first]} = claim(ctx)
      {:ok, _} = call(ctx, {:settle, first.call_id, invalid(), @now})

      assert %{claims: [second]} = claim(ctx)
      assert second.cue.item_id == "b"
    end
  end

  describe "settle" do
    test "pass stores the decision and readies the delivery; drop ends it", ctx do
      w = watcher(ctx)
      push(ctx, ["a", "b"])
      later = DateTime.add(@now, 5, :second)

      %{claims: [first]} = claim(ctx)

      assert {:ok, %{passed?: true, watcher_id: ^w, task_job_id: job, exhausted?: false}} =
               call(ctx, {:settle, first.call_id, {:pass, "A release.", "read notes"}, later})

      assert is_binary(job)

      assert %{state: "passed", reason: "A release.", hint: "read notes", ready_at: ready} =
               delivery(ctx, first.delivery.id)

      assert ready == "2026-10-10T12:00:05.000000Z"

      assert %{result: "pass", finished_at: "2026-10-10T12:00:05.000000Z"} =
               call_row(ctx, first.call_id)

      %{claims: [second]} = claim(ctx, later)

      assert {:ok, %{passed?: false}} =
               call(ctx, {:settle, second.call_id, {:drop, "Not mine."}, later})

      assert %{state: "dropped", reason: "Not mine.", outcome: nil, settled_at: settled} =
               delivery(ctx, second.delivery.id)

      assert settled == "2026-10-10T12:00:05.000000Z"
    end

    test "provider failures back off 30 s, 2 min, then 10 min; held from the third", ctx do
      w = watcher(ctx)
      push(ctx, ["a"])

      steps = [
        {@now, ~U[2026-10-10 12:00:30.000000Z], false},
        {~U[2026-10-10 12:00:30.000000Z], ~U[2026-10-10 12:02:30.000000Z], false},
        {~U[2026-10-10 12:02:30.000000Z], ~U[2026-10-10 12:12:30.000000Z], true},
        {~U[2026-10-10 12:12:30.000000Z], ~U[2026-10-10 12:22:30.000000Z], false}
      ]

      for {{at, retry_at, held_now?}, n} <- Enum.with_index(steps, 1) do
        %{claims: [claim]} = claim(ctx, at)

        assert {:ok, outcome} = call(ctx, {:settle, claim.call_id, provider_down(), at})
        assert outcome.held_now? == held_now?
        assert outcome.held? == n >= 3
        assert outcome.waiting == 1
        assert %{failures: ^n} = watcher_row(ctx, w)
        assert watcher_row(ctx, w).retry_at == CuesSql.stamp(retry_at)

        # Attempts and ready_at unchanged; back to pending with no fence.
        assert %{state: "pending", attempts: 0, call_id: nil, ready_at: ready} =
                 delivery(ctx, claim.delivery.id)

        assert ready == "2026-10-10T12:00:00.000000Z"
        assert %{result: "provider_failure", error: error} = call_row(ctx, claim.call_id)
        assert error =~ "network"

        # C30: no claim before filter_retry_at.
        assert %{claims: []} = claim(ctx, DateTime.add(retry_at, -1, :second))
      end

      %{claims: [claim]} = claim(ctx, ~U[2026-10-10 12:22:30.000000Z])

      assert {:ok, %{recovered?: true, passed?: true}} =
               call(ctx, {:settle, claim.call_id, {:pass, "Ok.", nil}, @now})

      assert watcher_row(ctx, w) == %{failures: 0, retry_at: nil}
    end

    test "content failures retry the cue after 30 s, then 2 min; the third exhausts it", ctx do
      watcher(ctx)
      push(ctx, ["a"])

      %{claims: [c1]} = claim(ctx)

      assert {:ok, %{exhausted?: false, attempt: 1}} =
               call(ctx, {:settle, c1.call_id, invalid(), @now})

      assert %{state: "pending", attempts: 1, ready_at: "2026-10-10T12:00:30.000000Z"} =
               delivery(ctx, c1.delivery.id)

      t2 = ~U[2026-10-10 12:00:30.000000Z]
      %{claims: [c2]} = claim(ctx, t2)

      assert {:ok, %{exhausted?: false, attempt: 2}} =
               call(ctx, {:settle, c2.call_id, invalid(), t2})

      assert %{ready_at: "2026-10-10T12:02:30.000000Z"} = delivery(ctx, c1.delivery.id)

      t3 = ~U[2026-10-10 12:02:30.000000Z]
      %{claims: [c3]} = claim(ctx, t3)

      assert {:ok, %{exhausted?: true, attempt: 3}} =
               call(ctx, {:settle, c3.call_id, invalid(), t3})

      assert %{state: "exhausted", attempts: 3, outcome: "filter_failed", settled_at: settled} =
               delivery(ctx, c1.delivery.id)

      assert settled == "2026-10-10T12:02:30.000000Z"
      assert %{result: "content_failure"} = call_row(ctx, c3.call_id)
    end

    test "a settle with a stale fence is refused and writes nothing", ctx do
      watcher(ctx)
      push(ctx, ["a"])
      %{claims: [claim]} = claim(ctx)

      assert {:ok, %{reset: 1}} = call(ctx, {:reset, @now})
      before = delivery(ctx, claim.delivery.id)

      assert {:error, :stale} = call(ctx, {:settle, claim.call_id, {:pass, "Late.", nil}, @now})
      assert delivery(ctx, claim.delivery.id) == before
      assert %{result: "aborted"} = call_row(ctx, claim.call_id)
    end

    test "a settle whose delivery left the call's fence is refused and closes the call", ctx do
      watcher(ctx)
      push(ctx, ["a"])
      %{claims: [claim]} = claim(ctx)

      # The delivery left `filtering` while its call was still open.
      exec!(
        ctx.conn,
        "UPDATE cue_deliveries SET state = 'pending', filter_call_id = NULL WHERE id = ?",
        [claim.delivery.id]
      )

      before = delivery(ctx, claim.delivery.id)

      assert {:error, :stale} = call(ctx, {:settle, claim.call_id, {:pass, "Late.", nil}, @now})
      assert delivery(ctx, claim.delivery.id) == before

      assert %{result: "aborted", finished_at: finished, error: error} =
               call_row(ctx, claim.call_id)

      assert finished == CuesSql.stamp(@now)
      assert error =~ "stale"
    end

    test "an unknown call and a malformed result are refused", ctx do
      assert {:error, :stale} = call(ctx, {:settle, "cfc_missing", {:drop, "x"}, @now})

      assert {:error, {:invalid, :result}} =
               call(ctx, {:settle, "cfc_missing", {:maybe, "x"}, @now})
    end
  end

  describe "reset (C18)" do
    test "every filtering delivery goes back to pending without spending an attempt", ctx do
      watcher(ctx)
      push(ctx, ["a"])
      %{claims: [c1]} = claim(ctx)
      {:ok, _} = call(ctx, {:settle, c1.call_id, invalid(), @now})
      t2 = ~U[2026-10-10 12:00:30.000000Z]
      %{claims: [c2]} = claim(ctx, t2)

      assert {:ok, %{reset: 1, aborted: 1}} = call(ctx, {:reset, t2})

      assert %{state: "pending", attempts: 1, call_id: nil, ready_at: ready} =
               delivery(ctx, c2.delivery.id)

      assert ready == "2026-10-10T12:00:30.000000Z"

      assert %{result: "aborted", finished_at: "2026-10-10T12:00:30.000000Z"} =
               call_row(ctx, c2.call_id)
    end
  end

  describe "held watchers" do
    test "lists watchers held by provider failures with their waiting count", ctx do
      w = watcher(ctx)
      push(ctx, ["a", "b"])
      exec!(ctx.conn, "UPDATE cue_watchers SET filter_failures = 3 WHERE id = ?", [w])

      assert {:ok, [%{watcher_id: ^w, filter_failures: 3, waiting: 2}]} =
               call(ctx, {:held_watchers})
    end
  end

  describe "live calls (M60_CUE_INTAKE_AT_SCALE.md §3.2)" do
    defp live_call(id, at),
      do: %{id: id, session_id: "s-#{id}", started_at: at, provider: "openai", model: "m-1"}

    defp settle_live(ctx, w, id, result, at \\ @now),
      do: call(ctx, {:settle_live, w, live_call(id, at), result, at})

    test "a drop writes the call's ledger row with no delivery, once", ctx do
      w = watcher(ctx)

      assert {:ok, %{result: :dropped, recovered?: false}} =
               settle_live(ctx, w, "cfc_d", {:drop, "Off topic."})

      # The same write sent again after a timeout that still ran.
      assert {:ok, %{result: :dropped}} = settle_live(ctx, w, "cfc_d", {:drop, "Off topic."})

      assert %{watcher_id: ^w, delivery_id: nil, provider: "openai", model: "m-1"} =
               call_row(ctx, "cfc_d")

      assert %{result: "drop", error: nil} = call_row(ctx, "cfc_d")
      assert [[1]] = rows(ctx.conn, "SELECT count(*) FROM cue_filter_calls")
    end

    test "provider failures back the watcher off and hold it from the third, as a stored " <>
           "call's do; a drop after the hold recovers it",
         ctx do
      w = watcher(ctx)

      for {n, retry_at} <- [
            {1, ~U[2026-10-10 12:00:30.000000Z]},
            {2, ~U[2026-10-10 12:02:00.000000Z]},
            {3, ~U[2026-10-10 12:10:00.000000Z]}
          ] do
        assert {:ok, outcome} = settle_live(ctx, w, "cfc_p#{n}", provider_down())
        assert outcome.held_now? == (n == 3)
        assert outcome.result == if(n == 3, do: :held, else: :retry)
        assert watcher_row(ctx, w) == %{failures: n, retry_at: CuesSql.stamp(retry_at)}

        assert %{result: "provider_failure", error: "network: connection refused"} =
                 call_row(ctx, "cfc_p#{n}")
      end

      # The hold is the watcher's: its stored deliveries wait too.
      push(ctx, ["a"])
      assert %{claims: []} = claim(ctx, ~U[2026-10-10 12:09:59.000000Z])

      assert {:ok, %{result: :dropped, recovered?: true}} =
               settle_live(ctx, w, "cfc_ok", {:drop, "Off topic."})

      assert watcher_row(ctx, w) == %{failures: 0, retry_at: nil}
    end

    test "a provider failure sent again after a timeout that still ran counts once, and " <>
           "answers the backoff the first write left",
         ctx do
      w = watcher(ctx)
      retry_at = ~U[2026-10-10 12:00:30.000000Z]

      assert {:ok, %{result: :retry, filter_failures: 1, retry_at: ^retry_at}} =
               settle_live(ctx, w, "cfc_p", provider_down())

      # The same call's write, sent again a second later.
      later = DateTime.add(@now, 1, :second)
      resent = {:settle_live, w, live_call("cfc_p", @now), provider_down(), later}

      assert {:ok, %{result: :retry, filter_failures: 1, retry_at: ^retry_at, held_now?: false}} =
               call(ctx, resent)

      assert watcher_row(ctx, w) == %{failures: 1, retry_at: CuesSql.stamp(retry_at)}
      assert [[1]] = rows(ctx.conn, "SELECT count(*) FROM cue_filter_calls")
    end

    test "a content failure is the item's: the ledger row only", ctx do
      w = watcher(ctx)

      assert {:ok, %{result: :failed, held_now?: false}} =
               settle_live(ctx, w, "cfc_c", invalid())

      assert watcher_row(ctx, w) == %{failures: 0, retry_at: nil}
      assert %{result: "content_failure"} = call_row(ctx, "cfc_c")
    end

    test "a pass or an unknown result is refused here", ctx do
      w = watcher(ctx)

      assert {:error, {:invalid, :live_result}} =
               settle_live(ctx, w, "cfc_x", {:pass, "Ok.", nil})

      assert {:error, {:invalid, :live_result}} =
               settle_live(ctx, w, "cfc_x", {:aborted, %{kind: :shutdown, message: "x"}})
    end

    test "the live context: instructions, recent examples and the calls the budget counts, " <>
           "live ones included",
         ctx do
      w = watcher(ctx, %{budget: 3})
      other = watcher(ctx)

      exec!(
        ctx.conn,
        "INSERT INTO cue_watcher_instructions (id, watcher_id, number, text, added_at) " <>
          "VALUES ('cwi_1', ?, 1, 'Only launches.', ?)",
        [w, CuesSql.stamp(@now)]
      )

      {:ok, _row} = settle_live(ctx, w, "cfc_old", {:drop, "No."}, DateTime.add(@now, -2, :day))
      {:ok, _row} = settle_live(ctx, w, "cfc_new", {:drop, "No."})
      push(ctx, ["a"])

      for stored <- claim(ctx).claims,
          do: {:ok, _outcome} = call(ctx, {:settle, stored.call_id, {:drop, "No."}, @now})

      assert {:ok, %{^w => context, ^other => %{used: 1, instructions: []}}} =
               call(ctx, {:live_context, [w, other], @now})

      assert context == %{
               instructions: [%{number: 1, text: "Only launches."}],
               examples: [],
               used: 2
             }

      # The stored claim's budget counts the live rows as well: two live calls
      # and one stored call in the window spend this watcher's three.
      {:ok, _row} = settle_live(ctx, w, "cfc_third", {:drop, "No."})
      push(ctx, ["b"])

      assert %{claims: [%{watcher: %{id: ^other}}], over_budget: [%{watcher_id: ^w}]} =
               claim(ctx)
    end
  end
end
