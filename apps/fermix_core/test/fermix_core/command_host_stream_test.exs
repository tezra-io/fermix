defmodule FermixCore.CommandHostStreamTest do
  # async: false — each test spawns a real OS process group and polls it; the
  # supervisor is per-test (never the global one) so tests stay isolated, but
  # timing is steadier run serially (mirrors CommandHostTest).
  use ExUnit.Case, async: false

  alias FermixCore.CommandHost
  alias FermixCore.CommandRunner

  # The bound on every wait for the host's messages or exit: a hang guard
  # (AGENTS.md, "Tests under load"), never how a test waits, since a satisfied
  # wait returns the moment its message lands.
  @arrival_ms 10_000

  # A grandchild is no BEAM process, so nothing reports its reaping: once the
  # event that sends its SIGKILL has been seen, `kill -0` is polled until it
  # fails, for at least @reap_bound_ms.
  @reap_bound_ms 10_000
  @poll_ms 100

  # The bound on the probe emulator's run: its boot, then a stream that its own
  # 10 s timeout ends when the child blocks.
  @probe_ms 30_000

  # Evaluated in the probe emulator: one streamed child that reads its stdin to
  # end of file, then says whether that stdin is /dev/null; prints what the
  # child wrote and how it ended.
  @held_stdin_probe """
  {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

  {:ok, %{ref: ref}} =
    FermixCore.CommandRunner.start_stream(
      "/bin/sh",
      ["-c", "cat >/dev/null; [ /dev/stdin -ef /dev/null ] && echo dev-null"],
      dynamic_supervisor: sup,
      timeout_ms: 10_000
    )

  collect = fn collect, acc ->
    receive do
      {:command_host_data, ^ref, chunk} -> collect.(collect, acc <> chunk)
      {:command_host_exit, ^ref, result} -> {acc, result}
    end
  end

  {out, result} = collect.(collect, "")
  ending = with {:ok, %{exit: code}} <- result, do: {:ok, code}
  IO.puts(inspect({out, ending}))
  System.halt(0)
  """
  @probe_boot ~s|Probe = lists:last(init:get_plain_arguments()), | <>
                ~s|{ok, _} = application:ensure_all_started(elixir), | <>
                ~s|'Elixir.Code':eval_string(unicode:characters_to_binary(Probe)).|

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

    assert_receive {:command_host_exit, ^ref, {:error, {:timeout, 300}}}, @arrival_ms
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

    assert_receive {:command_host_exit, ^ref, {:error, :cancelled}}, @arrival_ms
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

  test "subscriber death sweeps a trapping grandchild", %{sh: sh} do
    sup = start_host_sup()
    test = self()

    # The subscriber owns the stream (default stream_to = self()); its death must
    # fire the host's subscriber monitor and group-SIGKILL the grandchild. It
    # relays the grandchild's pid announcement, then waits to be killed.
    subscriber =
      spawn(fn ->
        {:ok, %{host: host, ref: ref}} =
          CommandRunner.start_stream(sh, trapping_grandchild_cmd(),
            dynamic_supervisor: sup,
            timeout_ms: 30_000
          )

        send(test, {:stream, host, ref})

        receive do
          {:command_host_data, ^ref, _chunk} = announcement -> send(test, announcement)
        end

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:stream, host, ref}, @arrival_ms
    assert_receive {:command_host_data, ^ref, announcement}, @arrival_ms
    grandchild = announced_pid(announcement)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    host_mon = Process.monitor(host)
    Process.exit(subscriber, :kill)

    # The host sweeps the group before it stops, so its :DOWN means the SIGKILL
    # was sent; only the grandchild's reaping is left to poll.
    assert_receive {:DOWN, ^host_mon, :process, ^host, _reason}, @arrival_ms
    assert await_death(grandchild) == :dead
  end

  test "supervisor shutdown sweeps an in-flight streaming command", %{sh: sh} do
    sup = start_host_sup()

    {:ok, %{host: _host, ref: ref}} =
      CommandRunner.start_stream(sh, trapping_grandchild_cmd(),
        dynamic_supervisor: sup,
        timeout_ms: 30_000
      )

    assert_receive {:command_host_data, ^ref, announcement}, @arrival_ms
    grandchild = announced_pid(announcement)
    on_exit(fn -> liveness_gated_kill(grandchild) end)

    # Synchronous: it returns once the host's terminate/2 has swept the group.
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

    assert_receive {:command_host_exit, ^ref, {:error, {:subscriber_stalled, n}}}, @arrival_ms
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

  # A port child that is given no stdin of its own shares the emulator's fd 0,
  # and this suite runs with that at /dev/null, where any child reads end of
  # file. So the stream runs in a second emulator whose stdin is a pipe this test
  # holds open and never writes, as a daemon started from a pipe has: a child
  # sharing it blocks in `cat` until its timeout.
  test "a streamed child's stdin is /dev/null, though the daemon's stays open", %{dir: dir} do
    port = start_held_stdin_emulator(dir)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> liveness_gated_kill(os_pid) end)

    {output, status} = probe_result(port, "")
    assert status == 0, "the probe emulator exited #{status}: #{output}"
    assert output == ~s({"dev-null\\n", {:ok, 0}}\n)
  end

  test "buffered mode is unaffected by streaming support", %{sh: sh} do
    sup = start_host_sup()

    assert {:ok, %{exit: 0, stdout: "hi\n", truncated?: false}} =
             CommandRunner.run(sh, ["-c", "echo hi"],
               supervised: true,
               dynamic_supervisor: sup,
               timeout_ms: 30_000
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
  # reassembled output and the terminal result. Bounded by the per-receive
  # @arrival_ms hang guard and by the command's own bounded output.
  defp collect_until_exit(host, ref, acc \\ "") do
    receive do
      {:command_host_data, ^ref, chunk} ->
        CommandHost.ack(host, ref, 1)
        collect_until_exit(host, ref, acc <> chunk)

      {:command_host_exit, ^ref, result} ->
        {acc, result}
    after
      @arrival_ms ->
        flunk("no {:command_host_exit, #{inspect(ref)}, _} within #{@arrival_ms} ms")
    end
  end

  # This suite's own emulator and code path, so the probe runs the code under
  # test. The port is opened without :in, so it holds the probe's stdin pipe
  # open and never writes to it. No crash dump: a failed boot writes none here.
  defp start_held_stdin_emulator(dir) do
    erl = Path.join([:code.root_dir(), "bin", "erl"])
    code_path = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    Port.open({:spawn_executable, erl}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      cd: dir,
      env: [{~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}],
      args: ["-noinput" | code_path] ++ ["-eval", @probe_boot, "-extra", @held_stdin_probe]
    ])
  end

  # The probe emulator's whole output and its exit status.
  defp probe_result(port, acc) do
    receive do
      {^port, {:data, chunk}} -> probe_result(port, acc <> chunk)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      @probe_ms -> flunk("the probe emulator did not exit within #{@probe_ms} ms: #{acc}")
    end
  end

  # A trapping, fd-closing grandchild: ignores SIGTERM, announces its own pid as
  # the stream's only output, closes fds (so it never holds the port open), then
  # loops. Only SIGKILL reaps it.
  defp trapping_grandchild_cmd do
    inner = ~s(trap "" TERM; echo $$; exec 0<&- 1>&- 2>&-; while true; do sleep 1; done)
    ["-c", ~s(sh -c '#{inner}' & wait)]
  end

  # The announcement is one write far below PIPE_BUF, so it is one chunk.
  defp announced_pid(chunk) do
    {pid, "\n"} = Integer.parse(chunk)
    pid
  end

  # ExUnit owns the supervisor's lifecycle. A hand-rolled `start_link` + `on_exit`
  # stop cannot: the supervisor is linked to the test process, so it begins its own
  # parent-exit shutdown the moment the test ends, racing the on_exit runner. Losing
  # that race exits with the reason `GenServer.stop` gets back from `:sys.terminate`
  # on an already-terminating process, which nests three deep —
  # `{{:shutdown, {:sys, :terminate, _}}, {GenServer, :stop, _}}` — so a `catch`
  # listing flat reasons misses it and fails whichever test's on_exit lost the race.
  # Enumerating one more shape just moves the bug; `start_supervised!` removes the
  # race, since ExUnit shuts the supervisor down deterministically instead.
  # `restart: :temporary` because this is a per-test fixture, not a service: the
  # shutdown-sweep test stops it on purpose, and the default `:permanent` would
  # have ExUnit resurrect it mid-test.
  defp start_host_sup do
    start_supervised!({DynamicSupervisor, strategy: :one_for_one}, restart: :temporary)
  end

  # Waits (bounded) for a BEAM process to be dead. Monitoring a pid that already
  # exited delivers an immediate :DOWN, so this is race-free even post-stop.
  defp await_death_of_pid(pid) do
    mon = Process.monitor(pid)

    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
    after
      @arrival_ms -> flunk("process #{inspect(pid)} did not stop within #{@arrival_ms} ms")
    end
  end

  defp alive?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  defp await_death(os_pid) do
    Enum.reduce_while(1..div(@reap_bound_ms, @poll_ms), :alive, fn _attempt, _acc ->
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
