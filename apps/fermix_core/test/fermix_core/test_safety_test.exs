defmodule FermixCore.TestSafetyTest do
  use ExUnit.Case, async: true

  test "tests do not call destructive file cleanup APIs directly" do
    offenders =
      test_files()
      |> Enum.flat_map(&direct_cleanup_calls/1)

    assert offenders == []
  end

  defp test_files do
    "apps/*/test/**/*_test.exs"
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "test_safety_test.exs"))
  end

  defp direct_cleanup_calls(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} -> direct_cleanup_call?(line) end)
    |> Enum.map(fn {_line, line_no} -> "#{path}:#{line_no}" end)
  end

  defp direct_cleanup_call?(line) do
    String.contains?(line, cleanup_prefixes())
  end

  defp cleanup_prefixes do
    file = "File."

    [
      file <> "rm(",
      file <> "rm!(",
      file <> "rm_rf(",
      file <> "rm_rf!(",
      "&" <> file <> "rm/1",
      "&" <> file <> "rm!/1",
      "&" <> file <> "rm_rf/1",
      "&" <> file <> "rm_rf!/1"
    ]
  end
end
