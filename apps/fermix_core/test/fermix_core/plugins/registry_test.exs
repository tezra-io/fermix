defmodule FermixCore.Plugins.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Registry

  test "loads bundled first-party plugin manifests" do
    assert {:ok, plugins} = Registry.list()

    names = Enum.map(plugins, & &1.name)
    assert names == ["gmail", "google_calendar", "google_drive"]

    calendar = Enum.find(plugins, &(&1.name == "google_calendar"))
    assert calendar.display_name == "Google Calendar"
    assert calendar.auth.type == :oauth2
    assert calendar.auth.provider == "google"
    assert calendar.auth.account_mode == "single"
    assert Map.get(calendar.interface, "icon") == "assets/icon.png"
    assert Enum.any?(calendar.skills, &(Map.get(&1, "path") == "skills/google-calendar/SKILL.md"))

    drive = Enum.find(plugins, &(&1.name == "google_drive"))
    assert drive.display_name == "Google Drive"
    assert drive.auth.type == :oauth2
    assert drive.auth.provider == "google"
    assert "https://www.googleapis.com/auth/drive" in drive.auth.scopes
    assert Map.get(drive.interface, "logo") == "assets/app-icon.png"
  end

  test "rejects unknown manifest fields" do
    manifest = valid_manifest("bad_plugin") |> Map.put("unexpected", true)

    assert {:error, {:unknown_fields, ["unexpected"]}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects duplicate tool names" do
    tool = valid_tool("bad_plugin_search")
    manifest = valid_manifest("bad_plugin") |> Map.put("tools", [tool, tool])

    assert {:error, {:duplicate_tool_name, "bad_plugin_search"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects provider-incompatible tool names" do
    tool = valid_tool("bad_plugin.search")
    manifest = valid_manifest("bad_plugin") |> Map.put("tools", [tool])

    assert {:error, {:invalid_tool_name, "bad_plugin.search"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects missing or verbose tool descriptions" do
    missing = Map.delete(valid_tool("bad_plugin_search"), "description")
    verbose = valid_tool("bad_plugin_search", String.duplicate("x", 101))

    assert {:error, {:invalid_tool_description, "bad_plugin_search"}} =
             Registry.decode_manifest(
               valid_manifest("bad_plugin") |> Map.put("tools", [missing]),
               "/tmp/bad/plugin.json"
             )

    assert {:error, {:invalid_tool_description, "bad_plugin_search"}} =
             Registry.decode_manifest(
               valid_manifest("bad_plugin") |> Map.put("tools", [verbose]),
               "/tmp/bad/plugin.json"
             )
  end

  test "rejects duplicate skill names" do
    skill = %{"name" => "bad-plugin", "path" => "skills/bad-plugin/SKILL.md"}
    manifest = valid_manifest("bad_plugin") |> Map.put("skills", [skill, skill])

    assert {:error, {:duplicate_skill_name, "bad-plugin"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects plugin and skill name collisions" do
    skill = %{"name" => "bad_plugin", "path" => "skills/bad-plugin/SKILL.md"}
    manifest = valid_manifest("bad_plugin") |> Map.put("skills", [skill])

    assert {:error, {:plugin_skill_name_collision, "bad_plugin"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects tools without required scopes" do
    tool = valid_tool("bad_plugin_read")
    manifest = valid_oauth_manifest("bad_plugin") |> Map.put("tools", [tool])

    assert {:error, {:missing_tool_scopes, "bad_plugin_read"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects tools that require a scope outside auth.scopes" do
    tool = %{
      "name" => "bad_plugin_write",
      "description" => "Write bad plugin data.",
      "read_only" => false,
      "requires_scopes" => ["https://www.googleapis.com/auth/gmail.send"]
    }

    manifest = valid_oauth_manifest("bad_plugin") |> Map.put("tools", [tool])

    assert {:error, {:unknown_tool_scopes, "bad_plugin_write"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "accepts oauth2 manifests with empty scopes (providers without a scope model)" do
    tool = valid_tool("bad_plugin_read")

    manifest =
      valid_oauth_manifest("bad_plugin")
      |> put_in(["auth", "scopes"], [])
      |> Map.put("tools", [tool])

    assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
    assert plugin.auth.scopes == []
  end

  test "rejects tools requiring scopes on an empty-scope oauth2 plugin" do
    tool = valid_tool("bad_plugin_read") |> Map.put("requires_scopes", ["repo"])

    manifest =
      valid_oauth_manifest("bad_plugin")
      |> put_in(["auth", "scopes"], [])
      |> Map.put("tools", [tool])

    assert {:error, {:unknown_tool_scopes, "bad_plugin_read"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects OAuth plugins without a health check" do
    manifest = valid_oauth_manifest("bad_plugin") |> Map.delete("health_check")

    assert {:error, {:missing_health_check, "bad_plugin"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  describe "schema_version 2 manifests" do
    test "loads a v2 api_key plugin with an http-rail tool and the new fields" do
      manifest =
        v2_manifest("notion")
        |> Map.merge(%{
          "min_core_version" => "0.4.0",
          "plugin_api" => 2,
          "auth" => %{
            "type" => "api_key",
            "key_name" => "NOTION_TOKEN",
            "header" => "Authorization: Bearer",
            "prompt" => "Token"
          },
          "tools" => [http_tool("notion_search")]
        })

      assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
      assert plugin.schema_version == 2
      assert plugin.min_core_version == "0.4.0"
      assert plugin.plugin_api == 2
      assert plugin.auth.type == :api_key
      assert plugin.auth.key_name == "NOTION_TOKEN"
    end

    test "decodes auth.scheme \"Bot\" and defaults it to nil when absent" do
      with_scheme =
        v2_manifest("notion")
        |> api_key_auth()
        |> put_in(["auth", "scheme"], "Bot")
        |> Map.put("tools", [http_tool("notion_search")])

      assert {:ok, plugin} = Registry.decode_manifest(with_scheme, "/tmp/notion/plugin.json")
      assert plugin.auth.scheme == "Bot"

      without =
        v2_manifest("notion") |> api_key_auth() |> Map.put("tools", [http_tool("notion_search")])

      assert {:ok, plugin} = Registry.decode_manifest(without, "/tmp/notion/plugin.json")
      assert plugin.auth.scheme == nil
    end

    test "an unknown auth.scheme is rejected at decode" do
      manifest =
        v2_manifest("notion")
        |> api_key_auth()
        |> put_in(["auth", "scheme"], "Basic")
        |> Map.put("tools", [http_tool("notion_search")])

      assert {:error, {:invalid_auth_scheme, "Basic"}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "a declarative http tool with a request must declare parameters" do
      no_params = Map.delete(http_tool("notion_search"), "parameters")
      manifest = v2_manifest("notion") |> Map.put("tools", [no_params]) |> api_key_auth()

      assert {:error, {:missing_tool_parameters, "notion_search"}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "an http tool with no request is allowed (composite/hardcoded during migration)" do
      hardcoded = http_tool("notion_search") |> Map.drop(["request", "parameters"])
      manifest = v2_manifest("notion") |> Map.put("tools", [hardcoded]) |> api_key_auth()
      assert {:ok, _plugin} = Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "an http template with an undeclared placeholder is rejected at load" do
      bad =
        put_in(
          http_tool("notion_search"),
          ["request", "url"],
          "https://api.notion.com/{undeclared}"
        )

      manifest = v2_manifest("notion") |> Map.put("tools", [bad]) |> api_key_auth()

      assert {:error,
              {:invalid_tool_template, "notion_search", {:undeclared_placeholder, "undeclared"}}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "an unknown rail is rejected" do
      bad = Map.put(http_tool("notion_search"), "rail", "grpc")
      manifest = v2_manifest("notion") |> Map.put("tools", [bad]) |> api_key_auth()

      assert {:error, {:invalid_tool_rail, "notion_search", "grpc"}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "an mcp-rail tool requires a runtime block" do
      mcp_tool = %{
        "name" => "obsidian_read",
        "description" => "Read a note.",
        "read_only" => true,
        "rail" => "mcp"
      }

      manifest =
        v2_manifest("obsidian")
        |> Map.put("tools", [mcp_tool])
        |> Map.put("auth", %{"type" => "none"})

      assert {:error, {:invalid_runtime, nil}} =
               Registry.decode_manifest(manifest, "/tmp/obsidian/plugin.json")

      with_runtime = Map.put(manifest, "runtime", %{"kind" => "node", "command" => "server.mjs"})
      assert {:ok, plugin} = Registry.decode_manifest(with_runtime, "/tmp/obsidian/plugin.json")
      assert plugin.runtime["kind"] == "node"
    end

    test "api_key tools do not require requires_scopes" do
      tool = http_tool("notion_search") |> Map.delete("requires_scopes")
      manifest = v2_manifest("notion") |> Map.put("tools", [tool]) |> api_key_auth()
      assert {:ok, _plugin} = Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "an mcp-rail runtime command may not escape the bundled bin dir" do
      base =
        v2_manifest("obsidian")
        |> Map.put("tools", [mcp_tool("obsidian_read")])
        |> Map.put("auth", %{"type" => "none"})

      for command <- ["../../../../bin/sh", "/bin/sh", "bin/server", "..", "."] do
        manifest =
          Map.put(base, "runtime", %{
            "kind" => "node",
            "command" => command,
            "vendored" => true
          })

        assert {:error, {:invalid_runtime, _}} =
                 Registry.decode_manifest(manifest, "/tmp/obsidian/plugin.json")
      end

      ok =
        Map.put(base, "runtime", %{
          "kind" => "node",
          "command" => "server.mjs",
          "vendored" => true
        })

      assert {:ok, _plugin} = Registry.decode_manifest(ok, "/tmp/obsidian/plugin.json")
    end

    test "an interface asset may not escape the plugin dir" do
      plugin_root = FermixTestSupport.SafeRm.make_tmp_dir!("registry-asset")
      manifest_path = Path.join([plugin_root, "evil", "plugin.json"])
      File.mkdir_p!(Path.dirname(manifest_path))
      # A real file one level above the plugin dir; `../secret.png` reaches it.
      File.write!(Path.join(plugin_root, "secret.png"), "x")

      escaping = Map.put(valid_manifest("evil"), "interface", %{"logo" => "../secret.png"})

      assert {:error, {:asset_escapes_plugin_dir, "../secret.png"}} =
               Registry.decode_manifest(escaping, manifest_path)

      File.write!(Path.join([plugin_root, "evil", "logo.png"]), "x")
      in_dir = Map.put(valid_manifest("evil"), "interface", %{"logo" => "logo.png"})
      assert {:ok, _plugin} = Registry.decode_manifest(in_dir, manifest_path)

      FermixTestSupport.SafeRm.rm_rf!(plugin_root)
    end
  end

  # --- M40 §3.2: per-region hosts and per-tool setting gates ---------------

  describe "request.regional_urls" do
    test "a regional http tool loads on a plugin_api 2 manifest" do
      tool = regional_tool("notion_search")
      manifest = v2_manifest("notion") |> Map.put("tools", [tool]) |> api_key_auth()

      assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
      assert [%{"request" => request}] = plugin.tools
      assert Map.keys(request["regional_urls"]) |> Enum.sort() == ["eu", "na"]
      refute Map.has_key?(request, "url")
    end

    test "a non-https regional url is rejected at load, tagged with the tool" do
      tool =
        put_in(
          regional_tool("notion_search"),
          ["request", "regional_urls", "eu"],
          "http://api.eu.notion.com/v1/search"
        )

      manifest = v2_manifest("notion") |> Map.put("tools", [tool]) |> api_key_auth()

      assert {:error,
              {:invalid_tool_template, "notion_search",
               {:non_https_url, "http://api.eu.notion.com/v1/search"}}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "declaring both url and regional_urls is rejected at load" do
      tool =
        put_in(regional_tool("notion_search"), ["request", "url"], "https://api.notion.com/x")

      manifest = v2_manifest("notion") |> Map.put("tools", [tool]) |> api_key_auth()

      assert {:error, {:invalid_tool_template, "notion_search", :regional_urls_and_url}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "a request declaring neither url nor regional_urls is rejected at load" do
      tool =
        update_in(regional_tool("notion_search"), ["request"], &Map.delete(&1, "regional_urls"))

      manifest = v2_manifest("notion") |> Map.put("tools", [tool]) |> api_key_auth()

      assert {:error, {:invalid_tool_template, "notion_search", :missing_url}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "a placeholder in any regional url must be a declared parameter" do
      tool =
        put_in(
          regional_tool("notion_search"),
          ["request", "regional_urls", "eu"],
          "https://api.eu.notion.com/v1/{undeclared}"
        )

      manifest = v2_manifest("notion") |> Map.put("tools", [tool]) |> api_key_auth()

      assert {:error,
              {:invalid_tool_template, "notion_search", {:undeclared_placeholder, "undeclared"}}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end
  end

  describe "per-tool requires_setting" do
    test "a tool may gate itself on a key its own manifest declares" do
      manifest = gated_manifest("notion_wake", "ALLOW_WAKE")

      assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
      assert [%{"requires_setting" => "ALLOW_WAKE"}] = plugin.tools
      assert [%{key: "ALLOW_WAKE"}] = plugin.config
    end

    test "a requires_setting naming a key the manifest does not declare is rejected" do
      manifest =
        gated_manifest("notion_wake", "ALLOW_WAKE")
        |> put_in(["tools", Access.at(0), "requires_setting"], "ALLOW_SOMETHING_ELSE")

      assert {:error, {:unknown_requires_setting, "notion_wake", "ALLOW_SOMETHING_ELSE"}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "a requires_setting that is not a string is rejected" do
      manifest =
        gated_manifest("notion_wake", "ALLOW_WAKE")
        |> put_in(["tools", Access.at(0), "requires_setting"], true)

      assert {:error, {:unknown_requires_setting, "notion_wake", true}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    # The gate governs what `Plugins.Capabilities` advertises, and mcp-rail
    # entries never register there — MCP discovery is authoritative. A gate that
    # could not take effect is refused rather than silently ignored.
    test "an mcp-rail tool cannot carry the gate" do
      manifest =
        gated_manifest("notion_wake", "ALLOW_WAKE")
        |> put_in(["tools", Access.at(0), "rail"], "mcp")
        |> Map.put("runtime", %{
          "kind" => "node",
          "min_version" => "20",
          "command" => "node",
          "args" => ["src/index.js"],
          "vendored" => false
        })

      assert {:error, {:requires_setting_on_mcp_tool, "notion_wake"}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end

    test "a manifest that declares no config at all cannot gate a tool" do
      manifest =
        gated_manifest("notion_wake", "ALLOW_WAKE") |> Map.delete("config")

      assert {:error, {:unknown_requires_setting, "notion_wake", "ALLOW_WAKE"}} =
               Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
    end
  end

  # The runtime half of the gate (M8 §9.3): the local process itself may be
  # gated on one of its own manifest's `config` keys, so an operator switch
  # decides whether a vendored helper runs at all — not just which of its tools
  # are advertised.
  describe "runtime requires_setting" do
    test "a runtime may gate itself on a key its own manifest declares" do
      assert {:ok, plugin} =
               Registry.decode_manifest(gated_runtime_manifest("ALLOW_CONTROL"), "/tmp/p.json")

      assert plugin.runtime["requires_setting"] == "ALLOW_CONTROL"
    end

    test "a runtime block with no gate still decodes" do
      manifest =
        gated_runtime_manifest("ALLOW_CONTROL")
        |> update_in(["runtime"], &Map.delete(&1, "requires_setting"))

      assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/p.json")
      refute Map.has_key?(plugin.runtime, "requires_setting")
    end

    test "a gate naming a key the manifest does not declare is rejected" do
      manifest =
        gated_runtime_manifest("ALLOW_CONTROL")
        |> put_in(["runtime", "requires_setting"], "ALLOW_SOMETHING_ELSE")

      assert {:error, {:unknown_requires_setting, "runtime", "ALLOW_SOMETHING_ELSE"}} =
               Registry.decode_manifest(manifest, "/tmp/p.json")
    end

    test "a gate that is not a string is rejected" do
      manifest =
        gated_runtime_manifest("ALLOW_CONTROL") |> put_in(["runtime", "requires_setting"], true)

      assert {:error, {:unknown_requires_setting, "runtime", true}} =
               Registry.decode_manifest(manifest, "/tmp/p.json")
    end

    test "a manifest that declares no config at all cannot gate its runtime" do
      manifest = gated_runtime_manifest("ALLOW_CONTROL") |> Map.delete("config")

      assert {:error, {:unknown_requires_setting, "runtime", "ALLOW_CONTROL"}} =
               Registry.decode_manifest(manifest, "/tmp/p.json")
    end

    # A hosted runtime is not a process this daemon starts, so there is no
    # local switch to gate it with.
    test "a remote runtime may not carry the gate" do
      manifest =
        v2_manifest("remotefix")
        |> api_key_auth()
        |> Map.merge(%{
          "plugin_api" => 3,
          "runtime" => %{
            "kind" => "remote_mcp",
            "transport" => "streamable_http",
            "protocol_version" => "2025-06-18",
            "base_url" => "https://mcp.example.com",
            "mcp_path" => "/mcp",
            "tool_name_mode" => "prefix",
            "requires_setting" => "ALLOW_CONTROL"
          }
        })

      assert {:error, {:remote_runtime_conflict, ["requires_setting"]}} =
               Registry.decode_manifest(manifest, "/tmp/p.json")
    end
  end

  defp gated_runtime_manifest(key) do
    v2_manifest("gatedrt")
    |> api_key_auth()
    |> Map.put("config", [
      %{"key" => key, "prompt" => "Allow it", "required" => false, "kind" => "boolean"}
    ])
    |> Map.put("runtime", %{
      "kind" => "binary",
      "command" => "gatedrt-helper",
      "vendored" => true,
      "requires_setting" => key
    })
    |> Map.put("tools", [mcp_tool("gatedrt_do")])
  end

  # A setting's kind is what both doors render it as: a switch or a text field.
  # It is declared rather than inferred, because a gate that reads exactly
  # "true" and a field the operator types into are the same wire shape, and
  # guessing from the key name is how a vault path becomes a toggle.
  describe "config entry kinds" do
    test "an entry that declares no kind is text" do
      manifest = config_manifest(%{"key" => "VAULT_PATH", "prompt" => "Where?"})

      assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/cfg/plugin.json")

      assert [%{key: "VAULT_PATH", prompt: "Where?", required: false, kind: :text}] =
               plugin.config
    end

    test "both declared kinds decode to their atom" do
      for {declared, kind} <- [{"text", :text}, {"boolean", :boolean}] do
        entry = %{"key" => "ALLOW_WAKE", "prompt" => "Allow waking", "kind" => declared}

        assert {:ok, plugin} =
                 Registry.decode_manifest(config_manifest(entry), "/tmp/cfg/plugin.json")

        assert [%{key: "ALLOW_WAKE", kind: ^kind}] = plugin.config
      end
    end

    # Refused at decode rather than defaulted: a manifest asking for a switch
    # Fermix does not have must not quietly render as a text field the operator
    # then types the wrong word into.
    test "any other kind is refused, named with the key that declared it" do
      for declared <- ["switch", "Boolean", "", nil, true] do
        entry = %{"key" => "ALLOW_WAKE", "prompt" => "Allow waking", "kind" => declared}

        assert {:error, {:invalid_config_kind, "ALLOW_WAKE", ^declared}} =
                 Registry.decode_manifest(config_manifest(entry), "/tmp/cfg/plugin.json"),
               "#{inspect(declared)} was accepted as a setting kind"
      end
    end

    # The gate is not restricted to boolean entries: a text setting can gate a
    # tool too, and boolean is the kind the gate is meant for rather than the
    # only one it accepts.
    test "a boolean entry can carry a tool gate" do
      manifest =
        gated_manifest("notion_wake", "ALLOW_WAKE")
        |> put_in(["config", Access.at(0), "kind"], "boolean")

      assert {:ok, plugin} = Registry.decode_manifest(manifest, "/tmp/notion/plugin.json")
      assert [%{key: "ALLOW_WAKE", kind: :boolean}] = plugin.config
      assert [%{"requires_setting" => "ALLOW_WAKE"}] = plugin.tools
    end
  end

  defp regional_tool(name) do
    http_tool(name)
    |> update_in(["request"], fn request ->
      request
      |> Map.delete("url")
      |> Map.put("regional_urls", %{
        "na" => "https://api.notion.com/v1/search",
        "eu" => "https://api.eu.notion.com/v1/search"
      })
    end)
  end

  defp config_manifest(entry) do
    valid_manifest("cfgfix") |> Map.put("config", [entry])
  end

  defp gated_manifest(tool_name, key) do
    v2_manifest("notion")
    |> api_key_auth()
    |> Map.put("config", [%{"key" => key, "prompt" => "Allow it", "required" => false}])
    |> Map.put("tools", [Map.put(http_tool(tool_name), "requires_setting", key)])
  end

  defp mcp_tool(name) do
    %{"name" => name, "description" => "An mcp tool.", "read_only" => true, "rail" => "mcp"}
  end

  defp v2_manifest(name) do
    valid_manifest(name)
    |> Map.merge(%{"schema_version" => 2, "plugin_api" => 2, "min_core_version" => "0.1.0"})
  end

  defp api_key_auth(manifest) do
    Map.put(manifest, "auth", %{
      "type" => "api_key",
      "key_name" => "TOKEN",
      "header" => "Authorization: Bearer",
      "prompt" => "Token"
    })
  end

  defp http_tool(name) do
    %{
      "name" => name,
      "description" => "An http tool.",
      "read_only" => true,
      "rail" => "http",
      "parameters" => %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}},
      "request" => %{
        "method" => "GET",
        "url" => "https://api.notion.com/v1/search",
        "query" => %{"q" => "{query}"}
      }
    }
  end

  defp valid_manifest(name) do
    %{
      "schema_version" => 1,
      "name" => name,
      "display_name" => "Bad Plugin",
      "description" => "Invalid manifest",
      "category" => "test",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{"type" => "none"},
      "tools" => [],
      "skills" => [],
      "health_check" => %{"kind" => "local_readiness", "requires_auth" => false}
    }
  end

  defp valid_oauth_manifest(name) do
    valid_manifest(name)
    |> Map.put("auth", %{
      "type" => "oauth2",
      "provider" => "google",
      "profile_key" => name,
      "account_mode" => "single",
      "scopes" => [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events"
      ]
    })
    |> Map.put("health_check", %{"kind" => "local_readiness", "requires_auth" => true})
  end

  defp valid_tool(name, description \\ "Search bad plugin data.") do
    %{"name" => name, "description" => description, "read_only" => true}
  end
end
