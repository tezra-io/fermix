defmodule FermixCore.CommandHostTest do
  # async: false — each test spawns a real OS process group and polls it; the
  # supervisor is per-test (never the global one) so tests stay isolated, but
  # timing is steadier run serially.
  use ExUnit.Case, async: false

  alias FermixCore.CommandRunner

  # Bounded liveness polling (mirrors fermix_nif_test): the port child is its own
  # process-group leader, and each grandchild writes its own pid to a file. Death
  # is asserted by polling `kill -0` until it fails, never a fixed sleep.
  @poll_max 50
  @poll_ms 100

  setup do
    sh = System.find_executable("sh") || "/bin/sh"
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("command-host")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    %{sh: sh, dir: dir}
  end

  test "requester killed mid-command sweeps a forked grandchild", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "grandchild.pid")

    requester =
      spawn(fn ->
        CommandRunner.run(sh, trapping_grandchild_cmd(pidfile),
          supervised: true,
          dynamic_supervisor: sup,
          timeout_ms: 30_000
        )
      end)

    grandchild = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    # Brutally kill the requester: closing an Erlang port sends no OS signal, so
    # on today's code the grandchild would orphan. The host's requester monitor
    # must fire and group-SIGKILL it.
    Process.exit(requester, :kill)

    assert await_death(grandchild) == :dead
  end

  test "timeout path reaps a TERM-trapping fd-closing grandchild", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "grandchild.pid")
    test = self()

    spawn(fn ->
      result =
        CommandRunner.run(sh, trapping_grandchild_cmd(pidfile),
          supervised: true,
          dynamic_supervisor: sup,
          timeout_ms: 1_000,
          kill_grace_ms: 200
        )

      send(test, {:result, result})
    end)

    grandchild = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    # The grandchild ignores SIGTERM; only the unconditional post-drain SIGKILL
    # reaps it. Old code gated the KILL on the direct child's exit and let it escape.
    assert await_death(grandchild) == :dead
    assert_receive {:result, {:error, {:timeout, 1_000}}}, 5_000
  end

  test "success path sweeps a backgrounded straggler", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "straggler.pid")
    test = self()

    spawn(fn ->
      result =
        CommandRunner.run(sh, success_straggler_cmd(pidfile),
          supervised: true,
          dynamic_supervisor: sup,
          timeout_ms: 30_000
        )

      send(test, {:result, result})
    end)

    straggler = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(straggler) end)

    # The command exits 0, leaving a fd-closed background child. Exit-ending
    # sweep is an immediate group-SIGKILL — any survivor is a leak by definition.
    assert await_death(straggler) == :dead
    assert_receive {:result, {:ok, %{exit: 0, truncated?: false}}}, 5_000
  end

  test "supervisor shutdown sweeps an in-flight command", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "grandchild.pid")

    spawn(fn ->
      CommandRunner.run(sh, trapping_grandchild_cmd(pidfile),
        supervised: true,
        dynamic_supervisor: sup,
        timeout_ms: 30_000
      )
    end)

    grandchild = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    # Stopping the supervisor with a live host runs the host's terminate/2 sweep.
    :ok = DynamicSupervisor.stop(sup)

    assert await_death(grandchild) == :dead
  end

  test "a host crash surfaces to the caller as command_host_crashed", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "sleeper.pid")
    test = self()

    spawn(fn ->
      result =
        CommandRunner.run(sh, ["-c", "echo $$ > #{pidfile}; exec sleep 30"],
          supervised: true,
          dynamic_supervisor: sup,
          timeout_ms: 30_000
        )

      send(test, {:result, result})
    end)

    sleeper = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(sleeper) end)

    # Killing the host directly is untrappable — terminate/2 does not run, so the
    # group leaks (accepted §8 host-crash non-goal, cleaned up above). The caller
    # must still learn promptly, never hang.
    host = await_host_child(sup)
    Process.exit(host, :kill)

    assert_receive {:result, {:error, {:command_host_crashed, :killed}}}, 5_000
  end

  # A trapping, fd-closing grandchild: writes its own pid, ignores SIGTERM, closes
  # fds (so it never holds the port open), then loops. Only SIGKILL reaps it. `$$`
  # inside the single-quoted inner script is expanded by the inner sh, so the
  # pidfile carries the grandchild's pid.
  defp trapping_grandchild_cmd(pidfile) do
    inner =
      ~s(trap "" TERM; echo $$ > #{pidfile}; exec 0<&- 1>&- 2>&-; while true; do sleep 1; done)

    ["-c", ~s(sh -c '#{inner}' & wait)]
  end

  # A fd-closed background straggler; the outer sh waits until the pidfile exists
  # (so the straggler's pid is recorded before we can miss it) then exits 0.
  defp success_straggler_cmd(pidfile) do
    inner = ~s(echo $$ > #{pidfile}; exec 0<&- 1>&- 2>&-; while true; do sleep 1; done)

    ["-c", ~s(sh -c '#{inner}' & until [ -s #{pidfile} ]; do sleep 0.02; done; exit 0)]
  end

  defp start_host_sup do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(sup), do: DynamicSupervisor.stop(sup) end)
    sup
  end

  defp await_host_child(sup) do
    Enum.reduce_while(1..@poll_max, nil, fn _attempt, _acc ->
      case DynamicSupervisor.which_children(sup) do
        [{_id, pid, _type, _mods} | _] when is_pid(pid) ->
          {:halt, pid}

        _none ->
          Process.sleep(@poll_ms)
          {:cont, nil}
      end
    end) || flunk("no host child appeared under the supervisor")
  end

  defp await_pidfile(path) do
    Enum.reduce_while(1..@poll_max, nil, fn _attempt, _acc ->
      case read_pid(path) do
        {:ok, pid} ->
          {:halt, pid}

        :error ->
          Process.sleep(@poll_ms)
          {:cont, nil}
      end
    end) || flunk("pidfile never appeared: #{path}")
  end

  defp read_pid(path) do
    with {:ok, content} <- File.read(path),
         {pid, _rest} <- Integer.parse(String.trim(content)) do
      {:ok, pid}
    else
      _absent_or_empty -> :error
    end
  end

  defp alive?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  defp await_death(os_pid) do
    Enum.reduce_while(1..@poll_max, :alive, fn _attempt, _acc ->
      if alive?(os_pid) do
        Process.sleep(@poll_ms)
        {:cont, :alive}
      else
        {:halt, :dead}
      end
    end)
  end

  defp liveness_gated_kill(os_pid) do
    if alive?(os_pid) do
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
