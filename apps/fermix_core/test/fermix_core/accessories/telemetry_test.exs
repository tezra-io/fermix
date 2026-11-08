defmodule FermixCore.Accessories.TelemetryTest do
  @moduledoc """
  The accessory link's events (docs/TELEMETRY_CONTRACT.md, *Accessory link*):
  two sessionless points, an attach's outcome and a link fault, and one event
  per call under the call's own session id, with the link's counters. Atoms
  and counts only: no key, signature, nonce, audio or message text.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Telemetry
  alias FermixTestSupport.TelemetryCapture

  @accessory String.duplicate("ab", 32)

  test "an attach's outcome is a point with its status, mode and the endpoint it verified" do
    TelemetryCapture.attach([[:fermix, :accessory, :attach]], :emitter)

    :ok =
      Telemetry.emit_attach(:attached, 1_250, %{
        mode: :attach,
        kind: "stackchan",
        accessory_id: @accessory,
        accessory_refusal: nil
      })

    assert_receive {:telemetry, [:fermix, :accessory, :attach], %{count: 1, duration_us: 1_250},
                    meta}

    assert meta == %{
             status: :attached,
             mode: :attach,
             kind: :stackchan,
             endpoint: "accessory:" <> @accessory,
             accessory_refusal: nil
           }
  end

  test "an attach refused names the refusal, and never a kind the host does not know" do
    TelemetryCapture.attach([[:fermix, :accessory, :attach]], :emitter)

    :ok =
      Telemetry.emit_attach(:unsupported_kind, 10, %{
        mode: :pairing,
        kind: "toaster",
        accessory_id: nil,
        accessory_refusal: nil
      })

    assert_receive {:telemetry, [:fermix, :accessory, :attach], _measurements, meta}
    assert %{status: :unsupported_kind, kind: nil, endpoint: nil} = meta

    :ok =
      Telemetry.emit_attach(:accessory_refused, 10, %{
        mode: :attach,
        kind: nil,
        accessory_id: nil,
        accessory_refusal: :unknown_host
      })

    assert_receive {:telemetry, [:fermix, :accessory, :attach], _measurements,
                    %{status: :accessory_refused, accessory_refusal: :unknown_host}}
  end

  test "an attach status outside the vocabulary fails loud" do
    assert_raise FunctionClauseError, fn ->
      Telemetry.emit_attach(:mystery, 1, %{
        mode: :attach,
        kind: nil,
        accessory_id: nil,
        accessory_refusal: nil
      })
    end
  end

  test "a link fault is a point with its reason, where it was found, and its count" do
    TelemetryCapture.attach([[:fermix, :accessory, :fault]], :emitter)

    :ok = Telemetry.emit_fault(:crc_mismatch, :receive, 3)

    assert_receive {:telemetry, [:fermix, :accessory, :fault], %{count: 3},
                    %{reason: :crc_mismatch, stage: :receive}}
  end

  test "a call's link counters ride under the call's own session id" do
    session_id = "voice_live:#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: session_id)

    counters = %{
      duration_ms: 4_200,
      mic_frames: 200,
      mic_chunks: 40,
      pcm_seq_gaps: 1,
      speaker_frames: 30,
      speaker_bytes: 96_000,
      segments: 2,
      flushes: 1,
      credit_waits: 3,
      backlog_peak_bytes: 48_000,
      task_events: 2,
      task_faults: 0
    }

    :ok =
      Telemetry.emit_call_link(session_id, counters, %{
        endpoint: "accessory:" <> @accessory,
        engine: "openai_live",
        source: :screen_tap,
        reason: :end_request
      })

    assert_receive {:telemetry, [:fermix, :accessory, :call_link], ^counters, meta}

    assert meta == %{
             session_id: session_id,
             endpoint: "accessory:" <> @accessory,
             engine: "openai_live",
             source: :screen_tap,
             reason: :end_request
           }
  end

  # M91 F3: the robot's own counters, the early-microphone fault and the
  # interrupts' positions are named counters of the call's link event.
  test "the robot's counters, early microphone frames and interrupts are call counters" do
    session_id = "session:#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: session_id)

    counters = %{
      mic_frames_before_live: 0,
      interrupts: 2,
      interrupt_played_ms_last: 20,
      interrupt_played_ms_total: 120,
      robot_uptime_s: 61,
      robot_frames_rx: 812,
      robot_frames_tx: 940,
      robot_crc_errors: 0,
      robot_resync_bytes: 0,
      robot_pcm_seq_gaps: 0,
      robot_mic_overflows: 0,
      robot_spk_underflows: 3
    }

    :ok =
      Telemetry.emit_call_link(session_id, counters, %{
        endpoint: "accessory:" <> @accessory,
        engine: "openai_realtime",
        source: :mac,
        reason: :end_request
      })

    assert_receive {:telemetry, [:fermix, :accessory, :call_link], ^counters, _meta}
  end

  test "a counter the contract does not name is refused, so nothing else reaches the event" do
    assert_raise ArgumentError, fn ->
      Telemetry.emit_call_link("session:1", %{mic_frames: 1, transcript: 0}, %{
        endpoint: "accessory:" <> @accessory,
        engine: "openai_realtime",
        source: :mac,
        reason: :end_request
      })
    end
  end

  test "every event is registered for the JSONL trace" do
    events = Enum.map(Telemetry.trace_event_definitions(), & &1.event)

    assert events == [
             [:fermix, :accessory, :attach],
             [:fermix, :accessory, :fault],
             [:fermix, :accessory, :call_link]
           ]

    assert Enum.all?(Telemetry.trace_event_definitions(), &(&1.trace_type == :agent_event))
  end
end
