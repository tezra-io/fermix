defmodule FermixCore.ComputerUse.TelemetryTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Telemetry

  setup do
    test_pid = self()
    handler_id = "cu-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:fermix, :computer_use, :session_start],
        [:fermix, :computer_use, :session_complete],
        [:fermix, :computer_use, :session_error],
        [:fermix, :computer_use, :session_pause],
        [:fermix, :computer_use, :session_resume]
      ],
      fn event, measurements, metadata, _ ->
        if self() == test_pid do
          send(test_pid, {:cu, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "session_start carries session_id, mode, and parent_session for nested traces" do
    Telemetry.session_start(%{
      session_id: "cua_abc",
      parent_session: "main-1",
      agent: "main",
      mode: :host,
      origin: :interactive
    })

    assert_receive {:cu, [:fermix, :computer_use, :session_start], %{}, meta}
    assert meta.session_id == "cua_abc"
    assert meta.parent_session == "main-1"
    assert meta.mode == :host
    assert meta.origin == :interactive
  end

  test "session_start omits parent_session when absent (a root session)" do
    Telemetry.session_start(%{session_id: "cua_root", agent: "main", mode: :host})

    assert_receive {:cu, [:fermix, :computer_use, :session_start], %{}, meta}
    refute Map.has_key?(meta, :parent_session)
  end

  test "session_complete carries action/duration measurements" do
    Telemetry.session_complete(
      %{session_id: "cua_x", agent: "main", mode: :host},
      %{actions: 7, duration_ms: 1234}
    )

    assert_receive {:cu, [:fermix, :computer_use, :session_complete], measurements, meta}
    assert measurements == %{actions: 7, duration_ms: 1234}
    assert meta.session_id == "cua_x"
  end

  test "session_error previews the reason" do
    Telemetry.session_error(
      %{session_id: "cua_e", agent: "main", mode: :host},
      {:driver_crash, :boom}
    )

    assert_receive {:cu, [:fermix, :computer_use, :session_error], %{}, meta}
    assert meta.session_id == "cua_e"
    assert is_binary(meta.reason)
    assert meta.reason =~ "driver_crash"
  end

  # Pause and resume say why nothing was dispatched between two actions, so they
  # carry the run's correlation exactly as the bookends do.
  test "session_pause and session_resume carry the run's correlation" do
    meta = %{session_id: "cua_p", parent_session: "main-2", agent: "main", mode: :host}

    Telemetry.session_pause(meta)
    Telemetry.session_resume(meta)

    assert_receive {:cu, [:fermix, :computer_use, :session_pause], %{}, paused}
    assert paused.session_id == "cua_p"
    assert paused.parent_session == "main-2"
    assert paused.mode == :host

    assert_receive {:cu, [:fermix, :computer_use, :session_resume], %{}, resumed}
    assert resumed.session_id == "cua_p"
  end

  # A verb missing from the definitions is invisible in the JSONL with no error,
  # so the invariant is written over the whole family rather than a subset.
  test "trace_event_definitions covers every computer_use verb as an agent_event" do
    definitions = Telemetry.trace_event_definitions()

    assert Enum.map(definitions, & &1.event) == [
             [:fermix, :computer_use, :session_start],
             [:fermix, :computer_use, :session_complete],
             [:fermix, :computer_use, :session_error],
             [:fermix, :computer_use, :session_pause],
             [:fermix, :computer_use, :session_resume]
           ]

    assert Enum.all?(definitions, &(&1.trace_type == :agent_event))
    assert Enum.all?(definitions, &(&1.agent_field == :agent))

    assert Enum.map(definitions, & &1.trace_event) == [
             "computer_use_session_start",
             "computer_use_session_complete",
             "computer_use_session_error",
             "computer_use_session_pause",
             "computer_use_session_resume"
           ]
  end
end
