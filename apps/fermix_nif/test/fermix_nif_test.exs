defmodule FermixNifTest do
  use ExUnit.Case, async: false

  # Bounded liveness polling: an Erlang port child is its own process-group
  # leader, so its os_pid is a usable pgid. Death is asserted by polling
  # `kill -0` until ESRCH rather than sleeping a fixed duration.
  @poll_max 50
  @poll_ms 100

  describe "kill_pgid/2 signals a real process group" do
    test "SIGKILL reaps a live group and returns :ok" do
      {_port, os_pid} = spawn_sleeper()
      on_exit(fn -> liveness_gated_kill(os_pid) end)

      assert await_group(os_pid) == :present
      assert FermixNif.kill_pgid(os_pid, :sigkill) == :ok
      assert await_death(os_pid) == :dead
    end

    test "signalling a dead group returns {:error, :esrch}" do
      {_port, os_pid} = spawn_sleeper()
      on_exit(fn -> liveness_gated_kill(os_pid) end)

      assert await_group(os_pid) == :present
      assert FermixNif.kill_pgid(os_pid, :sigkill) == :ok
      assert await_death(os_pid) == :dead

      assert FermixNif.kill_pgid(os_pid, :sigkill) == {:error, :esrch}
    end
  end

  describe "kill_pgid/2 guards" do
    test "rejects a zero pgid" do
      assert_raise FunctionClauseError, fn -> FermixNif.kill_pgid(0, :sigkill) end
    end

    test "rejects a negative pgid" do
      assert_raise FunctionClauseError, fn -> FermixNif.kill_pgid(-1, :sigkill) end
    end

    test "rejects an unsupported signal atom" do
      {_port, os_pid} = spawn_sleeper()
      on_exit(fn -> liveness_gated_kill(os_pid) end)

      assert_raise FunctionClauseError, fn -> FermixNif.kill_pgid(os_pid, :sighup) end
    end
  end

  defp spawn_sleeper do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep 30"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp alive?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  # The port child's setpgid can lag the os_pid read, so the group may not exist
  # for a moment after spawn. `kill -0 -- -<pgid>` probes the group (status 0
  # once a member exists).
  defp group_exists?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true)

    status == 0
  end

  defp await_group(os_pid) do
    Enum.reduce_while(1..@poll_max, :absent, fn _attempt, _acc ->
      if group_exists?(os_pid) do
        {:halt, :present}
      else
        Process.sleep(@poll_ms)
        {:cont, :absent}
      end
    end)
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
