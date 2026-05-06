defmodule Fermix.CLI.StatusCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.StatusCommand

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    socket_dir = mkdir!()
    task_sup = :"status_command_task_sup_#{System.unique_integer([:positive, :monotonic])}"
    System.put_env("FERMIX_HOME", socket_dir)

    {:ok, _sup} = Task.Supervisor.start_link(name: task_sup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"status_command_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: Path.join(socket_dir, "daemon.sock"),
        task_supervisor: task_sup
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      restore_env("FERMIX_HOME", previous_home)
      File.rm_rf!(socket_dir)
    end)

    :ok
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

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-status-command-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
