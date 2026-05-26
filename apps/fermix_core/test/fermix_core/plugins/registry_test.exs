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
    assert drive.scope_profiles == ["readonly"]
    assert Map.get(drive.interface, "logo") == "assets/app-icon.png"
  end

  test "rejects unknown manifest fields" do
    manifest = valid_manifest("bad_plugin") |> Map.put("unexpected", true)

    assert {:error, {:unknown_fields, ["unexpected"]}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects duplicate tool names" do
    tool = %{"name" => "bad_plugin.search", "read_only" => true}
    manifest = valid_manifest("bad_plugin") |> Map.put("tools", [tool, tool])

    assert {:error, {:duplicate_tool_name, "bad_plugin.search"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
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

  test "rejects write tools that require the default read profile" do
    tool = %{
      "name" => "bad_plugin.write",
      "read_only" => false,
      "requires_scope_profile" => "readonly"
    }

    manifest = valid_oauth_manifest("bad_plugin") |> Map.put("tools", [tool])

    assert {:error, {:write_tool_requires_default_scope, "bad_plugin.write", "readonly"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects non-monotonic OAuth scope profiles" do
    auth =
      valid_oauth_manifest("bad_plugin")
      |> Map.fetch!("auth")
      |> put_in(["scope_profiles", "events_write", "scopes"], [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/calendar.events"
      ])

    manifest = valid_oauth_manifest("bad_plugin") |> Map.put("auth", auth)

    assert {:error, {:non_monotonic_scope_profile, "events_write", "readonly"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
  end

  test "rejects OAuth plugins without a health check" do
    manifest = valid_oauth_manifest("bad_plugin") |> Map.delete("health_check")

    assert {:error, {:missing_health_check, "bad_plugin"}} =
             Registry.decode_manifest(manifest, "/tmp/bad/plugin.json")
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
      "scope_profiles" => %{
        "readonly" => %{
          "default" => true,
          "scopes" => [
            "openid",
            "email",
            "profile",
            "https://www.googleapis.com/auth/calendar.readonly"
          ]
        },
        "events_write" => %{
          "scopes" => [
            "openid",
            "email",
            "profile",
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/calendar.events"
          ]
        }
      }
    })
    |> Map.put("health_check", %{"kind" => "local_readiness", "requires_auth" => true})
  end
end
