defmodule Fermix.CLI.ServiceCommandTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.ServiceCommand

  @switches [user: :boolean, system: :boolean]

  defmodule StandaloneBuildInfo do
    @moduledoc false
    def app_engine?, do: false
  end

  defmodule PermissiveHomeOwner do
    @moduledoc false
    def app_managed?(_opts), do: false
  end

  # `capture_io` runs the verb in this process, so the scripted answers live in
  # the process dictionary: no extra process, and nothing shared between cases.
  defmodule StubService do
    @moduledoc false

    def script(results) do
      Process.put(:stub_service, results)
      __MODULE__
    end

    def install(scope, opts), do: answer(:install, [scope, opts])
    def uninstall(scope, opts), do: answer(:uninstall, [scope, opts])
    def status(opts), do: answer(:status, [opts])

    defp answer(key, args) do
      case Keyword.fetch(Process.get(:stub_service, []), key) do
        {:ok, answer} when is_function(answer) -> apply(answer, args)
        {:ok, answer} -> answer
        :error -> raise "the stub service was asked for #{key}, which this case did not script"
      end
    end
  end

  describe "parse_scope/2" do
    test "no flag defaults to :user" do
      assert {:ok, :user} = ServiceCommand.parse_scope([], @switches)
    end

    test "--user is :user" do
      assert {:ok, :user} = ServiceCommand.parse_scope(["--user"], @switches)
    end

    test "--system is :system" do
      assert {:ok, :system} = ServiceCommand.parse_scope(["--system"], @switches)
    end

    test "--user and --system together is rejected" do
      assert {:error, message} = ServiceCommand.parse_scope(["--user", "--system"], @switches)
      assert message =~ "mutually exclusive"
    end

    test "unknown flag is rejected" do
      assert {:error, message} = ServiceCommand.parse_scope(["--bogus"], @switches)
      assert message =~ "invalid options"
    end
  end

  describe "format_reason/1" do
    test "a published refusal speaks with its own published sentence" do
      assert ServiceCommand.format_reason({:linger_denied, "Access denied"}) =~
               "sudo loginctl enable-linger"

      assert ServiceCommand.format_reason(:user_manager_unreachable) =~
               "no user service manager"
    end

    test "launchctl_failed includes exit code and output" do
      assert ServiceCommand.format_reason({:launchctl_failed, 5, "boom"}) ==
               "launchctl failed (5): boom"
    end

    test "systemctl_failed includes exit code and output" do
      assert ServiceCommand.format_reason({:systemctl_failed, 3, "stderr"}) ==
               "systemctl failed (3): stderr"
    end

    test "unsupported_os tags the offending OS atom" do
      assert ServiceCommand.format_reason({:unsupported_os, {:win32, :nt}}) =~ "unsupported OS"
    end
  end

  describe "run_action/4" do
    test "prints success and returns 0 when the action succeeds" do
      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run_action(fn :user -> :ok end, :user, "installed", "fermix svc") ==
                   0
        end)

      assert stdout =~ "fermix svc: installed user-scope unit"
    end

    test "prints stderr and returns 1 when the action errors" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ServiceCommand.run_action(
                   fn :user -> {:error, {:systemctl_failed, 7, "boom"}} end,
                   :user,
                   "installed",
                   "fermix svc"
                 ) == 1
        end)

      assert stderr =~ "systemctl failed (7): boom"
    end
  end

  describe "install and uninstall" do
    test "machine mode prints one envelope on stdout and the prose on stderr" do
      deps = deps(install: {:ok, status_fixture()})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["install", "--json"], deps) == 0
        end)

      assert [line] = String.split(String.trim(stdout), "\n")

      assert Jason.decode!(line) == %{
               "schema_version" => 1,
               "ok" => true,
               "result" => status_fixture()
             }
    end

    test "human mode prints labelled lines from the same result" do
      deps = deps(install: {:ok, status_fixture()})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["install"], deps) == 0
        end)

      assert stdout =~ "Service:      active (running)"
      assert stdout =~ "Home:         /home/o/.fermix"
      assert stdout =~ "Unit:         /usr/lib/systemd/user/fermix.service (package)"
      assert stdout =~ "Alignment:    aligned"
      refute stdout =~ "schema_version"
    end

    test "the chosen home and port reach the service" do
      test = self()

      deps =
        deps(
          install: fn _scope, opts ->
            send(test, {:install_opts, opts})
            {:ok, status_fixture()}
          end
        )

      ExUnit.CaptureIO.capture_io(fn ->
        assert ServiceCommand.run(
                 ["install", "--home", "/home/o/.fermix", "--port", "4040"],
                 deps
               ) ==
                 0
      end)

      assert_received {:install_opts, opts}
      assert opts[:home] == "/home/o/.fermix"
      assert opts[:port] == 4040
    end

    test "a refusal renders one code and one sentence, and exits 1" do
      deps =
        deps(install: {:error, {:foreign_unit, "/home/o/.config/systemd/user/fermix.service"}})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["install", "--json"], deps) == 1
        end)

      envelope = Jason.decode!(String.trim(stdout))
      assert envelope["ok"] == false
      assert envelope["error"]["code"] == "foreign_unit"
      assert envelope["error"]["sentence"] =~ "/home/o/.config/systemd/user/fermix.service"
    end

    test "the same refusal reads as one sentence on stderr in human mode" do
      deps = deps(install: {:error, {:invalid_port, "the web listener port must be a number"}})

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ServiceCommand.run(["install"], deps) == 1
        end)

      assert stderr =~ "the web listener port must be a number"
    end

    # The settings file is the one write that has to work while the daemon is
    # down, so a failure to make it is its own code rather than a systemd one.
    test "a settings file that cannot be written is its own refusal" do
      deps = deps(install: {:error, {:config_write_failed, :eacces}})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert ServiceCommand.run(["install", "--json"], deps) == 1
          end)
        end)

      envelope = Jason.decode!(String.trim(stdout))
      assert envelope["error"]["code"] == "config_write_failed"
      assert envelope["error"]["sentence"] =~ "web listener port"
      assert envelope["error"]["sentence"] =~ ":eacces"
    end

    test "a standalone install keeps its own sentence and its own envelope" do
      deps = deps(install: :ok)

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["install"], deps) == 0
        end)

      assert stdout =~ "fermix service: installed user-scope unit."

      machine =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["uninstall", "--json"], deps(uninstall: :ok)) == 0
        end)

      assert Jason.decode!(String.trim(machine))["result"] == %{
               "action" => "uninstalled",
               "scope" => "user"
             }
    end

    test "an unknown flag is a usage error, and exits 2" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ServiceCommand.run(["install", "--bogus"], deps()) == 2
        end)

      assert stderr =~ "invalid options"
      assert stderr =~ "Usage:"
    end
  end

  describe "status" do
    test "machine mode prints the status envelope" do
      deps = deps(status: {:ok, status_fixture()})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["status", "--json"], deps) == 0
        end)

      assert Jason.decode!(String.trim(stdout))["result"]["alignment"] == "aligned"
    end

    test "an unreachable user manager refuses with its own code" do
      deps = deps(status: {:error, :user_manager_unreachable})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ServiceCommand.run(["status", "--json"], deps) == 1
        end)

      assert Jason.decode!(String.trim(stdout))["error"]["code"] == "user_manager_unreachable"
    end

    test "a distribution with no packaged service says so" do
      deps = deps(status: {:error, :foreign_distribution})

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ServiceCommand.run(["status"], deps) == 1
        end)

      assert stderr =~ "not installed from a Linux package"
    end

    test "status takes no scope flags" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ServiceCommand.run(["status", "--system"], deps()) == 2
        end)

      assert stderr =~ "invalid options"
    end
  end

  defp deps(results \\ []) do
    [
      build_info: StandaloneBuildInfo,
      home_owner: PermissiveHomeOwner,
      username: fn _opts -> "operator" end,
      service: StubService.script(results)
    ]
  end

  defp status_fixture do
    %{
      "binding" => %{"state" => "bound", "home" => "/home/o/.fermix", "reason" => nil},
      "unit" => %{
        "effective_path" => "/usr/lib/systemd/user/fermix.service",
        "vendor" => true,
        "legacy_generated" => false,
        "foreign" => false,
        "need_daemon_reload" => false
      },
      "enabled" => true,
      "active" => true,
      "sub_state" => "running",
      "pid" => 4711,
      "invocation_id" => "4b1e9d1a",
      "restart_count" => 0,
      "linger" => "enabled",
      "path_source" => "engine_baseline",
      "listener" => %{
        "port" => 4030,
        "origin" => "http://127.0.0.1:4030",
        "source" => "daemon"
      },
      "installed" => %{
        "engine_id" => "fermix-core",
        "product_version" => "1.2.3",
        "build_id" => "release-9",
        "source_commit" => String.duplicate("a", 40),
        "distribution_identity" => "linux_package",
        "artifact_target" => "linux_x86_64",
        "architecture" => "x86_64",
        "integrity" => "verified"
      },
      "running" => %{"build_id" => "release-9"},
      "alignment" => "aligned"
    }
  end
end
