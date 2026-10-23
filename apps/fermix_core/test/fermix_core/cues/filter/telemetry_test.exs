defmodule FermixCore.Cues.Filter.TelemetryTest do
  # The trace handler binds a VM-global telemetry handler, so this module runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Filter.Telemetry, as: FilterTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.TelemetryCapture

  @events [
    [:fermix, :cue_filter, :run_start],
    [:fermix, :cue_filter, :run_complete],
    [:fermix, :cue_filter, :run_error]
  ]

  defp run(watcher_id) do
    %{
      session_id: FilterTelemetry.session_id(watcher_id, ~U[2026-10-17 09:05:03Z]),
      call_id: "cfc_#{watcher_id}",
      watcher_id: watcher_id,
      delivery_id: 17,
      cue_id: 9,
      source_ref: "eng-feeds",
      attempt: 1,
      provider: "openai",
      model: nil
    }
  end

  test "a session id names the run kind, the watcher, the time and a random suffix" do
    id = FilterTelemetry.session_id("cwt_ab12", ~U[2026-10-17 09:05:03Z])
    assert id =~ ~r/^cue_filter_cwt_ab12_20261017_090503_[0-9a-f]{6}$/
    assert String.starts_with?(id, FilterTelemetry.session_prefix())
    refute id == FilterTelemetry.session_id("cwt_ab12", ~U[2026-10-17 09:05:03Z])
  end

  test "the bookends carry ids, the decision or the failure's kind, and nothing else" do
    watcher = "cwt_#{System.unique_integer([:positive])}"
    TelemetryCapture.attach(@events, watcher_id: watcher)
    run = run(watcher)

    FilterTelemetry.run_start(run)
    FilterTelemetry.run_complete(run, :pass, 120)
    FilterTelemetry.run_error(run, :provider_failure, :rate_limit, 80)

    assert_receive {:telemetry, [:fermix, :cue_filter, :run_start], %{count: 1}, start}
    assert start.agent == "cue_filter"
    assert start.session_id == run.session_id
    assert start.filter_call_id == run.call_id
    assert {start.delivery_id, start.cue_id, start.attempt} == {17, 9, 1}
    refute Map.has_key?(start, :model)

    assert_receive {:telemetry, [:fermix, :cue_filter, :run_complete], %{duration_ms: 120},
                    %{status: "ok", decision: "pass"}}

    assert_receive {:telemetry, [:fermix, :cue_filter, :run_error], %{duration_ms: 80},
                    %{status: "provider_failure", error_kind: "rate_limit"}}
  end

  test "an unknown status or decision is refused" do
    run = run("cwt_x")
    assert_raise FunctionClauseError, fn -> FilterTelemetry.run_complete(run, :maybe, 1) end
    assert_raise FunctionClauseError, fn -> FilterTelemetry.run_error(run, :odd, :kind, 1) end
  end

  test "the bookends reach the JSONL trace stream as agent events" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "fermix_cue_filter_trace_#{System.unique_integer([:positive])}"
      )

    server = :"cue_filter_trace_#{System.unique_integer([:positive])}"
    prefix = "cue-filter-test-#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: dir, name: server})
    TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    watcher = "cwt_trace#{System.unique_integer([:positive])}"
    run = run(watcher)
    FilterTelemetry.run_start(run)
    FilterTelemetry.run_complete(run, :drop, 40)
    :sys.get_state(server)

    rows =
      [dir, Date.utc_today() |> Date.to_iso8601(), "agent_event.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["watcher_id"] == watcher))

    assert Enum.map(rows, & &1["event"]) == ["cue_filter_run_start", "cue_filter_run_complete"]
    assert Enum.all?(rows, &(&1["agent"] == "cue_filter"))
    assert Enum.all?(rows, &(&1["session_id"] == run.session_id))
  end
end
