defmodule FermixCore.Bench.Reporter do
  @moduledoc """
  JSON reporting and median (p50) regression comparison for Fermix benchmarks.

  The gate compares the **p50 (median)** of each stage, not p95. The median over
  the hundreds–thousands of samples each scenario collects is stable run-to-run,
  whereas the p95 tail is dominated by OS-scheduling / cache jitter and would
  flag a "regression" even between two runs of the *identical* binary.

  Two absolute floors suppress the residual microsecond noise, applied before any
  ratio test:

    * `min_significant_us` — a stage whose new median is below this is faster than
      the timer resolves reliably run-to-run; never a regression.
    * `min_delta_us` — an absolute median move smaller than this is within
      measurement noise; never a regression (a 1µs→2µs swing is +100% but
      meaningless).

  A genuine code regression shifts the whole distribution, so its median clears
  both floors and the ratio thresholds catch it. Defaults are tuned so that
  comparing a report against itself (or a fresh capture of the same commit)
  reports `:ok`.
  """

  # Parallel-contention / throughput scenarios measure chaotic queueing latency
  # that swings several-fold between runs even median-merged (`--runs N`). They
  # are informational trend data, not a pass/fail latency gate: their rows are
  # reported with an `:info` status and never flip the overall result.
  @informational_scenarios ~w(shared_fifo_contention shared_multi_conv_throughput)

  @default_warn_ratio 0.20
  @default_fail_ratio 0.50
  # Below this median a stage is past the timer's reliable run-to-run resolution
  # — including the parallel-contention scenarios whose fast stages jitter several
  # µs between runs. The gate effectively watches the stages heavy enough to move
  # real turn latency (the ~100µs dispatcher/history stages), not the sub-20µs ones.
  @default_min_significant_us 20
  # A median move smaller than this (µs) is within measurement noise.
  @default_min_delta_us 10

  @spec write_json(map(), String.t()) :: :ok | {:error, term()}
  def write_json(report, path) when is_map(report) and is_binary(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok -> File.write(path, Jason.encode_to_iodata!(report, pretty: true))
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Median-merge several full benchmark reports captured back-to-back into one.

  Each stage statistic (p50/p95/p99/max) becomes the median of that field across
  the runs, so run-to-run variance — especially the parallel-contention scenarios
  whose medians swing several-fold between single runs — collapses to a stable
  central value the gate can trust. The first report supplies the non-statistical
  fields (git sha, timestamp, scenario shape). A single-element list is returned
  unchanged.
  """
  @spec aggregate([map()]) :: map()
  def aggregate([report]), do: report

  def aggregate([first | _] = reports) when is_list(reports) do
    scenarios =
      first
      |> Map.fetch!(:scenarios)
      |> Map.new(fn {name, scenario} ->
        stages =
          scenario
          |> Map.fetch!(:stages)
          |> Map.new(fn {stage, _stats} ->
            {stage, median_stage_stats(reports, name, stage)}
          end)

        {name, Map.put(scenario, :stages, stages)}
      end)

    first
    |> Map.put(:scenarios, scenarios)
    |> update_in([:config], fn config -> Map.put(config || %{}, :runs, length(reports)) end)
  end

  defp median_stage_stats(reports, name, stage) do
    stats_list =
      reports
      |> Enum.map(&get_in(&1, [:scenarios, name, :stages, stage]))
      |> Enum.reject(&is_nil/1)

    template = hd(stats_list)

    Map.new(template, fn {key, value} ->
      values = stats_list |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1)
      {key, if(values == [], do: value, else: median(values))}
    end)
  end

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, mid)
    else
      round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2)
    end
  end

  @spec compare_files(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare_files(old_path, new_path, opts \\ []) do
    with {:ok, old} <- read_json(old_path),
         {:ok, new} <- read_json(new_path) do
      {:ok, compare(old, new, opts)}
    end
  end

  @spec compare(map(), map(), keyword()) :: map()
  def compare(old, new, opts \\ []) when is_map(old) and is_map(new) do
    thresholds = thresholds(opts)
    rows = comparison_rows(old, new, thresholds)

    %{
      status: comparison_status(rows),
      summary: comparison_summary(rows),
      rows: rows,
      regressions: Enum.filter(rows, &(&1.status == :fail)),
      warnings: Enum.filter(rows, &(&1.status == :warn))
    }
  end

  defp thresholds(opts) do
    %{
      warn_ratio: Keyword.get(opts, :warn_ratio, @default_warn_ratio),
      fail_ratio: Keyword.get(opts, :fail_ratio, @default_fail_ratio),
      min_significant_us: Keyword.get(opts, :min_significant_us, @default_min_significant_us),
      min_delta_us: Keyword.get(opts, :min_delta_us, @default_min_delta_us)
    }
  end

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    end
  end

  defp comparison_rows(old, new, thresholds) do
    for {scenario, old_scenario} <- Map.get(old, "scenarios", %{}),
        {stage, old_stats} <- Map.get(old_scenario, "stages", %{}),
        new_stats = get_in(new, ["scenarios", scenario, "stages", stage]),
        is_map(new_stats) do
      build_row(scenario, stage, old_stats, new_stats, thresholds)
    end
  end

  defp build_row(scenario, stage, old_stats, new_stats, thresholds) do
    old_p50 = p50(old_stats)
    new_p50 = p50(new_stats)
    delta_ratio = delta_ratio(old_p50, new_p50)

    %{
      scenario: scenario,
      stage: stage,
      old_p50_us: old_p50,
      new_p50_us: new_p50,
      # p95 is reported for visibility but never gated on (too noisy).
      old_p95_us: p95(old_stats),
      new_p95_us: p95(new_stats),
      delta_ratio: Float.round(delta_ratio, 4),
      status: stage_status(scenario, old_p50, new_p50, delta_ratio, thresholds)
    }
  end

  defp stage_status(scenario, old_us, new_us, delta_ratio, thresholds) do
    if scenario in @informational_scenarios do
      :info
    else
      row_status(old_us, new_us, delta_ratio, thresholds)
    end
  end

  defp p50(%{"p50_us" => value}) when is_number(value), do: value
  defp p50(%{p50_us: value}) when is_number(value), do: value

  defp p95(%{"p95_us" => value}) when is_number(value), do: value
  defp p95(%{p95_us: value}) when is_number(value), do: value

  defp delta_ratio(old, new) when old == 0, do: if(new > 0, do: 1.0, else: 0.0)
  defp delta_ratio(old, new), do: (new - old) / old

  # Absolute floors first: a sub-resolution median, or a sub-noise absolute move,
  # is never a regression no matter how large the ratio looks.
  defp row_status(old_us, new_us, delta_ratio, t) do
    cond do
      new_us < t.min_significant_us -> :ok
      abs(new_us - old_us) < t.min_delta_us -> :ok
      delta_ratio > t.fail_ratio -> :fail
      delta_ratio > t.warn_ratio -> :warn
      true -> :ok
    end
  end

  defp comparison_status(rows) do
    cond do
      Enum.any?(rows, &(&1.status == :fail)) -> :fail
      Enum.any?(rows, &(&1.status == :warn)) -> :warn
      true -> :ok
    end
  end

  defp comparison_summary(rows) do
    %{
      measurements: length(rows),
      regressions: Enum.count(rows, &(&1.status == :fail)),
      warnings: Enum.count(rows, &(&1.status == :warn))
    }
  end
end
