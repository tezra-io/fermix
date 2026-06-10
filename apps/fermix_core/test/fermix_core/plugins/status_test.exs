defmodule FermixCore.Plugins.StatusTest do
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status
  alias FermixCore.Setup.ConfigStore

  defp probe_ok do
    [
      find_executable: fn _cmd -> "/usr/bin/node" end,
      version_fetch: fn _cmd -> {:ok, "v20.11.1\n"} end
    ]
  end

  defp probe_missing do
    [
      find_executable: fn _cmd -> nil end,
      version_fetch: fn _cmd -> raise "must not version-check a missing binary" end
    ]
  end

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugin-status-home")
    checkout = FermixTestSupport.SafeRm.make_tmp_dir!("plugin-status-checkout")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :oauth, %{})

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      FermixTestSupport.SafeRm.rm_rf!(home)
      FermixTestSupport.SafeRm.rm_rf!(checkout)
    end)

    %{checkout: checkout}
  end

  defp write_plugin(checkout, name, manifest_extra) do
    dir = Path.join(checkout, name)
    File.mkdir_p!(dir)

    manifest =
      Map.merge(
        %{
          "schema_version" => 2,
          "name" => name,
          "display_name" => name,
          "description" => "#{name} test plugin",
          "category" => "productivity",
          "version" => "1.0.0",
          "plugin_api" => 2,
          "auth" => %{"type" => "none"},
          "tools" => []
        },
        manifest_extra
      )

    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest))
    dir
  end

  defp mcp_manifest do
    %{
      "runtime" => %{
        "kind" => "node",
        "min_version" => "20",
        "command" => "node",
        "args" => ["src/index.js"],
        "vendored" => false
      },
      "config" => [
        %{"key" => "OBSIDIAN_VAULT_PATH", "prompt" => "Path to your vault", "required" => true}
      ],
      "tools" => [
        %{
          "name" => "obsidian_search_notes",
          "description" => "Full-text search across the vault",
          "rail" => "mcp",
          "read_only" => true
        }
      ]
    }
  end

  defp load_plugin(checkout, name) do
    {:ok, plugins} = Registry.list(dev_local: checkout)
    Enum.find(plugins, &(&1.name == name)) || raise "plugin #{name} not loaded"
  end

  defp put_plugins_env(enabled, entries) do
    Application.put_env(:fermix_core, :plugins, enabled: enabled, entries: entries)
  end

  test "an enabled mcp plugin with a healthy probe and config is ready", %{checkout: checkout} do
    write_plugin(checkout, "obsidian", mcp_manifest())
    put_plugins_env(["obsidian"], %{"obsidian" => [{"OBSIDIAN_VAULT_PATH", "/tmp/vault"}]})
    plugin = load_plugin(checkout, "obsidian")

    assert Status.status(plugin, probe: probe_ok()) == :ready
  end

  test "a failing host-runtime probe yields :missing_host_runtime", %{checkout: checkout} do
    write_plugin(checkout, "obsidian", mcp_manifest())
    put_plugins_env(["obsidian"], %{"obsidian" => [{"OBSIDIAN_VAULT_PATH", "/tmp/vault"}]})
    plugin = load_plugin(checkout, "obsidian")

    assert Status.status(plugin, probe: probe_missing()) == :missing_host_runtime
  end

  test "a required config key absent from the plugin entry yields :needs_config", %{
    checkout: checkout
  } do
    write_plugin(checkout, "obsidian", mcp_manifest())
    put_plugins_env(["obsidian"], %{"obsidian" => []})
    plugin = load_plugin(checkout, "obsidian")

    assert Status.status(plugin, probe: probe_ok()) == :needs_config
  end

  test "a disabled plugin is :not_configured before any runtime check", %{checkout: checkout} do
    write_plugin(checkout, "obsidian", mcp_manifest())
    put_plugins_env([], %{})
    plugin = load_plugin(checkout, "obsidian")

    assert Status.status(plugin, probe: probe_missing()) == :not_configured
  end

  test "an enabled name absent from every plugin source is :not_installed" do
    put_plugins_env(["ghost"], %{})

    assert Status.status("ghost") == :not_installed
  end

  test "an enabled name whose store entry is incompatible is :incompatible" do
    root = ConfigStore.workspace_paths().plugins
    DistStore.ensure!(root)
    :ok = DistStore.record(root, "oldie", %{"version" => "1.0.0", "plugin_api" => 99})
    put_plugins_env(["oldie"], %{})

    assert Status.status("oldie") == :incompatible
  end

  test "a disabled unknown name stays :not_configured" do
    put_plugins_env([], %{})

    assert Status.status("ghost") == :not_configured
  end

  test "ready?/1 is unchanged for plugins without a runtime block", %{checkout: checkout} do
    write_plugin(checkout, "notes", %{})
    put_plugins_env(["notes"], %{})
    plugin = load_plugin(checkout, "notes")

    assert Status.ready?(plugin)
  end
end
