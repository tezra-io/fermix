defmodule FermixCore.Agents.UltraStagesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.UltraStages

  describe "parse_decomposition/3" do
    test "parses a JSON array of subtasks" do
      json = ~s([{"id":"flights","task":"find flights"},{"id":"hotels","task":"find hotels"}])

      assert {:fanout,
              [%{id: "flights", task: "find flights"}, %{id: "hotels", task: "find hotels"}]} =
               UltraStages.parse_decomposition(json, "plan a trip", 12)
    end

    test "tolerates prose wrapped around the JSON array" do
      text = ~s(Sure! Here is the plan:\n[{"id":"a","task":"do a"}]\nLet me know.)

      assert {:fanout, [%{id: "a", task: "do a"}]} =
               UltraStages.parse_decomposition(text, "p", 12)
    end

    test "recognizes a CLARIFY response" do
      assert {:clarify, "Which city and dates?"} =
               UltraStages.parse_decomposition("CLARIFY: Which city and dates?", "trip", 12)
    end

    test "degrades a malformed response to a single subtask (never crashes)" do
      assert {:fanout, [%{id: "1", task: "the whole prompt"}]} =
               UltraStages.parse_decomposition("not json at all", "the whole prompt", 12)
    end

    test "caps at the passed max_subtasks" do
      json = 1..12 |> Enum.map(&%{"id" => "#{&1}", "task" => "t#{&1}"}) |> Jason.encode!()
      assert {:fanout, subtasks} = UltraStages.parse_decomposition(json, "p", 5)
      assert length(subtasks) == 5
    end

    test "drops malformed items (no task) but keeps the rest" do
      json = ~s([{"id":"a","task":"keep me"},{"id":"b"},{"task":""}])

      assert {:fanout, [%{id: "a", task: "keep me"}]} =
               UltraStages.parse_decomposition(json, "p", 12)
    end
  end

  describe "parse_findings/1" do
    test "extracts id + output from the subagents results shape" do
      json =
        ~s({"status":"completed","results":[{"id":"a","output":"found a"},{"id":"b","output":"found b"}]})

      assert [%{id: "a", output: "found a"}, %{id: "b", output: "found b"}] =
               UltraStages.parse_findings(json)
    end

    test "falls back to error text when output is nil" do
      json = ~s({"results":[{"id":"a","output":null,"error":"boom"}]})
      assert [%{id: "a", output: "boom"}] = UltraStages.parse_findings(json)
    end

    test "returns [] for malformed json" do
      assert [] = UltraStages.parse_findings("garbage")
    end
  end

  describe "verified?/1" do
    test "keeps supported findings" do
      assert UltraStages.verified?("yes, well supported")
      assert UltraStages.verified?("This is VALID.")
    end

    test "drops unsupported findings" do
      refute UltraStages.verified?("no")
      refute UltraStages.verified?("not enough evidence")
    end

    test "drops NEGATED affirmatives (a bare keyword match wrongly kept these)" do
      refute UltraStages.verified?("not supported")
      refute UltraStages.verified?("no, this is not valid")
      refute UltraStages.verified?("This finding is not valid.")
      refute UltraStages.verified?("isn't supported by the evidence")
    end

    test "keeps an affirmative that merely contains 'no' (e.g. 'no issues')" do
      assert UltraStages.verified?("yes, well supported, no issues")
    end
  end

  test "synthesize_user/3 folds the verified findings in, tagged by probe id" do
    content =
      UltraStages.synthesize_user("plan a trip", [%{id: "a", output: "fly SFO->TYO"}], 2_000)

    assert content =~ "plan a trip"
    assert content =~ "[a] fly SFO->TYO"
  end

  test "synthesize_user/3 caps each finding's output at max_finding_bytes" do
    long = String.duplicate("x", 5_000)
    content = UltraStages.synthesize_user("q", [%{id: "a", output: long}], 100)
    # the tagged finding survives, but its body is truncated to the cap
    assert content =~ "[a] "
    refute content =~ long
    assert byte_size(content) < 1_000
  end
end
