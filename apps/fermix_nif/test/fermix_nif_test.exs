defmodule FermixNifTest do
  use ExUnit.Case, async: false

  # Bounded liveness polling: an Erlang port child is its own process-group
  # leader, so its os_pid is a usable pgid. Death is asserted by polling
  # `kill -0` until ESRCH rather than sleeping a fixed duration.
  @poll_max 50
  @poll_ms 100

  # Beyond every platform's pid ceiling (macOS 99998, Linux ≤ 2^22), so no live
  # group can ever carry it: kill(2) answers ESRCH deterministically and the
  # probe signals nothing real.
  @absent_pgid 999_999_999

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

  # The flag lives on the terminal stdin is attached to, so this VM never calls
  # set_stdin_echo/1 with a boolean: under an interactive `mix test` that would
  # flip the developer's own terminal. A child VM whose stdin is a pipe proves
  # the native path end to end, and the operator's terminal is never touched.
  describe "set_stdin_echo/1" do
    test "answers :enotty when stdin is a pipe rather than a terminal" do
      assert child_vm_echo_result() == "{error,enotty}"
    end

    # The real path on a terminal this test owns: `script` gives a child VM a
    # fresh pseudo-terminal, so no terminal anyone is typing into is touched.
    # Off reports echo was on, back on reports it was off, and a third call
    # reports it on again: the flag moved and was restored.
    if is_nil(System.find_executable("script")),
      do: @tag(skip: "script(1) is not installed here, so no pseudo-terminal can be made")

    test "on a pseudo-terminal, turns echo off, back on, and reports the state it found" do
      assert pty_echo_result() =~ "echo:{ok,true}:{ok,false}:{ok,true}"
    end

    test "rejects anything but a boolean before reaching the terminal" do
      assert_raise FunctionClauseError, fn -> FermixNif.set_stdin_echo(:off) end
      assert_raise FunctionClauseError, fn -> FermixNif.set_stdin_echo(nil) end
    end
  end

  describe "hot code upgrade" do
    # A dev recompile under a live daemon hot-swaps this module (Phoenix code
    # reloader, or a second `mix compile` in another shell). Without a NIF
    # upgrade callback the VM refuses the swap — "Upgrade not supported by this
    # NIF library" — the module loses its native binding, and every
    # process-group sweep crashes until the daemon restarts. The load below IS
    # that swap, against the very same beam.
    test "kill_pgid/2 survives a reload of the module" do
      assert FermixNif.kill_pgid(@absent_pgid, :sigkill) == {:error, :esrch}

      assert {:module, FermixNif} = :code.load_file(FermixNif)
      :code.purge(FermixNif)

      assert FermixNif.kill_pgid(@absent_pgid, :sigkill) == {:error, :esrch}
    end
  end

  # System.cmd hands the child a pipe on stdin, which is the non-terminal world
  # under test.
  defp child_vm_echo_result do
    eval = ~s|io:format("~p", ['Elixir.FermixNif':set_stdin_echo(false)]), halt().|
    [erl | args] = child_vm_argv(eval)
    {output, 0} = System.cmd(erl, args, pty_cmd_opts())
    output
  end

  # util-linux `script` takes the command as one shell string (`-c`); the BSD
  # and macOS one takes it as trailing arguments. Both write the session to
  # /dev/null and give the command a pty with the default line discipline.
  defp pty_echo_result do
    script = System.find_executable("script")

    eval =
      "N = 'Elixir.FermixNif', A = N:set_stdin_echo(false), B = N:set_stdin_echo(true), " <>
        ~s|C = N:set_stdin_echo(true), io:format("echo:~p:~p:~p~n", [A, B, C]), halt().|

    {output, 0} = System.cmd(script, script_args(script, child_vm_argv(eval)), pty_cmd_opts())
    String.replace(output, "\r", "")
  end

  defp script_args(script, [command | args]) do
    if util_linux_script?(script),
      do: ["-qec", Enum.map_join([command | args], " ", &shell_quote/1), "/dev/null"],
      else: ["-q", "/dev/null", command | args]
  end

  defp util_linux_script?(script) do
    case System.cmd(script, ["--version"], stderr_to_stdout: true) do
      {version, 0} -> version =~ "util-linux"
      {_usage, _status} -> false
    end
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", ~S('"'"')) <> "'"

  # `erl` from this VM's own root (no PATH lookup) with this build's FermixNif
  # and the Elixir it was compiled against.
  defp child_vm_argv(eval) do
    erl = Path.join([:code.root_dir(), "bin", "erl"])
    nif_ebin = :fermix_nif |> :code.lib_dir() |> Path.join("ebin")
    elixir_ebin = :elixir |> :code.lib_dir() |> Path.join("ebin")
    [erl, "-noshell", "-pa", nif_ebin, "-pa", elixir_ebin, "-eval", eval]
  end

  # A child that fails to boot writes no crash dump into the working tree.
  defp pty_cmd_opts, do: [stderr_to_stdout: true, env: [{"ERL_CRASH_DUMP_SECONDS", "0"}]]

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
