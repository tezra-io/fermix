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
        {:ok, "answer from " <> Enum.map_join(verified, ",", & &1.id)}
      end,
      deliver: deliver_to(self())
    }

    assert {:ok, "answer from a"} = UltraOrchestrator.run("plan a trip", deps)
  end

  test "verify runs concurrently when verify_concurrency > 1, preserving order + filtering" do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, max: 0} end)
    findings = for n <- 1..6, do: %{id: "f#{n}", task: "t#{n}"}

    deps = %{
      decompose: fn _ -> {:fanout, findings} end,
      fanout: fn subs -> Enum.map(subs, &%{id: &1.id, output: "o-#{&1.id}"}) end,
      verify: fn finding ->
        Agent.update(tracker, fn s -> %{active: s.active + 1, max: max(s.max, s.active + 1)} end)
        Process.sleep(30)
        Agent.update(tracker, fn s -> %{s | active: s.active - 1} end)
        # drop f3 to prove filtering still holds under concurrency
        finding.id != "f3"
      end,
      synthesize: fn _p, verified -> {:ok, Enum.map_join(verified, ",", & &1.id)} end,
      verify_concurrency: 4,
      deliver: deliver_to(self())
    }

    assert {:ok, "f1,f2,f4,f5,f6"} = UltraOrchestrator.run("q", deps)
    assert Agent.get(tracker, & &1.max) > 1
  end

  test "a verify that raises drops only that finding, never crashes the turn" do
    findings = for n <- 1..5, do: %{id: "f#{n}", task: "t#{n}"}

    deps = %{
      decompose: fn _ -> {:fanout, findings} end,
      fanout: fn subs -> Enum.map(subs, &%{id: &1.id, output: "o-#{&1.id}"}) end,
      verify: fn
        %{id: "f3"} -> raise "verify boom"
        _ -> true
      end,
      synthesize: fn _p, verified -> {:ok, Enum.map_join(verified, ",", & &1.id)} end,
      verify_concurrency: 4,
      deliver: deliver_to(self())
    }

    # f3's verify raises; the turn survives, f3 is dropped, order is preserved.
    assert {:ok, "f1,f2,f4,f5"} = UltraOrchestrator.run("q", deps)
  end

  test "narrates each stage as progress" do
    deps = %{
      decompose: fn _ -> {:fanout, [%{id: "a", task: "t"}]} end,
      fanout: fn _ -> [%{id: "a", output: "o"}] end,
      verify: fn _ -> true end,
      synthesize: fn _, _ -> {:ok, "done"} end,
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
        {:ok, "should not run"}
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
      synthesize: fn _prompt, [] -> {:ok, "direct answer"} end,
      deliver: deliver_to(self())
    }

    assert {:ok, "direct answer"} = UltraOrchestrator.run("trivial", deps)
    refute_received :fanned_out
  end

  test "a decompose provider failure surfaces as {:error, reason}, no fan-out" do
    test_pid = self()

    deps = %{
      decompose: fn _ -> {:error, :no_auth_file} end,
      fanout: fn _ ->
        send(test_pid, :fanned_out)
        []
      end,
      verify: fn _ -> true end,
      synthesize: fn _, _ -> {:ok, "should not run"} end,
      deliver: deliver_to(self())
    }

    assert {:error, :no_auth_file} = UltraOrchestrator.run("q", deps)
    refute_received :fanned_out
  end

  test "a synthesize provider failure surfaces as {:error, reason}, not empty success" do
    deps = %{
      decompose: fn _ -> {:fanout, [%{id: "a", task: "t"}]} end,
      fanout: fn _ -> [%{id: "a", output: "o"}] end,
      verify: fn _ -> true end,
      synthesize: fn _, _ -> {:error, :refresh_failed} end,
      deliver: deliver_to(self())
    }

    assert {:error, :refresh_failed} = UltraOrchestrator.run("q", deps)
  end
end
