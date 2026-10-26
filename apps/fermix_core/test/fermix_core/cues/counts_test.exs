defmodule FermixCore.Cues.CountsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Counts
  alias FermixTestSupport.TelemetryCapture

  @t0 ~U[2026-10-12 14:20:00Z]

  test "totals per ref and UTC hour, written as absolute rows of one incarnation" do
    counts =
      Counts.new("source")
      |> Counts.add("bsky-news", "received", 40, @t0)
      |> Counts.add("bsky-news", "unmatched", 38, @t0)
      |> Counts.add("bsky-news", "received", 2, DateTime.add(@t0, 30, :second))
      |> Counts.add("bsky-news", "stale", 0, @t0)

    assert [row] = Counts.rows(counts)

    assert row == %{
             scope: "source",
             ref: "bsky-news",
             hour: ~U[2026-10-12 14:00:00Z],
             incarnation: counts.incarnation,
             counts: %{"received" => 42, "unmatched" => 38}
           }

    refute Counts.new("source").incarnation == counts.incarnation
  end

  test "an hour is forgotten once a flush wrote it and it has passed; the current one stays" do
    counts =
      Counts.new("watcher")
      |> Counts.add("cwt_a", "offered", 3, @t0)
      |> Counts.add("cwt_a", "offered", 1, DateTime.add(@t0, 3_600, :second))

    rows = Counts.rows(counts)
    next_hour = DateTime.add(@t0, 3_600, :second)

    assert counts |> Counts.written(rows, @t0) |> Counts.rows() |> length() == 2

    assert [%{hour: ~U[2026-10-12 15:00:00Z]}] =
             counts |> Counts.written(rows, next_hour) |> Counts.rows()

    # A flush that failed wrote nothing: every hour is sent again.
    assert counts |> Counts.written([], next_hour) |> Counts.rows() |> length() == 2
  end

  test "a report traces each outcome gained since the last one, once" do
    TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], :emitter)

    counts =
      Counts.new("watcher")
      |> Counts.add("cwt_r", "offered", 5, @t0)
      |> Counts.add("cwt_r", "overflow", 2, @t0)
      |> Counts.add("cwt_r", "passed", 1, @t0)
      |> Counts.report()

    assert_received {:telemetry, _event, %{count: 2}, %{phase: :overflow, watcher_id: "cwt_r"}}
    refute_received {:telemetry, _event, _m, %{phase: :offered}}
    refute_received {:telemetry, _event, _m, %{phase: :passed}}

    counts |> Counts.add("cwt_r", "overflow", 1, @t0) |> Counts.report()
    assert_received {:telemetry, _event, %{count: 1}, %{phase: :overflow}}

    Counts.new("source") |> Counts.add("s", "invalid", 4, @t0) |> Counts.report()
    assert_received {:telemetry, _event, %{count: 4}, %{phase: :rejected, source_ref: "s"}}
  end

  test "a name outside the scope's list is refused" do
    assert_raise MatchError, fn -> Counts.add(Counts.new("source"), "s", "dropped", 1, @t0) end
    assert_raise FunctionClauseError, fn -> Counts.new("delivery") end
  end
end
