defmodule FermixCore.Jobs.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 2]

  alias FermixCore.Jobs.Telemetry, as: JobTelemetry

  # What a line must never carry: words someone else wrote, the look's note,
  # a proposed change's values. Each fact below holds one of these. The ones
  # with no space pass the token check unchanged, so a builder that said such
  # a fact at all would show it.
  @outside_words [
    "Harbourview feed",
    "Quayside said",
    "Kestrel note",
    "Marlow Lane 14",
    "HarbourviewFeed",
    "QuaysideSaid",
    "KestrelNote",
    "MarlowLane14"
  ]

  @heal_phases ~w(opened joined verdict decided rerun delivered delivery_failed closed answered)
  @heal_keys ~w(heal_id job_id run_id subject_kind subject_id failure_kind outcome attempts
                dead_letter platform conclusion decision requested refusal read_outside
                rerun_outcome answer applied error)a
  @look_keys ~w(heal_id job_id run_id session_id parent_session agent failure_kind decision
                status duration_ms error)a
  # Values no caller sends today, which a line must still survive.
  @odd_values [nil, :odd, 42, -3, 4.2, true, %{"x" => 1}, ["x"], {:x, 1}, "", "x\ny"]
  # What a key may hold when every key is drawn on its own: the odd values,
  # and the ones that pick a builder's clauses.
  @mixed_values @odd_values ++
                  [
                    false,
                    2,
                    "job",
                    "provider",
                    "job-7",
                    "started",
                    "running",
                    "verdict",
                    "healed",
                    "still_failing",
                    "none",
                    "tell",
                    "apply",
                    "timeout",
                    "error",
                    "x\nERROR fake"
                  ]
  # The most bytes of one value a line says (`Jobs.Telemetry`'s bound).
  @token_max 512

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

  # The engine log's line for each step of a heal: a pure builder over the
  # facts the trace row carries, giving the line with its level.
  describe "heal_line/2" do
    test "says each step of a heal at its level, with its ids and Fermix's own words" do
      for {phase, facts, said} <- heal_steps() do
        assert JobTelemetry.heal_line(phase, facts) == said, "phase #{phase}"
      end

      assert heal_steps() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(@heal_phases)
    end

    test "a verdict's message is said as the verdict" do
      facts = Map.merge(heal_run_facts("jhl_51"), %{conclusion: "verdict", platform: "slack"})

      assert JobTelemetry.heal_line("delivered", facts) ==
               {:info, "Job heal jhl_51: its verdict was delivered (job job-7, platform slack)"}

      failed = Map.merge(facts, %{attempts: 3, dead_letter: false})

      assert JobTelemetry.heal_line("delivery_failed", failed) ==
               {:warning,
                "Job heal jhl_51: its verdict could not be sent on attempt 3, which was not " <>
                  "the last (job job-7, platform slack)"}
    end

    # An ok run's close carries only its own job and run, which for a
    # provider's or a plugin's heal is whichever job's run proved it: the line
    # names that run as the one that closed it, never as the heal's own job.
    test "a heal an ok run closed names the run that closed it" do
      healed = %{heal_id: "jhl_62", job_id: "job-9", run_id: "run_pqr", outcome: "healed"}

      assert JobTelemetry.heal_line("closed", healed) ==
               {:info, "Job heal jhl_62: closed as healed: job job-9 run run_pqr ended ok"}

      assert JobTelemetry.heal_line("closed", Map.delete(healed, :job_id)) ==
               {:info, "Job heal jhl_62: closed as healed: run run_pqr ended ok"}
    end

    # Ids Fermix makes: a heal id, a run id, a job id (its name's slug and a
    # counter, no length limit) and a look's session (its job id and 28 bytes).
    test "says every id Fermix made whole, however long the job's id" do
      for job_id <- [long_job_id(50), long_job_id(120)] do
        facts = %{
          heal_id: "jhl_5f1c0a9e7b3d2468",
          job_id: job_id,
          run_id: "run_Qx7-Lm2_Zp0",
          failure_kind: "time_limit",
          subject_kind: "job",
          subject_id: job_id
        }

        assert JobTelemetry.heal_line("opened", facts) ==
                 {:info,
                  "Job heal jhl_5f1c0a9e7b3d2468: opened (job #{job_id}, run run_Qx7-Lm2_Zp0, " <>
                    "failure time_limit)"}
      end
    end

    test "a value past the bound is cut in its middle, keeping its head and its tail" do
      head = String.duplicate("h", 400)
      tail = String.duplicate("t", 400)

      {:info, line} =
        JobTelemetry.heal_line("opened", %{heal_id: "jhl_63", job_id: head <> tail})

      assert "Job heal jhl_63: opened (job " <> said = line
      said = String.trim_trailing(said, ")")
      assert byte_size(said) <= @token_max
      assert String.starts_with?(said, String.duplicate("h", 200))
      assert String.ends_with?(said, String.duplicate("t", 200))
      assert said =~ "..."
    end

    test "is nil for a step its caller already logs with more said" do
      facts = heal_run_facts("jhl_52")

      for outcome <- ["running", "refused", "unanswered"] do
        refute JobTelemetry.heal_line("rerun", Map.put(facts, :rerun_outcome, outcome)), outcome
      end

      # A dead letter, and a message that never reached a send (no attempt
      # counted), each have their warning where they happen.
      dead = Map.merge(facts, %{attempts: 20, dead_letter: true})
      refute JobTelemetry.heal_line("delivery_failed", dead)
      refute JobTelemetry.heal_line("delivery_failed", Map.put(facts, :dead_letter, false))

      # A refused or redirected decision: `HealRun`'s warning says what was
      # asked and what Fermix carries out instead.
      for {asked, carried, refusal} <- [
            {"raise_limit", "tell", "not_upward"},
            {"raise_limit", "propose", "past_ceiling"}
          ] do
        refused = Map.merge(facts, %{decision: carried, requested: asked, refusal: refusal})
        refute JobTelemetry.heal_line("decided", refused), refusal
      end
    end

    test "a step whose fact is missing still says the step and the ids it has" do
      bare = %{heal_id: "jhl_56", job_id: "job-7"}

      assert JobTelemetry.heal_line("decided", bare) ==
               {:info, "Job heal jhl_56: its decision was recorded (job job-7)"}

      assert JobTelemetry.heal_line("closed", bare) ==
               {:info, "Job heal jhl_56: closed (job job-7)"}

      assert JobTelemetry.heal_line("answered", bare) ==
               {:info, "Job heal jhl_56: the owner answered (job job-7)"}

      assert JobTelemetry.heal_line("rerun", bare) ==
               {:info, "Job heal jhl_56: its rerun was asked for (job job-7)"}

      assert JobTelemetry.heal_line("delivery_failed", bare) ==
               {:warning, "Job heal jhl_56: its message could not be sent (job job-7)"}

      assert JobTelemetry.heal_line("opened", %{}) == {:info, "Job heal ?: opened"}
    end

    test "is total: bare facts and odd values give a line or nil, never a raise" do
      for phase <- @heal_phases, facts <- odd_facts(@heal_keys) ++ mixed_facts(@heal_keys) do
        said = JobTelemetry.heal_line(phase, facts)
        assert_said(said)
        if said, do: assert_safe(said)
      end
    end

    test "makes every value one safe token: no fact forges a line or carries outside words" do
      for {phase, facts, _said} <- heal_steps(), forged <- forged_facts(@heal_keys) do
        said = JobTelemetry.heal_line(phase, Map.merge(facts, forged))
        assert said, "phase #{phase} said nothing for #{inspect(forged)}"
        assert_safe(said)
      end

      {:info, line} =
        JobTelemetry.heal_line("opened", %{heal_id: "jhl_58", subject_id: "x\nERROR fake"})

      assert line == "Job heal jhl_58: opened"

      {:info, line} =
        JobTelemetry.heal_line("opened", %{
          heal_id: "jhl_58",
          subject_kind: "provider",
          subject_id: "x\nERROR fake"
        })

      assert line == "Job heal jhl_58: opened (subject provider x?ERROR?fake)"
    end
  end

  # What became of a failed scheduled run, in one line (M106 §5.3, §5.4).
  describe "run_line/3" do
    test "says a quiet retry being set, and its quiet retries used up", %{job: job, run: run} do
      run = Map.put(run, :failure_kind, "provider_rate_limit")

      assert JobTelemetry.run_line(job, run, retry(2, ~U[2026-11-20 07:02:50.123456Z])) ==
               {:info,
                "Scheduled job job-7 run run_abc failed (provider_rate_limit); quiet retry 2 " <>
                  "runs at 2026-11-20T07:02:50Z"}

      # A time in another zone is said in UTC, to the second.
      lisbon = %DateTime{
        year: 2026,
        month: 7,
        day: 20,
        hour: 8,
        minute: 2,
        second: 50,
        microsecond: {250_000, 6},
        time_zone: "Europe/Lisbon",
        zone_abbr: "WEST",
        utc_offset: 0,
        std_offset: 3600
      }

      assert {:info, summer} = JobTelemetry.run_line(job, run, retry(1, lisbon))
      assert summer =~ "; quiet retry 1 runs at 2026-07-20T07:02:50Z"

      assert JobTelemetry.run_line(job, run, retry(1, nil)) ==
               {:info,
                "Scheduled job job-7 run run_abc failed (provider_rate_limit); quiet retry 1 " <>
                  "is the job's next run"}

      reaped = Map.put(run, :failure_kind, "reaped")
      exhausted = Map.put(exhausted(4), :heal, {:opened, "jhl_9"})

      assert JobTelemetry.run_line(job, reaped, exhausted) ==
               {:warning,
                "Scheduled job job-7 run run_abc failed (reaped); its quiet retries are used up " <>
                  "after 4 failed runs in a row"}
    end

    test "says a failure no heal tells the owner of, with its retries in the same one line", %{
      job: job,
      run: run
    } do
      run = Map.put(run, :failure_kind, "provider_unavailable")

      quiet = %{
        heal: :quiet,
        failure_kind: "provider_unavailable",
        subject_kind: "provider",
        subject_id: "openai"
      }

      assert JobTelemetry.run_line(job, run, Map.merge(none(), quiet)) ==
               {:info,
                "Scheduled job job-7 run run_abc failed (provider_unavailable); the owner is not " <>
                  "told: a heal for the same failure closed lately (subject provider openai)"}

      assert JobTelemetry.run_line(job, run, Map.merge(exhausted(4), quiet)) ==
               {:warning,
                "Scheduled job job-7 run run_abc failed (provider_unavailable); its quiet " <>
                  "retries are used up after 4 failed runs in a row; the owner is not told: a " <>
                  "heal for the same failure closed lately (subject provider openai)"}

      # The job's own heal is said as the job, once.
      own = %{quiet | subject_kind: "job", subject_id: "job-7"}

      assert JobTelemetry.run_line(job, run, Map.merge(none(), own)) ==
               {:info,
                "Scheduled job job-7 run run_abc failed (provider_unavailable); the owner is not " <>
                  "told: a heal for the same failure closed lately"}

      assert JobTelemetry.run_line(job, run, Map.put(none(), :heal, :out_of_scope)) ==
               {:info,
                "Scheduled job job-7 run run_abc failed (provider_unavailable); no heal opens: " <>
                  "the job was not set up by the owner"}
    end

    test "says no kind when the run carries none", %{job: job, run: run} do
      assert JobTelemetry.run_line(job, run, retry(3, nil)) ==
               {:info,
                "Scheduled job job-7 run run_abc failed; quiet retry 3 is the job's next run"}
    end

    # M106 §6: a run that ended ok while a tool never once worked is taken as a
    # failure is, and can be kept quiet too; it is said as what it was.
    test "says a run that ended ok without working, kept quiet", %{job: job, run: run} do
      ok = Map.merge(run, %{status: "ok", failure_kind: nil})

      quiet =
        Map.merge(none(), %{
          heal: :quiet,
          failure_kind: "tool_never_succeeded",
          subject_kind: "plugin",
          subject_id: "harbour_id"
        })

      assert JobTelemetry.run_line(job, ok, quiet) ==
               {:info,
                "Scheduled job job-7 run run_abc ended ok without working " <>
                  "(tool_never_succeeded); the owner is not told: a heal for the same failure " <>
                  "closed lately (subject plugin harbour_id)"}

      refute JobTelemetry.run_line(job, ok, Map.merge(none(), %{heal: :none, healed: []}))
    end

    test "is nil for a failure a heal took, whose own line follows, and with no settlement", %{
      job: job,
      run: run
    } do
      for heal <- [{:opened, "jhl_9"}, {:joined, "jhl_9"}, {:verdict, "jhl_9"}] do
        refute JobTelemetry.run_line(job, run, Map.put(none(), :heal, heal))
      end

      refute JobTelemetry.run_line(job, run, nil)
    end

    test "is total over every disposition, with a bare run and odd values", %{job: job} do
      for job <- [job, %{}, %{id: :odd}],
          run <- [%{}, %{id: "run_bare"}, %{id: 42, failure_kind: :time_limit}],
          settlement <- odd_settlements() do
        assert_said(JobTelemetry.run_line(job, run, settlement))
      end

      assert JobTelemetry.run_line(%{}, %{}, retry(2, nil)) ==
               {:info, "Scheduled job ? run ? failed; quiet retry 2 is the job's next run"}
    end

    test "makes every value one safe token and never carries the run's error or reply", %{
      run: run
    } do
      run =
        Map.merge(run, %{
          id: "run_x\nERROR forged",
          failure_kind: "provider\r\nunavailable",
          error: Enum.at(@outside_words, 0),
          final_response: Enum.at(@outside_words, 1)
        })

      settlement =
        Map.merge(exhausted(4), %{
          heal: :quiet,
          subject_kind: "provider",
          subject_id: "open\u2028ai\e[31m",
          failure_text: Enum.at(@outside_words, 2)
        })

      said = JobTelemetry.run_line(%{id: String.duplicate("z", 300)}, run, settlement)
      assert said
      assert_safe(said)
    end
  end

  # Fermix's look at a failed job (M106 §5.5): its start with its session, its end.
  describe "look_line/2" do
    test "says a look's start with its session, and its end with how it ended and took" do
      look = look_facts("jhl_60")

      assert JobTelemetry.look_line(:start, look) ==
               {:info,
                "Job heal jhl_60: its look started (job job-7, run run_abc, session " <>
                  "heal_job-7_20261120_070250_a1b2c3)"}

      assert JobTelemetry.look_line(
               :complete,
               Map.merge(look, %{decision: "none", duration_ms: 8123})
             ) ==
               {:info,
                "Job heal jhl_60: its look finished in 8123 ms (job job-7, session " <>
                  "heal_job-7_20261120_070250_a1b2c3)"}

      timed_out = Map.merge(look, %{status: "timeout", duration_ms: 120_000, error: "watchdog"})

      assert JobTelemetry.look_line(:error, timed_out) ==
               {:warning,
                "Job heal jhl_60: its look ran out of time after 120000 ms (job job-7, session " <>
                  "heal_job-7_20261120_070250_a1b2c3)"}
    end

    test "says the look's session, job and run whole, however long the job's id" do
      for job_id <- [long_job_id(50), long_job_id(120)] do
        session = "heal_#{job_id}_20261120_070250_a1b2c3"
        look = %{look_facts("jhl_64") | job_id: job_id, session_id: session}

        assert JobTelemetry.look_line(:start, look) ==
                 {:info,
                  "Job heal jhl_64: its look started (job #{job_id}, run run_abc, session " <>
                    "#{session})"}

        assert JobTelemetry.look_line(:complete, Map.put(look, :duration_ms, 8123)) ==
                 {:info,
                  "Job heal jhl_64: its look finished in 8123 ms (job #{job_id}, session " <>
                    "#{session})"}

        timed_out = Map.merge(look, %{status: "timeout", duration_ms: 120_000})

        assert JobTelemetry.look_line(:error, timed_out) ==
                 {:warning,
                  "Job heal jhl_64: its look ran out of time after 120000 ms (job #{job_id}, " <>
                    "session #{session})"}
      end
    end

    test "is nil for a look that failed, which its caller already warns of" do
      failed = Map.merge(look_facts("jhl_61"), %{status: "error", duration_ms: 40})
      refute JobTelemetry.look_line(:error, failed)
    end

    test "is total over bare facts and odd values, and makes each value a safe token" do
      for stage <- [:start, :complete, :error],
          facts <- odd_facts(@look_keys) ++ mixed_facts(@look_keys) ++ forged_facts(@look_keys) do
        said = JobTelemetry.look_line(stage, facts)
        assert_said(said)
        if said, do: assert_safe(said)
      end

      assert JobTelemetry.look_line(:start, %{}) == {:info, "Job heal ?: its look started"}
      assert JobTelemetry.look_line(:complete, %{}) == {:info, "Job heal ?: its look finished"}
      assert JobTelemetry.look_line(:error, %{}) == {:warning, "Job heal ?: its look ended"}
    end
  end

  # The test env's level is :warning (config/test.exs); these raise it to
  # :info for the module's own run and put it back.
  describe "the engine log" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "each step is one line at its level", %{job: job, run: run} do
      heal_id = "jhl_#{System.unique_integer([:positive])}"
      run = Map.merge(run, %{id: "run_#{heal_id}", failure_kind: "provider_rate_limit"})
      failed = %{job_id: "job-7", run_id: run.id, subject_kind: "job", subject_id: "job-7"}
      look = heal_run(heal_id)

      log =
        capture_log([level: :info], fn ->
          JobTelemetry.heal(
            "opened",
            Map.merge(failed, %{
              heal_id: heal_id,
              failure_kind: "time_limit",
              error: Enum.at(@outside_words, 0)
            })
          )

          JobTelemetry.heal_run_start(look, 120_000)
          JobTelemetry.heal_run_error(look, "timeout", 120_000, Enum.at(@outside_words, 1))

          JobTelemetry.heal(
            "verdict",
            Map.merge(failed, %{heal_id: heal_id, failure_kind: "tool_never_succeeded"})
          )

          JobTelemetry.run_error(
            job,
            run,
            "error",
            Enum.at(@outside_words, 2),
            retry(2, ~U[2026-11-20 07:02:50.000000Z])
          )
        end)

      assert [opened, started, timed_out, verdict, retried] =
               log |> String.split("\n") |> Enum.filter(&(&1 =~ run.id or &1 =~ heal_id))

      assert opened =~ "[info] Job heal #{heal_id}: opened (job job-7, run #{run.id}, failure"
      assert started =~ "[info] Job heal #{heal_id}: its look started (job job-7, run #{run.id}"
      assert started =~ "session #{look.session_id})"

      assert timed_out =~
               "[warning] Job heal #{heal_id}: its look ran out of time after 120000 ms"

      assert verdict =~ "[warning] Job heal #{heal_id}: a run it watched did not work either"

      assert retried =~
               "[info] Scheduled job job-7 run #{run.id} failed (provider_rate_limit); quiet " <>
                 "retry 2 runs at 2026-11-20T07:02:50Z"

      for words <- @outside_words, do: refute(log =~ words)
    end

    test "a step its caller logs, a refused decision and a failure a heal took add no line", %{
      job: job,
      run: run
    } do
      heal_id = "jhl_#{System.unique_integer([:positive])}"
      run = Map.put(run, :id, "run_#{heal_id}")

      log =
        capture_log([level: :info], fn ->
          JobTelemetry.heal("delivery_failed", %{
            heal_id: heal_id,
            attempts: 20,
            dead_letter: true,
            error: :no_delivery_target
          })

          JobTelemetry.heal("rerun", %{
            heal_id: heal_id,
            rerun_outcome: "refused",
            error: :expired
          })

          JobTelemetry.heal("decided", %{
            heal_id: heal_id,
            decision: "tell",
            requested: "raise_limit",
            refusal: "not_upward"
          })

          JobTelemetry.heal_run_error(heal_run(heal_id), "error", 40, :provider_down)

          JobTelemetry.run_error(
            job,
            run,
            "error",
            "auth",
            Map.put(none(), :heal, {:opened, heal_id})
          )
        end)

      refute log =~ heal_id
      refute log =~ run.id
    end

    # A failed run's line comes with its `run_error`; an ok run has none, so
    # its settle says the one an ok run kept quiet gets.
    test "an ok run kept quiet is one line from its settle, a failed run's none", %{
      job: job,
      run: run
    } do
      ok = Map.merge(run, %{id: "run_ok_#{System.unique_integer([:positive])}", status: "ok"})
      failed = %{ok | id: "run_failed_#{System.unique_integer([:positive])}", status: "error"}

      quiet = %{
        heal: :quiet,
        healed: [],
        failure_kind: "tool_never_succeeded",
        subject_kind: "plugin",
        subject_id: "harbour_id"
      }

      log =
        capture_log([level: :info], fn ->
          JobTelemetry.heal_settled(job, ok, quiet)
          JobTelemetry.heal_settled(job, failed, quiet)
        end)

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ ok.id))
      assert line =~ "[info] Scheduled job job-7 run #{ok.id} ended ok without working"
      refute log =~ failed.id
    end
  end

  # A line or nil, and a line is a string at a level the log writes.
  defp assert_said(nil), do: :ok

  defp assert_said(said) do
    assert {level, line} = said
    assert level in [:info, :warning]
    assert is_binary(line)
  end

  # One line of printable ASCII, every value a bounded token, and none of the
  # words someone else wrote.
  defp assert_safe({_level, line}) do
    assert String.printable?(line)
    refute line =~ ~r/[\x00-\x1f\x7f]/
    refute line =~ ~r/[^\x20-\x7e]/
    refute line =~ String.duplicate("z", @token_max + 1)

    # A value is at most the bound (a token may hold a colon, so splitting on
    # it only shortens what is measured).
    for word <- String.split(line, [" ", ",", "(", ")", ";", ":"]),
        do: assert(byte_size(word) <= @token_max, "#{word} is longer than one token")

    for words <- @outside_words, do: refute(line =~ words)
  end

  # Bare facts, and every key holding each odd value in turn.
  defp odd_facts(keys) do
    [%{}, %{heal_id: "jhl_57"}] ++
      for value <- @odd_values, do: Map.new(keys, &{&1, value})
  end

  # Every key drawn on its own from `@mixed_values`, so the values that pick
  # one clause meet odd ones in the others; seeded, so a failure repeats.
  defp mixed_facts(keys) do
    :rand.seed(:exsss, {106, 5, 4})
    for _sample <- 1..1500, do: Map.new(keys, &{&1, Enum.random(@mixed_values)})
  end

  # A job id as Fermix makes one: its name's slug, an underscore and a
  # counter, about `bytes` long.
  defp long_job_id(bytes) do
    slug =
      "harbour_tide_table_for_the_north_quay_berths_and_the_ferry_slipway_" <>
        "on_the_west_breakwater_checked_each_morning_before_the_first_sailing"

    String.slice(slug, 0, bytes - 6) <> "_k3x9q"
  end

  # Every key a line may say holds a forged line break, a control character,
  # a separator or an overlong value; every key it never says holds words
  # someone else wrote, with spaces and without (which the token check would
  # pass unchanged, so a line that said one would show it).
  defp forged_facts(keys) do
    spaced = outside_facts(Enum.slice(@outside_words, 0, 4))
    outside = outside_facts(Enum.slice(@outside_words, 4, 4))

    forged =
      for value <- [
            "x\nERROR fake",
            "x\r\n[error] forged",
            "tele\u2028gram\e[31m",
            "x\ty\u0000",
            String.duplicate("z", 300),
            String.duplicate("z", 2000)
          ] do
        keys
        |> Map.new(&{&1, value})
        |> Map.drop([:refusal, :requested, :error, :dead_letter, :attempts, :applied])
        |> Map.merge(outside)
      end

    [spaced, outside | forged]
  end

  # The facts a line never says: a failure's words, the look's note, a
  # change's values, what the look asked and why a check refused it.
  defp outside_facts([words, said, note, value]) do
    %{
      error: words,
      failure_words: said,
      failure_text: said,
      note: note,
      change: %{"prompt" => %{"from" => "x", "to" => value}},
      requested: value,
      refusal_detail: value
    }
  end

  defp odd_settlements do
    shapes =
      for disposition <- [:none, :retry, :exhausted, :odd, "retry", nil],
          attempts <- [nil, 2, :x, "2", %{}],
          retry_at <- [nil, ~U[2026-11-20 07:02:50Z], "2026", 5],
          heal <- [:quiet, :out_of_scope, {:opened, 1}, :odd, nil, %{}] do
        %{
          disposition: disposition,
          attempts: attempts,
          retry_at: retry_at,
          heal: heal,
          subject_kind: :odd,
          subject_id: 7
        }
      end

    [nil, %{}, :odd, "settled" | shapes]
  end

  defp retry(attempts, retry_at),
    do: %{disposition: :retry, attempts: attempts, retry_at: retry_at, heal: :none, healed: []}

  defp exhausted(attempts), do: %{disposition: :exhausted, attempts: attempts, retry_at: nil}
  defp none, do: %{disposition: :none, attempts: 0, retry_at: nil}

  # What a look's bookends carry (`HealDiagnosis`'s correlation).
  defp look_facts(heal_id) do
    %{
      heal_id: heal_id,
      job_id: "job-7",
      run_id: "run_abc",
      session_id: "heal_job-7_20261120_070250_a1b2c3",
      parent_session: "cron_job-7_20261120",
      agent: "job_heal:job-7",
      failure_kind: "time_limit"
    }
  end

  defp heal_run(heal_id) do
    %{
      look_facts(heal_id)
      | run_id: "run_#{heal_id}",
        session_id: "heal_job-7_20261120_070250_#{heal_id}"
    }
  end

  # One heal's every step, as its caller traces it, and its line. A job's
  # heal is placed by its job once; a provider's or a plugin's by its subject.
  defp heal_steps do
    [
      {"opened",
       %{
         heal_id: "jhl_41",
         job_id: "job-7",
         run_id: "run_abc",
         failure_kind: "time_limit",
         subject_kind: "job",
         subject_id: "job-7"
       }, {:info, "Job heal jhl_41: opened (job job-7, run run_abc, failure time_limit)"}},
      {"joined",
       %{
         heal_id: "jhl_42",
         job_id: "job-9",
         run_id: "run_def",
         failure_kind: "tool_never_succeeded",
         subject_kind: "plugin",
         subject_id: "harbour_id"
       },
       {:info,
        "Job heal jhl_42: joined by a later run (job job-9, run run_def, failure " <>
          "tool_never_succeeded, subject plugin harbour_id)"}},
      {"verdict",
       %{
         heal_id: "jhl_43",
         job_id: "job-7",
         run_id: "run_ghi",
         failure_kind: "tool_never_succeeded",
         subject_kind: "job",
         subject_id: "job-7"
       },
       {:warning,
        "Job heal jhl_43: a run it watched did not work either; its next message says the job " <>
          "still fails (job job-7, run run_ghi, failure tool_never_succeeded)"}},
      {"decided",
       Map.merge(heal_run_facts("jhl_44"), %{
         decision: "pause",
         requested: "pause",
         refusal: nil,
         read_outside: true
       }), {:info, "Job heal jhl_44: its decision is pause (job job-7)"}},
      {"decided", Map.merge(heal_run_facts("jhl_59"), %{decision: "none", refusal: nil}),
       {:info, "Job heal jhl_59: its look gave no decision (job job-7)"}},
      {"rerun",
       Map.merge(heal_run_facts("jhl_45"), %{rerun_outcome: "started", run_id: "run_jkl"}),
       {:info, "Job heal jhl_45: its rerun started (job job-7, run run_jkl)"}},
      {"delivered", Map.put(heal_run_facts("jhl_46"), :platform, "telegram"),
       {:info, "Job heal jhl_46: its message was delivered (job job-7, platform telegram)"}},
      {"delivered", Map.merge(provider_facts("jhl_55"), %{platform: "telegram"}),
       {:info,
        "Job heal jhl_55: its message was delivered (subject provider openai, platform " <>
          "telegram)"}},
      {"delivery_failed", Map.merge(heal_run_facts("jhl_47"), %{attempts: 2, dead_letter: false}),
       {:warning,
        "Job heal jhl_47: its message could not be sent on attempt 2, which was not the last " <>
          "(job job-7)"}},
      {"closed", %{heal_id: "jhl_48", job_id: "job-7", run_id: "run_mno", outcome: "healed"},
       {:info, "Job heal jhl_48: closed as healed: job job-7 run run_mno ended ok"}},
      {"closed", Map.merge(heal_run_facts("jhl_49"), %{outcome: "still_failing"}),
       {:warning, "Job heal jhl_49: closed as still_failing (job job-7)"}},
      {"closed", Map.put(provider_facts("jhl_54"), :outcome, "expired"),
       {:info, "Job heal jhl_54: closed as expired (subject provider openai)"}},
      {"answered",
       %{
         heal_id: "jhl_50",
         job_id: "job-7",
         decision: "propose",
         answer: "apply",
         applied: true,
         platform: "companion"
       },
       {:info,
        "Job heal jhl_50: the owner answered apply; the change was applied (job job-7, " <>
          "platform companion)"}},
      {"answered",
       %{
         heal_id: "jhl_53",
         job_id: "job-7",
         decision: "propose",
         answer: "leave",
         applied: false,
         platform: "telegram"
       },
       {:info,
        "Job heal jhl_53: the owner answered leave; the change was not applied (job job-7, " <>
          "platform telegram)"}}
    ]
  end

  # A provider's heal: no job of its own (the Scheduler's expiry and
  # `HealRun`'s traces pass the heal's nil `job_id`).
  defp provider_facts(heal_id) do
    %{
      heal_id: heal_id,
      job_id: nil,
      subject_kind: "provider",
      subject_id: "openai",
      failure_kind: "provider_quota"
    }
  end

  # What every trace a heal run writes carries (`HealRun`'s `trace/3`).
  defp heal_run_facts(heal_id) do
    %{
      heal_id: heal_id,
      job_id: "job-7",
      subject_kind: "job",
      subject_id: "job-7",
      failure_kind: "time_limit",
      conclusion: "first"
    }
  end
end
