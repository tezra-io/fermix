defmodule FermixCore.Plugins.StatusTest do
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Dist.McpSource
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

  defp api_key_manifest do
    %{
      "auth" => %{"type" => "api_key", "header" => "authorization", "scopes" => []},
      "tools" => []
    }
  end

  # A plugin-api-3 `remote_mcp` manifest: signed profiles, one setup-only
  # discovery tool, and a single-workspace resource scope (M27 §7.2, §8.1).
  defp remote_manifest do
    %{
      "plugin_api" => 3,
      "min_core_version" => "0.1.0",
      "auth" => %{
        "type" => "api_key",
        "key_name" => "WORKSPACEDEMO_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste a token"
      },
      "runtime" => %{
        "kind" => "remote_mcp",
        "transport" => "streamable_http",
        "protocol_version" => "2025-06-18",
        "base_url" => "https://mcp.example.com",
        "mcp_path" => "/mcp",
        "tool_name_mode" => "preserve"
      },
      "tool_profiles" => [
        %{
          "name" => "retrieval",
          "display_name" => "Retrieval only",
          "default" => true,
          "required_credential_scope" => "read",
          "scope_visibility" => "none",
          "tools" => ["workspacedemo_search"]
        }
      ],
      "setup_tools" => ["workspacedemo_list_workspaces"],
      "resource_scope" => %{
        "kind" => "single_workspace",
        "discovery_tool" => "workspacedemo_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      "budgets" => %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      "result_contract" => %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      "tools" => [
        sign(%{
          "name" => "workspacedemo_list_workspaces",
          "description" => "List workspaces.",
          "policy_class" => "external_api",
          "read_only" => true,
          "replay_safe" => false,
          "required_credential_scope" => "read",
          "rail" => "mcp",
          "collection_policy" => nil,
          "argument_guards" => [],
          "parameters" => %{"type" => "object", "properties" => %{}},
          "output_schema" => nil,
          "upstream_annotations" => nil
        }),
        sign(%{
          "name" => "workspacedemo_search",
          "description" => "Search a workspace.",
          "policy_class" => "external_api",
          "read_only" => true,
          "replay_safe" => true,
          "required_credential_scope" => "read",
          "rail" => "mcp",
          "collection_policy" => nil,
          "argument_guards" => [],
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "workspaceId" => %{"type" => "string"},
              "query" => %{"type" => "string"}
            }
          },
          "output_schema" => nil,
          "upstream_annotations" => nil
        })
      ]
    }
  end

  defp sign(tool) do
    {:ok, digest} =
      CanonicalJson.descriptor_digest(
        Map.fetch!(tool, "name"),
        Map.fetch!(tool, "parameters"),
        Map.get(tool, "output_schema"),
        Map.get(tool, "upstream_annotations")
      )

    Map.put(tool, "descriptor_sha256", digest)
  end

  defp load_plugin(checkout, name) do
    {:ok, plugins} = Registry.list(dev_local: checkout)
    Enum.find(plugins, &(&1.name == name)) || raise "plugin #{name} not loaded"
  end

  defp put_plugin_secrets(secrets) do
    previous = Application.get_env(:fermix_core, :plugin_secrets, %{})
    Application.put_env(:fermix_core, :plugin_secrets, secrets)
    on_exit(fn -> Application.put_env(:fermix_core, :plugin_secrets, previous) end)
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

  test "an enabled api_key plugin with no stored secret is :needs_secret", %{checkout: checkout} do
    write_plugin(checkout, "keyfix", api_key_manifest())
    put_plugins_env(["keyfix"], %{})
    put_plugin_secrets(%{})
    plugin = load_plugin(checkout, "keyfix")

    assert Status.status(plugin) == :needs_secret
  end

  test "an enabled api_key plugin with a stored secret is :ready", %{checkout: checkout} do
    write_plugin(checkout, "keyfix", api_key_manifest())
    put_plugins_env(["keyfix"], %{})
    put_plugin_secrets(%{"keyfix" => "tok"})
    plugin = load_plugin(checkout, "keyfix")

    assert Status.status(plugin) == :ready
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

  describe "remote plugins (M27 §7.8)" do
    setup %{checkout: checkout} do
      write_plugin(checkout, "workspacedemo", remote_manifest())
      :ok
    end

    test "a credential but no selected workspace is :needs_workspace", %{checkout: checkout} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => []})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_plugin(checkout, "workspacedemo")) == :needs_workspace
    end

    # `:needs_workspace` is not `:ready`, so no server spec materializes, so no
    # MCP child spawns, so no capability is ever discovered: zero agent tools.
    test "…and it materializes no server spec, so it registers no tools", %{checkout: checkout} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => []})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert {:ok, specs} = McpSource.server_specs(registry: [dev_local: checkout])
      assert specs == []
    end

    test "the secret is asked for first: no credential is :needs_secret", %{checkout: checkout} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => [{"workspace_id", "ws_alpha"}]})
      put_plugin_secrets(%{})

      assert Status.status(load_plugin(checkout, "workspacedemo")) == :needs_secret
    end

    test "a credential and a selected workspace is :ready", %{checkout: checkout} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => [{"workspace_id", "ws_alpha"}]})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_plugin(checkout, "workspacedemo")) == :ready
      assert {:ok, [spec]} = McpSource.server_specs(registry: [dev_local: checkout])
      assert spec.selected_profile == "retrieval"
    end

    test "an undeclared access profile is invalid config, never the safe default", %{
      checkout: checkout
    } do
      entry = [{"workspace_id", "ws_alpha"}, {"access_profile", "captur"}]
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => entry})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_plugin(checkout, "workspacedemo")) == :invalid_remote_config
    end

    test "a workspace id that is not opaque visible ASCII is invalid config", %{
      checkout: checkout
    } do
      entry = [{"workspace_id", "ws alpha"}]
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => entry})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_plugin(checkout, "workspacedemo")) == :invalid_remote_config
    end
  end

  test "ready?/1 is unchanged for plugins without a runtime block", %{checkout: checkout} do
    write_plugin(checkout, "notes", %{})
    put_plugins_env(["notes"], %{})
    plugin = load_plugin(checkout, "notes")

    assert Status.ready?(plugin)
  end
end
