defmodule FermixCore.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias FermixCore.CommandRunner

  setup do
    sh = System.find_executable("sh") || "/bin/sh"
    %{sh: sh}
  end

  test "captures stdout on a successful command", %{sh: sh} do
    assert {:ok, %{exit: 0, stdout: "hello\n", truncated?: false}} =
             CommandRunner.run(sh, ["-c", "echo hello"], timeout_ms: 2_000)
  end

  test "surfaces non-zero exit codes", %{sh: sh} do
    assert {:ok, %{exit: 7, stdout: "", truncated?: false}} =
             CommandRunner.run(sh, ["-c", "exit 7"], timeout_ms: 2_000)
  end

  test "captures stderr alongside stdout", %{sh: sh} do
    assert {:ok, %{exit: 0, stdout: out, truncated?: false}} =
             CommandRunner.run(sh, ["-c", "echo to-stdout; echo to-stderr 1>&2"],
               timeout_ms: 2_000
             )

    assert out =~ "to-stdout"
    assert out =~ "to-stderr"
  end

  test "returns executable_not_found for a missing path" do
    path = "/no/such/binary-#{System.unique_integer([:positive])}"
    assert {:error, {:executable_not_found, ^path}} = CommandRunner.run(path, [])
  end

  test "honours cwd by listing the requested directory", %{sh: sh} do
    dir = Path.join(System.tmp_dir!(), "fermix_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "marker.txt"), "x")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    assert {:ok, %{exit: 0, stdout: out}} =
             CommandRunner.run(sh, ["-c", "ls"], cwd: dir, timeout_ms: 2_000)

    assert out =~ "marker.txt"
  end

  test "passes env entries through verbatim", %{sh: sh} do
    assert {:ok, %{exit: 0, stdout: "abc\n"}} =
             CommandRunner.run(sh, ["-c", "echo \"$FERMIX_TEST_VAR\""],
               env: [{"FERMIX_TEST_VAR", "abc"}],
               timeout_ms: 2_000
             )
  end

  test "kills the OS child on timeout and returns :timeout", %{sh: sh} do
    marker =
      Path.join(System.tmp_dir!(), "fermix_runner_kill_#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm(marker) end)

    assert {:error, {:timeout, 100}} =
             CommandRunner.run(sh, ["-c", "sleep 5; touch #{marker}"], timeout_ms: 100)

    Process.sleep(500)
    refute File.exists?(marker), "child outlived the BEAM task — sleep ran to completion"
  end

  test "kills the whole process group on timeout so a forked grandchild cannot orphan", %{sh: sh} do
    # Production incident: skill scripts run via the shell tool as `sh -c "...uv
    # run python..."` fork a python grandchild. On timeout the runner killed only
    # the direct child (the wrapper sh); the grandchild was reparented to launchd
    # (PID 1) and ran for days at high CPU. The runner must signal the child's
    # PROCESS GROUP so every descendant dies with it. Erlang starts each port in
    # its own session, so the group == the child tree and never the BEAM.
    marker =
      Path.join(System.tmp_dir!(), "fermix_runner_group_#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm(marker) end)

    # The direct child (group leader) backgrounds an inner sh that touches the
    # marker AFTER a delay, then waits. Killing only the leader leaves the inner
    # sh alive to create the marker; a group kill takes the whole tree.
    assert {:error, {:timeout, 100}} =
             CommandRunner.run(sh, ["-c", "sh -c 'sleep 1; touch #{marker}' & wait"],
               timeout_ms: 100
             )

    Process.sleep(2_000)
    refute File.exists?(marker), "grandchild outlived the group kill — process group not reaped"
  end

  test "discards late child output on timeout so it never leaks to the caller", %{sh: sh} do
    # Regression: a secret helper (`security`) that finishes just after the
    # timeout used to leave its output — the raw secret — in the caller's mailbox,
    # which crashed a GenServer caller (SetupLive/BootReport) and wrote the secret
    # to the crash log. The child here ignores SIGTERM and prints during the kill
    # grace, then exits; the runner must drain that output, leaving the caller's
    # mailbox with no stray port message.
    assert {:error, {:timeout, 20}} =
             CommandRunner.run(sh, ["-c", "trap '' TERM; sleep 0.05; printf LEAKED"],
               timeout_ms: 20,
               kill_grace_ms: 500
             )

    refute_received {_port, {:data, _}}
    refute_received {_port, {:exit_status, _}}
  end

  test "truncates output once max_output_bytes is exceeded", %{sh: sh} do
    assert {:ok, %{exit: 124, stdout: out, truncated?: true}} =
             CommandRunner.run(sh, ["-c", "yes x | head -c 8192"],
               timeout_ms: 5_000,
               max_output_bytes: 128
             )

    assert byte_size(out) <= 256
  end

  test "supervised: false completes inline and sweeps a straggler at end of run", %{sh: sh} do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("command-runner-oneshot")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    pidfile = Path.join(dir, "straggler.pid")

    inner = ~s(echo $$ > #{pidfile}; exec 0<&- 1>&- 2>&-; while true; do sleep 1; done)
    cmd = ["-c", ~s(sh -c '#{inner}' & until [ -s #{pidfile} ]; do sleep 0.02; done; exit 0)]

    # No supervision tree is consulted — the collect runs inline in this process,
    # and the exit-ending sweep group-SIGKILLs the fd-closed background straggler.
    assert {:ok, %{exit: 0, truncated?: false}} =
             CommandRunner.run(sh, cmd, supervised: false, timeout_ms: 30_000)

    straggler = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(straggler) end)
    assert await_death(straggler) == :dead
  end

  test "supervised: true with an absent supervisor fails loudly before any spawn", %{sh: sh} do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("command-runner-nosup")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    marker = Path.join(dir, "spawned.marker")

    assert_raise RuntimeError, ~r/command host supervisor .* is not running/, fn ->
      CommandRunner.run(sh, ["-c", "touch #{marker}"],
        supervised: true,
        dynamic_supervisor: :fermix_absent_command_host_sup
      )
    end

    # The raise must precede any OS process — the marker command never ran.
    refute File.exists?(marker), "a command spawned despite the missing supervisor"
  end

  @poll_max 50
  @poll_ms 100

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
