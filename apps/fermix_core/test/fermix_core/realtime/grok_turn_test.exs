defmodule FermixCore.Realtime.GrokTurnTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.GrokTurn

  # A response that carried one call, done, with its output sent.
  defp answered_response(turn, response_id, call_id) do
    turn = GrokTurn.response_created(turn, response_id, nil)
    {:ok, turn} = GrokTurn.function_call(turn, response_id, call_id)
    turn |> GrokTurn.response_done(response_id) |> GrokTurn.answered(call_id)
  end

  describe "function_call/3" do
    test "a call id is run once for the whole call" do
      turn = GrokTurn.response_created(GrokTurn.new(), "r1", nil)
      assert {:ok, turn} = GrokTurn.function_call(turn, "r1", "call_1")
      assert {:duplicate, _turn} = GrokTurn.function_call(turn, "r1", "call_1")
      assert {:duplicate, _turn} = GrokTurn.function_call(turn, "r2", "call_1")
    end

    test "a response carries at most eight calls" do
      turn = GrokTurn.response_created(GrokTurn.new(), "r1", nil)

      turn =
        Enum.reduce(1..8, turn, fn n, acc ->
          {:ok, acc} = GrokTurn.function_call(acc, "r1", "call_#{n}")
          acc
        end)

      assert {:too_many, _turn} = GrokTurn.function_call(turn, "r1", "call_9")
    end

    test "past 1,024 remembered ids the call is exhausted rather than forgetful" do
      turn =
        Enum.reduce(1..1_024, GrokTurn.new(), fn n, acc ->
          {_status, acc} = GrokTurn.function_call(acc, "r#{div(n, 8)}", "call_#{n}")
          acc
        end)

      assert {:exhausted, _turn} = GrokTurn.function_call(turn, "r_last", "call_new")
    end
  end

  describe "the continuation" do
    test "is owed once a done response's every call is answered, and due when nothing stands in the way" do
      turn = GrokTurn.response_created(GrokTurn.new(), "r1", nil)
      {:ok, turn} = GrokTurn.function_call(turn, "r1", "a")
      {:ok, turn} = GrokTurn.function_call(turn, "r1", "b")
      turn = GrokTurn.response_done(turn, "r1")

      turn = GrokTurn.answered(turn, "a")
      refute GrokTurn.due?(turn, true)

      turn = GrokTurn.answered(turn, "b")
      assert GrokTurn.due?(turn, true)
      refute GrokTurn.due?(turn, false)
    end

    test "is not due while the owner speaks, while a response runs, or before VAD's own response" do
      turn = answered_response(GrokTurn.new(), "r1", "a")
      assert GrokTurn.due?(turn, true)

      refute turn |> GrokTurn.speech_started() |> GrokTurn.due?(true)
      refute turn |> GrokTurn.response_created("r2", %{"x" => "y"}) |> GrokTurn.due?(true)

      after_speech = turn |> GrokTurn.speech_started() |> GrokTurn.speech_stopped()
      refute GrokTurn.due?(after_speech, true)
      assert after_speech |> GrokTurn.vad_grace_over() |> GrokTurn.due?(true)
    end

    test "a response Grok starts on its own consumes what was owed: one answer per result" do
      turn = answered_response(GrokTurn.new(), "r1", "a")
      turn = turn |> GrokTurn.response_created("vad_2", nil) |> GrokTurn.response_done("vad_2")
      refute GrokTurn.due?(turn, true)
    end

    test "its own response fulfils the request, and a result owed meanwhile stays owed" do
      turn = GrokTurn.new()

      turn =
        Enum.reduce([{"r1", "a"}, {"r2", "b"}], turn, fn {response, call}, acc ->
          acc = GrokTurn.response_created(acc, response, nil)
          {:ok, acc} = GrokTurn.function_call(acc, response, call)
          GrokTurn.response_done(acc, response)
        end)

      turn = GrokTurn.answered(turn, "a")
      {id, turn} = GrokTurn.request(turn)
      assert GrokTurn.requested(turn) == id

      # The second result is answered while the first continuation is asked for.
      turn = GrokTurn.answered(turn, "b")
      refute GrokTurn.due?(turn, true)

      turn =
        turn
        |> GrokTurn.response_created("r3", %{"fermix_continuation" => id})
        |> GrokTurn.response_done("r3")

      assert GrokTurn.requested(turn) == nil
      assert GrokTurn.due?(turn, true)
    end

    test "a request that never started is owed again, at most twice" do
      turn = answered_response(GrokTurn.new(), "r1", "a")
      {_id, turn} = GrokTurn.request(turn)
      assert {:retry, turn} = GrokTurn.request_failed(turn)
      assert GrokTurn.due?(turn, true)

      {_id, turn} = GrokTurn.request(turn)
      assert {:gave_up, turn} = GrokTurn.request_failed(turn)
      refute GrokTurn.due?(turn, true)
      assert {:none, _turn} = GrokTurn.request_failed(turn)
    end

    test "a response with no call owes nothing" do
      turn =
        GrokTurn.new() |> GrokTurn.response_created("r1", nil) |> GrokTurn.response_done("r1")

      refute GrokTurn.due?(turn, true)
    end
  end

  describe "fence/2" do
    test "an interrupted response is fenced and no longer cancellable" do
      turn = GrokTurn.response_created(GrokTurn.new(), "r1", nil)
      assert GrokTurn.cancellable(turn) == ["r1"]

      turn = GrokTurn.fence(turn, "r1")
      assert GrokTurn.fenced?(turn, "r1")
      assert GrokTurn.cancellable(turn) == []
      assert GrokTurn.active(turn) == ["r1"]
    end
  end
end
