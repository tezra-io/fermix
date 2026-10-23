defmodule FermixCore.Cues.Filter.AnswerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Filter.Answer

  describe "a valid answer" do
    test "pass with a reason and a hint" do
      assert {:pass, "It names a release.", "check the changelog"} =
               Answer.parse(
                 ~s({"decision": "pass", "reason": "It names a release.", "hint": "check the changelog"})
               )
    end

    test "drop with a reason; a hint on a drop is ignored" do
      assert {:drop, "Off topic."} =
               Answer.parse(~s({"decision": "drop", "reason": "Off topic.", "hint": "x"}))
    end

    test "a missing, null or blank hint is nil" do
      assert {:pass, "Yes.", nil} = Answer.parse(~s({"decision": "pass", "reason": "Yes."}))

      assert {:pass, "Yes.", nil} =
               Answer.parse(~s({"decision": "pass", "reason": "Yes.", "hint": null}))

      assert {:pass, "Yes.", nil} =
               Answer.parse(~s({"decision": "pass", "reason": "Yes.", "hint": "  "}))
    end

    test "the decision word is read without case or surrounding space" do
      assert {:drop, "No."} = Answer.parse(~s({"decision": " DROP ", "reason": "No."}))
    end

    test "prose and a code fence around the object are tolerated" do
      reply = """
      Here is my answer:
      ```json
      {"decision": "pass", "reason": "Security advisory."}
      ```
      """

      assert {:pass, "Security advisory.", nil} = Answer.parse(reply)
    end

    test "the first JSON object wins; braces in prose before it are skipped" do
      reply =
        ~s(Thinking {not json} then {"decision": "drop", "reason": "Old news."} ) <>
          ~s({"decision": "pass", "reason": "second"})

      assert {:drop, "Old news."} = Answer.parse(reply)
    end

    test "braces and quotes inside strings do not end the object early" do
      reply = ~s({"decision": "pass", "reason": "It says \\"}\\" in the title {a}."})
      assert {:pass, ~s(It says "}" in the title {a}.), nil} = Answer.parse(reply)
    end
  end

  describe "limits are cut, not refused" do
    test "a reason over 200 characters is cut to 200" do
      long = String.duplicate("a", 450)

      assert {:pass, reason, nil} =
               Answer.parse(Jason.encode!(%{"decision" => "pass", "reason" => long}))

      assert String.length(reason) == 200
    end

    test "a hint over 500 characters is cut to 500" do
      long = String.duplicate("h", 900)

      assert {:pass, "Yes.", hint} =
               Answer.parse(
                 Jason.encode!(%{"decision" => "pass", "reason" => "Yes.", "hint" => long})
               )

      assert String.length(hint) == 500
    end
  end

  describe "an invalid answer is a content failure, never a guess" do
    test "no JSON object at all" do
      assert {:error, :invalid_answer, _detail} = Answer.parse("I think this should pass.")
      assert {:error, :invalid_answer, _detail} = Answer.parse("")
    end

    test "an object that does not decode" do
      assert {:error, :invalid_answer, _detail} =
               Answer.parse(~s({"decision": "pass", "reason": }))
    end

    test "a JSON array or scalar is not an answer" do
      assert {:error, :invalid_answer, _detail} = Answer.parse(~s(["pass"]))
      assert {:error, :invalid_answer, _detail} = Answer.parse(~s("pass"))
    end

    test "a decision other than pass or drop" do
      assert {:error, :invalid_answer, detail} =
               Answer.parse(~s({"decision": "maybe", "reason": "Unsure."}))

      assert detail =~ "pass or drop"
      assert {:error, :invalid_answer, _detail} = Answer.parse(~s({"reason": "No decision."}))
      assert {:error, :invalid_answer, _detail} = Answer.parse(~s({"decision": true}))
    end

    test "an empty or missing reason" do
      assert {:error, :invalid_answer, detail} =
               Answer.parse(~s({"decision": "pass", "reason": "  "}))

      assert detail =~ "reason"
      assert {:error, :invalid_answer, _detail} = Answer.parse(~s({"decision": "pass"}))
    end

    test "a hint that is not text" do
      assert {:error, :invalid_answer, _detail} =
               Answer.parse(~s({"decision": "pass", "reason": "Yes.", "hint": 7}))
    end

    test "a repeated key is ambiguous and refused" do
      assert {:error, :invalid_answer, _detail} =
               Answer.parse(~s({"decision": "pass", "decision": "drop", "reason": "Two."}))
    end

    test "the detail never echoes the reply's text" do
      reply = ~s({"decision": "secret-word", "reason": "planted"})
      assert {:error, :invalid_answer, detail} = Answer.parse(reply)
      refute detail =~ "secret-word"
      refute detail =~ "planted"
    end
  end
end
