defmodule FermixCore.Jobs.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Jobs.Telemetry, as: JobTelemetry

  setup do
    events = [
      [:fermix, :job, :run_start],
      [:fermix, :job, :run_complete],
      [:fermix, :job, :run_error]
    ]

    handler = "job-tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:job_event, event, measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])

    # Establish the production default (content capture off) as the baseline so
    # the run_start "no :input" assertion never inherits a capture_content = true
    # left in app env by another async:false module. Tests that need capture on
    # set it explicitly.
    Application.put_env(:fermix_core, :telemetry, capture_content: false)

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    job = %{id: "job-7", name: "Daily digest", schedule_kind: "cron", schedule_expr: "0 9 * * *"}

    run = %{
      id: "run_abc",
      session_id: "cron_job-7_20260602",
      trigger: "schedule",
      started_at: ~U[2026-06-02 09:00:00Z],
      completed_at: ~U[2026-06-02 09:00:05Z]
    }

    %{job: job, run: run}
  end

  test "run_start carries job/run correlation ids", %{job: job, run: run} do
    JobTelemetry.run_start(job, run, %{prompt_snapshot: "Summarize today"})

    assert_receive {:job_event, [:fermix, :job, :run_start], _measurements, metadata}
    assert metadata.agent == "scheduled:job-7"
    assert metadata.job_id == "job-7"
    assert metadata.run_id == "run_abc"
    assert metadata.session_id == "cron_job-7_20260602"
    assert metadata.trigger == "schedule"
    refute Map.has_key?(metadata, :input)
  end

  test "run_complete reports duration and status", %{job: job, run: run} do
    JobTelemetry.run_complete(job, run, %{response: "done", iterations: 3, total_tokens: 250})

    assert_receive {:job_event, [:fermix, :job, :run_complete], measurements, metadata}
    assert measurements.duration_ms == 5_000
    assert measurements.iterations == 3
    assert measurements.total_tokens == 250
    assert metadata.status == "ok"
  end

  test "run_error captures status and error", %{job: job, run: run} do
    JobTelemetry.run_error(job, run, "timeout", "loop exceeded")

    assert_receive {:job_event, [:fermix, :job, :run_error], %{count: 1}, metadata}
    assert metadata.status == "timeout"
    assert metadata.error == "loop exceeded"
  end

  test "content is attached only when capture is enabled", %{job: job, run: run} do
    Application.put_env(:fermix_core, :telemetry, capture_content: true)

    JobTelemetry.run_start(job, run, %{prompt_snapshot: "Summarize today"})
    assert_receive {:job_event, [:fermix, :job, :run_start], _m, start_meta}
    assert start_meta.input == "Summarize today"

    JobTelemetry.run_complete(job, run, %{response: "the digest"})
    assert_receive {:job_event, [:fermix, :job, :run_complete], _m2, complete_meta}
    assert complete_meta.output == "the digest"
  end
end
