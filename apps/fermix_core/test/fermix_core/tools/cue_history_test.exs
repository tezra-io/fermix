defmodule FermixCore.Tools.CueHistoryTest do
  # `cue_history` (M60 §9.10 item 1, C51): only in a cue run, only its own
  # watcher's deliveries within 30 days, framed.
  use ExUnit.Case, async: true

  alias FermixCore.Tools.CueHistory
  alias FermixTestSupport.CueDeliveryFixtures, as: Rows
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.TelemetryCapture

  @frame_open "<untrusted_tool_result"
  @now ~U[2026-10-17 12:00:00.000000Z]
  @day 86_400

  setup do
    %{repo: repo, conn: conn} = CueFixtures.start_repo("cue_history")
    mine = Rows.watcher(conn, %{sources: ["gh-releases"]})
    theirs = Rows.watcher(conn, %{sources: ["gh-releases"]})
    %{repo: repo, conn: conn, mine: mine, theirs: theirs}
  end

  defp deliver(ctx, watcher, seconds_ago, subject, extra \\ %{}) do
    received = DateTime.add(@now, -seconds_ago, :second)

    cue =
      Rows.cue(ctx.conn, %{
        source_ref: "gh-releases",
        received_at: received,
        subject: subject,
        text: "SNAPSHOT #{subject}"
      })

    Rows.delivery(
      ctx.conn,
      cue,
      Map.merge(
        %{
          watcher_id: watcher.id,
          source_ref: "gh-releases",
          subject: subject,
          received_at: received
        },
        extra
      )
    )
  end

  defp cue_run(ctx, delivery_id) do
    %{
      agent_name: "scheduled:#{ctx.mine.job_id}",
      conversation_key: {:scheduled_job, ctx.mine.job_id, "run_now"},
      session_id: "cron_#{ctx.mine.job_id}_#{System.unique_integer([:positive])}",
      source_trust: :operator,
      job_id: ctx.mine.job_id,
      run_id: "run_now",
      trigger: "cue",
      outside_sources: MapSet.new([{:cue, "gh-releases"}]),
      cue: %{delivery_id: delivery_id, watcher_id: ctx.mine.id, task_notes?: false},
      memory_repo: ctx.repo,
      clock: fn -> @now end
    }
  end

  defp decoded({:ok, %{success: true, output: output}}), do: Jason.decode!(output)

  test "C51: yesterday's subject comes back with its outcome and calls, framed", ctx do
    yesterday =
      deliver(ctx, ctx.mine, @day, "phoenix-1.8.2", %{outcome: "acted", reason: "a release"})

    run = Rows.run(ctx.conn, ctx.mine.job_id, yesterday, "Opened an issue for Phoenix 1.8.2.")

    call =
      Rows.call(ctx.conn, %{
        run_id: run,
        job_id: ctx.mine.job_id,
        delivery_id: yesterday,
        at: DateTime.add(@now, -@day + 60, :second),
        args_json: ~s({"title":"Upgrade to Phoenix 1.8.2"}),
        result_summary: "issue 42"
      })

    current = deliver(ctx, ctx.mine, 60, "phoenix-1.8.2", %{state: "claimed"})
    assert CueHistory.advertise?(cue_run(ctx, current))

    body =
      decoded(CueHistory.execute(%{"subject" => "phoenix-1.8.2"}, cue_run(ctx, current)))

    assert [delivery] = body["deliveries"]
    assert delivery["delivery_id"] == yesterday
    assert delivery["outcome"] == "acted"
    assert [%{"id" => ^call, "decision" => "allow", "result_status" => "ok"}] = delivery["calls"]

    framed = delivery["outside_text"]
    assert framed =~ @frame_open
    assert framed =~ "Upgrade to Phoenix 1.8.2"
    assert framed =~ "issue 42"
    assert framed =~ "Opened an issue for Phoenix 1.8.2."
    assert framed =~ "Subject: phoenix-1.8.2"
    refute Jason.encode!(Map.delete(delivery, "outside_text")) =~ "Upgrade to Phoenix"
  end

  test "C51: another task's subject returns nothing", ctx do
    deliver(ctx, ctx.theirs, @day, "redis-7.4", %{outcome: "acted"})
    current = deliver(ctx, ctx.mine, 60, "phoenix-1.8.2", %{state: "claimed"})

    body = decoded(CueHistory.execute(%{"subject" => "redis-7.4"}, cue_run(ctx, current)))

    assert body["deliveries"] == []
    assert body["note"] == "This watcher received nothing else that matches."
  end

  test "it reads no further back than 30 days and at most 20 items", ctx do
    deliver(ctx, ctx.mine, 31 * @day, "old")
    for n <- 1..25, do: deliver(ctx, ctx.mine, n * 3_600, "recent-#{n}")
    current = deliver(ctx, ctx.mine, 60, "now", %{state: "claimed"})

    body = decoded(CueHistory.execute(%{"limit" => 100}, cue_run(ctx, current)))

    assert length(body["deliveries"]) == 20
    refute Enum.any?(body["deliveries"], &(&1["outside_text"] =~ "SNAPSHOT old"))
    refute Enum.any?(body["deliveries"], &(&1["delivery_id"] == current))
  end

  test "outside a cue run it is not offered and refuses by name, with one exec event", ctx do
    deliver(ctx, ctx.mine, @day, "phoenix-1.8.2")

    owner = %{
      agent_name: "main",
      conversation_key: {"telegram", "owner", :root},
      session_id: "owner-#{System.unique_integer([:positive])}",
      source_trust: :operator,
      computer_use_origin: :interactive,
      memory_repo: ctx.repo
    }

    scheduled = %{
      agent_name: "scheduled:job_cron",
      conversation_key: {:scheduled_job, "job_cron", "run_cron"},
      session_id: "cron-#{System.unique_integer([:positive])}",
      source_trust: :operator,
      trigger: "schedule",
      memory_repo: ctx.repo
    }

    for context <- [owner, scheduled] do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: context.session_id)

      refute CueHistory.advertise?(context)

      assert {:ok, %{success: false, error: "cue_history is available only in a run a cue woke."}} =
               CueHistory.execute(%{}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                      %{tool: "cue_history", success: false}}
    end
  end

  test "a cue run without its watcher in the context is refused", ctx do
    context = Map.put(cue_run(ctx, 1), :cue, %{delivery_id: 1})

    assert {:ok, %{success: false, error: "cue_history is available only in a run a cue woke."}} =
             CueHistory.execute(%{}, context)
  end
end
