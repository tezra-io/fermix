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
