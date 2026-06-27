defmodule FermixCore.Bench.ReporterTest do
  use ExUnit.Case, async: true

  alias FermixCore.Bench.Reporter

  test "writes JSON reports and gates regressions on the p50 median" do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("bench-reporter")
    old_path = Path.join(dir, "old.json")
    new_path = Path.join(dir, "new.json")

    # Both stages are well above the absolute floors so the ratio gate applies:
    # provider_call +80% -> fail, prompt_context +30% -> warn.
    old = report(provider_p50: 100, prompt_p50: 100)
    new = report(provider_p50: 180, prompt_p50: 130)

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

  test "p95 jitter alone never trips the gate (gate is p50, not p95)" do
    # p50 identical, p95 doubled — the old p95 gate would fail; the p50 gate is :ok.
    old = report(provider_p50: 50, prompt_p50: 50, provider_p95: 60, prompt_p95: 60)
    new = report(provider_p50: 50, prompt_p50: 50, provider_p95: 200, prompt_p95: 200)

    diff = Reporter.compare(old, new)

    assert diff.status == :ok
    assert diff.summary.regressions == 0
    assert diff.summary.warnings == 0
  end

  test "microsecond noise below the absolute floors is never a regression" do
    # The false-positive class: a 1µs->2µs swing is +100% but meaningless
    # (below min_significant_us); a 7->11µs move is +57% but below min_delta_us.
    old = report(provider_p50: 1, prompt_p50: 7)
    new = report(provider_p50: 2, prompt_p50: 11)

    diff = Reporter.compare(old, new)

    assert diff.status == :ok
    assert Enum.all?(diff.rows, &(&1.status == :ok))
  end

  test "a real regression above the floors still fails" do
    old = report(provider_p50: 40, prompt_p50: 40)
    new = report(provider_p50: 90, prompt_p50: 40)

    diff = Reporter.compare(old, new)

    assert diff.status == :fail
    assert [%{stage: "provider_call", delta_ratio: 1.25}] = diff.regressions
  end

  test "informational (contention) scenarios never flip the gate" do
    old = %{
      "version" => 1,
      "scenarios" => %{
        "shared_fifo_contention" => %{"stages" => %{"agent_mailbox" => stats(100, 100)}}
      }
    }

    # A 10x "regression" on a contention scenario must still gate :ok (:info row).
    new =
      put_in(
        old,
        ["scenarios", "shared_fifo_contention", "stages", "agent_mailbox"],
        stats(1000, 1000)
      )

    diff = Reporter.compare(old, new)

    assert diff.status == :ok
    assert diff.summary == %{measurements: 1, regressions: 0, warnings: 0}
    assert [%{scenario: "shared_fifo_contention", status: :info}] = diff.rows
  end

  test "aggregate/1 median-merges per-stage stats across runs" do
    merged = Reporter.aggregate([run_report(10), run_report(30), run_report(20)])

    # median of [10, 30, 20] = 20
    assert get_in(merged, [:scenarios, "s", :stages, "stage", :p50_us]) == 20
    assert merged.config.runs == 3
  end

  test "aggregate/1 returns a single report unchanged" do
    only = run_report(10)
    assert Reporter.aggregate([only]) == only
  end

  # In-memory report shape with atom keys, as Runner.run returns it.
  defp run_report(p50) do
    %{
      version: 1,
      config: %{output: "x"},
      scenarios: %{
        "s" => %{
          messages_dispatched: 1,
          stages: %{"stage" => %{count: 1, p50_us: p50, p95_us: p50, p99_us: p50, max_us: p50}}
        }
      }
    }
  end

  defp report(opts) do
    provider_p50 = Keyword.fetch!(opts, :provider_p50)
    prompt_p50 = Keyword.fetch!(opts, :prompt_p50)
    provider_p95 = Keyword.get(opts, :provider_p95, provider_p50)
    prompt_p95 = Keyword.get(opts, :prompt_p95, prompt_p50)

    %{
      "version" => 1,
      "scenarios" => %{
        "shared_text_minimal" => %{
          "stages" => %{
            "agent_message" => stats(90, 90),
            "prompt_context" => stats(prompt_p50, prompt_p95),
            "provider_call" => stats(provider_p50, provider_p95)
          }
        }
      }
    }
  end

  defp stats(p50, p95) do
    %{"count" => 10, "p50_us" => p50, "p95_us" => p95, "p99_us" => p95, "max_us" => p95}
  end
end
