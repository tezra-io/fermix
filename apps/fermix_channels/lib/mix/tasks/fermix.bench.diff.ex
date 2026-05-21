defmodule Mix.Tasks.Fermix.Bench.Diff do
  @moduledoc """
  Compare two Fermix benchmark JSON reports.
  """

  use Mix.Task

  alias FermixCore.Bench.Reporter

  @shortdoc "Compare Fermix benchmark reports"

  @impl true
  def run(argv) do
    Mix.Task.run("loadpaths")

    case argv do
      [old_path, new_path] -> compare!(project_path(old_path), project_path(new_path))
      _other -> Mix.raise("usage: mix fermix.bench.diff OLD.json NEW.json")
    end
  end

  defp compare!(old_path, new_path) do
    case Reporter.compare_files(old_path, new_path) do
      {:ok, diff} ->
        print_diff(diff)
        if diff.status == :fail, do: Mix.raise("benchmark regression detected")

      {:error, reason} ->
        Mix.raise("benchmark diff failed: #{inspect(reason)}")
    end
  end

  defp print_diff(diff) do
    Mix.shell().info("Status: #{diff.status}")
    Mix.shell().info(summary_line(diff.summary))

    diff.rows
    |> Enum.sort_by(fn row -> {row.scenario, row.stage} end)
    |> Enum.each(fn row ->
      Mix.shell().info(
        "#{row.scenario}/#{row.stage}: #{row.old_p95_us}us -> #{row.new_p95_us}us #{row.status}"
      )
    end)
  end

  defp summary_line(summary) do
    "#{summary.regressions} regressions, #{summary.warnings} warnings across #{summary.measurements} measurements"
  end

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
