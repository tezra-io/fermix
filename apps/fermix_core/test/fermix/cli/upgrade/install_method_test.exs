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
    assert {:unmanaged, "/opt/local/bin/fermix"} =
             InstallMethod.detect("/opt/local/bin/fermix")
  end

  test "follows symlink targets into the brew Cellar" do
    tmp = FermixTestSupport.SafeRm.make_tmp_dir!("symlink")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp) end)

    cellar_dir = Path.join(tmp, "Cellar/fermix/0.1.0/bin")
    File.mkdir_p!(cellar_dir)
    cellar_target = Path.join(cellar_dir, "fermix")
    File.write!(cellar_target, "binary")

    bin_dir = Path.join(tmp, "bin")
    File.mkdir_p!(bin_dir)
    link_path = Path.join(bin_dir, "fermix")
    File.ln_s!(cellar_target, link_path)

    assert {:managed, :homebrew, "brew upgrade fermix"} =
             InstallMethod.detect(link_path)
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
