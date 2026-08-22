defmodule Fermix.CLI.AppManagedCommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Fermix.CLI
  alias Fermix.CLI.AppRoute
  alias Fermix.CLI.RestartCommand
  alias Fermix.CLI.ServiceCommand
  alias Fermix.CLI.Setup
  alias Fermix.CLI.StartCommand
  alias Fermix.CLI.StopCommand
  alias Fermix.CLI.UninstallCommand
  alias Fermix.CLI.UpgradeCommand

  defmodule AppBuildInfo do
    def app_engine?, do: true
  end

  defmodule StandaloneBuildInfo do
    def app_engine?, do: false
  end

  defmodule RaisingService do
    def installed?(_scope), do: raise("legacy service inspection must not run")
    def install(_scope), do: raise("legacy service install must not run")
    def uninstall(_scope), do: raise("legacy service uninstall must not run")
    def start(_scope), do: raise("legacy service start must not run")
    def stop(_scope), do: raise("legacy service stop must not run")
    def restart(_scope), do: raise("legacy service restart must not run")
  end

  defmodule AppManagedUpgrade do
    def check, do: {:error, {:app_managed, :update}}
    def run, do: {:error, {:app_managed, :update}}
  end

  defp recording_route_opts do
    test_pid = self()

    [
      opener: fn url ->
        send(test_pid, {:opened, url})
        :ok
      end
    ]
  end

  # `pids` is the sequence `hello` answers with, one per call. The command reads
  # the first as the pid it is replacing and polls until a different one appears.
  defp restart_deps(pids, overrides \\ []) do
    test_pid = self()
    counter = :counters.new(1, [])

    client = fn method, params, _opts ->
      send(test_pid, {:called, method, params})

      case method do
        "hello" -> hello_reply(pids, counter)
        "lifecycle.prepare" -> {:ok, %{"lease_id" => "lease-1", "ttl_ms" => 30_000}}
        "lifecycle.commit" -> {:ok, %{"lease_id" => "lease-1", "status" => "committed"}}
      end
    end

    defaults = [
      build_info: AppBuildInfo,
      service: RaisingService,
      client: client,
      sleep: fn _ms -> :ok end,
      verify_polls: Keyword.get(overrides, :polls, 10)
    ]

    Keyword.merge(defaults, Keyword.delete(overrides, :polls))
  end

  defp hello_reply(pids, counter) do
    :counters.add(counter, 1, 1)
    index = :counters.get(counter, 1) - 1

    case Enum.at(pids, index) do
      nil -> {:error, :not_running}
      pid -> {:ok, %{"engine" => %{"pid" => pid, "product_version" => "0.9.0"}}}
    end
  end

  test "start and stop refuse legacy service control before inspecting service units" do
    deps = [build_info: AppBuildInfo, service: RaisingService]

    for {command, label} <- [{StartCommand, "fermix start"}, {StopCommand, "fermix stop"}] do
      stderr =
        capture_io(:stderr, fn ->
          assert apply(command, :run, [[], deps]) == 1
        end)

      assert stderr =~ label
      assert stderr =~ "managed by Fermix.app"
      assert stderr =~ "background service"
    end
  end

  # M34 §4: "restart follows the app-owned restart contract without creating
  # legacy units." Without a branch here the command falls through to "no
  # service installed. Run `fermix service install` first" — a verb this same
  # engine refuses, so the operator loops. Two new surfaces route them here:
  # `Daemon.Client.describe_error(:invalid_management_response)` and the
  # `daemon socket` doctor row both say "restart it with `fermix restart`".
  test "restart drives the app-owned contract instead of a legacy unit" do
    stdout =
      capture_io(fn ->
        assert RestartCommand.run([], restart_deps(["100", "100", "412"])) == 0
      end)

    assert_receive {:called, "lifecycle.prepare", %{}}
    assert_receive {:called, "lifecycle.commit", %{"lease_id" => "lease-1"}}
    assert stdout =~ "fermix restart"
    assert stdout =~ "412"
    refute stdout =~ "service install"
  end

  test "restart with no daemon names the app's controls, never a refused verb" do
    deps = restart_deps([], client: fn _method, _params, _opts -> {:error, :not_running} end)

    stderr = capture_io(:stderr, fn -> assert RestartCommand.run([], deps) == 1 end)

    assert stderr =~ "Fermix.app"
    assert stderr =~ "background service"
    refute stderr =~ "service install"
    refute_received {:called, "lifecycle.prepare", _params}
  end

  test "restart that never sees a new daemon fails loud and cancels nothing it committed" do
    stdout_and_status =
      capture_io(:stderr, fn ->
        assert RestartCommand.run([], restart_deps(["100", "100"], polls: 2)) == 1
      end)

    assert stdout_and_status =~ "did not come back"
    assert stdout_and_status =~ "Fermix.app"
    refute stdout_and_status =~ "service install"
  end

  test "service install and uninstall refuse app-managed engines before mutation" do
    deps = [build_info: AppBuildInfo, service: RaisingService]

    for subcommand <- ["install", "uninstall"] do
      stderr =
        capture_io(:stderr, fn ->
          assert ServiceCommand.run([subcommand], deps) == 1
        end)

      assert stderr =~ "fermix service"
      assert stderr =~ "managed by Fermix.app"
      assert stderr =~ "background service"
    end
  end

  test "a rejected scope never masks the app-managed refusal" do
    deps = [build_info: AppBuildInfo, service: RaisingService]

    stderr =
      capture_io(:stderr, fn ->
        assert ServiceCommand.run(["install", "--user", "--system"], deps) == 1
      end)

    assert stderr =~ "managed by Fermix.app"
    refute stderr =~ "mutually exclusive"
  end

  test "setup opens the native setup route before any token or service work" do
    run_opts = [
      build_info: AppBuildInfo,
      route_opts: recording_route_opts(),
      runtime: fn _opts, _io -> raise "terminal setup runtime must not run" end,
      web_launcher: fn _opts -> raise "setup web launcher must not run" end,
      service: RaisingService
    ]

    stdout =
      capture_io(fn -> assert Setup.run(["--web", "--rotate-token"], run_opts) == 0 end)

    assert stdout =~ "Opened Fermix setup."
    assert_receive {:opened, "fermix://setup"}
  end

  test "setup on an app engine needs no local supervision tree" do
    refute Setup.supervision_required?(["--terminal"], build_info: AppBuildInfo)
    assert Setup.supervision_required?(["--terminal"], build_info: StandaloneBuildInfo)
  end

  test "uninstall opens the native uninstall route" do
    deps = [build_info: AppBuildInfo, route_opts: recording_route_opts()]

    stdout = capture_io(fn -> assert UninstallCommand.run([], deps) == 0 end)

    assert stdout =~ "Opened Fermix uninstall."
    assert_receive {:opened, "fermix://uninstall"}
  end

  test "uninstall on a standalone engine refuses instead of guessing an owner" do
    stderr =
      capture_io(:stderr, fn ->
        assert UninstallCommand.run([], build_info: StandaloneBuildInfo) == 1
      end)

    assert stderr =~ "fermix uninstall"
    assert stderr =~ "not managed by Fermix.app"
    assert stderr =~ "fermix service uninstall"
  end

  # The route is dead code until the verb is registered, and `main/1` sends an
  # unknown verb to usage with exit 2 — a status the refusal never returns.
  test "the top-level dispatcher registers the uninstall verb" do
    stderr = capture_io(:stderr, fn -> assert CLI.main(["uninstall"]) == 1 end)

    assert stderr =~ "fermix uninstall:"
    refute stderr =~ "unknown command"
  end

  test "opening an app route logs nothing on either outcome" do
    ok_log =
      capture_log(fn -> assert AppRoute.open(:setup, opener: fn _url -> :ok end) == :ok end)

    failed_log =
      capture_log(fn ->
        assert AppRoute.open(:uninstall, opener: fn _url -> {:error, :no_opener} end) ==
                 {:error, :no_opener}
      end)

    for log <- [ok_log, failed_log] do
      refute log =~ "fermix://"
      refute log =~ "AppRoute"
    end
  end

  test "upgrade and upgrade check open the native update route" do
    opts = [route_opts: recording_route_opts()]

    for argv <- [[], ["--check"]] do
      stdout = capture_io(fn -> assert UpgradeCommand.run(argv, AppManagedUpgrade, opts) == 0 end)

      assert stdout =~ "Opened Fermix update settings."
      assert_receive {:opened, "fermix://update"}
    end
  end

  test "upgrade route failures expose no opener details" do
    stderr =
      capture_io(:stderr, fn ->
        opts = [route_opts: [opener: fn _url -> {:error, {:opener_failed, "secret"}} end]]
        assert UpgradeCommand.run([], AppManagedUpgrade, opts) == 1
      end)

    assert stderr =~ "could not open Fermix update settings"
    refute stderr =~ "secret"
  end
end
