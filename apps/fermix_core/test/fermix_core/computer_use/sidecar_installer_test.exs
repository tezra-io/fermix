defmodule FermixCore.ComputerUse.SidecarInstallerTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.SidecarInstaller

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-cu-installer",
        "home-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(home)
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case prev_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case prev_plugins do
        nil -> Application.delete_env(:fermix_core, :plugins)
        value -> Application.put_env(:fermix_core, :plugins, value)
      end

      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    {:ok, target} = Compux.Binary.target()
    %{home: home, target: target, version: to_string(Application.spec(:compux, :vsn))}
  end

  defp write_bin(path, mode) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, mode)
    path
  end

  # A fermix `[fermix_core.plugins] dev_local` checkout of the sidecar.
  defp dev_local_binary(home, target, mode) do
    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))

    write_bin(
      Path.join([home, "dev-plugins", "computer_use_sidecar", "bin", target, "compux"]),
      mode
    )
  end

  # The compux download cache under FERMIX_HOME/plugins/compux/<vsn>/<target>/compux.
  defp cache_binary(home, version, target, mode) do
    write_bin(Path.join([home, "plugins", "compux", version, target, "compux"]), mode)
  end

  test "plugin_name is the stable card identifier" do
    assert SidecarInstaller.plugin_name() == "computer_use_sidecar"
  end

  test "installed? is false with neither a dev_local build nor a cached binary" do
    refute SidecarInstaller.installed?()
  end

  describe "dev_local build (the plugin-author loop)" do
    test "binary_path + installed? resolve a 0755 dev_local build", %{home: home, target: target} do
      binary = dev_local_binary(home, target, 0o755)
      assert {:ok, ^binary} = SidecarInstaller.binary_path()
      assert SidecarInstaller.installed?()
    end

    test "installed? is false when the dev_local binary is not executable", %{
      home: home,
      target: target
    } do
      dev_local_binary(home, target, 0o644)
      refute SidecarInstaller.installed?()
    end
  end

  describe "compux download cache" do
    test "installed? + binary_path resolve a cached 0755 binary", %{
      home: home,
      target: target,
      version: version
    } do
      binary = cache_binary(home, version, target, 0o755)
      assert SidecarInstaller.installed?()
      assert {:ok, ^binary} = SidecarInstaller.binary_path()
    end

    test "installed? on an empty cache stays false WITHOUT downloading", %{home: _home} do
      # The readiness hot path must never trigger a network fetch. With no cached
      # binary and no dev_local build, installed? is a pure false.
      refute SidecarInstaller.installed?()
    end
  end

  test "the checksum gate passes for this host now that compux v0.3.0 shipped", %{home: home} do
    # The pinned compux ref ships a populated checksum map for both released
    # targets (macos-aarch64, linux-x86_64), so the download no longer fails at
    # the checksum gate. The stub fetcher keeps the test hermetic: reaching it
    # proves the gate passed for this host's target; no bytes are fetched.
    assert {:error, :network_disabled_in_tests} =
             Compux.Binary.path(
               cache_dir: Path.join(home, "cache"),
               fetcher: fn _url -> {:error, :network_disabled_in_tests} end
             )
  end
end
