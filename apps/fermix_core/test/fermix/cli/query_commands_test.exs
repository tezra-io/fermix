defmodule Fermix.CLI.QueryCommandsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.AgentsCommand
  alias Fermix.CLI.CapabilitiesCommand
  alias Fermix.CLI.Daemon
  alias Fermix.CLI.HealthCommand
  alias Fermix.CLI.SkillsCommand
  alias Fermix.CLI.VoiceCommand

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    socket_dir = mkdir!()
    task_sup = :"query_command_task_sup_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(socket_dir) end)

    System.put_env("FERMIX_HOME", socket_dir)
    on_exit(fn -> restore_env("FERMIX_HOME", previous_home) end)

    {:ok, _sup} = Task.Supervisor.start_link(name: task_sup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"query_command_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: Path.join(socket_dir, "daemon.sock"),
        task_supervisor: task_sup
      )

    Process.unlink(daemon)
    on_exit(fn -> stop_daemon(daemon) end)

    :ok
  end

  test "health --json returns daemon-evaluated health" do
    {exit_status, output} = run_command(fn -> HealthCommand.run(["--json"]) end)

    assert exit_status == 0
    decoded = Jason.decode!(output)
    assert decoded["status"] in ["ready", "setup_required", "degraded"]
    assert is_list(decoded["channels"])
  end

  test "voice status --json returns realtime health" do
    {exit_status, output} = run_command(fn -> VoiceCommand.run(["status", "--json"]) end)

    assert exit_status == 0
    decoded = Jason.decode!(output)
    assert decoded["daemon"] == "online"
    assert is_map(decoded["realtime"])
    assert decoded["realtime"]["status"] in ["disabled", "ready", "setup_required", "degraded"]
  end

  test "agents --json returns main-agent and worker status" do
    {exit_status, output} = run_command(fn -> AgentsCommand.run(["--json"]) end)

    assert exit_status == 0
    decoded = Jason.decode!(output)
    assert decoded["main"]["name"] == "main"
    assert decoded["main"]["health"] == "online"
    assert decoded["main"]["activity"] in ["idle", "running"]
    assert decoded["main"]["status"] in ["idle", "running"]
    assert is_list(decoded["skill_workers"])
  end

  test "capabilities --kind builtin --json returns filtered capabilities" do
    {exit_status, output} =
      run_command(fn -> CapabilitiesCommand.run(["--kind", "builtin", "--json"]) end)

    assert exit_status == 0
    decoded = Jason.decode!(output)
    assert decoded["counts"]["skill"] == 0
    assert decoded["counts"]["mcp"] == 0
    assert is_list(decoded["capabilities"])
  end

  test "skills list --json returns installed skill summaries" do
    {exit_status, output} = run_command(fn -> SkillsCommand.run(["list", "--json"]) end)

    assert exit_status == 0
    decoded = Jason.decode!(output)
    assert is_integer(decoded["count"])
    assert is_list(decoded["skills"])
    assert Enum.any?(decoded["skills"], &(&1["name"] == "self-knowledge"))
  end

  # Blocks in terminate past the stop timeout, so GenServer.stop exits
  # {:timeout, ...} — a non-:noproc exit, the same class a concurrently-dying
  # daemon produced as :shutdown in CI. Unlinked (start, not start_link) so it
  # can't disturb the test process.
  defmodule SlowTerminatingDaemon do
    use GenServer

    def start, do: GenServer.start(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      Process.flag(:trap_exit, true)
      {:ok, :ok}
    end

    @impl true
    def terminate(_reason, _state), do: Process.sleep(2_000)
  end

  test "stop_daemon forcefully finishes a daemon that misses the graceful deadline" do
    {:ok, daemon} = SlowTerminatingDaemon.start()

    assert stop_daemon(daemon) == :ok
    refute Process.alive?(daemon)
  end

  defp run_command(fun) do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:exit_status, fun.()})
      end)

    receive do
      {:exit_status, status} -> {status, output}
    after
      100 -> flunk("command did not return")
    end
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-query-command-#{System.unique_integer([:positive, :monotonic])}"
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
