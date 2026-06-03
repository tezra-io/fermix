defmodule FermixCore.Agents.UltraOrchestratorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.UltraOrchestrator

  defp deliver_to(pid), do: fn {:text, text} -> send(pid, {:progress, text}) end

  test "runs decompose → fan out → verify → synthesize, dropping unverified findings" do
    deps = %{
      decompose: fn _prompt -> {:fanout, [%{id: "a", task: "do a"}, %{id: "b", task: "do b"}]} end,
      fanout: fn subtasks -> Enum.map(subtasks, &%{id: &1.id, output: "found #{&1.id}"}) end,
      # verification drops finding "b"
      verify: fn finding -> finding.id != "b" end,
      synthesize: fn _prompt, verified ->
        "answer from " <> Enum.map_join(verified, ",", & &1.id)
      end,
      deliver: deliver_to(self())
    }

    assert {:ok, "answer from a"} = UltraOrchestrator.run("plan a trip", deps)
  end

  test "narrates each stage as progress" do
    deps = %{
      decompose: fn _ -> {:fanout, [%{id: "a", task: "t"}]} end,
      fanout: fn _ -> [%{id: "a", output: "o"}] end,
      verify: fn _ -> true end,
      synthesize: fn _, _ -> "done" end,
      deliver: deliver_to(self())
    }

    assert {:ok, "done"} = UltraOrchestrator.run("q", deps)

    assert_receive {:progress, p1}
    assert p1 =~ "decomposing"
    assert_receive {:progress, p2}
    assert p2 =~ "parallel"
    assert_receive {:progress, p3}
    assert p3 =~ "Verifying"
    assert_receive {:progress, p4}
    assert p4 =~ "Synthesizing"
  end

  test "clarify-before-fanout ends with questions and never fans out" do
    test_pid = self()

    deps = %{
      decompose: fn _ -> {:clarify, "Which city and dates?"} end,
      fanout: fn _ ->
        send(test_pid, :fanned_out)
        []
      end,
      verify: fn _ -> true end,
      synthesize: fn _, _ ->
        send(test_pid, :synthesized)
        "should not run"
      end,
      deliver: deliver_to(self())
    }

    assert {:ok, "Which city and dates?"} = UltraOrchestrator.run("a vague trip", deps)
    refute_received :fanned_out
    refute_received :synthesized
  end

  test "an empty decomposition synthesizes directly without fanning out" do
    test_pid = self()

    deps = %{
      decompose: fn _ -> {:fanout, []} end,
      fanout: fn _ ->
        send(test_pid, :fanned_out)
        []
      end,
      verify: fn _ -> true end,
      synthesize: fn _prompt, [] -> "direct answer" end,
      deliver: deliver_to(self())
    }

    assert {:ok, "direct answer"} = UltraOrchestrator.run("trivial", deps)
    refute_received :fanned_out
  end
end
