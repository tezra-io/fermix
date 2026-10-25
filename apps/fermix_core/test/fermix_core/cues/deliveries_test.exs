defmodule FermixCore.Cues.DeliveriesTest do
  # The read side behind list_cues and cue_history (M60 §9.5, §9.10): what a
  # delivery shows, what is framed, the page bounds, and the receipts summary.
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Deliveries
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesDeliveriesSql
  alias FermixTestSupport.CueDeliveryFixtures, as: Rows
  alias FermixTestSupport.CueFixtures

  @frame_open "<untrusted_tool_result"
  @frame_close "</untrusted_tool_result>"
  @day 86_400

  setup do
    %{repo: repo, conn: conn} = CueFixtures.start_repo("deliveries")
    now = ~U[2026-10-17 12:00:00.000000Z]
    %{repo: repo, conn: conn, now: now}
  end

  defp at(now, seconds_ago), do: DateTime.add(now, -seconds_ago, :second)

  # One acted delivery with a run, a mandate call and a proposal, every
  # free-text field carrying its own marker.
  defp acted_delivery(conn, watcher, now) do
    cue =
      Rows.cue(conn, %{
        source_ref: "gh-releases",
        received_at: at(now, @day),
        type: "release.published",
        subject: "phoenix-1.8.2",
        text: "SNAPSHOT-MARK Phoenix 1.8.2 released"
      })

    delivery =
      Rows.delivery(conn, cue, %{
        watcher_id: watcher.id,
        source_ref: "gh-releases",
        received_at: at(now, @day),
        subject: "phoenix-1.8.2",
        outcome: "acted",
        reason: "REASON-MARK a release of a watched framework",
        hint: "HINT-MARK open an issue"
      })

    run = Rows.run(conn, watcher.job_id, delivery, "REPLY-MARK " <> String.duplicate("r", 400))

    call =
      Rows.call(conn, %{
        run_id: run,
        job_id: watcher.job_id,
        delivery_id: delivery,
        at: at(now, @day - 60),
        args_json: ~s({"title":"ARGS-MARK Upgrade Phoenix"}),
        reason: "CALL-REASON-MARK",
        result_summary: "RESULT-MARK issue 42 opened"
      })

    proposal =
      Rows.proposal(conn, %{
        call_id: call,
        run_id: run,
        job_id: watcher.job_id,
        watcher_id: watcher.id,
        delivery_id: delivery,
        at: at(now, @day - 60),
        args_json: ~s({"title":"ARGS-MARK Upgrade Phoenix"})
      })

    %{cue: cue, delivery: delivery, run: run, call: call, proposal: proposal}
  end

  describe "list/2" do
    test "a delivery carries Fermix's record, its run, its calls and proposals", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["gh-releases"]})
      ids = acted_delivery(ctx.conn, watcher, ctx.now)

      assert {:ok, %{deliveries: [delivery], more?: false}} =
               Deliveries.list(%{limit: 10, watcher_id: watcher.id}, repo: ctx.repo)

      shown = Deliveries.present(delivery)

      assert shown.delivery_id == ids.delivery
      assert shown.watcher == watcher.name
      assert shown.source == "gh-releases"
      assert shown.state == "acked"
      assert shown.outcome == "acted"
      assert shown.run == %{id: ids.run, status: "ok"}
      assert [%{id: call_id, decision: "allow", result_status: "ok"}] = shown.calls
      assert call_id == ids.call
      assert [%{id: proposal_id, state: "waiting"}] = shown.proposals
      assert proposal_id == ids.proposal
    end

    test "every cue-derived field is inside the frame and nowhere outside it", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["gh-releases"]})
      acted_delivery(ctx.conn, watcher, ctx.now)

      {:ok, %{deliveries: [delivery]}} = Deliveries.list(%{limit: 10}, repo: ctx.repo)
      shown = Deliveries.present(delivery)
      framed = shown.outside_text
      outside = shown |> Map.delete(:outside_text) |> Jason.encode!()

      assert String.starts_with?(framed, ~s(#{@frame_open} source="cue:gh-releases">))
      assert String.ends_with?(framed, @frame_close)

      for mark <-
            ~w(SNAPSHOT-MARK REASON-MARK HINT-MARK REPLY-MARK ARGS-MARK CALL-REASON-MARK RESULT-MARK) do
        assert framed =~ mark, "#{mark} is not framed"
        refute outside =~ mark, "#{mark} is outside the frame"
      end

      refute outside =~ "phoenix-1.8.2", "the cue's subject is outside the frame"
      refute outside =~ "release.published", "the cue's type is outside the frame"
    end

    test "the reply shows its first 280 characters only, marked as cut", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["gh-releases"]})
      acted_delivery(ctx.conn, watcher, ctx.now)

      {:ok, %{deliveries: [delivery]}} = Deliveries.list(%{limit: 10}, repo: ctx.repo)

      assert String.length(delivery.run.reply_excerpt) == 281
      assert String.ends_with?(delivery.run.reply_excerpt, "…")
    end

    test "filters by watcher, state and time; pages newest first", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["feed"]})
      other = Rows.watcher(ctx.conn, %{sources: ["feed"]})

      # Inserted oldest first: the delivery id is the arrival order.
      ids =
        for n <- 4..1//-1 do
          cue = Rows.cue(ctx.conn, %{source_ref: "feed", received_at: at(ctx.now, n * 3_600)})
          state = if rem(n, 2) == 0, do: "dropped", else: "acked"

          Rows.delivery(ctx.conn, cue, %{
            watcher_id: watcher.id,
            source_ref: "feed",
            received_at: at(ctx.now, n * 3_600),
            state: state,
            outcome: if(state == "acked", do: "ignored")
          })
        end

      other_cue = Rows.cue(ctx.conn, %{source_ref: "feed", received_at: at(ctx.now, 60)})

      Rows.delivery(ctx.conn, other_cue, %{
        watcher_id: other.id,
        source_ref: "feed",
        received_at: at(ctx.now, 60)
      })

      assert {:ok, %{deliveries: page, more?: true}} =
               Deliveries.list(%{limit: 3, watcher_id: watcher.id}, repo: ctx.repo)

      newest_first = Enum.reverse(ids)
      assert Enum.map(page, & &1.id) == Enum.take(newest_first, 3)

      assert {:ok, %{deliveries: [last], more?: false}} =
               Deliveries.list(
                 %{limit: 3, watcher_id: watcher.id, before_id: List.last(page).id},
                 repo: ctx.repo
               )

      assert last.id == List.last(newest_first)

      assert {:ok, %{deliveries: dropped}} =
               Deliveries.list(%{limit: 10, watcher_id: watcher.id, state: "dropped"},
                 repo: ctx.repo
               )

      assert Enum.map(dropped, & &1.state) == ["dropped", "dropped"]

      assert {:ok, %{deliveries: recent}} =
               Deliveries.list(
                 %{limit: 10, watcher_id: watcher.id, since: at(ctx.now, 2 * 3_600)},
                 repo: ctx.repo
               )

      assert length(recent) == 2
    end

    test "a page is bounded: no more than 25 rows, and calls per delivery are counted", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["gh-releases"]})
      ids = acted_delivery(ctx.conn, watcher, ctx.now)

      for n <- 1..12 do
        Rows.call(ctx.conn, %{
          run_id: ids.run,
          job_id: watcher.job_id,
          delivery_id: ids.delivery,
          at: at(ctx.now, @day - 60 - n),
          args_json: "{}",
          decision: "refuse"
        })
      end

      assert_raise FunctionClauseError, fn -> Deliveries.list(%{limit: 26}, repo: ctx.repo) end

      {:ok, %{deliveries: [delivery]}} = Deliveries.list(%{limit: 25}, repo: ctx.repo)
      shown = Deliveries.present(delivery)

      assert length(shown.calls) == 10
      assert shown.more_calls == 3
    end
  end

  describe "history/4" do
    test "stays within the watcher and 30 days, newest first, leaving out a delivery", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["feed"]})
      other = Rows.watcher(ctx.conn, %{sources: ["feed"]})

      deliver = fn who, seconds_ago, subject ->
        cue =
          Rows.cue(ctx.conn, %{
            source_ref: "feed",
            received_at: at(ctx.now, seconds_ago),
            subject: subject
          })

        Rows.delivery(ctx.conn, cue, %{
          watcher_id: who.id,
          source_ref: "feed",
          subject: subject,
          received_at: at(ctx.now, seconds_ago)
        })
      end

      old = deliver.(watcher, 31 * @day, "disk-a")
      yesterday = deliver.(watcher, @day, "disk-a")
      current = deliver.(watcher, 60, "disk-a")
      _theirs = deliver.(other, 3_600, "disk-a")
      _other_subject = deliver.(watcher, 7_200, "disk-b")

      assert {:ok, rows} =
               Deliveries.history(
                 watcher.id,
                 %{limit: 20, subject: "disk-a", exclude_id: current},
                 ctx.now,
                 repo: ctx.repo
               )

      assert Enum.map(rows, & &1.id) == [yesterday]
      refute old in Enum.map(rows, & &1.id)
    end
  end

  describe "summary/2" do
    test "says from receipts that a source sent cues and nothing is listening", ctx do
      watcher = Rows.watcher(ctx.conn, %{sources: ["heard"]})

      for n <- 1..40 do
        Rows.cue(ctx.conn, %{
          source_ref: "unheard",
          received_at: at(ctx.now, n * 3_600),
          routed: 0
        })
      end

      cue = Rows.cue(ctx.conn, %{source_ref: "heard", received_at: at(ctx.now, 600)})

      Rows.delivery(ctx.conn, cue, %{
        watcher_id: watcher.id,
        source_ref: "heard",
        received_at: at(ctx.now, 600),
        outcome: "ignored"
      })

      since = at(ctx.now, 7 * @day)
      assert {:ok, summary} = Deliveries.summary(%{since: since}, repo: ctx.repo)
      shown = Deliveries.present_summary(summary, since)

      unheard = Enum.find(shown.sources, &(&1.source == "unheard"))
      assert unheard.cues == 40
      assert unheard.not_routed == 40
      assert unheard.listening == []

      assert unheard.note ==
               "Nothing is listening: the 40 cues it sent since Saturday, October 10, 2026 at 12:00 PM UTC reached no watcher."

      heard = Enum.find(shown.sources, &(&1.source == "heard"))
      assert heard.listening == [watcher.name]
      refute Map.has_key?(heard, :note)

      assert [%{watcher: name, deliveries: 1, by_state: %{"acked" => 1}}] = shown.watchers
      assert name == watcher.name
    end
  end

  test "an unknown or mistyped filter is an error from the Repo, never a crash of it", ctx do
    request = {:list_deliveries, %{limit: 5, bogus: 1, before_id: -1}}

    assert {:error, {:invalid_filters, bad}} =
             Repo.cues_call(CuesDeliveriesSql, request, server: ctx.repo)

    assert Enum.sort(bad) == [:before_id, :bogus]
    assert {:ok, %{deliveries: []}} = Deliveries.list(%{limit: 5}, repo: ctx.repo)
  end
end
