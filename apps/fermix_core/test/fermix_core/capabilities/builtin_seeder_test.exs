defmodule FermixCore.Capabilities.BuiltinSeederTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Upgrade.Manifest
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  # The computer-use tool is the only conditionally-seeded built-in that depends on
  # host state (`ComputerUse.ready?/0` = enabled + sidecar installed + permissions).
  # These tests pin both ends of that gate: off (the default) seeds nothing; a ready
  # daemon seeds it with the explicit `:gui_control` classification — never the
  # silent `:read_only` default that would misclassify the most dangerous tool.
  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_cu = Application.get_env(:fermix_core, :computer_use)
    prev_watch = Application.get_env(:fermix_core, :watch)
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-builtin-seeder",
        "home-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(home)
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      restore_env(:computer_use, prev_cu)
      restore_env(:watch, prev_watch)
      restore_env(:plugins, prev_plugins)

      case prev_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    registry_name = :"cu_seeder_reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CapabilityRegistry.start_link(name: registry_name)

    {:ok, {os, arch}} = Manifest.target_for_host()
    %{home: home, registry: registry_name, target: "#{os}-#{arch}"}
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  defp seed(registry), do: BuiltinSeeder.start_link(capability_registry: registry)

  test "does NOT seed computer_use when the feature is disabled (default)", %{registry: reg} do
    Application.put_env(:fermix_core, :computer_use, enabled: false)

    :ignore = seed(reg)

    assert CapabilityRegistry.find(reg, "computer_use") == :error
    # Sanity: the rest of the catalog still seeds.
    assert {:ok, _shell} = CapabilityRegistry.find(reg, "shell")
  end

  test "does NOT seed computer_use when enabled but the sidecar is not installed", %{
    registry: reg
  } do
    Application.put_env(:fermix_core, :computer_use, enabled: true)

    :ignore = seed(reg)

    assert CapabilityRegistry.find(reg, "computer_use") == :error
  end

  test "seeds computer_use with :gui_control when enabled AND the sidecar is installed", %{
    home: home,
    registry: reg,
    target: target
  } do
    install_dev_local_sidecar(home, target)
    Application.put_env(:fermix_core, :computer_use, enabled: true)
    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))

    :ignore = seed(reg)

    assert {:ok, cap} = CapabilityRegistry.find(reg, "computer_use")
    assert cap.policy_class == :gui_control
    assert cap.metadata.category == :computer
  end

  test "does NOT seed watch/stop_watch when the feature is disabled (default)", %{registry: reg} do
    Application.put_env(:fermix_core, :watch, enabled: false)

    :ignore = seed(reg)

    assert CapabilityRegistry.find(reg, "watch") == :error
    assert CapabilityRegistry.find(reg, "stop_watch") == :error
  end

  test "seeds watch + stop_watch (both :gui_control) when enabled", %{registry: reg} do
    Application.put_env(:fermix_core, :watch, enabled: true)

    :ignore = seed(reg)

    assert {:ok, watch} = CapabilityRegistry.find(reg, "watch")
    assert watch.policy_class == :gui_control
    # stop_watch is :gui_control too so a subagent (which keeps :exec but not
    # :gui_control) can't stop the operator's live watch.
    assert {:ok, stop} = CapabilityRegistry.find(reg, "stop_watch")
    assert stop.policy_class == :gui_control
  end

  defp install_dev_local_sidecar(home, target) do
    bin_dir =
      Path.join([home, "dev-plugins", "computer_use_sidecar", "bin", target])

    File.mkdir_p!(bin_dir)
    binary = Path.join(bin_dir, "compux")
    File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, 0o755)
    binary
  end
end
