defmodule FermixCore.PhoneCalls.Call.EndingTest do
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Call.Ending
  alias FermixCore.PhoneCalls.Limits

  @confirmed %{engine_stopping?: false, closed?: true, hangup_error: nil}

  # The moduledoc's table, row by row: the cause, the end reason the outcome
  # reading is given, and the failure word the row keeps.
  @table [
    {:no_answer, :no_answer, "no_answer"},
    {:deadline, :deadline, "call_deadline_reached"},
    {:recipient_silence, :deadline, "recipient_silence_timeout"},
    {:transcript_limit, :deadline, "transcript_limit_reached"},
    {{:cancelled, :owner}, :cancelled, "cancelled_by_owner"},
    {{:cancelled, :disabled}, :cancelled, "phone_calls_disabled"},
    {{:cancelled, :shutdown}, :cancelled, "engine_stopped"},
    {{:finish, :done}, :hangup, nil},
    {{:finish, :needs_owner}, :hangup, nil},
    {{:finish, :cannot_proceed}, :hangup, "cannot_proceed"},
    {{:finish, :voicemail}, :voicemail, nil},
    {:core_turn_limit, :hangup, "core_turn_limit_reached"},
    {:call_failed, :failed, "call_failed"},
    {{:remote_closed, "remote_hangup"}, :hangup, nil},
    {{:remote_closed, "close_requested"}, :hangup, nil},
    {{:remote_closed, "expired"}, :deadline, "provider_session_expired"},
    {{:remote_closed, "connection_lost"}, :connection_lost, "provider_connection_lost"},
    {{:remote_closed, "content"}, :failed, "provider_closed_for_content"},
    {{:remote_closed, "a_new_reason"}, :hangup, "provider_closed"},
    {{:remote_closed, nil}, :hangup, "provider_closed"},
    {:sideband_lost, :connection_lost, "sideband_lost"},
    {:attach_failed, :connection_lost, "attach_failed"},
    {:attach_timeout, :connection_lost, "attach_timeout"},
    {:session_not_recorded, :connection_lost, "session_not_recorded"}
  ]

  test "each cause gives its end reason and its failure word" do
    for {cause, end_reason, word} <- @table do
      ending = Ending.new(cause)
      assert Ending.end_reason(ending) == end_reason, inspect(cause)
      assert Ending.failure_reason(ending, @confirmed) == word, inspect(cause)
    end
  end

  test "a cause outside the vocabulary is refused at once" do
    assert_raise FunctionClauseError, fn -> Ending.new(:something_else) end
  end

  test "the engine's stop and an unconfirmed hangup are said beside the cause" do
    stopping = %{@confirmed | engine_stopping?: true}
    unconfirmed = %{@confirmed | closed?: false, hangup_error: "timeout"}

    assert Ending.failure_reason(Ending.new(:deadline), stopping) ==
             "call_deadline_reached; engine_stopped"

    assert Ending.failure_reason(Ending.new({:finish, :done}), stopping) == "engine_stopped"

    # The stop's own cause is not said twice.
    assert Ending.failure_reason(Ending.new({:cancelled, :shutdown}), stopping) ==
             "engine_stopped"

    assert Ending.failure_reason(Ending.new({:finish, :done}), unconfirmed) == "hangup timeout"

    assert Ending.failure_reason(Ending.new(:no_answer), unconfirmed) ==
             "no_answer; hangup timeout"

    # A confirmed end says nothing of a hangup that failed.
    assert Ending.failure_reason(Ending.new(:no_answer), %{unconfirmed | closed?: true}) ==
             "no_answer"
  end

  test "speech is waited for in bounded quiet windows, never on voicemail or a stop" do
    ending = Ending.new({:finish, :done})
    assert Ending.waits_for_speech?(ending, false)
    refute Ending.waits_for_speech?(ending, true)
    refute Ending.waits_for_speech?(Ending.new({:finish, :voicemail}), false)

    assert :done = Ending.speech_checked(ending, false, false)
    assert :done = Ending.speech_checked(ending, true, true)

    windows =
      Stream.unfold(ending, fn ending ->
        case Ending.speech_checked(ending, true, false) do
          {:wait, next} -> {next, next}
          :done -> nil
        end
      end)
      |> Enum.count()

    assert windows == Limits.max_speech_checks() - 1
  end

  test "stages move only through the named ones" do
    ending = Ending.new(:deadline)
    assert Ending.put_stage(ending, :hangup).stage == :hangup
    assert_raise FunctionClauseError, fn -> Ending.put_stage(ending, :later) end
  end
end
