defmodule FermixCore.Plugins.StatusTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.DistVerifierStub

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

    store = Path.join(home, "plugins")
    fixtures = Path.join(home, "fixtures")
    File.mkdir_p!(fixtures)
    DistStore.ensure!(store)

    %{checkout: checkout, store: store, fixtures: fixtures}
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

  defp load_installed(store, name) do
    {:ok, plugins} = Registry.list(installed_root: store)
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

  # A remote manifest is loadable ONLY from a verified artifact (M27 §9.3), so
  # these install one rather than dropping it in a dev_local checkout — that path
  # is refused by design, and a test that used it would be asserting against a
  # plugin the product will never load.
  describe "remote plugins (M27 §7.8)" do
    setup %{store: store, fixtures: fixtures} do
      DistVerifierStub.init()
      on_exit(&DistVerifierStub.cleanup/0)

      :ok =
        DistFixtures.install_remote_plugin(
          store,
          fixtures,
          "workspacedemo",
          "1.0.0",
          remote_manifest()
        )

      :ok = DistVerifierStub.allow("workspacedemo", "1.0.0")
      :ok
    end

    test "a credential but no selected workspace is :needs_workspace", %{store: store} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => []})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_installed(store, "workspacedemo")) == :needs_workspace
    end

    # `:needs_workspace` is not `:ready`, so no server spec materializes, so no
    # MCP child spawns, so no capability is ever discovered: zero agent tools.
    test "…and it materializes no server spec, so it registers no tools", %{store: store} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => []})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert {:ok, specs} =
               McpSource.server_specs(registry: [installed_root: store])

      assert specs == []
    end

    test "the secret is asked for first: no credential is :needs_secret", %{store: store} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => [{"workspace_id", "ws_alpha"}]})
      put_plugin_secrets(%{})

      assert Status.status(load_installed(store, "workspacedemo")) == :needs_secret
    end

    test "a credential and a selected workspace is :ready", %{store: store} do
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => [{"workspace_id", "ws_alpha"}]})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_installed(store, "workspacedemo")) == :ready

      assert {:ok, [spec]} =
               McpSource.server_specs(registry: [installed_root: store])

      assert spec.selected_profile == "retrieval"
    end

    test "an undeclared access profile is invalid config, never the safe default", %{
      store: store
    } do
      entry = [{"workspace_id", "ws_alpha"}, {"access_profile", "captur"}]
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => entry})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_installed(store, "workspacedemo")) == :invalid_remote_config
    end

    test "a workspace id that is not opaque visible ASCII is invalid config", %{
      store: store
    } do
      entry = [{"workspace_id", "ws alpha"}]
      put_plugins_env(["workspacedemo"], %{"workspacedemo" => entry})
      put_plugin_secrets(%{"workspacedemo" => "tok"})

      assert Status.status(load_installed(store, "workspacedemo")) == :invalid_remote_config
    end
  end

  test "ready?/1 is unchanged for plugins without a runtime block", %{checkout: checkout} do
    write_plugin(checkout, "notes", %{})
    put_plugins_env(["notes"], %{})
    plugin = load_plugin(checkout, "notes")

    assert Status.ready?(plugin)
  end

  # A grant quarantined because the provider refused the saved sign-in client
  # publishes the existing `:reauthorization_required` status (the vocabulary,
  # the verbs and the action ids do not grow), and one predicate lets the
  # surfaces that word the cause tell it apart.
  describe "a grant whose sign-in client was refused" do
    setup do
      put_plugins_env(["google_calendar"], %{})

      Application.put_env(:fermix_core, :oauth, %{
        "google" => [client_id: "123.apps.googleusercontent.com", client_secret: "stale"]
      })

      {:ok, plugin} = Registry.find("google_calendar")
      %{plugin: plugin}
    end

    defp store_grant(plugin, status) do
      :ok =
        Store.write(Config.auth_profile(plugin), %{
          auth_mode: "oauth2",
          provider: "google",
          granted_scopes: [],
          tokens: %{access_token: "AT", refresh_token: "RT"},
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          last_refresh: nil,
          status: status
        })
    end

    test "is quarantined as :reauthorization_required", %{plugin: plugin} do
      store_grant(plugin, "client_rejected")

      assert Status.status(plugin) == :reauthorization_required
      assert Status.status("google_calendar") == :reauthorization_required
      refute Status.ready?(plugin)
    end

    test "is told apart by client_rejected?/1, and only it is", %{plugin: plugin} do
      store_grant(plugin, "client_rejected")
      assert Status.client_rejected?(plugin)
      assert Status.client_rejected?("google_calendar")

      for other <- ["ready", "reauthorization_required", "invalidated"] do
        store_grant(plugin, other)
        refute Status.client_rejected?(plugin), "#{other} read as a refused client"
      end
    end

    test "a plugin with no stored grant, or no such plugin, is not a refused client" do
      refute Status.client_rejected?("google_calendar")
      refute Status.client_rejected?("ghost")
    end

    # The predicate must answer identically in a tree-less CLI VM, so it reads
    # the auth store and nothing else: no token manager is asked, or started.
    test "reads the store alone, starting no token manager", %{plugin: plugin} do
      store_grant(plugin, "client_rejected")
      profile = Config.auth_profile(plugin)

      assert Status.client_rejected?(plugin)
      assert Elixir.Registry.lookup(FermixCore.Auth.TokenRegistry, profile) == []
    end
  end

  # --- M40 §3.2: the account region and per-tool setting gates -------------
  #
  # `region/1` reads the same stored grant `granted_scopes/1` reads, so it
  # answers identically in a tree-less CLI VM. The value itself is recorded by
  # the OAuth sign-in that learns the account's region.
  describe "region/1" do
    test "is nil for a plugin with no stored grant", %{checkout: checkout} do
      write_plugin(checkout, "regiofix", oauth_manifest())
      put_plugins_env(["regiofix"], %{})

      assert Status.region(load_plugin(checkout, "regiofix")) == nil
    end

    test "is nil when the stored grant records no region", %{checkout: checkout} do
      plugin = grant_without_region(checkout)

      assert Status.region(plugin) == nil
    end

    test "is the region the sign-in recorded on the grant", %{checkout: checkout} do
      plugin = grant_without_region(checkout)

      :ok = Store.write(Config.auth_profile(plugin), stored_grant(region: "na"))
      assert Status.region(plugin) == "na"

      :ok = Store.write(Config.auth_profile(plugin), stored_grant(region: "eu"))
      assert Status.region(plugin) == "eu"
    end
  end

  # A regional provider's sign-in client is incomplete until the region is
  # chosen: the audience the exchange must send comes from it, so a client
  # without one cannot sign in at all. The ladder says so in the one word that
  # leads with "Set up the sign-in client" rather than sending the owner to a
  # sign-in the daemon refuses.
  describe "a regional provider's sign-in client" do
    setup %{checkout: checkout} do
      write_plugin(checkout, "teslafix", tesla_manifest())
      put_plugins_env(["teslafix"], %{})

      %{plugin: load_plugin(checkout, "teslafix")}
    end

    test "with an identifier and a secret but no region is needs_client_config", %{plugin: plugin} do
      put_tesla_client([])

      assert Status.status(plugin) == :needs_client_config
    end

    test "with a blank region is needs_client_config", %{plugin: plugin} do
      put_tesla_client(region: "  ")

      assert Status.status(plugin) == :needs_client_config
    end

    test "with a region chosen falls through to the auth ladder", %{plugin: plugin} do
      put_tesla_client(region: "eu")

      assert Status.status(plugin) == :needs_auth
    end

    # A provider with one region has no region to choose, so the ladder must not
    # hold a complete client back waiting for one.
    test "a provider with one region is never held back by it", %{checkout: checkout} do
      write_plugin(checkout, "regiofix", oauth_manifest())
      put_plugins_env(["regiofix"], %{})

      Application.put_env(:fermix_core, :oauth, %{
        "google" => [client_id: "cid", client_secret: "sec"]
      })

      assert Status.status(load_plugin(checkout, "regiofix")) == :needs_auth
    end
  end

  # Tesla answers every Fleet API call from the wrong region with 421, so a
  # sign-in confirms the account's own region and records a mismatch on the
  # grant. The ladder publishes it as its own word: the fix is the sign-in
  # client, not a renewed sign-in.
  describe "a grant minted for the wrong region" do
    setup %{checkout: checkout} do
      write_plugin(checkout, "teslafix", tesla_manifest())
      put_plugins_env(["teslafix"], %{})
      put_tesla_client(region: "na")

      %{plugin: load_plugin(checkout, "teslafix")}
    end

    test "is wrong_region, not ready and not a renewal", %{plugin: plugin} do
      :ok =
        Store.write(
          Config.auth_profile(plugin),
          stored_grant(status: "wrong_region", region: "na", region_actual: "eu")
        )

      assert Status.status(plugin) == :wrong_region
    end

    test "names the account's own region beside the chosen one", %{plugin: plugin} do
      :ok =
        Store.write(
          Config.auth_profile(plugin),
          stored_grant(status: "wrong_region", region: "na", region_actual: "eu")
        )

      assert Status.region(plugin) == "na"
      assert Status.region_actual(plugin) == "eu"
    end

    # Tesla's 421 does not always name a base URL this registry knows, so the
    # mismatch is recorded with no account region rather than a guessed one.
    test "records the mismatch even when the account's region is unknown", %{plugin: plugin} do
      :ok =
        Store.write(
          Config.auth_profile(plugin),
          stored_grant(status: "wrong_region", region: "na")
        )

      assert Status.status(plugin) == :wrong_region
      assert Status.region_actual(plugin) == nil
    end

    test "a plugin with no stored grant has no account region", %{plugin: plugin} do
      assert Status.region_actual(plugin) == nil
    end
  end

  test "wrong_region sits directly after reauthorization_required in the ladder" do
    statuses = Status.statuses()

    assert Enum.find_index(statuses, &(&1 == :wrong_region)) ==
             Enum.find_index(statuses, &(&1 == :reauthorization_required)) + 1
  end

  describe "tool_setting_satisfied?/2" do
    test "an ungated tool is always satisfied", %{checkout: checkout} do
      write_plugin(checkout, "gatefix", gated_manifest())
      put_plugins_env(["gatefix"], %{})
      plugin = load_plugin(checkout, "gatefix")

      assert Status.tool_setting_satisfied?(plugin, tool(plugin, "gatefix_read"))
    end

    test "a gated tool is satisfied only by the exact value \"true\"", %{checkout: checkout} do
      write_plugin(checkout, "gatefix", gated_manifest())

      plugin_for = fn entries ->
        put_plugins_env(["gatefix"], %{"gatefix" => entries})
        load_plugin(checkout, "gatefix")
      end

      satisfied = plugin_for.([{"ALLOW_WAKE", "true"}])
      assert Status.tool_setting_satisfied?(satisfied, tool(satisfied, "gatefix_wake"))

      for entries <- [[], [{"ALLOW_WAKE", "false"}], [{"ALLOW_WAKE", "TRUE"}]] do
        plugin = plugin_for.(entries)

        refute Status.tool_setting_satisfied?(plugin, tool(plugin, "gatefix_wake")),
               "#{inspect(entries)} satisfied the gate"
      end
    end

    # The kind a setting declares is what the two doors RENDER; it does not
    # change what the gate reads. A switch declared boolean and written "false"
    # is off, and the text-kinded manifest above still gates, so the gate is
    # not restricted to one kind.
    test "a boolean setting written false leaves the gated tool off", %{checkout: checkout} do
      write_plugin(checkout, "boolgate", boolean_gated_manifest())

      plugin_for = fn entries ->
        put_plugins_env(["boolgate"], %{"boolgate" => entries})
        load_plugin(checkout, "boolgate")
      end

      off = plugin_for.([{"ALLOW_WAKE", "false"}])
      assert [%{key: "ALLOW_WAKE", kind: :boolean}] = off.config
      refute Status.tool_setting_satisfied?(off, tool(off, "boolgate_wake"))

      unset = plugin_for.([])
      refute Status.tool_setting_satisfied?(unset, tool(unset, "boolgate_wake"))

      on = plugin_for.([{"ALLOW_WAKE", "true"}])
      assert Status.tool_setting_satisfied?(on, tool(on, "boolgate_wake"))
    end
  end

  describe "runtime_setting_satisfied?/1" do
    test "a runtime with no gate is always satisfied", %{checkout: checkout} do
      write_plugin(checkout, "obsidian", mcp_manifest())
      put_plugins_env(["obsidian"], %{"obsidian" => [{"OBSIDIAN_VAULT_PATH", "/tmp/vault"}]})

      assert Status.runtime_setting_satisfied?(load_plugin(checkout, "obsidian"))
    end

    test "a plugin with no runtime block at all is always satisfied", %{checkout: checkout} do
      write_plugin(checkout, "gatefix", gated_manifest())
      put_plugins_env(["gatefix"], %{})

      assert Status.runtime_setting_satisfied?(load_plugin(checkout, "gatefix"))
    end

    # One resolver behind both gates, so a spelling can never mean "on" for the
    # runtime and "off" for a tool.
    test "a gated runtime is satisfied only by the exact value \"true\"", %{checkout: checkout} do
      write_plugin(checkout, "rtgate", gated_runtime_manifest())

      plugin_for = fn entries ->
        put_plugins_env(["rtgate"], %{"rtgate" => entries})
        load_plugin(checkout, "rtgate")
      end

      assert Status.runtime_setting_satisfied?(plugin_for.([{"ALLOW_CONTROL", "true"}]))

      for entries <- [[], [{"ALLOW_CONTROL", "false"}], [{"ALLOW_CONTROL", "TRUE"}]] do
        refute Status.runtime_setting_satisfied?(plugin_for.(entries)),
               "#{inspect(entries)} satisfied the runtime gate"
      end
    end

    test "setting_on?/2 is the one resolver both gates read", %{checkout: checkout} do
      write_plugin(checkout, "rtgate", gated_runtime_manifest())
      put_plugins_env(["rtgate"], %{"rtgate" => [{"ALLOW_CONTROL", "true"}]})
      plugin = load_plugin(checkout, "rtgate")

      assert Status.setting_on?(plugin, "ALLOW_CONTROL")
      refute Status.setting_on?(plugin, "NEVER_SET")
    end

    # The gate decides whether a child process is spawned, not whether the
    # plugin is installed, configured and signed in. Reporting it through the
    # status ladder would make the row say the plugin needs attention when the
    # operator has simply left an optional helper switched off.
    test "a gated-off runtime leaves the plugin ready", %{checkout: checkout} do
      write_plugin(checkout, "rtgate", gated_runtime_manifest())
      put_plugins_env(["rtgate"], %{"rtgate" => [{"ALLOW_CONTROL", "false"}]})
      plugin = load_plugin(checkout, "rtgate")

      assert Status.status(plugin, probe: probe_ok()) == :ready
      refute Status.runtime_setting_satisfied?(plugin)
    end
  end

  defp gated_runtime_manifest do
    %{
      "runtime" => %{
        "kind" => "node",
        "command" => "node",
        "args" => ["src/index.js"],
        "vendored" => false,
        "requires_setting" => "ALLOW_CONTROL"
      },
      "config" => [
        %{
          "key" => "ALLOW_CONTROL",
          "prompt" => "Allow the helper to run",
          "required" => false,
          "kind" => "boolean"
        }
      ],
      "tools" => [
        %{
          "name" => "rtgate_do",
          "description" => "Do the thing",
          "rail" => "mcp",
          "read_only" => false
        }
      ]
    }
  end

  defp grant_without_region(checkout) do
    write_plugin(checkout, "regiofix", oauth_manifest())
    put_plugins_env(["regiofix"], %{})
    plugin = load_plugin(checkout, "regiofix")

    :ok = Store.write(Config.auth_profile(plugin), stored_grant([]))
    plugin
  end

  defp put_tesla_client(extra) do
    Application.put_env(:fermix_core, :oauth, %{
      "tesla" =>
        Keyword.merge([client_id: "tesla-client-id", client_secret: "tesla-secret"], extra)
    })
  end

  defp stored_grant(extra) do
    Enum.into(extra, %{
      auth_mode: "oauth2",
      provider: "google",
      granted_scopes: [],
      tokens: %{access_token: "AT", refresh_token: "RT"},
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      last_refresh: nil,
      status: "ready"
    })
  end

  defp tool(plugin, name), do: Enum.find(plugin.tools, &(&1["name"] == name))

  defp oauth_manifest do
    %{
      "auth" => %{
        "type" => "oauth2",
        "provider" => "google",
        "profile_key" => "regiofix",
        "account_mode" => "single",
        "scopes" => ["openid"]
      },
      "health_check" => %{"kind" => "local_readiness", "requires_auth" => true},
      "tools" => []
    }
  end

  defp tesla_manifest do
    %{
      "auth" => %{
        "type" => "oauth2",
        "provider" => "tesla",
        "profile_key" => "teslafix",
        "account_mode" => "single",
        "scopes" => ["openid"]
      },
      "health_check" => %{"kind" => "local_readiness", "requires_auth" => true},
      "tools" => []
    }
  end

  defp boolean_gated_manifest do
    %{
      "config" => [
        %{
          "key" => "ALLOW_WAKE",
          "prompt" => "Allow waking",
          "required" => false,
          "kind" => "boolean"
        }
      ],
      "tools" => [
        %{
          "name" => "boolgate_wake",
          "description" => "Wake it.",
          "read_only" => false,
          "requires_setting" => "ALLOW_WAKE",
          "rail" => "http",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "request" => %{"method" => "POST", "url" => "https://example.com/wake"}
        }
      ]
    }
  end

  defp gated_manifest do
    %{
      "config" => [%{"key" => "ALLOW_WAKE", "prompt" => "Allow waking", "required" => false}],
      "tools" => [
        %{
          "name" => "gatefix_read",
          "description" => "Read state.",
          "read_only" => true,
          "rail" => "http",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "request" => %{"method" => "GET", "url" => "https://example.com/read"}
        },
        %{
          "name" => "gatefix_wake",
          "description" => "Wake it.",
          "read_only" => false,
          "requires_setting" => "ALLOW_WAKE",
          "rail" => "http",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "request" => %{"method" => "POST", "url" => "https://example.com/wake"}
        }
      ]
    }
  end
end
