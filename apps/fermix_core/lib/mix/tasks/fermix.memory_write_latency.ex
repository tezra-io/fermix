defmodule Mix.Tasks.Fermix.MemoryWriteLatency do
  @moduledoc """
  Benchmarks `ConversationStore.add_message/4` synchronous return latency.

  The durable SQLite commit runs asynchronously under a Task.Supervisor since
  2026-05-02, so the "durable" stats below measure the synchronous return path
  with the durable store wired up (in-memory append + task enqueue + telemetry).
  Async commit latency is exposed separately via the `[:fermix, :memory,
  :message_persist]` telemetry event.
  """

  use Mix.Task

  alias FermixCore.Memory.ConversationWriteBenchmark

  @shortdoc "Benchmark ConversationStore.add_message/4 sync return latency"

  @switches [
    iterations: :integer,
    warmup: :integer,
    message_bytes: :integer,
    database_path: :string,
    keep_database: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")

    {:ok, _apps} = Application.ensure_all_started(:exqlite)
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    raise_on_invalid_options(invalid)

    opts
    |> ConversationWriteBenchmark.run()
    |> print_result()
  end

  defp raise_on_invalid_options([]), do: :ok

  defp raise_on_invalid_options(invalid) do
    Mix.raise("invalid options: #{inspect(invalid)}")
  end

  defp print_result({:ok, result}) do
    Mix.shell().info("ConversationStore.add_message/4 latency")
    Mix.shell().info("iterations: #{result.iterations}")
    Mix.shell().info("warmup: #{result.warmup}")
    Mix.shell().info("message bytes: #{result.message_bytes}")
    Mix.shell().info("database path: #{result.database_path}")
    Mix.shell().info("")
    print_stats("memory only", result.in_memory)
    print_stats("durable sqlite", result.durable)
    print_stats("durable overhead", result.overhead)
  end

  defp print_result({:error, reason}) do
    Mix.raise("conversation write latency benchmark failed: #{inspect(reason)}")
  end

  defp print_stats(label, stats) do
    Mix.shell().info(
      "#{label}: avg=#{format_us(stats.avg_us)} p50=#{stats.p50_us}us " <>
        "p95=#{stats.p95_us}us p99=#{stats.p99_us}us max=#{stats.max_us}us"
    )
  end

  defp format_us(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1) <> "us"
end
