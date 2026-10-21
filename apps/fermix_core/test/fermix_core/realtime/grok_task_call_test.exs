defmodule FermixCore.Realtime.GrokTaskCallTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.GrokTaskCall

  describe "tool/0" do
    test "registers exactly one function with the action enum and no extra fields" do
      tool = GrokTaskCall.tool()

      assert tool.type == "function"
      assert tool.name == "fermix_task"
      assert tool.parameters.properties.action.enum == ["submit", "cancel"]
      assert tool.parameters.required == ["action"]
      assert tool.parameters.additionalProperties == false
      assert Jason.encode!(tool) =~ "fermix_task"
    end
  end

  describe "parse/1" do
    test "a submit carries its trimmed request and no task id" do
      assert GrokTaskCall.parse(~s({"action":"submit","request":"  book the room at ten  "})) ==
               {:ok, {:submit, "book the room at ten", nil}}
    end

    test "a submit naming a task replaces it" do
      assert GrokTaskCall.parse(~s({"action":"submit","request":"make it eleven","task_id":"t1"})) ==
               {:ok, {:submit, "make it eleven", "t1"}}
    end

    test "a cancel needs the task it names" do
      assert GrokTaskCall.parse(~s({"action":"cancel","task_id":"t1"})) == {:ok, {:cancel, "t1"}}
      assert GrokTaskCall.parse(~s({"action":"cancel"})) == {:error, :missing_task_id}
    end

    test "refuses what the contract does not allow" do
      assert GrokTaskCall.parse("not json") == {:error, :invalid_json}
      assert GrokTaskCall.parse(~s(["submit"])) == {:error, :not_an_object}
      assert GrokTaskCall.parse(~s({"action":"delete"})) == {:error, :unknown_action}
      assert GrokTaskCall.parse(~s({"request":"x"})) == {:error, :unknown_action}
      assert GrokTaskCall.parse(~s({"action":"submit"})) == {:error, :missing_request}

      assert GrokTaskCall.parse(~s({"action":"submit","request":"   "})) ==
               {:error, :missing_request}

      assert GrokTaskCall.parse(~s({"action":"submit","request":7})) == {:error, :missing_request}

      assert GrokTaskCall.parse(~s({"action":"submit","request":"x","device_id":"mine"})) ==
               {:error, :unknown_field}

      assert GrokTaskCall.parse(~s({"action":"cancel","task_id":""})) ==
               {:error, :invalid_task_id}

      assert GrokTaskCall.parse(~s({"action":"cancel","task_id":3})) == {:error, :invalid_task_id}
    end

    test "bounds the arguments at 8 KiB and the request at 4 KiB" do
      request = String.duplicate("a", 4_097)

      assert GrokTaskCall.parse(Jason.encode!(%{action: "submit", request: request})) ==
               {:error, :request_too_large}

      padded =
        Jason.encode!(%{action: "submit", request: "x", task_id: "t1"}) <>
          String.duplicate(" ", 8_192)

      assert GrokTaskCall.parse(padded) == {:error, :arguments_too_large}
    end
  end

  describe "output/2" do
    test "is one JSON object with its status, dropping absent fields" do
      json = GrokTaskCall.output("completed", %{task_id: "t1", result: "Booked.", message: nil})

      assert Jason.decode!(json) == %{
               "status" => "completed",
               "task_id" => "t1",
               "result" => "Booked."
             }
    end

    test "refuses a status outside the contract" do
      assert_raise FunctionClauseError, fn -> GrokTaskCall.output("done", %{}) end
    end
  end
end
