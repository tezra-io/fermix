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
        [:fermix, :computer_use, :session_error]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:cu, event, measurements, metadata})
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
end
