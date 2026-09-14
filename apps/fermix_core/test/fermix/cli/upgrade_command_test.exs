defmodule Fermix.CLI.UpgradeCommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fermix.CLI.UpgradeCommand

  defmodule ManagedUpgrade do
    def run, do: {:error, {:managed_install, :homebrew, "brew upgrade fermix"}}
  end

  defmodule PackagedUpgrade do
    @hint "sudo apt update && sudo apt upgrade fermix (Fedora and RHEL: " <>
            "sudo dnf upgrade fermix; openSUSE: sudo zypper update fermix)"

    def run, do: {:error, {:managed_install, :linux_package, @hint}}
  end

  test "managed-install refusal names the restart step after the package manager" do
    {exit_code, output} = with_io(:stderr, fn -> UpgradeCommand.run([], ManagedUpgrade) end)

    assert exit_code == 2
    assert output =~ "managed by homebrew"
    assert output =~ "brew upgrade fermix"
    assert output =~ "`fermix restart`"
  end

  test "a packaged engine's refusal reads as words and carries every family" do
    {exit_code, output} = with_io(:stderr, fn -> UpgradeCommand.run([], PackagedUpgrade) end)

    assert exit_code == 2
    assert output =~ "managed by this machine's package manager"
    refute output =~ "linux_package"
    assert output =~ "sudo apt update && sudo apt upgrade fermix"
    assert output =~ "sudo dnf upgrade fermix"
    assert output =~ "sudo zypper update fermix"
    assert output =~ "`fermix restart`"
  end
end
