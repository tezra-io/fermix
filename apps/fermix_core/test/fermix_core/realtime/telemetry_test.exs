defmodule FermixCore.Realtime.TelemetryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Telemetry

  @meta %{
    session_id: "session:7",
    device_id: "dev-1",
    model: "gpt-realtime-2",
    voice: "marin",
    session_scope: "session:7"
  }

  setup do
    events =
      ~w(call_start session_created session_updated provider_error reconnect call_stop)a

    handler_id = "test-realtime-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      Enum.map(events, &[:fermix, :realtime, &1]),
      fn event, measurements, metadata, _config ->
        send(test_pid, {:rt, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "call_start emits correlation + session metadata" do
    Telemetry.call_start(@meta)

    assert_receive {:rt, [:fermix, :realtime, :call_start], %{}, meta}
    assert meta.session_id == "session:7"
    assert meta.agent == "realtime"
    assert meta.model == "gpt-realtime-2"
    assert meta.voice == "marin"
  end

  test "session_created and session_updated emit" do
    Telemetry.session_created(@meta)
    assert_receive {:rt, [:fermix, :realtime, :session_created], _m, _meta}

    Telemetry.session_updated(@meta)
    assert_receive {:rt, [:fermix, :realtime, :session_updated], _m, _meta}
  end

  test "reconnect carries the attempt number" do
    Telemetry.reconnect(@meta, 2)

    assert_receive {:rt, [:fermix, :realtime, :reconnect], _m, meta}
    assert meta.attempt == 2
  end

  test "provider_error carries a bounded reason" do
    Telemetry.provider_error(@meta, "boom")

    assert_receive {:rt, [:fermix, :realtime, :provider_error], _m, meta}
    assert meta.reason == "boom"
  end

  test "call_stop forwards measurements with session metadata" do
    Telemetry.call_stop(@meta, %{duration_ms: 1234})

    assert_receive {:rt, [:fermix, :realtime, :call_stop], measurements, meta}
    assert measurements.duration_ms == 1234
    assert meta.session_id == "session:7"
  end
end
