defmodule Mix.Tasks.Fermix.Bench.Soak do
  @moduledoc """
  Run the manual Fermix soak benchmark.
  """

  use Mix.Task

  alias FermixChannels.Bench.Runner
  alias FermixCore.Bench.Reporter

  @shortdoc "Run the Fermix 10-minute soak benchmark"
  @default_duration_ms 10 * 60 * 1_000
  @default_samples 100
  @default_output "bench/soak.json"

  @switches [
    duration_ms: :integer,
    samples: :integer,
    output: :string
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    raise_on_invalid_options(invalid)

    opts
    |> soak_opts()
    |> run_soak()
    |> print_result()
  end

  defp soak_opts(opts) do
    %{
      duration_ms: Keyword.get(opts, :duration_ms, @default_duration_ms),
      samples: Keyword.get(opts, :samples, @default_samples),
      output: opts |> Keyword.get(:output, @default_output) |> project_path()
    }
  end

  defp run_soak(%{duration_ms: duration_ms, samples: samples} = opts)
       when duration_ms > 0 and samples > 0 do
    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + duration_ms
    before_memory = :erlang.memory(:total)

    batches = run_batches(deadline, samples, [])
    after_memory = :erlang.memory(:total)

    report =
      opts
      |> build_report(batches, before_memory, after_memory, started_at)
      |> maybe_write_report(opts.output)

    report
  end

  defp run_soak(_opts), do: Mix.raise("duration-ms and samples must be positive")

  defp run_batches(deadline, samples, batches) do
    if System.monotonic_time(:millisecond) >= deadline and batches != [] do
      Enum.reverse(batches)
    else
      batch = run_batch!(samples)
      run_batches(deadline, samples, [batch | batches])
    end
  end

  defp run_batch!(samples) do
    {:ok, report} =
      Runner.run(
        scenarios: ["shared_multi_conv_throughput"],
        samples: samples,
        warmup: 0,
        output: nil
      )

    report.scenarios["shared_multi_conv_throughput"]
  end

  defp build_report(opts, batches, before_memory, after_memory, started_at) do
    elapsed_ms = max(System.monotonic_time(:millisecond) - started_at, 1)
    processed = Enum.reduce(batches, 0, &(&1.messages_processed + &2))

    %{
      version: 1,
      scenario: "shared_soak_10min",
      duration_ms: elapsed_ms,
      target_duration_ms: opts.duration_ms,
      batches: length(batches),
      messages_processed: processed,
      throughput_messages_per_second: Float.round(processed * 1_000 / elapsed_ms, 2),
      memory: %{
        beam_total_before_bytes: before_memory,
        beam_total_after_bytes: after_memory,
        beam_total_growth_bytes: after_memory - before_memory,
        beam_total_growth_bytes_per_minute:
          Float.round((after_memory - before_memory) * 60_000 / elapsed_ms, 2)
      }
    }
  end

  defp maybe_write_report(report, nil), do: {:ok, report}

  defp maybe_write_report(report, output) do
    case Reporter.write_json(report, output) do
      :ok -> {:ok, report}
      {:error, reason} -> {:error, reason}
    end
  end

  defp print_result({:ok, report}) do
    Mix.shell().info(
      "Fermix soak complete: batches=#{report.batches} processed=#{report.messages_processed} " <>
        "throughput=#{report.throughput_messages_per_second}/s"
    )
  end

  defp print_result({:error, reason}), do: Mix.raise("soak benchmark failed: #{inspect(reason)}")

  defp raise_on_invalid_options([]), do: :ok
  defp raise_on_invalid_options(invalid), do: Mix.raise("invalid options: #{inspect(invalid)}")

  defp project_path(nil), do: nil

  defp project_path(path) do
    case Path.type(path) do
      :absolute -> path
      _relative -> Path.join(project_root(), path)
    end
  end

  defp project_root do
    Mix.Project.project_file() |> Path.dirname()
  end
end
