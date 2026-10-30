defmodule FermixCore.Cues.TelemetryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Telemetry

  setup do
    FermixTestSupport.TelemetryCapture.attach(
      [[:fermix, :cue, :lifecycle], [:fermix, :cue, :source]],
      :emitter
    )

    :ok
  end

  # The phase surface is pinned, not inferred: adding a phase is a deliberate
  # edit that also updates `@cue_phases` in
  # apps/fermix_opik/test/fermix_opik/aggregation_test.exs.
  test "every phase of design §14 is allowed, plus the counted ones, the two error phases and a follow-up's" do
    assert Enum.sort(Telemetry.phases()) ==
             Enum.sort(~w(accepted duplicate conflict stale rejected rate_limited over_budget
                          routed gap expired unmatched overflow write_failed passed dropped
                          filter_retry filter_held filter_failed claimed settled retry exhausted
                          proposed confirmed denied proposal_expired proposal_refused
                          ingest_error sweep_error follow_up_triggered follow_up_decided
                          follow_up_expired follow_up_refused follow_up_started
                          follow_up_approval_asked follow_up_approval_decided
                          follow_up_approval_expired)a)
  end

  test "an automatic follow-up's approval prompt traces sessionless, by its id" do
    ids = %{proposal_id: "cfa_a", watcher_id: "cwt_a", state: "waiting"}

    for phase <- ~w(follow_up_approval_asked follow_up_approval_decided
                    follow_up_approval_expired)a do
      assert :ok = Telemetry.lifecycle(phase, %{}, ids)

      assert_raise ArgumentError, ~r/sessionless/, fn ->
        Telemetry.lifecycle(phase, %{}, Map.put(ids, :session_id, "cron_j_1"))
      end
    end
  end

  test "a follow-up's trigger phases are sessionless and its start needs the run's session" do
    ids = %{trigger_id: "cft_a", watcher_id: "cwt_a", delivery_id: 7, cue_id: 3, job_id: "j"}

    assert :ok = Telemetry.lifecycle(:follow_up_triggered, %{}, Map.put(ids, :state, "waiting"))

    assert_raise ArgumentError, ~r/sessionless/, fn ->
      Telemetry.lifecycle(:follow_up_refused, %{}, Map.put(ids, :session_id, "cron_j_1"))
    end

    assert_raise ArgumentError, ~r/needs the run's :session_id/, fn ->
      Telemetry.lifecycle(:follow_up_started, %{}, ids)
    end

    assert :ok =
             Telemetry.lifecycle(:follow_up_started, %{}, Map.put(ids, :session_id, "cron_j_1"))
  end

  test "a counted phase carries its count and the source or watcher, and no session" do
    Telemetry.lifecycle(:unmatched, %{count: 41}, %{source_ref: "bsky-news"})
    Telemetry.lifecycle(:dropped, %{count: 3}, %{watcher_id: "cwt_a"})

    assert_receive {:telemetry, [:fermix, :cue, :lifecycle], %{count: 41},
                    %{phase: :unmatched, source_ref: "bsky-news"}}

    assert_receive {:telemetry, [:fermix, :cue, :lifecycle], %{count: 3},
                    %{phase: :dropped, watcher_id: "cwt_a"}}

    assert_raise ArgumentError, ~r/sessionless/, fn ->
      Telemetry.lifecycle(:overflow, %{count: 1}, %{watcher_id: "cwt_a", session_id: "s"})
    end
  end

  test "a lifecycle event carries ids, counts, the phase and the component" do
    Telemetry.lifecycle(:routed, %{}, %{
      source_ref: "eng-blogs",
      cue_id: 7,
      delivery_id: 9,
      watcher_id: "cwt_a"
    })

    assert_receive {:telemetry, [:fermix, :cue, :lifecycle], %{count: 1}, metadata}

    assert metadata == %{
             phase: :routed,
             component: "cues",
             source_ref: "eng-blogs",
             cue_id: 7,
             delivery_id: 9,
             watcher_id: "cwt_a"
           }
  end

  test "measurements are the allowed non-negative integers" do
    Telemetry.lifecycle(:accepted, %{count: 1, accept_ms: 12}, %{source_ref: "s"})
    assert_receive {:telemetry, _event, %{count: 1, accept_ms: 12}, _metadata}

    assert_raise ArgumentError, fn -> Telemetry.lifecycle(:accepted, %{bytes: 3}, %{}) end
    assert_raise ArgumentError, fn -> Telemetry.lifecycle(:accepted, %{accept_ms: -1}, %{}) end
  end

  test "an unknown phase or metadata key raises" do
    assert_raise ArgumentError, ~r/phase/, fn -> Telemetry.lifecycle(:vanished, %{}, %{}) end

    assert_raise ArgumentError, ~r/payload/, fn ->
      Telemetry.lifecycle(:accepted, %{}, %{payload: "the owner's text"})
    end
  end

  test "sessionless phases refuse a session id; run and proposal phases need one" do
    assert_raise ArgumentError, fn ->
      Telemetry.lifecycle(:accepted, %{}, %{session_id: "cue_filter_x"})
    end

    assert_raise ArgumentError, fn -> Telemetry.lifecycle(:claimed, %{}, %{delivery_id: 1}) end
    assert_raise ArgumentError, fn -> Telemetry.lifecycle(:proposed, %{}, %{proposal_id: "p"}) end

    Telemetry.lifecycle(:claimed, %{queue_ms: 40}, %{delivery_id: 1, session_id: "job_run_1"})

    assert_receive {:telemetry, _event, %{queue_ms: 40},
                    %{phase: :claimed, session_id: "job_run_1"}}

    Telemetry.lifecycle(:passed, %{}, %{delivery_id: 1, reason: "no filter"})
    assert_receive {:telemetry, _event, _m, %{phase: :passed, reason: "no filter"}}
  end

  test "an error result keeps only its derived class" do
    Telemetry.lifecycle(:ingest_error, %{}, %{
      source_ref: "s",
      result: {:error, {:sqlite, "disk full at /x"}}
    })

    assert_receive {:telemetry, _event, _m, metadata}
    assert metadata.result == :error
    assert metadata.error_class == "sqlite"
    refute inspect(metadata) =~ "disk full"
  end

  test "a source event names its source and phase" do
    Telemetry.source(:reconnect, %{source_ref: "bsky-devs", attempt: 2, status: "reconnecting"})

    assert_receive {:telemetry, [:fermix, :cue, :source], %{count: 1}, metadata}
    assert metadata.phase == :reconnect
    assert metadata.source_ref == "bsky-devs"
    assert metadata.attempt == 2

    assert_raise ArgumentError, fn -> Telemetry.source(:reconnect, %{attempt: 1}) end
    assert_raise ArgumentError, fn -> Telemetry.source(:teleport, %{source_ref: "s"}) end
  end

  test "both events are registered for the JSONL trace" do
    assert Enum.map(Telemetry.trace_event_definitions(), & &1.event) == [
             [:fermix, :cue, :lifecycle],
             [:fermix, :cue, :source]
           ]
  end
end
