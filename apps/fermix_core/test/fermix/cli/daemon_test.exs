defmodule Fermix.CLI.DaemonTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client

  setup do
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.TaskSup)
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "fermix.sock")

    {:ok, daemon} =
      Daemon.start_link(
        name: :"daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.TaskSup
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      File.rm_rf(socket_dir)
    end)

    %{socket_path: socket_path, daemon: daemon}
  end

  test "status returns ok with version + uptime", %{socket_path: socket_path} do
    Process.sleep(50)
    assert {:ok, reply} = Client.status(socket_path: socket_path, timeout: 1_000)
    assert reply["status"] == "ok"
    assert is_binary(reply["version"])
    assert is_integer(reply["uptime_ms"])
    assert reply["uptime_ms"] >= 0
  end

  test "unknown method returns error", %{socket_path: socket_path} do
    Process.sleep(50)

    assert {:ok, reply} =
             Client.request("does-not-exist", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "error"
    assert reply["reason"] == "unknown method"
    assert reply["method"] == "does-not-exist"
  end

  test "no daemon listening returns :not_running" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "missing.sock")
    on_exit(fn -> File.rm_rf(socket_dir) end)

    assert {:error, :not_running} =
             Client.status(socket_path: socket_path, timeout: 500)
  end

  test "socket file is created with 0600 permissions", %{socket_path: socket_path} do
    Process.sleep(50)
    {:ok, %File.Stat{mode: mode}} = File.stat(socket_path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "stale socket file is replaced on init" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "stale.sock")
    File.touch!(socket_path)
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.StaleSup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"stale_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.StaleSup
      )

    Process.sleep(50)
    assert {:ok, %{"status" => "ok"}} = Client.status(socket_path: socket_path, timeout: 1_000)

    GenServer.stop(daemon, :normal, 1_000)
    File.rm_rf(socket_dir)
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-daemon-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end
end
