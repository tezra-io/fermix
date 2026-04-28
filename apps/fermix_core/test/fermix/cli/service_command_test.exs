defmodule Fermix.CLI.ServiceCommandTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.ServiceCommand

  @switches [user: :boolean, system: :boolean]

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
    test "linger_failed surfaces the embedded operator message verbatim" do
      msg =
        "loginctl enable-linger you failed (exit 1): permission denied. Re-run after granting."

      assert ServiceCommand.format_reason({:linger_failed, 1, msg}) == msg
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
end
