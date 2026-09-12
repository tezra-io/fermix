defmodule Fermix.CLI.StatusCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.StatusCommand
  alias FermixCore.BuildInfo
  alias FermixCore.Management.Protocol

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    socket_dir = mkdir!()
    task_sup = :"status_command_task_sup_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(socket_dir) end)

    System.put_env("FERMIX_HOME", socket_dir)
    on_exit(fn -> restore_env("FERMIX_HOME", previous_home) end)

    {:ok, _sup} = Task.Supervisor.start_link(name: task_sup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"status_command_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: Path.join(socket_dir, "daemon.sock"),
        task_supervisor: task_sup
      )

    Process.unlink(daemon)
    on_exit(fn -> stop_daemon(daemon) end)

    :ok
  end

  # M34 §2 defines no v1 `status` method, so the plain line is projected from
  # `hello` (identity, negotiated protocol) plus `overview.get` (uptime).
  test "plain status prints the running line without a skew warning when versions match" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:status_exit, StatusCommand.run([])})
      end)

    assert_receive {:status_exit, 0}
    assert output =~ "fermix: running (pid #{System.pid()}, "
    assert output =~ "version #{BuildInfo.product_version()}"
    assert output =~ "protocol v#{Protocol.protocol_version()}"
    refute output =~ "warning:"
  end

  test "status --json prints the overview snapshot as JSON" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:status_exit, StatusCommand.run(["--json"])})
      end)

    assert_receive {:status_exit, 0}

    decoded = Jason.decode!(output)
    assert decoded["daemon"]["status"] == "running"
    assert decoded["agents"]["main"]["health"] == "online"
    assert decoded["agents"]["main"]["activity"] in ["idle", "running"]
    assert decoded["agents"]["main"]["status"] in ["idle", "running"]
    assert is_map(decoded["jobs"])
  end

  test "status --full prints a broad human overview" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:status_exit, StatusCommand.run(["--full"])})
      end)

    assert_receive {:status_exit, 0}

    assert output =~ "fermix: running"
    assert output =~ "readiness:"
    assert output =~ "main agent:"
    assert output =~ "main activity:"
    assert output =~ "jobs:"
    assert output =~ "capabilities:"
  end

  # `overview.get` excludes filesystem paths by contract, so `--full` reports
  # the daemon's own home only through `fermix doctor` and the daemon log.
  test "status --full reports no filesystem path" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:status_exit, StatusCommand.run(["--full"])})
      end)

    assert_receive {:status_exit, 0}
    refute output =~ "paths:"
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-status-command-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp stop_daemon(daemon) do
    monitor = Process.monitor(daemon)

    try do
      GenServer.stop(daemon, :normal, 1_000)
    catch
      :exit, _reason -> Process.exit(daemon, :kill)
    end

    receive do
      {:DOWN, ^monitor, :process, ^daemon, _reason} -> :ok
    after
      1_000 -> flunk("fixture daemon remained alive after forced teardown")
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
