defmodule FermixCore.Agents.LifecycleTelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.LifecycleTelemetry

  @all_events [
    [:fermix, :agent, :start],
    [:fermix, :agent, :stop],
    [:fermix, :agent, :task_start],
    [:fermix, :agent, :task_complete],
    [:fermix, :skill, :invoke],
    [:fermix, :skill, :journal_write],
    [:fermix, :supervisor, :spawn],
    [:fermix, :supervisor, :exit]
  ]

  @trace_events [
    {[:fermix, :agent, :start], "agent_start", :agent_event, :name},
    {[:fermix, :agent, :stop], "agent_stop", :agent_event, :name},
    {[:fermix, :agent, :task_start], "agent_task_start", :agent_event, :name},
    {[:fermix, :agent, :task_complete], "agent_task_complete", :agent_event, :name},
    {[:fermix, :skill, :invoke], "skill_invoke", :agent_event, :skill},
    {[:fermix, :skill, :journal_write], "skill_journal_write", :agent_event, :skill}
  ]

  setup do
    test_pid = self()
    handler_prefix = "lifecycle-contract-#{System.unique_integer([:positive])}"

    Enum.each(@all_events, fn event ->
      :telemetry.attach(
        "#{handler_prefix}-#{Enum.join(event, "-")}",
        event,
        fn emitted_event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, emitted_event, measurements, metadata})
        end,
        nil
      )
    end)

    on_exit(fn ->
      Enum.each(@all_events, fn event ->
        :telemetry.detach("#{handler_prefix}-#{Enum.join(event, "-")}")
      end)
    end)

    :ok
  end

  test "pins the traced lifecycle event mapping" do
    assert Enum.map(LifecycleTelemetry.trace_event_definitions(), fn definition ->
             {definition.event, definition.trace_event, definition.trace_type,
              definition.agent_field}
           end) == @trace_events

    Enum.each(@trace_events, fn {event, trace_event, _trace_type, _agent_field} ->
      assert LifecycleTelemetry.trace_event_name(event) == trace_event
    end)
  end

  test "emits the documented lifecycle telemetry payloads" do
    LifecycleTelemetry.agent_start(
      "coding-skill",
      :skill,
      "skill-session-1",
      parent: "main",
      parent_session: "main-session-1"
    )

    assert_receive {:telemetry, [:fermix, :agent, :start], %{}, metadata}

    assert metadata == %{
             name: "coding-skill",
             role: "skill",
             session_id: "skill-session-1",
             parent: "main",
             parent_session: "main-session-1"
           }

    LifecycleTelemetry.agent_task_start(
      "coding-skill",
      :skill,
      "skill-session-1",
      "Read README",
      parent: "main",
      parent_session: "main-session-1"
    )

    assert_receive {:telemetry, [:fermix, :agent, :task_start], %{}, metadata}

    assert metadata == %{
             name: "coding-skill",
             role: "skill",
             session_id: "skill-session-1",
             task_summary: "Read README",
             parent: "main",
             parent_session: "main-session-1"
           }

    LifecycleTelemetry.agent_task_complete(
      "coding-skill",
      :skill,
      "skill-session-1",
      true,
      18,
      2,
      parent: "main",
      parent_session: "main-session-1"
    )

    assert_receive {:telemetry, [:fermix, :agent, :task_complete], measurements, metadata}

    assert measurements == %{duration_ms: 18, iterations: 2}

    assert metadata == %{
             name: "coding-skill",
             role: "skill",
             session_id: "skill-session-1",
             success: true,
             parent: "main",
             parent_session: "main-session-1"
           }

    LifecycleTelemetry.agent_stop(
      "coding-skill",
      :skill,
      "skill-session-1",
      :normal,
      18,
      parent: "main",
      parent_session: "main-session-1"
    )

    assert_receive {:telemetry, [:fermix, :agent, :stop], measurements, metadata}

    assert measurements == %{duration_ms: 18}

    assert metadata == %{
             name: "coding-skill",
             role: "skill",
             session_id: "skill-session-1",
             reason: "normal",
             parent: "main",
             parent_session: "main-session-1"
           }

    LifecycleTelemetry.skill_invoke(
      "coding-skill",
      "skill-session-1",
      "Read README",
      true,
      18,
      "main-session-1",
      parent: "main"
    )

    assert_receive {:telemetry, [:fermix, :skill, :invoke], measurements, metadata}
    assert measurements == %{duration_ms: 18}

    assert metadata == %{
             skill: "coding-skill",
             session_id: "skill-session-1",
             task_summary: "Read README",
             success: true,
             parent: "main",
             parent_session: "main-session-1"
           }

    LifecycleTelemetry.skill_journal_write(
      "coding-skill",
      "skill-session-1",
      "/tmp/fake-journal.md",
      512
    )

    assert_receive {:telemetry, [:fermix, :skill, :journal_write], measurements, metadata}
    assert measurements == %{bytes: 512}

    assert metadata == %{
             skill: "coding-skill",
             session_id: "skill-session-1",
             path: "/tmp/fake-journal.md"
           }
  end

  test "emits the documented supervisor telemetry payloads" do
    LifecycleTelemetry.supervisor_spawn("coding-skill", false, "main")

    assert_receive {:telemetry, [:fermix, :supervisor, :spawn], %{}, metadata}

    assert metadata == %{
             name: "coding-skill",
             persistent: false,
             parent: "main"
           }

    LifecycleTelemetry.supervisor_exit("coding-skill", :normal, true)

    assert_receive {:telemetry, [:fermix, :supervisor, :exit], %{}, metadata}

    assert metadata == %{
             name: "coding-skill",
             reason: "normal",
             was_monitored: true
           }
  end
end
