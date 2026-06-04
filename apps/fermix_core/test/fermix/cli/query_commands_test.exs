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
    System.put_env("FERMIX_HOME", socket_dir)

    {:ok, _sup} = Task.Supervisor.start_link(name: task_sup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"query_command_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: Path.join(socket_dir, "daemon.sock"),
        task_supervisor: task_sup
      )

    on_exit(fn ->
      stop_daemon(daemon)
      restore_env("FERMIX_HOME", previous_home)
      FermixTestSupport.SafeRm.rm_rf!(socket_dir)
    end)

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

  # The daemon can die between an aliveness check and the stop (it owns a
  # socket task tree that tears down on test exit), so a `Process.alive?` guard
  # is a TOCTOU race — the `:noproc` exit then aborts on_exit before
  # `restore_env`/`rm_rf!` run, leaking this test's FERMIX_HOME into every
  # later test in the suite (seen as flaky CI failures in unrelated sandbox
  # tests). Tolerate exactly the already-dead case; the teardown only needs
  # the daemon gone.
  defp stop_daemon(daemon) do
    GenServer.stop(daemon, :normal, 1_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
