defmodule FermixCore.Memory.ConversationWriteBenchmarkTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationWriteBenchmark

  test "measures memory-only and durable conversation write latency" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-conversation-write-benchmark-test-#{System.unique_integer([:positive])}.db"
      )

    assert {:ok, result} =
             ConversationWriteBenchmark.run(
               iterations: 5,
               warmup: 1,
               message_bytes: 32,
               database_path: db_path
             )

    assert result.iterations == 5
    assert result.warmup == 1
    assert result.message_bytes == 32
    assert_stats(result.in_memory)
    assert_stats(result.durable)
    assert_stats(result.overhead)
    refute File.exists?(db_path)
  end

  defp assert_stats(stats) do
    assert is_float(stats.avg_us)
    assert stats.avg_us >= 0.0
    assert is_integer(stats.p50_us)
    assert is_integer(stats.p95_us)
    assert is_integer(stats.p99_us)
    assert is_integer(stats.max_us)
    assert stats.max_us >= stats.p50_us
  end
end
