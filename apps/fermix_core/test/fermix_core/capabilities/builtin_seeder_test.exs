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

  # The installed-check resolves through Compux.Binary.target/0, which supports
  # fewer hosts than Manifest.target_for_host/0 (no linux-aarch64) — on those
  # hosts an installed sidecar is impossible, so this test cannot pass there.
  case Compux.Binary.target() do
    {:ok, _target} ->
      :ok

    {:error, reason} ->
      @tag skip: "compux sidecar unsupported on this host: #{inspect(reason)}"
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

  # --- Coding-harness seeding gate (§7.3 boot snapshot) -------------------

  describe "harness_modules/1 gating" do
    test "seeds nothing when the harness is disabled, even if both CLIs are present" do
      assert BuiltinSeeder.harness_modules(
               harness_enabled: false,
               vendor_available_fn: fn _vendor -> true end
             ) == []
    end

    test "seeds nothing when enabled but no vendor CLI is detected" do
      assert BuiltinSeeder.harness_modules(
               harness_enabled: true,
               vendor_available_fn: fn _vendor -> false end
             ) == []
    end

    test "codex-only detection seeds codex_run plus the shared history tools" do
      modules =
        BuiltinSeeder.harness_modules(
          harness_enabled: true,
          cloud_enabled: false,
          vendor_available_fn: fn
            "codex" -> true
            _ -> false
          end
        )

      assert FermixCore.Tools.CodexRun in modules
      refute FermixCore.Tools.ClaudeCodeRun in modules
      assert FermixCore.Tools.ListCodingRuns in modules
      assert FermixCore.Tools.GetCodingRun in modules
      assert FermixCore.Tools.CancelCodingRun in modules
      # The cloud rail is OFF by default this release — the codex-gated cloud tools
      # are not seeded even though the codex CLI is present.
      refute FermixCore.Tools.CodexCloudRun in modules
      refute FermixCore.Tools.StopTrackingCodingRun in modules
    end

    test "the cloud tools seed only when cloud_enabled AND the codex CLI is present" do
      cloud_on =
        BuiltinSeeder.harness_modules(
          harness_enabled: true,
          cloud_enabled: true,
          vendor_available_fn: fn _vendor -> true end
        )

      assert FermixCore.Tools.CodexCloudRun in cloud_on
      assert FermixCore.Tools.StopTrackingCodingRun in cloud_on

      # cloud_enabled but no codex CLI → the codex-gated cloud tools stay absent.
      claude_only =
        BuiltinSeeder.harness_modules(
          harness_enabled: true,
          cloud_enabled: true,
          vendor_available_fn: fn
            "claude" -> true
            _ -> false
          end
        )

      refute FermixCore.Tools.CodexCloudRun in claude_only
      refute FermixCore.Tools.StopTrackingCodingRun in claude_only
    end

    test "claude-only detection seeds claude_code_run plus the shared history tools" do
      modules =
        BuiltinSeeder.harness_modules(
          harness_enabled: true,
          vendor_available_fn: fn
            "claude" -> true
            _ -> false
          end
        )

      assert FermixCore.Tools.ClaudeCodeRun in modules
      refute FermixCore.Tools.CodexRun in modules
      assert FermixCore.Tools.ListCodingRuns in modules
      # The cloud tools are codex-gated — absent when only claude is present.
      refute FermixCore.Tools.CodexCloudRun in modules
      refute FermixCore.Tools.StopTrackingCodingRun in modules
    end

    test "both CLIs seed both run tools once each" do
      modules =
        BuiltinSeeder.harness_modules(
          harness_enabled: true,
          vendor_available_fn: fn _vendor -> true end
        )

      assert FermixCore.Tools.CodexRun in modules
      assert FermixCore.Tools.ClaudeCodeRun in modules
      assert Enum.count(modules, &(&1 == FermixCore.Tools.CodexRun)) == 1
    end

    test "all harness tools are in the classification-coverage list unconditionally" do
      coverage = BuiltinSeeder.builtin_tool_modules()

      for module <- [
            FermixCore.Tools.CodexRun,
            FermixCore.Tools.ClaudeCodeRun,
            FermixCore.Tools.CodexCloudRun,
            FermixCore.Tools.ListCodingRuns,
            FermixCore.Tools.GetCodingRun,
            FermixCore.Tools.CancelCodingRun,
            FermixCore.Tools.StopTrackingCodingRun
          ] do
        assert module in coverage
      end
    end
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
