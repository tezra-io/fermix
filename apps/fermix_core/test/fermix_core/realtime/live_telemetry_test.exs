defmodule FermixCore.Realtime.LiveTelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.LiveTelemetry

  @meta %{
    session_id: "voice_live:7",
    device_id: "dev-1",
    model: "gpt-live-1",
    voice: "marin",
    provider_session_id: "sess_live_abc"
  }

  @delegation %{delegation_id: "dlg_1", revision: 2, turn_session_id: "voice_delegation_7"}

  setup do
    handler_id = "test-voice-live-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = Enum.map(LiveTelemetry.trace_event_definitions(), & &1.event)

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:vl, event, measurements, metadata})
      end,
      nil
    )

    # `provider_error` shapes its reason through the shared content gate, so this
    # module establishes the posture it asserts against rather than reading
    # whatever an earlier module left in the global app env.
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, false))

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    :ok
  end

  test "call_start carries the call id, the engine and the sweep floor" do
    LiveTelemetry.call_start(@meta, 900_000)

    assert_receive {:vl, [:fermix, :voice_live, :call_start], %{}, meta}
    assert meta.agent == "voice_live"
    assert meta.session_id == "voice_live:7"
    assert meta.engine == "openai_live"
    assert meta.device_id == "dev-1"
    assert meta.model == "gpt-live-1"
    assert meta.voice == "marin"
    assert meta.max_duration_ms == 900_000
  end

  test "session_started carries the provider session id" do
    LiveTelemetry.session_started(@meta)

    assert_receive {:vl, [:fermix, :voice_live, :session_started], %{}, meta}
    assert meta.provider_session_id == "sess_live_abc"
    assert meta.session_id == "voice_live:7"
  end

  test "delegation_start carries the delegation correlation ids" do
    LiveTelemetry.delegation_start(@meta, @delegation)

    assert_receive {:vl, [:fermix, :voice_live, :delegation_start], %{}, meta}
    assert meta.delegation_id == "dlg_1"
    assert meta.revision == 2
    assert meta.turn_session_id == "voice_delegation_7"
    assert meta.session_id == "voice_live:7"
  end

  test "delegation_stop carries the terminal status and the duration measurement" do
    LiveTelemetry.delegation_stop(@meta, @delegation, "completed", 1_234)

    assert_receive {:vl, [:fermix, :voice_live, :delegation_stop], measurements, meta}
    assert measurements == %{duration_ms: 1_234}
    assert meta.status == "completed"
    assert meta.turn_session_id == "voice_delegation_7"
  end

  test "delegation_stop refuses a status outside the terminal vocabulary" do
    assert_raise FunctionClauseError, fn ->
      LiveTelemetry.delegation_stop(@meta, @delegation, "running", 10)
    end
  end

  test "provider_error carries a bounded reason" do
    long = String.duplicate("x", 4_000)
    LiveTelemetry.provider_error(@meta, long)

    assert_receive {:vl, [:fermix, :voice_live, :provider_error], %{}, meta}
    assert String.length(meta.reason) < String.length(long)
    assert meta.session_id == "voice_live:7"
  end

  test "call_stop carries the numeric ledger and the reason that ended the call" do
    LiveTelemetry.call_stop(
      @meta,
      %{
        voice_seconds: 62,
        voice_cost_millicents: 5_167,
        backend_turns: 2,
        accounting_complete: 1
      },
      :cost_limit
    )

    assert_receive {:vl, [:fermix, :voice_live, :call_stop], measurements, meta}

    assert measurements == %{
             voice_seconds: 62,
             voice_cost_millicents: 5_167,
             backend_turns: 2,
             accounting_complete: 1
           }

    assert meta.reason == "cost_limit"
    assert meta.session_id == "voice_live:7"
  end

  # A measurement that is not a number reaches Opik as an unpriceable field and
  # reads as a real reading in the JSONL. Fail at the emitter instead.
  test "call_stop refuses a non-numeric measurement" do
    assert_raise ArgumentError, fn ->
      LiveTelemetry.call_stop(@meta, %{voice_seconds: :unknown}, :call_stop)
    end
  end

  test "absent optional metadata is dropped, never emitted as nil" do
    LiveTelemetry.call_start(%{session_id: "voice_live:8"}, 60_000)

    assert_receive {:vl, [:fermix, :voice_live, :call_start], %{}, meta}
    refute Map.has_key?(meta, :provider_session_id)
    refute Map.has_key?(meta, :device_id)
    refute Map.has_key?(meta, :parent_session)
    assert meta.session_id == "voice_live:8"
    assert meta.engine == "openai_live"
  end

  test "a parent session rides as correlation when the call was opened by a turn" do
    LiveTelemetry.call_start(Map.put(@meta, :parent_session, "main-3"), 60_000)

    assert_receive {:vl, [:fermix, :voice_live, :call_start], %{}, meta}
    assert meta.parent_session == "main-3"
  end

  test "a call without a session id fails loud rather than emitting an orphan" do
    assert_raise KeyError, fn -> LiveTelemetry.call_start(%{model: "gpt-live-1"}, 60_000) end
  end

  test "trace_event_definitions covers every voice_live event as an agent_event" do
    definitions = LiveTelemetry.trace_event_definitions()

    assert Enum.map(definitions, & &1.event) == [
             [:fermix, :voice_live, :call_start],
             [:fermix, :voice_live, :session_started],
             [:fermix, :voice_live, :delegation_start],
             [:fermix, :voice_live, :delegation_stop],
             [:fermix, :voice_live, :provider_error],
             [:fermix, :voice_live, :call_stop]
           ]

    assert Enum.all?(definitions, &(&1.trace_type == :agent_event))
    assert Enum.all?(definitions, &(&1.agent_field == :agent))

    assert Enum.map(definitions, & &1.trace_event) == [
             "voice_live_call_start",
             "voice_live_session_started",
             "voice_live_delegation_start",
             "voice_live_delegation_stop",
             "voice_live_provider_error",
             "voice_live_call_stop"
           ]
  end
end
