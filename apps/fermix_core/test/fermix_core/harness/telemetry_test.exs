defmodule FermixCore.Harness.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Telemetry, as: HarnessTelemetry

  setup do
    events = [
      [:fermix, :harness, :run_start],
      [:fermix, :harness, :run_complete],
      [:fermix, :harness, :run_error],
      [:fermix, :harness, :progress]
    ]

    handler = "harness-tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:harness_event, event, measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])

    # Establish the production default (content capture off) as the baseline so
    # the "no :input/:output" assertions never inherit a capture_content = true
    # left in app env by another async:false module. Tests that need capture on
    # set it explicitly.
    Application.put_env(:fermix_core, :telemetry, capture_content: false)

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    run = %{
      id: "hr_abc123def456",
      vendor: "codex",
      rail: "local",
      status: "completed",
      reason: nil,
      exit_code: 0,
      usage: %{total_cost_usd: 0.02},
      origin_kind: "chat",
      origin_session_id: "main-1",
      started_at: ~U[2026-07-19 09:00:00Z],
      completed_at: ~U[2026-07-19 09:00:30Z]
    }

    %{run: run}
  end

  test "run_start carries the harness correlation ids and never a parent_session", %{run: run} do
    HarnessTelemetry.run_start(run, "implement the feature", 1_800_000)

    assert_receive {:harness_event, [:fermix, :harness, :run_start], _measurements, metadata}
    assert metadata.agent == "harness:codex"
    assert metadata.run_id == "hr_abc123def456"
    assert metadata.session_id == "harness_hr_abc123def456"
    assert metadata.vendor == "codex"
    assert metadata.rail == "local"
    assert metadata.origin_kind == "chat"
    # The spawning turn is correlation metadata only, never a nesting parent.
    assert metadata.origin_session_id == "main-1"
    refute Map.has_key?(metadata, :parent_session)
    assert metadata.max_duration_ms == 1_800_000
    # Content capture is off in the baseline → the prompt is not attached.
    refute Map.has_key?(metadata, :input)
  end

  test "run_start drops the sweep bound when no max duration is given", %{run: run} do
    HarnessTelemetry.run_start(run)

    assert_receive {:harness_event, [:fermix, :harness, :run_start], _measurements, metadata}
    # No max duration → key dropped (the exporter falls back to the idle TTL).
    refute Map.has_key?(metadata, :max_duration_ms)
  end

  test "run_complete carries status/exit_code/usage and the run duration", %{run: run} do
    HarnessTelemetry.run_complete(run)

    assert_receive {:harness_event, [:fermix, :harness, :run_complete], measurements, metadata}
    assert metadata.status == "completed"
    assert metadata.exit_code == 0
    assert metadata.usage == %{total_cost_usd: 0.02}
    assert measurements.duration_ms == 30_000
    # nil reason is dropped, output is not captured in the baseline.
    refute Map.has_key?(metadata, :reason)
    refute Map.has_key?(metadata, :output)
  end

  test "run_error carries the terminal error class and reason", %{run: run} do
    failed = %{run | status: "failed", reason: "exit_1", exit_code: 1}

    HarnessTelemetry.run_error(failed, "protocol")

    assert_receive {:harness_event, [:fermix, :harness, :run_error], %{count: 1} = measurements,
                    metadata}

    assert metadata.status == "failed"
    assert metadata.reason == "exit_1"
    assert metadata.error == "protocol"
    assert measurements.duration_ms == 30_000
  end

  test "progress carries the phase label and event/framing counters", %{run: run} do
    HarnessTelemetry.progress(run, %{phase: "running", events: 8, framing_errors: 0})

    assert_receive {:harness_event, [:fermix, :harness, :progress], measurements, metadata}
    assert metadata.phase == "running"
    assert metadata.session_id == "harness_hr_abc123def456"
    assert measurements.events == 8
    assert measurements.framing_errors == 0
  end

  test "prompt and response are attached only when content capture is enabled", %{run: run} do
    Application.put_env(:fermix_core, :telemetry, capture_content: true)

    HarnessTelemetry.run_start(run, "the full brief")
    assert_receive {:harness_event, [:fermix, :harness, :run_start], _m, start_meta}
    assert start_meta.input == "the full brief"

    HarnessTelemetry.run_complete(run, "the run summary")
    assert_receive {:harness_event, [:fermix, :harness, :run_complete], _m2, complete_meta}
    assert complete_meta.output == "the run summary"
  end

  test "a run without a binary :id fails loud" do
    assert_raise ArgumentError, ~r/binary :id/, fn ->
      HarnessTelemetry.run_start(%{vendor: "codex"})
    end
  end
end
