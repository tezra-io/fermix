defmodule Mix.Tasks.Fermix.Bench do
  @moduledoc """
  Run deterministic Fermix latency benchmarks.
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
    compare_path = opts |> Keyword.get(:compare) |> project_path()

    opts
    |> runner_opts()
    |> Runner.run()
    |> print_result(compare_path)
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

  defp print_result({:error, reason}, _compare_path) do
    Mix.raise("benchmark failed: #{inspect(reason)}")
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
      "superseded=#{scenario.messages_superseded} throughput=#{scenario.throughput_messages_per_second}/s"
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
        "  #{row.scenario}/#{row.stage}: #{row.old_p95_us}us -> #{row.new_p95_us}us #{row.status}"
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
