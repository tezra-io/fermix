defmodule FermixCore.CommandHostStreamTest do
  # async: false — each test spawns a real OS process group and polls it; the
  # supervisor is per-test (never the global one) so tests stay isolated, but
  # timing is steadier run serially (mirrors CommandHostTest).
  use ExUnit.Case, async: false

  alias FermixCore.CommandHost
  alias FermixCore.CommandRunner

  # Bounded liveness polling: death is asserted by polling `kill -0` until it
  # fails, never a fixed sleep (mirrors CommandHostTest).
  @poll_max 50
  @poll_ms 100

  setup do
    sh = System.find_executable("sh") || "/bin/sh"
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("command-host-stream")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    %{sh: sh, dir: dir}
  end

  test "forwards chunks then a terminal exit on a clean success", %{sh: sh} do
    sup = start_host_sup()

    {:ok, %{host: host, ref: ref}} =
      CommandRunner.start_stream(sh, ["-c", "printf 'hello\\n'; exit 0"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000
      )

    {out, result} = collect_until_exit(host, ref)
    assert out == "hello\n"
    assert {:ok, %{exit: 0, truncated?: false, forwarded_bytes: 6}} = result
  end

  test "surfaces a non-zero exit code as an :ok terminal", %{sh: sh} do
    sup = start_host_sup()

    {:ok, %{host: host, ref: ref}} =
      CommandRunner.start_stream(sh, ["-c", "printf 'x\\n'; exit 7"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000
      )

    {out, result} = collect_until_exit(host, ref)
    assert out == "x\n"
    assert {:ok, %{exit: 7, truncated?: false}} = result
  end

  test "wall-clock timeout ends with {:error, {:timeout, ms}}", %{sh: sh} do
    sup = start_host_sup()

    {:ok, %{host: _host, ref: ref, os_pid: os_pid}} =
      CommandRunner.start_stream(sh, ["-c", "sleep 30"],
        dynamic_supervisor: sup,
        timeout_ms: 300,
        kill_grace_ms: 200
      )

    assert is_integer(os_pid)
    on_exit(fn -> cleanup_os_pid(os_pid) end)

    assert_receive {:command_host_exit, ^ref, {:error, {:timeout, 300}}}, 5_000
    refute_received {:command_host_data, ^ref, _}
  end

  test "cancel ends with {:error, :cancelled} and is idempotent", %{sh: sh} do
    sup = start_host_sup()

    # A TERM-trapping child stays alive through the SIGTERM, so the host remains
    # in its drain window until the grace SIGKILL — a deterministic window in
    # which the second (idempotent) cancel lands.
    {:ok, %{host: host, ref: ref, os_pid: os_pid}} =
      CommandRunner.start_stream(sh, ["-c", "trap '' TERM; while true; do sleep 1; done"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000,
        kill_grace_ms: 300
      )

    assert is_integer(os_pid)
    on_exit(fn -> cleanup_os_pid(os_pid) end)

    # cancel/2 is synchronous: on return the host is already draining, so the
    # second call is guaranteed to hit the idempotent path.
    assert :ok = CommandHost.cancel(host, ref)
    assert :ok = CommandHost.cancel(host, ref)

    assert_receive {:command_host_exit, ^ref, {:error, :cancelled}}, 5_000
  end

  test "cancel after the terminal exit has been received is still :ok (noproc race)", %{sh: sh} do
    sup = start_host_sup()

    {:ok, %{host: host, ref: ref}} =
      CommandRunner.start_stream(sh, ["-c", "printf 'ok\\n'; exit 0"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000
      )

    # Drain to the terminal exit: the host has now sent {:command_host_exit, ...}
    # and stopped :normal, so a racing cancel hits a dead pid.
    {_out, {:ok, %{exit: 0}}} = collect_until_exit(host, ref)
    await_death_of_pid(host)

    # cancel/2 is documented idempotent even for an already-ended host: the
    # :noproc GenServer.call exit must resolve to :ok, never crash the caller.
    assert :ok = CommandHost.cancel(host, ref)
  end

  test "output-cap breach truncates with a terminal {:ok, truncated?: true}", %{sh: sh} do
    sup = start_host_sup()

    {:ok, %{host: host, ref: ref}} =
      CommandRunner.start_stream(sh, ["-c", "yes x | head -c 8192"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000,
        max_output_bytes: 128
      )

    {_out, result} = collect_until_exit(host, ref)
    assert {:ok, %{exit: 124, truncated?: true}} = result
  end

  test "subscriber death sweeps a trapping grandchild", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "grandchild.pid")
    test = self()

    # The subscriber owns the stream (default stream_to = self()); its death must
    # fire the host's subscriber monitor and group-SIGKILL the grandchild.
    subscriber =
      spawn(fn ->
        {:ok, %{host: host}} =
          CommandRunner.start_stream(sh, trapping_grandchild_cmd(pidfile),
            dynamic_supervisor: sup,
            timeout_ms: 30_000
          )

        send(test, {:host, host})

        receive do
          :never -> :ok
        end
      end)

    _host = await_message(:host) || flunk("subscriber never started the stream")
    grandchild = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    Process.exit(subscriber, :kill)

    assert await_death(grandchild) == :dead
  end

  test "supervisor shutdown sweeps an in-flight streaming command", %{sh: sh, dir: dir} do
    sup = start_host_sup()
    pidfile = Path.join(dir, "grandchild.pid")

    {:ok, %{host: _host}} =
      CommandRunner.start_stream(sh, trapping_grandchild_cmd(pidfile),
        dynamic_supervisor: sup,
        timeout_ms: 30_000
      )

    grandchild = await_pidfile(pidfile)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    :ok = DynamicSupervisor.stop(sup)

    assert await_death(grandchild) == :dead
  end

  test "a stalled subscriber (no acks, pending breach) is swept and errors", %{sh: sh} do
    sup = start_host_sup()

    # ack_window 1 forwards exactly one chunk; the rest queue. Never acking, the
    # 1 MB stream overflows the 4 KB pending bound → subscriber_stalled ending.
    # max_output_bytes is raised so the total cap cannot fire first.
    {:ok, %{host: _host, ref: ref, os_pid: os_pid}} =
      CommandRunner.start_stream(sh, ["-c", "yes | head -c 1000000"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000,
        max_output_bytes: 10_000_000,
        ack_window: 1,
        pending_bytes_max: 4_096
      )

    on_exit(fn -> cleanup_os_pid(os_pid) end)

    assert_receive {:command_host_exit, ^ref, {:error, {:subscriber_stalled, n}}}, 5_000
    assert n > 4_096
  end

  test "acks resume delivery — all bytes arrive intact and in order", %{sh: sh} do
    sup = start_host_sup()

    # A small ack window forces queuing; acking each chunk must flush the queue so
    # every byte is delivered, in order, with none dropped or reordered. The
    # generator is a deterministic loop (no pipe/SIGPIPE, so no merged broken-pipe
    # stderr noise) emitting exactly 1000 lines of "0123456789\n".
    {:ok, %{host: host, ref: ref}} =
      CommandRunner.start_stream(
        sh,
        ["-c", "i=0; while [ $i -lt 1000 ]; do printf '0123456789\\n'; i=$((i+1)); done"],
        dynamic_supervisor: sup,
        timeout_ms: 30_000,
        ack_window: 2,
        pending_bytes_max: 1_048_576
      )

    {out, result} = collect_until_exit(host, ref)
    assert out == String.duplicate("0123456789\n", 1000)
    assert {:ok, %{exit: 0, truncated?: false, forwarded_bytes: 11_000}} = result
  end

  test ":in gives the child immediate stdin EOF", %{sh: sh} do
    sup = start_host_sup()

    # Without the :in port option the child's stdin stays open and `cat` blocks
    # forever; with it, `cat` reads EOF immediately and the command completes.
    {:ok, %{host: host, ref: ref}} =
      CommandRunner.start_stream(sh, ["-c", "cat >/dev/null; echo done"],
        dynamic_supervisor: sup,
        timeout_ms: 10_000
      )

    {out, result} = collect_until_exit(host, ref)
    assert out == "done\n"
    assert {:ok, %{exit: 0, truncated?: false}} = result
  end

  test "buffered mode is unaffected by streaming support", %{sh: sh} do
    sup = start_host_sup()

    assert {:ok, %{exit: 0, stdout: "hi\n", truncated?: false}} =
             CommandRunner.run(sh, ["-c", "echo hi"],
               supervised: true,
               dynamic_supervisor: sup,
               timeout_ms: 5_000
             )
  end

  test "start_stream refuses a missing executable before any spawn" do
    path = "/no/such/binary-#{System.unique_integer([:positive])}"
    assert {:error, {:executable_not_found, ^path}} = CommandRunner.start_stream(path, [])
  end

  test "start_stream with an absent supervisor raises before any spawn", %{sh: sh, dir: dir} do
    marker = Path.join(dir, "spawned.marker")

    assert_raise RuntimeError, ~r/command host supervisor .* is not running/, fn ->
      CommandRunner.start_stream(sh, ["-c", "touch #{marker}"],
        dynamic_supervisor: :fermix_absent_stream_sup
      )
    end

    refute File.exists?(marker), "a command spawned despite the missing supervisor"
  end

  # Collects forwarded chunks (acking each) until the terminal exit, returning the
  # reassembled output and the terminal result. Bounded by the per-receive 5s
  # timeout and by the command's own bounded output.
  defp collect_until_exit(host, ref, acc \\ "") do
    receive do
      {:command_host_data, ^ref, chunk} ->
        CommandHost.ack(host, ref, 1)
        collect_until_exit(host, ref, acc <> chunk)

      {:command_host_exit, ^ref, result} ->
        {acc, result}
    after
      5_000 -> flunk("no {:command_host_exit, #{inspect(ref)}, _} within 5s")
    end
  end

  # A trapping, fd-closing grandchild: writes its own pid, ignores SIGTERM, closes
  # fds (so it never holds the port open), then loops. Only SIGKILL reaps it.
  defp trapping_grandchild_cmd(pidfile) do
    inner =
      ~s(trap "" TERM; echo $$ > #{pidfile}; exec 0<&- 1>&- 2>&-; while true; do sleep 1; done)

    ["-c", ~s(sh -c '#{inner}' & wait)]
  end

  defp start_host_sup do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    # The supervisor is linked to the test process, so it begins its own
    # parent-exit shutdown the moment the test ends — racing the on_exit runner.
    # A `Process.alive?/1` guard is a TOCTOU trap (it can pass microseconds
    # before the supervisor dies, then `stop/1` exits `:noproc`). Stop
    # unconditionally and tolerate the already-dead cases instead.
    on_exit(fn ->
      try do
        DynamicSupervisor.stop(sup)
      catch
        # :noproc arrives wrapped by GenServer.stop; a supervisor already in
        # parent-exit shutdown propagates the BARE :shutdown from :sys.terminate.
        :exit, reason when reason in [:noproc, :normal, :shutdown] -> :ok
        :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> :ok
      end
    end)

    sup
  end

  # Waits (bounded) for a BEAM process to be dead. Monitoring a pid that already
  # exited delivers an immediate :DOWN, so this is race-free even post-stop.
  defp await_death_of_pid(pid) do
    mon = Process.monitor(pid)

    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("process #{inspect(pid)} did not stop within 5s")
    end
  end

  defp await_message(tag) do
    receive do
      {^tag, value} -> value
    after
      5_000 -> nil
    end
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

  defp cleanup_os_pid(nil), do: :ok
  defp cleanup_os_pid(os_pid) when is_integer(os_pid), do: liveness_gated_kill(os_pid)

  defp liveness_gated_kill(os_pid) do
    if alive?(os_pid) do
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
