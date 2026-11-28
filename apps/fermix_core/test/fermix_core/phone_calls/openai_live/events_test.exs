defmodule FermixCore.PhoneCalls.OpenAILive.EventsTest do
  @moduledoc """
  `Events.normalize/1` and `Events.dedupe/2` against fixtures shaped exactly as
  OpenAI's *Sideband WebSocket* reference and *Telephony and SIP* guide print
  them. Ids, numbers and words are invented.

  Every shape the eval runners' simulated endpoint sends comes from the one
  wire fixture both sides read (`test/fixtures/phone_calls/gpt_live_wire.json`),
  so the two cannot drift; the cases that file does not hold (missing fields,
  reflected audio, unknown types, keys the called party presses) are typed
  here.
  """

  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.OpenAILive.Events

  @fixture Path.expand("../../../fixtures/phone_calls/gpt_live_wire.json", __DIR__)
  @external_resource @fixture
  @server_events (@fixture |> File.read!() |> Jason.decode!())["server_events"]

  @session "live_u0_inv01"

  defp wire(type), do: Map.fetch!(@server_events, type)["event"]

  describe "transport progress" do
    test "ringing, answered and failed keep the vendor's ids and words" do
      for {type, kind} <- [{"transport.ringing", :ringing}, {"transport.answered", :answered}] do
        event = wire(type)

        assert {^kind, %{session_id: session_id, event_id: event_id}} = Events.normalize(event)
        assert {session_id, event_id} == {event["session_id"], event["event_id"]}
      end

      failed = wire("transport.failed")
      error = failed["error"]

      assert Events.normalize(failed) ==
               {:call_failed,
                %{
                  session_id: failed["session_id"],
                  code: error["code"],
                  message: error["message"],
                  param: error["param"],
                  event_id: failed["event_id"]
                }}
    end

    test "a failure with no error object is still a failure, with no invented reason" do
      assert {:call_failed, %{code: nil, message: nil, param: nil}} =
               Events.normalize(%{"type" => "transport.failed", "event_id" => "event_call_9"})
    end

    # Ringing is optional: a late attach can miss it. The normalizer passes on
    # what arrived, in the order it arrived, and adds nothing.
    test "events out of order or with a gap are passed on as they came, nothing added" do
      arrived = [
        %{"type" => "transport.answered", "event_id" => "event_call_2", "session_id" => @session},
        %{"type" => "transport.ringing", "event_id" => "event_call_1", "session_id" => @session}
      ]

      assert [{:answered, %{event_id: "event_call_2"}}, {:ringing, %{event_id: "event_call_1"}}] =
               Enum.map(arrived, &Events.normalize/1)

      assert [{:answered, _answered}] =
               Enum.map(Enum.take(arrived, 1), &Events.normalize/1)
    end
  end

  describe "transcript" do
    test "input is the remote party, output is the assistant, both verbatim with offsets" do
      for {type, speaker} <- [
            {"session.input_transcript.delta", :remote},
            {"session.output_transcript.delta", :assistant}
          ] do
        event = wire(type)

        assert Events.normalize(event) ==
                 {:transcript,
                  %{
                    speaker: speaker,
                    text: event["delta"],
                    start_ms: event["start_ms"],
                    end_ms: event["end_ms"],
                    event_id: event["event_id"]
                  }}
      end
    end

    test "a fragment's own spacing is kept verbatim" do
      assert {:transcript, %{text: " Table for two?"}} =
               Events.normalize(%{
                 "type" => "session.input_transcript.delta",
                 "event_id" => "event_transcript_1",
                 "delta" => " Table for two?",
                 "start_ms" => 1_000,
                 "end_ms" => 1_200
               })
    end

    test "a missing offset is nil, never zero" do
      assert {:transcript, %{start_ms: nil, end_ms: nil}} =
               Events.normalize(%{
                 "type" => "session.input_transcript.delta",
                 "event_id" => "event_transcript_3",
                 "delta" => "hello"
               })
    end

    test "a fragment with no text cannot be used and says so" do
      event = %{"type" => "session.output_transcript.delta", "event_id" => "event_transcript_4"}

      assert {:malformed, "session.output_transcript.delta", ^event} = Events.normalize(event)
    end

    # An empty fragment is no speech: it would grow the transcript by an entry
    # of no bytes, and on the remote side count as the person speaking.
    test "a fragment whose text is empty is no text, either side" do
      for type <- ["session.input_transcript.delta", "session.output_transcript.delta"] do
        event = %{"type" => type, "event_id" => "event_transcript_5", "delta" => ""}

        assert {:malformed, ^type, ^event} = Events.normalize(event)
      end
    end
  end

  describe "delegation" do
    test "carries the id unchanged, the target and the offset, and no request text" do
      event = wire("session.delegation.created")

      assert Events.normalize(event) ==
               {:delegation,
                %{
                  id: event["delegation"]["id"],
                  target: event["delegation"]["target"],
                  offset_ms: event["offset_ms"],
                  event_id: event["event_id"]
                }}
    end

    test "a delegation with no id cannot be answered and says so" do
      event = %{
        "type" => "session.delegation.created",
        "event_id" => "event_delegation_2",
        "delegation" => %{"target" => "client"}
      }

      assert {:malformed, "session.delegation.created", ^event} = Events.normalize(event)
    end
  end

  describe "usage and finalization" do
    test "usage is a cumulative snapshot, flagged so: the latest replaces, never sums" do
      snapshots =
        Enum.map([12, 30, 47], fn seconds ->
          Events.normalize(%{
            "type" => "session.usage.updated",
            "event_id" => "event_usage_#{seconds}",
            "usage" => %{"seconds" => seconds},
            "context_window" => %{"usage_ratio" => 0.42}
          })
        end)

      assert Enum.all?(snapshots, &match?({:usage, %{cumulative: true}}, &1))
      assert {:usage, %{seconds: 47, context_usage_ratio: 0.42}} = List.last(snapshots)
    end

    test "usage with no number is not a snapshot" do
      event = %{"type" => "session.usage.updated", "event_id" => "event_usage_x", "usage" => %{}}

      assert {:malformed, "session.usage.updated", ^event} = Events.normalize(event)
    end

    test "the wire's usage snapshot is flagged cumulative" do
      event = wire("session.usage.updated")

      assert Events.normalize(event) ==
               {:usage,
                %{
                  seconds: event["usage"]["seconds"],
                  cumulative: true,
                  context_usage_ratio: event["context_window"]["usage_ratio"],
                  event_id: event["event_id"]
                }}
    end

    test "session.closed carries the vendor's reason and the final usage" do
      event = wire("session.closed")

      assert Events.normalize(event) ==
               {:session_closed,
                %{
                  reason: event["reason"],
                  seconds: event["usage"]["seconds"],
                  event_id: event["event_id"]
                }}
    end

    test "a close with no usage leaves the final seconds unknown, not zero" do
      assert {:session_closed, %{reason: "connection_lost", seconds: nil}} =
               Events.normalize(%{
                 "type" => "session.closed",
                 "event_id" => "event_closed_2",
                 "reason" => "connection_lost"
               })
    end

    test "session.started carries the session's expiry" do
      assert {:session_started, %{session_id: @session, expires_at: 1_790_000_000}} =
               Events.normalize(%{
                 "type" => "session.started",
                 "event_id" => "event_started",
                 "session" => %{
                   "id" => @session,
                   "expires_at" => 1_790_000_000,
                   "status" => "active",
                   "model" => "gpt-live-1"
                 }
               })
    end
  end

  describe "keypad, acknowledgements and errors" do
    test "a DTMF acknowledgement names the send it answers" do
      event = wire("transport.dtmf.sent")

      assert Events.normalize(event) ==
               {:dtmf_sent,
                %{
                  key: event["event"],
                  client_event_id: event["client_event_id"],
                  event_id: event["event_id"]
                }}
    end

    test "a key the called party pressed is reported with its key" do
      assert {:dtmf_received, %{key: "5", event_id: "event_dtmf_2"}} =
               Events.normalize(%{
                 "type" => "transport.dtmf.received",
                 "event_id" => "event_dtmf_2",
                 "event" => "5"
               })
    end

    test "an append acknowledgement names its kind and the append it answers" do
      for {type, kind} <- [
            {"session.instructions.appended", :instructions},
            {"session.thinking.appended", :thinking},
            {"session.commentary.appended", :commentary}
          ] do
        event = wire(type)

        assert Events.normalize(event) ==
                 {:append_acked,
                  %{
                    kind: kind,
                    client_event_id: event["client_event_id"],
                    event_id: event["event_id"]
                  }}
      end
    end

    test "a vendor error keeps its words and the client event it refuses" do
      event = wire("error")
      error = event["error"]

      assert Events.normalize(event) ==
               {:vendor_error,
                %{
                  type: error["type"],
                  code: error["code"],
                  message: error["message"],
                  param: error["param"],
                  client_event_id: error["client_event_id"],
                  event_id: event["event_id"]
                }}
    end

    test "a vendor error's client event id may ride at the top level instead" do
      assert {:vendor_error, %{client_event_id: "ev_dtmf_3", code: "unknown_parameter"}} =
               Events.normalize(%{
                 "type" => "error",
                 "event_id" => "event_error_2",
                 "client_event_id" => "ev_dtmf_3",
                 "error" => %{"type" => "invalid_request_error", "code" => "unknown_parameter"}
               })
    end
  end

  describe "everything else" do
    test "reflected audio, both directions, is marked for discarding" do
      assert {:reflected_audio, :output} =
               Events.normalize(%{
                 "type" => "session.output_audio.delta",
                 "delta" => "AAAA",
                 "start_ms" => 0,
                 "end_ms" => 20
               })

      assert {:reflected_audio, :input} =
               Events.normalize(%{"type" => "session.input_audio.append", "audio" => "AAAA"})
    end

    test "an unknown or unused type stays observable and is never a transition" do
      future = %{"type" => "transport.transferred", "event_id" => "event_future"}
      assert {:unknown, "transport.transferred", ^future} = Events.normalize(future)

      info = %{"type" => "info", "event_id" => "event_info", "code" => "data_channel_permissions"}
      assert {:unknown, "info", ^info} = Events.normalize(info)
    end

    test "an object with no type is malformed" do
      assert {:malformed, nil, %{"event_id" => "x"}} = Events.normalize(%{"event_id" => "x"})
    end
  end

  describe "dedupe/2" do
    test "a replayed event id is delivered once" do
      ringing = %{"type" => "transport.ringing", "event_id" => "event_call_1"}

      assert {:new, seen} = Events.dedupe(Events.new_seen(), ringing)
      assert :duplicate = Events.dedupe(seen, ringing)
      assert {:new, _seen} = Events.dedupe(seen, %{ringing | "event_id" => "event_call_2"})
    end

    test "an event with no id is never a duplicate" do
      audio = %{"type" => "session.output_audio.delta", "delta" => "AAAA"}

      assert {:new, seen} = Events.dedupe(Events.new_seen(), audio)
      assert {:new, _seen} = Events.dedupe(seen, audio)
    end

    test "memory is bounded: past the cap the oldest id is forgotten" do
      seen =
        Enum.reduce(1..3, Events.new_seen(2), fn n, seen ->
          {:new, seen} = Events.dedupe(seen, %{"event_id" => "e#{n}"})
          seen
        end)

      assert {:new, _seen} = Events.dedupe(seen, %{"event_id" => "e1"})
      assert :duplicate = Events.dedupe(seen, %{"event_id" => "e2"})
      assert :duplicate = Events.dedupe(seen, %{"event_id" => "e3"})
    end

    test "the production cap holds well over a 3-second replay" do
      assert Limits.max_seen_event_ids() >= 1_000
    end
  end
end
