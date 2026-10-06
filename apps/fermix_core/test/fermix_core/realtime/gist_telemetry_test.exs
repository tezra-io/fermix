defmodule FermixCore.Realtime.GistTelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.GistTelemetry

  @call_uuid "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"

  setup do
    handler_id = "test-voice-gist-#{System.unique_integer([:positive])}"
    test_pid = self()
    events = Enum.map(GistTelemetry.trace_event_definitions(), & &1.event)

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:gist, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{run: %{session_id: GistTelemetry.session_id(@call_uuid), call_uuid: @call_uuid}}
  end

  # M56 §7: a run of its own, keyed so the exporter reads it as one, with the
  # call's UUID to tie it to the call's record and trace.
  test "the session id names the run kind and the call", %{run: run} do
    assert run.session_id == "voice_gist:" <> @call_uuid
  end

  test "run_start opens the run with what it summarises, by size only", %{run: run} do
    GistTelemetry.run_start(run, %{
      tasks: 2,
      speech_bytes: 1_204,
      input_bytes: 1_530,
      tainted?: true
    })

    assert_receive {:gist, [:fermix, :voice_gist, :run_start], %{}, meta}

    assert meta == %{
             agent: "voice_gist",
             session_id: "voice_gist:" <> @call_uuid,
             call_uuid: @call_uuid,
             tasks: 2,
             speech_bytes: 1_204,
             input_bytes: 1_530,
             tainted: true
           }
  end

  test "run_complete closes it written, with the time taken and the gist's size", %{run: run} do
    GistTelemetry.run_complete(run, %{duration_ms: 2_100, gist_bytes: 310})

    assert_receive {:gist, [:fermix, :voice_gist, :run_complete], measurements, meta}
    assert measurements == %{duration_ms: 2_100, gist_bytes: 310}
    assert meta.status == "written"
    assert meta.session_id == "voice_gist:" <> @call_uuid
  end

  test "run_error closes it failed, with the reason's words and never the call's", %{run: run} do
    GistTelemetry.run_error(run, :timeout, 60_000)

    assert_receive {:gist, [:fermix, :voice_gist, :run_error], measurements, meta}
    assert measurements == %{count: 1, duration_ms: 60_000}
    assert meta.status == "failed"
    assert meta.error == "timeout"

    GistTelemetry.run_error(run, {:provider_error, String.duplicate("x", 2_000)}, 10)
    assert_receive {:gist, [:fermix, :voice_gist, :run_error], _measurements, long}
    assert String.length(long.error) <= 500
  end

  test "every event is registered for the trace stream as an agent_event row" do
    assert Enum.map(GistTelemetry.trace_event_definitions(), & &1.trace_event) == [
             "voice_gist_run_start",
             "voice_gist_run_complete",
             "voice_gist_run_error"
           ]

    assert Enum.all?(
             GistTelemetry.trace_event_definitions(),
             &(&1.trace_type == :agent_event and &1.agent_field == :agent)
           )
  end
end
