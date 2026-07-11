defmodule Fermix.CLI.Service.LaunchdTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Service.Launchd

  @svc %{scope: :user, label: "io.tezra.fermix"}

  # Tiny grace + no-op sleep so the SIGTERM->SIGKILL escalation runs in a couple of
  # polls with no real waiting (term_grace/poll = 2 polls, kill_grace/poll = 1).
  setup do
    Application.put_env(:fermix_core, :launchd_stop,
      poll_ms: 1,
      term_grace_ms: 2,
      kill_grace_ms: 1,
      sleep_fun: fn _ -> :ok end
    )

    on_exit(fn ->
      Application.delete_env(:fermix_core, :launchctl_runner)
      Application.delete_env(:fermix_core, :launchd_stop)
    end)

    :ok
  end

  # A stateful launchctl stub. `print` reports the job pid, which "dies" — reported as
  # a NEW pid (the KeepAlive relaunch) — after the signal named by `:dies_after`
  # (:term | :kill | :never | :not_running). Every argv is recorded for assertions.
  defp install_stub(dies_after) do
    {:ok, agent} = Agent.start_link(fn -> %{term: 0, kill: 0, calls: []} end)

    runner = fn "launchctl", args ->
      Agent.update(agent, fn s -> %{s | calls: s.calls ++ [args]} end)

      case args do
        ["print" | _] -> {print_output(Agent.get(agent, & &1), dies_after), 0}
        ["kill", "TERM" | _] -> Agent.update(agent, &%{&1 | term: &1.term + 1}) && {"", 0}
        ["kill", "KILL" | _] -> Agent.update(agent, &%{&1 | kill: &1.kill + 1}) && {"", 0}
        _ -> {"", 0}
      end
    end

    Application.put_env(:fermix_core, :launchctl_runner, runner)
    agent
  end

  defp print_output(_state, :not_running), do: ""
  defp print_output(%{term: t}, :term) when t > 0, do: "\tpid = 200\n"
  defp print_output(%{kill: k}, :kill) when k > 0, do: "\tpid = 200\n"
  defp print_output(_state, _dies_after), do: "\tpid = 100\n"

  defp calls(agent), do: Agent.get(agent, & &1.calls)
  defp sent?(calls, signal), do: Enum.any?(calls, &match?(["kill", ^signal | _], &1))

  test "start uses plain kickstart — never -k, which SIGKILLs the running daemon" do
    Application.put_env(:fermix_core, :launchctl_runner, fn "launchctl", args ->
      send(self(), {:launchctl, args})
      {"", 0}
    end)

    assert :ok = Launchd.start(@svc)
    assert_received {:launchctl, args}
    assert "kickstart" in args
    refute "-k" in args, "start must not SIGKILL a running instance (the -9 relaunch loop)"
  end

  test "stop sends SIGTERM and returns :ok once the process exits — no SIGKILL needed" do
    agent = install_stub(:term)

    assert :ok = Launchd.stop(@svc)

    calls = calls(agent)
    assert sent?(calls, "TERM")
    refute sent?(calls, "KILL"), "a clean SIGTERM exit must not escalate"
  end

  test "stop escalates to SIGKILL when SIGTERM does not kill within the grace" do
    agent = install_stub(:kill)

    assert :ok = Launchd.stop(@svc)

    calls = calls(agent)
    assert sent?(calls, "TERM")
    assert sent?(calls, "KILL"), "a stalled SIGTERM must escalate to SIGKILL"
  end

  test "stop fails loud with the surviving pid when even SIGKILL cannot cycle it" do
    agent = install_stub(:never)

    assert {:error, {:stop_failed, 100}} = Launchd.stop(@svc)

    calls = calls(agent)
    assert sent?(calls, "TERM") and sent?(calls, "KILL")
  end

  test "stop is a harmless no-op when nothing is running (no pid to escalate against)" do
    agent = install_stub(:not_running)

    assert :ok = Launchd.stop(@svc)

    calls = calls(agent)
    assert sent?(calls, "TERM")
    refute sent?(calls, "KILL")
  end

  test "stop stays a graceful no-op when launchd reports the job is not loaded" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Application.put_env(:fermix_core, :launchctl_runner, fn "launchctl", args ->
      Agent.update(agent, &(&1 ++ [args]))

      case args do
        # launchd's stable "not loaded" reply (non-zero exit) must read as
        # "nothing to stop", not as an error.
        ["print" | _] -> {~s(Could not find service "io.tezra.fermix" in domain for user), 113}
        _ -> {"", 0}
      end
    end)

    assert :ok = Launchd.stop(@svc)

    calls = Agent.get(agent, & &1)
    assert Enum.any?(calls, &match?(["kill", "TERM" | _], &1))
    refute Enum.any?(calls, &match?(["kill", "KILL" | _], &1))
  end

  test "stop surfaces a launchctl print failure instead of assuming the daemon is gone" do
    # A genuine query failure (privileges, a launchd hiccup) is NOT "not loaded":
    # `stop` cannot prove the daemon is gone, so it must fail loud, not return :ok.
    Application.put_env(:fermix_core, :launchctl_runner, fn "launchctl", args ->
      case args do
        ["print" | _] -> {"Bootstrap failed: 5: Input/output error", 5}
        _ -> {"", 0}
      end
    end)

    assert {:error, {:launchctl_failed, 5, _}} = Launchd.stop(@svc)
  end

  test "a transient print failure mid-shutdown is never read as a clean exit" do
    {:ok, agent} = Agent.start_link(fn -> %{prints: 0, kill: 0} end)

    runner = fn "launchctl", args ->
      case args do
        ["print" | _] ->
          n = Agent.get_and_update(agent, fn s -> {s.prints, %{s | prints: s.prints + 1}} end)
          # First read establishes the running pid; every later read fails
          # transiently — which must NOT masquerade as the process exiting.
          if n == 0,
            do: {"\tpid = 100\n", 0},
            else: {"launchctl print: transient error", 1}

        ["kill", "KILL" | _] ->
          Agent.update(agent, &%{&1 | kill: &1.kill + 1})
          {"", 0}

        _ ->
          {"", 0}
      end
    end

    Application.put_env(:fermix_core, :launchctl_runner, runner)

    assert {:error, {:stop_failed, 100}} = Launchd.stop(@svc)

    assert Agent.get(agent, & &1.kill) >= 1,
           "must escalate to SIGKILL, not trust a failed read as exit"
  end
end
