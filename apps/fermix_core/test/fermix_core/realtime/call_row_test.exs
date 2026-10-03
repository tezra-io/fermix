defmodule FermixCore.Realtime.CallRowTest do
  use ExUnit.Case, async: true

  alias FermixCore.Companion.Protocol
  alias FermixCore.Realtime.CallRow

  @uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"

  # A closed record as the memory database reads it back.
  @record %{
    uuid: @uuid,
    engine: "openai_live",
    started_at: "2026-10-02T09:00:00.000000Z",
    ended_at: "2026-10-02T09:06:10.000000Z",
    end_reason: "call_stop",
    voice_cost_cents: 30.833,
    accounting: "complete",
    tasks: [],
    gist: nil,
    gist_status: "none",
    gist_tainted: false,
    row_state: "row_pending"
  }

  @tasks [
    %{
      "task_id" => "dg_1",
      "revision" => 1,
      "state" => "completed",
      "request" => "user: book the room",
      "summary" => "Booked the room for 10am."
    },
    %{"task_id" => "dg_2", "revision" => 1, "state" => "failed", "summary" => "busy"},
    %{"task_id" => "dg_3", "revision" => 2, "state" => "timed_out", "summary" => nil}
  ]

  # M56 §4.2, D4: "Voice call, 6 minutes" and the gist on its own paragraph.
  test "a call with a gist is its sentence and the gist" do
    record = %{
      @record
      | gist: "You asked to book a room; it is booked for 10am.",
        gist_status: "written"
    }

    assert {call, text} = CallRow.ended(%{record | tasks: @tasks})
    assert text == "Voice call, 6 minutes\n\nYou asked to book a room; it is booked for 10am."
    assert call["gist_status"] == "written"
  end

  test "a call whose gist failed carries its task list, one task a line" do
    {call, text} = CallRow.ended(%{@record | tasks: @tasks, gist_status: "failed"})

    assert text ==
             "Voice call, 6 minutes\n\n" <>
               "- Completed: Booked the room for 10am.\n" <>
               "- Failed: busy\n" <>
               "- Timed out"

    assert call["gist_status"] == "failed"
  end

  test "a call with no gist and no task is its sentence alone" do
    assert {%{"gist_status" => "none"}, "Voice call, 6 minutes"} = CallRow.ended(@record)
  end

  test "the metadata names the call, its engine, its length and its settled bill" do
    {call, _text} = CallRow.ended(@record)

    assert call == %{
             "uuid" => @uuid,
             "event" => "ended",
             "engine" => "openai_live",
             "duration_s" => 370,
             "voice_cost_cents" => 30.833,
             "accounting" => "complete",
             "gist_status" => "none"
           }

    assert :ok = Protocol.validate_call_metadata(call)
  end

  test "an unknown cost is left out, never written as zero" do
    {call, _text} = CallRow.ended(%{@record | voice_cost_cents: nil, accounting: "incomplete"})

    refute Map.has_key?(call, "voice_cost_cents")
    assert call["accounting"] == "incomplete"
    assert :ok = Protocol.validate_call_metadata(call)
  end

  test "the sentence says minutes as a person would" do
    assert CallRow.sentence(0) == "Voice call, under a minute"
    assert CallRow.sentence(59) == "Voice call, under a minute"
    assert CallRow.sentence(60) == "Voice call, 1 minute"
    assert CallRow.sentence(89) == "Voice call, 1 minute"
    assert CallRow.sentence(90) == "Voice call, 2 minutes"
    assert CallRow.sentence(900) == "Voice call, 15 minutes"
  end
end
