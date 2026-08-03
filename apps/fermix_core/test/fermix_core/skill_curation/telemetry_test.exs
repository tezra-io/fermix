defmodule FermixCore.SkillCuration.TelemetryTest do
  # async: false — attaches global telemetry handlers.
  use ExUnit.Case, async: false

  alias FermixCore.SkillCuration.Telemetry, as: SkillCurationTelemetry

  @events [
    [:fermix, :skill_curation, :run_start],
    [:fermix, :skill_curation, :run_complete],
    [:fermix, :skill_curation, :run_error],
    [:fermix, :skill_curation, :proposal_actioned]
  ]

  setup do
    handler = "skill-curation-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:sc_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{
      meta: %{
        session_id: "skill_curation:abc",
        stage: :cycle,
        trigger: :scheduled,
        parent_session: nil
      }
    }
  end

  test "run_start carries the session identity and compacts nil parent", %{meta: meta} do
    SkillCurationTelemetry.run_start(meta)

    assert_receive {:sc_event, [:fermix, :skill_curation, :run_start], _meas, metadata}
    assert metadata.agent == "skill_curation"
    assert metadata.session_id == "skill_curation:abc"
    assert metadata.stage == :cycle
    assert metadata.trigger == :scheduled
    refute Map.has_key?(metadata, :parent_session)
  end

  test "a manual run passes the originating command session through" do
    SkillCurationTelemetry.run_start(%{
      session_id: "skill_curation:abc",
      stage: :cycle,
      trigger: :manual,
      parent_session: "command:skills:telegram:c1"
    })

    assert_receive {:sc_event, [:fermix, :skill_curation, :run_start], _meas, metadata}
    assert metadata.parent_session == "command:skills:telegram:c1"
  end

  test "run_complete carries counts only", %{meta: meta} do
    SkillCurationTelemetry.run_complete(meta, %{
      messages_scanned: 12,
      candidates: 2,
      proposals_new: 1,
      delivery_status: :delivered
    })

    assert_receive {:sc_event, [:fermix, :skill_curation, :run_complete], %{count: 1}, metadata}
    assert metadata.status == "ok"
    assert metadata.messages_scanned == 12
    assert metadata.proposals_new == 1
    assert metadata.delivery_status == :delivered
  end

  test "run_error names the reason kind", %{meta: meta} do
    SkillCurationTelemetry.run_error(meta, :parse, :missing_cycle_summary)

    assert_receive {:sc_event, [:fermix, :skill_curation, :run_error], %{count: 1}, metadata}
    assert metadata.status == "error"
    assert metadata.reason_kind == :parse
    assert metadata.error == ":missing_cycle_summary"
  end

  test "proposal_actioned is a point event with action, kind, and age" do
    SkillCurationTelemetry.proposal_actioned("approve", "new_skill", 86_400_000)

    assert_receive {:sc_event, [:fermix, :skill_curation, :proposal_actioned], measurements,
                    metadata}

    assert measurements.age_ms == 86_400_000
    assert metadata.action == "approve"
    assert metadata.kind == "new_skill"
  end

  test "every skill_curation event is registered for the JSONL trace stream" do
    registered = Enum.map(SkillCurationTelemetry.trace_event_definitions(), & &1.event)
    assert Enum.sort(registered) == Enum.sort(@events)

    assert Enum.all?(
             SkillCurationTelemetry.trace_event_definitions(),
             &(&1.trace_type == :agent_event and &1.agent_field == :agent)
           )
  end
end
