defmodule Mix.Tasks.Fermix.Bench do
  @moduledoc """
  Run deterministic Fermix latency benchmarks.

  Captures per-stage p50/p95/p99 for each scenario and writes a JSON report.

      mix fermix.bench --list                                # show scenarios
      mix fermix.bench --output bench/before.json            # capture a baseline
      mix fermix.bench --runs 5 --output bench/after.json    # stable gating capture
      mix fermix.bench.diff bench/before.json bench/after.json

  For a trustworthy regression gate pass `--runs N`: the report is the
  median-merge of N back-to-back runs, which collapses the run-to-run variance a
  single run shows on the parallel-contention scenarios. The gate
  (`mix fermix.bench.diff`) compares the p50 median with absolute floors, so
  microsecond jitter never reads as a regression.
  """

  use Mix.Task

  alias FermixChannels.Bench.Runner
  alias FermixCore.Bench.Reporter

  @shortdoc "Run Fermix latency benchmarks"

  @switches [
    scenarios: :string,
    samples: :integer,
    warmup: :integer,
    output: :string,
    compare: :string,
    runs: :integer,
    list: :boolean
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    raise_on_invalid_options(invalid)

    if Keyword.get(opts, :list, false) do
      print_scenarios()
    else
      run_bench(opts)
    end
  end

  defp run_bench(opts) do
    runs = max(Keyword.get(opts, :runs, 1), 1)
    compare_path = opts |> Keyword.get(:compare) |> project_path()
    output = opts |> Keyword.get(:output, "bench/current.json") |> project_path()

    # Capture each pass WITHOUT writing (output: nil returns the report instead of
    # persisting), median-merge, then write the aggregate once with the real
    # output path threaded back so `--compare` and the summary find it.
    base_opts = opts |> runner_opts() |> Keyword.put(:output, nil)

    case capture_runs(base_opts, runs) do
      {:ok, reports} ->
        report = reports |> Reporter.aggregate() |> put_output(output)
        Reporter.write_json(report, output)
        print_result({:ok, report}, compare_path)

      {:error, reason} ->
        Mix.raise("benchmark failed: #{inspect(reason)}")
    end
  end

  defp capture_runs(base_opts, runs) do
    Enum.reduce_while(1..runs, {:ok, []}, fn _i, {:ok, acc} ->
      case Runner.run(base_opts) do
        {:ok, report} -> {:cont, {:ok, [report | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_output(report, output) do
    Map.update(report, :config, %{output: output}, &Map.put(&1, :output, output))
  end

  defp runner_opts(opts) do
    []
    |> maybe_put(:scenarios, parse_scenarios(Keyword.get(opts, :scenarios)))
    |> maybe_put(:samples, Keyword.get(opts, :samples))
    |> maybe_put(:warmup, Keyword.get(opts, :warmup))
    |> maybe_put(:output, opts |> Keyword.get(:output, "bench/current.json") |> project_path())
  end

  defp parse_scenarios(nil), do: nil

  defp parse_scenarios(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp print_result({:ok, report}, nil) do
    print_summary(report)
  end

  defp print_result({:ok, report}, compare_path) when is_binary(compare_path) do
    print_summary(report)
    output = get_in(report, [:config, :output]) || "bench/current.json"

    case Reporter.compare_files(compare_path, output) do
      {:ok, diff} -> print_diff(diff)
      {:error, reason} -> Mix.raise("benchmark compare failed: #{inspect(reason)}")
    end
  end

  defp print_summary(report) do
    Mix.shell().info("Fermix benchmark complete")
    Mix.shell().info("git: #{report.git_sha}")

    Enum.each(report.scenarios, fn {name, scenario} ->
      Mix.shell().info(scenario_line(name, scenario))
      print_stage_summary(scenario.stages)
    end)
  end

  defp scenario_line(name, scenario) do
    "#{name}: dispatched=#{scenario.messages_dispatched} processed=#{scenario.messages_processed} " <>
      "throughput=#{scenario.throughput_messages_per_second}/s"
  end

  defp print_stage_summary(stages) do
    stage_order = Runner.stage_order()

    stages
    |> Enum.sort_by(fn {stage, _stats} -> stage_index(stage, stage_order) end)
    |> Enum.each(fn {stage, stats} ->
      Mix.shell().info(
        "  #{stage}: p50=#{stats.p50_us}us p95=#{stats.p95_us}us p99=#{stats.p99_us}us"
      )
    end)
  end

  defp stage_index(stage, stage_order) do
    Enum.find_index(stage_order, &(&1 == stage)) || length(stage_order)
  end

  defp print_diff(diff) do
    Mix.shell().info("compare status: #{diff.status}")
    Mix.shell().info(summary_line(diff.summary))

    diff.rows
    |> Enum.sort_by(fn row -> {row.scenario, row.stage} end)
    |> Enum.each(fn row ->
      Mix.shell().info(
        "  #{row.scenario}/#{row.stage}: p50 #{row.old_p50_us}us -> #{row.new_p50_us}us #{row.status}"
      )
    end)

    if diff.status == :fail, do: Mix.raise("benchmark regression detected")
  end

  defp summary_line(summary) do
    "#{summary.regressions} regressions, #{summary.warnings} warnings across #{summary.measurements} measurements"
  end

  defp print_scenarios do
    Mix.shell().info("Available benchmark scenarios:")
    Enum.each(Runner.list_scenarios(), &Mix.shell().info("  #{&1}"))
  end

  defp raise_on_invalid_options([]), do: :ok
  defp raise_on_invalid_options(invalid), do: Mix.raise("invalid options: #{inspect(invalid)}")

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp project_path(nil), do: nil

  defp project_path(path) when is_binary(path) do
    case Path.type(path) do
      :absolute -> path
      _relative -> Path.join(project_root(), path)
    end
  end

  defp project_root do
    Mix.Project.project_file() |> Path.dirname()
  end
end
