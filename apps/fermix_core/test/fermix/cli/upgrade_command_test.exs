defmodule Fermix.CLI.UpgradeCommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fermix.CLI.UpgradeCommand

  defmodule ManagedUpgrade do
    def run, do: {:error, {:managed_install, :homebrew, "brew upgrade fermix"}}
  end

  test "managed-install refusal names the restart step after the package manager" do
    {exit_code, output} = with_io(:stderr, fn -> UpgradeCommand.run([], ManagedUpgrade) end)

    assert exit_code == 2
    assert output =~ "managed by homebrew"
    assert output =~ "brew upgrade fermix"
    assert output =~ "`fermix restart`"
  end
end
