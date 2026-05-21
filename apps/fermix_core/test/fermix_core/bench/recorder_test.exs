defmodule FermixCore.Bench.RecorderTest do
  use ExUnit.Case, async: true

  alias FermixCore.Bench.Recorder

  test "records duration_us and duration_ms telemetry by stage" do
    event_us = [:fermix, :bench_test, :us, :"#{System.unique_integer([:positive])}"]
    event_ms = [:fermix, :bench_test, :ms, :"#{System.unique_integer([:positive])}"]

    {:ok, recorder} =
      Recorder.start(
        events: [
          {event_us, "micro"},
          {event_ms, "milli"}
        ]
      )

    try do
      assert :ets.info(recorder.table, :write_concurrency)

      :telemetry.execute(event_us, %{duration_us: 11}, %{})
      :telemetry.execute(event_ms, %{duration_ms: 2}, %{})

      assert %{"micro" => [11], "milli" => [2_000]} = Recorder.samples(recorder)
    after
      Recorder.stop(recorder)
    end
  end
end
