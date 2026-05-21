defmodule FermixCore.Bench.StatsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Bench.Stats

  test "summarizes sorted percentiles and spread" do
    stats = Stats.summarize([1, 2, 3, 4, 100])

    assert stats.count == 5
    assert stats.p50_us == 3
    assert stats.p95_us == 100
    assert stats.p99_us == 100
    assert stats.max_us == 100
    assert stats.mean_us == 22.0
    assert stats.stdev_us > 0
  end

  test "rejects empty samples" do
    assert {:error, :empty_samples} = Stats.summarize_safe([])
  end
end
