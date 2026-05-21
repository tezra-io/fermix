defmodule FermixCore.Bench.Reporter do
  @moduledoc """
  JSON reporting and p95 regression comparison for Fermix benchmarks.
  """

  @default_warn_ratio 0.20
  @default_fail_ratio 0.50

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

  @spec compare_files(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare_files(old_path, new_path, opts \\ []) do
    with {:ok, old} <- read_json(old_path),
         {:ok, new} <- read_json(new_path) do
      {:ok, compare(old, new, opts)}
    end
  end

  @spec compare(map(), map(), keyword()) :: map()
  def compare(old, new, opts \\ []) when is_map(old) and is_map(new) do
    warn_ratio = Keyword.get(opts, :warn_ratio, @default_warn_ratio)
    fail_ratio = Keyword.get(opts, :fail_ratio, @default_fail_ratio)
    rows = comparison_rows(old, new, warn_ratio, fail_ratio)

    %{
      status: comparison_status(rows),
      summary: comparison_summary(rows),
      rows: rows,
      regressions: Enum.filter(rows, &(&1.status == :fail)),
      warnings: Enum.filter(rows, &(&1.status == :warn))
    }
  end

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    end
  end

  defp comparison_rows(old, new, warn_ratio, fail_ratio) do
    for {scenario, old_scenario} <- Map.get(old, "scenarios", %{}),
        {stage, old_stats} <- Map.get(old_scenario, "stages", %{}),
        new_stats = get_in(new, ["scenarios", scenario, "stages", stage]),
        is_map(new_stats) do
      build_row(scenario, stage, old_stats, new_stats, warn_ratio, fail_ratio)
    end
  end

  defp build_row(scenario, stage, old_stats, new_stats, warn_ratio, fail_ratio) do
    old_p95 = p95(old_stats)
    new_p95 = p95(new_stats)
    delta_ratio = delta_ratio(old_p95, new_p95)

    %{
      scenario: scenario,
      stage: stage,
      old_p95_us: old_p95,
      new_p95_us: new_p95,
      delta_ratio: Float.round(delta_ratio, 4),
      status: row_status(delta_ratio, warn_ratio, fail_ratio)
    }
  end

  defp p95(%{"p95_us" => value}) when is_number(value), do: value
  defp p95(%{p95_us: value}) when is_number(value), do: value

  defp delta_ratio(0, 0), do: 0.0
  defp delta_ratio(0, _new), do: 1.0
  defp delta_ratio(old, new), do: (new - old) / old

  defp row_status(delta_ratio, _warn_ratio, fail_ratio) when delta_ratio > fail_ratio, do: :fail
  defp row_status(delta_ratio, warn_ratio, _fail_ratio) when delta_ratio > warn_ratio, do: :warn
  defp row_status(_delta_ratio, _warn_ratio, _fail_ratio), do: :ok

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
