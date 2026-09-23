defmodule Fermix.CLI.RestartCommandTest do
  @moduledoc """
  `fermix restart` on a packaged Linux engine (M38 §4.1, §4.6).

  Every fact comes from an injected service, so nothing here reaches a host
  service manager or a socket. The two other configurations — standalone and
  app-managed — keep their own coverage in `app_managed_command_test.exs`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fermix.CLI.RestartCommand

  defmodule PackagedBuildInfo do
    @moduledoc false
    def distribution_identity, do: "linux_package"
    def app_engine?, do: false
    def linux_package?, do: true
  end

  defmodule RefusingService do
    @moduledoc false
    def restart(_scope, _opts), do: raise("the restart transaction must not run")
  end

  @result %{"previous_pid" => "100", "pid" => "412", "alignment" => "aligned"}

  describe "--json" do
    test "prints the envelope on stdout and nothing else" do
      stdout = capture_io(fn -> assert run(["--json"], answering(@result)) == 0 end)

      assert Jason.decode!(String.trim(stdout)) == %{
               "schema_version" => 1,
               "ok" => true,
               "result" => @result
             }
    end

    test "a refusal is the shared failure envelope with exit 1" do
      deps = refusing(:service_unbound)

      stdout = capture_io(fn -> assert run(["--json"], deps) == 1 end)
      envelope = Jason.decode!(String.trim(stdout))

      assert envelope["ok"] == false
      assert envelope["error"]["code"] == "service_unbound"
      assert envelope["error"]["sentence"] =~ "fermix service install"
    end

    test "a daemon that would not open a window carries its own words" do
      deps = refusing({:lifecycle_refused, "the daemon is busy"})

      stdout = capture_io(fn -> assert run(["--json"], deps) == 1 end)
      envelope = Jason.decode!(String.trim(stdout))

      assert envelope["error"]["code"] == "lifecycle_refused"
      assert envelope["error"]["sentence"] =~ "the daemon is busy"
    end

    test "a service manager refusal keeps its own code" do
      deps = refusing({:systemctl_failed, 1, "Job for fermix.service failed."})

      stdout = capture_io(fn -> assert run(["--json"], deps) == 1 end)
      envelope = Jason.decode!(String.trim(stdout))

      assert envelope["error"]["code"] == "systemctl_failed"
      assert envelope["error"]["sentence"] =~ "Job for fermix.service failed."
    end
  end

  # Deferred and recorded: published protocol 1 and 2 carry no
  # `lifecycle.prepare_idle`, and running the interrupting restart instead would
  # be the opposite of what the flag asked for.
  describe "--when-idle" do
    test "is refused with the deferred-mode sentence, in both modes" do
      stdout = capture_io(fn -> assert run(["--when-idle", "--json"], refusing()) == 1 end)
      envelope = Jason.decode!(String.trim(stdout))

      assert envelope["error"]["code"] == "idle_restart_unavailable"

      assert envelope["error"]["sentence"] ==
               "This engine cannot restart when idle yet. Restarting now interrupts any " <>
                 "work in progress."

      stderr = capture_io(:stderr, fn -> assert run(["--when-idle"], refusing()) == 1 end)
      assert stderr =~ "cannot restart when idle yet"
    end

    test "nothing is restarted when the mode is refused" do
      capture_io(:stderr, fn -> assert run(["--when-idle"], refusing()) == 1 end)
    end
  end

  describe "human mode" do
    test "prints one line naming the new generation and the alignment" do
      stdout = capture_io(fn -> assert run([], answering(@result)) == 0 end)

      assert stdout =~ "pid 412"
      assert stdout =~ "was 100"
      assert stdout =~ "aligned"
      assert String.trim(stdout) |> String.split("\n") |> length() == 1
    end

    test "a recovery with nothing previously running says so" do
      result = %{@result | "previous_pid" => nil}
      stdout = capture_io(fn -> assert run([], answering(result)) == 0 end)

      assert stdout =~ "was not running"
    end

    test "a refusal is one sentence on stderr with exit 1" do
      stderr = capture_io(:stderr, fn -> assert run([], refusing(:service_unbound)) == 1 end)

      assert stderr =~ "No home is bound"
      refute stderr =~ "service_unbound"
    end
  end

  # There is no scope to choose on a packaged install: the package owns the one
  # user unit, so a scope flag is a usage error rather than a silent no-op.
  test "an unknown flag is a usage error, and nothing is restarted" do
    stderr = capture_io(:stderr, fn -> assert run(["--system"], refusing()) == 2 end)

    assert stderr =~ "invalid options"
    assert stderr =~ "fermix restart [--json] [--when-idle]"
  end

  test "a positional argument is a usage error" do
    stderr = capture_io(:stderr, fn -> assert run(["now"], refusing()) == 2 end)

    assert stderr =~ "unexpected argument: now"
  end

  defp run(argv, deps), do: RestartCommand.run(argv, deps)

  defp answering(result) do
    [build_info: PackagedBuildInfo, service: answering_service(result)]
  end

  defp answering_service(result) do
    Process.put(:restart_result, result)
    __MODULE__.AnsweringService
  end

  defp refusing, do: [build_info: PackagedBuildInfo, service: RefusingService]

  defp refusing(reason) do
    Process.put(:restart_reason, reason)
    [build_info: PackagedBuildInfo, service: __MODULE__.RefusedService]
  end

  defmodule AnsweringService do
    @moduledoc false
    def restart(:user, _opts), do: {:ok, Process.get(:restart_result)}
  end

  defmodule RefusedService do
    @moduledoc false
    def restart(:user, _opts), do: {:error, Process.get(:restart_reason)}
  end
end
