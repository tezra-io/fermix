defmodule FermixCore.Bench.ReporterTest do
  use ExUnit.Case, async: true

  alias FermixCore.Bench.Reporter

  test "writes JSON reports and compares p95 regressions" do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("bench-reporter")
    old_path = Path.join(dir, "old.json")
    new_path = Path.join(dir, "new.json")

    old = report_with_p95(100, 100)
    new = report_with_p95(180, 130)

    try do
      assert :ok = Reporter.write_json(old, old_path)
      assert :ok = Reporter.write_json(new, new_path)

      assert {:ok, diff} =
               Reporter.compare_files(old_path, new_path, warn_ratio: 0.2, fail_ratio: 0.5)

      assert diff.status == :fail
      assert diff.summary == %{measurements: 3, regressions: 1, warnings: 1}
      assert [%{scenario: "shared_text_minimal", stage: "provider_call"} = row] = diff.regressions
      assert row.delta_ratio == 0.8
      assert [%{stage: "prompt_context", status: :warn}] = diff.warnings
    after
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  defp report_with_p95(provider_p95, prompt_p95) do
    %{
      version: 1,
      scenarios: %{
        "shared_text_minimal" => %{
          stages: %{
            "agent_message" => stats(90),
            "prompt_context" => stats(prompt_p95),
            "provider_call" => stats(provider_p95)
          }
        }
      }
    }
  end

  defp stats(p95) do
    %{count: 10, p50_us: 80, p95_us: p95, p99_us: p95, max_us: p95}
  end
end
