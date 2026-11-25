defmodule FermixCore.Jobs.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Jobs.Telemetry, as: JobTelemetry

  setup do
    events = [
      [:fermix, :job, :run_start],
      [:fermix, :job, :run_complete],
      [:fermix, :job, :run_error],
      [:fermix, :job, :heal]
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
    # No max duration passed → key dropped (exporter falls back to the idle TTL).
    refute Map.has_key?(metadata, :max_duration_ms)
  end

  test "a cue run's bookends carry its watcher and delivery", %{job: job, run: run} do
    cue_run = Map.merge(run, %{trigger: "cue", cue_delivery_id: 42, watcher_id: "cwt_abc"})

    JobTelemetry.run_start(job, cue_run, %{prompt_snapshot: "Report it"})
    JobTelemetry.run_complete(job, cue_run, %{response: "[SILENT]"})
    JobTelemetry.run_error(job, cue_run, "error", "boom")

    for event <- [:run_start, :run_complete, :run_error] do
      assert_receive {:job_event, [:fermix, :job, ^event], _measurements, metadata}
      assert metadata.trigger == "cue"
      assert metadata.delivery_id == 42
      assert metadata.watcher_id == "cwt_abc"
      refute Map.has_key?(metadata, :cue_count)
    end
  end

  test "a run with no cue carries neither key", %{job: job, run: run} do
    JobTelemetry.run_start(job, Map.put(run, :cue_delivery_id, nil), %{prompt_snapshot: "x"})

    assert_receive {:job_event, [:fermix, :job, :run_start], _measurements, metadata}
    refute Map.has_key?(metadata, :delivery_id)
    refute Map.has_key?(metadata, :watcher_id)
  end

  test "run_start carries the run max duration for the exporter sweep bound", %{
    job: job,
    run: run
  } do
    JobTelemetry.run_start(job, run, %{prompt_snapshot: "Summarize today"}, 1_800_000)

    assert_receive {:job_event, [:fermix, :job, :run_start], _measurements, metadata}
    assert metadata.max_duration_ms == 1_800_000
  end

  test "run_complete reports duration and status", %{job: job, run: run} do
    JobTelemetry.run_complete(job, run, %{
      response: "done",
      iterations: 3,
      total_tokens: 250,
      tool_failures: 2
    })

    assert_receive {:job_event, [:fermix, :job, :run_complete], measurements, metadata}
    assert measurements.duration_ms == 5_000
    assert measurements.iterations == 3
    assert measurements.total_tokens == 250
    assert measurements.tool_failures == 2
    assert metadata.status == "ok"
  end

  test "run_complete counts zero tool failures when the result carries none", %{
    job: job,
    run: run
  } do
    JobTelemetry.run_complete(job, run, %{response: "done"})

    assert_receive {:job_event, [:fermix, :job, :run_complete], measurements, _metadata}
    assert measurements.tool_failures == 0
  end

  test "run_error captures status and error", %{job: job, run: run} do
    JobTelemetry.run_error(job, run, "timeout", "loop exceeded")

    assert_receive {:job_event, [:fermix, :job, :run_error], %{count: 1}, metadata}
    assert metadata.status == "timeout"
    assert metadata.error == "loop exceeded"
    refute Map.has_key?(metadata, :retry_disposition)
  end

  # M106 §5.3: a scheduled run's failure says whether it runs again.
  test "run_error carries a scheduled run's retry", %{job: job, run: run} do
    retry = %{disposition: :retry, attempts: 2, retry_at: ~U[2026-11-20 07:02:50.000000Z]}
    JobTelemetry.run_error(job, run, "error", "rate limited", retry)

    assert_receive {:job_event, [:fermix, :job, :run_error], %{count: 1}, metadata}
    assert metadata.retry_disposition == "retry"
    assert metadata.retry_attempts == 2
    assert metadata.retry_at == "2026-11-20T07:02:50.000000Z"

    JobTelemetry.run_error(job, run, "error", "auth", %{
      disposition: :none,
      attempts: 0,
      retry_at: nil
    })

    assert_receive {:job_event, [:fermix, :job, :run_error], %{count: 1}, none}
    assert {none.retry_disposition, none.retry_attempts} == {"none", 0}
    refute Map.has_key?(none, :retry_at)
  end

  # M106 §5.4: what a heal made of a failure rides on its run_error, and each
  # phase of the heal is one event of its own with the heal's id.
  test "run_error names the heal that took a failure, or says none did", %{job: job, run: run} do
    retry = %{disposition: :none, attempts: 0, retry_at: nil}

    JobTelemetry.run_error(
      job,
      run,
      "timeout",
      "wall-clock",
      Map.put(retry, :heal, {:opened, "jhl_1"})
    )

    assert_receive {:job_event, [:fermix, :job, :run_error], _measurements, opened}
    assert {opened.heal, opened.heal_id} == {"opened", "jhl_1"}

    JobTelemetry.run_error(job, run, "error", "auth", Map.put(retry, :heal, :out_of_scope))
    assert_receive {:job_event, [:fermix, :job, :run_error], _measurements, guest}
    assert guest.heal == "out_of_scope"
    refute Map.has_key?(guest, :heal_id)
  end

  test "heal_settled emits the heal a settle opened or joined, and each it closed", %{
    job: job,
    run: run
  } do
    run = Map.put(run, :failure_kind, "time_limit")

    JobTelemetry.heal_settled(job, run, %{
      heal: {:joined, "jhl_2"},
      healed: [],
      failure_kind: "time_limit",
      subject_kind: "job",
      subject_id: "job-7"
    })

    assert_receive {:job_event, [:fermix, :job, :heal], %{count: 1}, joined}

    assert %{phase: "joined", heal_id: "jhl_2", job_id: "job-7", run_id: "run_abc"} = joined
    assert %{failure_kind: "time_limit", subject_kind: "job", subject_id: "job-7"} = joined
    assert joined.agent == "scheduled:job-7"

    # An ok run that never got a plugin's tool to work (M106 §6): the kind and
    # the subject are the heal's, read from the settlement, never the run row's.
    ok_run = Map.put(run, :failure_kind, nil)

    JobTelemetry.heal_settled(job, ok_run, %{
      heal: {:opened, "jhl_6"},
      healed: [],
      failure_kind: "tool_never_succeeded",
      subject_kind: "plugin",
      subject_id: "harbour_id"
    })

    assert_receive {:job_event, [:fermix, :job, :heal], _measurements, opened}

    assert %{
             phase: "opened",
             heal_id: "jhl_6",
             failure_kind: "tool_never_succeeded",
             subject_kind: "plugin",
             subject_id: "harbour_id"
           } = opened

    JobTelemetry.heal_settled(job, run, %{heal: :none, healed: ["jhl_3", "jhl_4"]})

    for id <- ["jhl_3", "jhl_4"] do
      assert_receive {:job_event, [:fermix, :job, :heal], _measurements,
                      %{phase: "closed", heal_id: ^id, outcome: "healed"}}
    end

    JobTelemetry.heal_settled(job, run, %{heal: :quiet, healed: []})
    refute_received {:job_event, [:fermix, :job, :heal], _measurements, _metadata}
  end

  test "a heal's delivery failure carries its bounded error and no job when it has none" do
    JobTelemetry.heal("delivery_failed", %{
      heal_id: "jhl_5",
      subject_kind: "provider",
      subject_id: "openai",
      attempts: 3,
      dead_letter: true,
      error: String.duplicate("x", 900)
    })

    assert_receive {:job_event, [:fermix, :job, :heal], _measurements, failed}
    assert %{phase: "delivery_failed", agent: "job_heal", dead_letter: true, attempts: 3} = failed
    assert String.length(failed.error) == 500
    refute Map.has_key?(failed, :job_id)
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
