defmodule FermixCore.ComputerUse.SidecarInstallerTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Upgrade.Manifest
  alias FermixCore.ComputerUse.SidecarInstaller

  setup do
    prev = System.get_env("FERMIX_HOME")

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-cu-installer",
        "home-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(home)
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    {:ok, {os, arch}} = Manifest.target_for_host()
    %{home: home, target: "#{os}-#{arch}"}
  end

  defp current_dir(home),
    do: Path.join([home, "plugins", "installed", "computer_use_sidecar", "current"])

  defp fake_install(home, target, mode) do
    version_dir = Path.join([home, "plugins", "installed", "computer_use_sidecar", "0.1.0"])
    bin_dir = Path.join([version_dir, "bin", target])
    File.mkdir_p!(bin_dir)
    binary = Path.join(bin_dir, "fermix-computer-use")
    File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, mode)
    File.ln_s!(version_dir, current_dir(home))
    binary
  end

  test "binary_path resolves through the store's current symlink (no fabricated path)",
       %{home: home, target: target} do
    assert {:ok, path} = SidecarInstaller.binary_path()

    assert path ==
             Path.join([
               home,
               "plugins",
               "installed",
               "computer_use_sidecar",
               "current",
               "bin",
               target,
               "fermix-computer-use"
             ])
  end

  test "installed? is false when no version is installed" do
    refute SidecarInstaller.installed?()
  end

  test "installed? is true once a 0755 binary is present under current/", %{
    home: home,
    target: target
  } do
    fake_install(home, target, 0o755)
    assert SidecarInstaller.installed?()
  end

  test "installed? is false when the binary is present but NOT executable", %{
    home: home,
    target: target
  } do
    fake_install(home, target, 0o644)
    refute SidecarInstaller.installed?()
  end

  test "install/0 routes through the signed pipeline and fails closed with no catalog entry" do
    # The bundled index ships no computer_use_sidecar entry yet (that catalog entry
    # is coordinated separately), so run_install resolves no plugin and returns an
    # error — proving install/0 wires to the verified pipeline and never silently
    # no-ops. (Runs entirely under the tmp FERMIX_HOME store; no network.)
    assert {:error, _reason} = SidecarInstaller.install()
  end

  describe "dev_local resolution" do
    setup do
      prev = Application.get_env(:fermix_core, :plugins)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:fermix_core, :plugins)
          value -> Application.put_env(:fermix_core, :plugins, value)
        end
      end)

      :ok
    end

    test "a dev_local build wins over the installed store path", %{home: home, target: target} do
      bin_dir = Path.join([home, "dev-plugins", "computer_use_sidecar", "bin", target])
      File.mkdir_p!(bin_dir)
      binary = Path.join(bin_dir, "fermix-computer-use")
      File.write!(binary, "#!/bin/sh\n")
      File.chmod!(binary, 0o755)
      Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))

      assert {:ok, ^binary} = SidecarInstaller.binary_path()
      assert SidecarInstaller.installed?()
    end

    test "no dev_local build falls back to the installed store path", %{home: home} do
      Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "empty-dev"))

      assert {:ok, path} = SidecarInstaller.binary_path()
      assert path =~ "installed/computer_use_sidecar/current"
      refute SidecarInstaller.installed?()
    end
  end
end
