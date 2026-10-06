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

  # M56 §4.6: the two rows of a task that outlives its call.
  describe "a detached task's rows" do
    test "the running row names the request on one line" do
      {call, text} =
        CallRow.task_running(@uuid, "dg_1", 2, "user: book the room\nfor ten\nassistant: On it.")

      assert call == %{
               "uuid" => @uuid,
               "event" => "task_running",
               "task_id" => "dg_1",
               "revision" => 2
             }

      assert text == "Still working on: user: book the room for ten assistant: On it."
      assert :ok = Protocol.validate_call_metadata(call)
    end

    test "a long request keeps its end, where the ask is" do
      request = String.duplicate("earlier ", 200) <> "user: book the room"

      {_call, text} = CallRow.task_running(@uuid, "dg_1", 1, request)

      assert String.ends_with?(text, "user: book the room")
      assert byte_size(text) <= 420
    end

    test "a completed task's row is the result shown, or the whole reply with no delimiter" do
      {call, shown} =
        CallRow.task_done(
          @uuid,
          "dg_1",
          1,
          {:completed, "I found it.\n---shown---\nIt is at https://x.test/form."}
        )

      assert shown == "It is at https://x.test/form."
      assert call["state"] == "completed"
      assert :ok = Protocol.validate_call_metadata(call)

      assert {_call, "The room is booked for 10am."} =
               CallRow.task_done(@uuid, "dg_1", 1, {:completed, "The room is booked for 10am."})
    end

    test "every other end is its state and a sentence of its own" do
      for {outcome, state, text} <- [
            {{:failed, "The calendar could not be reached."}, "failed",
             "The calendar could not be reached."},
            {:cancelled, "cancelled", "The task was cancelled."},
            {:timed_out, "timed_out", "The task ran past its time limit and was stopped."},
            {:restarted, "failed", "The task stopped when Fermix restarted."}
          ] do
        assert {call, ^text} = CallRow.task_done(@uuid, "dg_1", 3, outcome)

        assert call == %{
                 "uuid" => @uuid,
                 "event" => "task_done",
                 "task_id" => "dg_1",
                 "revision" => 3,
                 "state" => state
               }

        assert :ok = Protocol.validate_call_metadata(call)
      end
    end

    test "the call's ended row names a task still running as such" do
      task = %{"task_id" => "dg_4", "revision" => 1, "state" => "detached", "summary" => "x"}
      {_call, text} = CallRow.ended(%{@record | tasks: [task], gist_status: "failed"})

      assert text == "Voice call, 6 minutes\n\n- Still running: x"
    end
  end
end
