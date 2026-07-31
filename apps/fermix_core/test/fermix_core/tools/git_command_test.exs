defmodule FermixCore.Tools.GitCommandTest do
  # async: false — the timeout test spawns a real OS process group through the
  # (global) CommandHost supervisor and polls it; serial runs keep timing steady.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.GitCommand

  # Bounded liveness polling (mirrors command_host_test): the stub git is its own
  # process-group leader and writes its pid to a file. Death is asserted by
  # polling `kill -0` until it fails, never a fixed sleep.
  @poll_max 50
  @poll_ms 100

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("git-command")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a never-completing git times out with the tool error and sweeps its group", %{dir: dir} do
    pidfile = Path.join(dir, "git.pid")
    stub = write_stub_git(dir, pidfile)

    # The executable-path seam points GitCommand at a stub that records its own
    # pid then sleeps far longer than the (short) test timeout. GitCommand routes
    # through CommandRunner (supervised: true, global host), so the wall-clock
    # timeout must both surface the tool error and sweep the OS process group.
    #
    # The run is driven from a Task so the pid can be read WHILE the stub is
    # alive. Reading it after the call returned raced the sweep against the
    # stub's own `echo $$ > pidfile`: the timeout fires whether or not /bin/sh
    # has run that line yet, and on a loaded host the sweep won about 1 run in
    # 8 — the group died before the pidfile existed, so the poll then waited 5 s
    # for a file nothing would ever write. It also made the death assertion
    # nearly vacuous, since the process was already gone before its pid was
    # known. Registration now has the full timeout to happen in, and the sweep
    # is observed on a process this test saw alive.
    task =
      Task.async(fn ->
        GitCommand.run(dir, "status", ["--short"], executable: stub, timeout_ms: 3_000)
      end)

    pid = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(pid) end)
    assert alive?(pid)

    assert {:error, message} = Task.await(task, 10_000)
    assert message =~ "git status timed out"

    assert await_death(pid) == :dead
  end

  # A stub `git` that writes its own pid ($$, the group leader) then sleeps long
  # enough that only the sweep can end it. Executable so CommandRunner can spawn it.
  defp write_stub_git(dir, pidfile) do
    path = Path.join(dir, "git")
    File.write!(path, "#!/bin/sh\necho $$ > #{pidfile}\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    path
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
