defmodule Fermix.CLI.Upgrade.InstallMethodTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade.InstallMethod

  test "homebrew Cellar paths are managed by brew" do
    assert {:managed, :homebrew, hint} =
             InstallMethod.detect("/opt/homebrew/Cellar/fermix/0.1.0/bin/fermix")

    assert hint == "brew upgrade fermix"
  end

  test "intel-mac brew prefix is detected" do
    assert {:managed, :homebrew, _hint} =
             InstallMethod.detect("/usr/local/Cellar/fermix/0.1.0/bin/fermix")
  end

  test "anything outside a package-manager root is unmanaged" do
    assert {:unmanaged, "/usr/local/bin/fermix"} =
             InstallMethod.detect("/usr/local/bin/fermix")
  end

  test "errors when fermix is not on PATH and no path is supplied" do
    refute_assert_or_pass = fn ->
      case InstallMethod.detect(nil) do
        {:error, :fermix_not_on_path} -> :ok
        {:unmanaged, _} -> :ok
        other -> flunk("unexpected result: #{inspect(other)}")
      end
    end

    refute_assert_or_pass.()
  end
end
