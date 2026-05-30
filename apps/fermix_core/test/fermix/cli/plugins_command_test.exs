defmodule Fermix.CLI.PluginsCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.PluginsCommand
  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Runtime

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugins-command")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :oauth, %{})
    _ = Runtime.reload()

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)

      CapabilityRegistry.unregister_kind(CapabilityRegistry, :builtin,
        metadata: %{plugin_owned?: true}
      )

      _ = Runtime.reload()
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "catalog emits plugin metadata as json" do
    output =
      capture_io(fn ->
        assert PluginsCommand.run(["catalog", "--json"]) == 0
      end)

    assert %{"plugins" => plugins} = Jason.decode!(output)
    assert Enum.any?(plugins, &(&1["name"] == "google_calendar"))
    assert Enum.any?(plugins, &(&1["name"] == "gmail"))
    assert Enum.any?(plugins, &(&1["name"] == "google_drive"))
    refute Enum.any?(plugins, &(&1["name"] == "weather"))
  end

  test "enable and disable persist plugin config", %{home: home} do
    output =
      capture_io(fn ->
        assert PluginsCommand.run(["enable", "google_drive"]) == 0
      end)

    assert output =~ "enabled google_drive"
    assert "google_drive" in Keyword.get(Application.get_env(:fermix_core, :plugins), :enabled)

    output =
      capture_io(fn ->
        assert PluginsCommand.run(["disable", "google_drive"]) == 0
      end)

    assert output =~ "disabled google_drive"
    assert Keyword.get(Application.get_env(:fermix_core, :plugins), :enabled) == []

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.plugins.google_drive]"
    assert contents =~ "enabled = false"
  end

  test "reload refreshes plugin-owned capabilities" do
    :ok =
      CapabilityRegistry.unregister_kind(CapabilityRegistry, :builtin,
        metadata: %{plugin_owned?: true}
      )

    Application.put_env(:fermix_core, :plugins,
      enabled: ["google_calendar"],
      entries: %{
        "google_calendar" => [auth_profile: "google_calendar:primary"]
      }
    )

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_id: "123.apps.googleusercontent.com", client_secret: "desktop-secret"]
    })

    :ok =
      Store.write("google_calendar:primary", %{
        auth_mode: "oauth2",
        provider: "google",
        account: %{email: "suj@example.com"},
        granted_scopes: [
          "openid",
          "email",
          "profile",
          "https://www.googleapis.com/auth/calendar.readonly"
        ],
        tokens: %{access_token: "AT", refresh_token: "RT"},
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        last_refresh: DateTime.utc_now(),
        status: "ready"
      })

    assert :error = CapabilityRegistry.find("google_calendar_search_events")

    output =
      capture_io(fn ->
        assert PluginsCommand.run(["reload"]) == 0
      end)

    assert output =~ "plugins reloaded"
    assert {:ok, capability} = CapabilityRegistry.find("google_calendar_search_events")
    assert capability.metadata[:plugin] == "google_calendar"
  end

  test "auth status reports missing local account" do
    output =
      capture_io(fn ->
        assert PluginsCommand.run(["auth", "status", "google_calendar"]) == 0
      end)

    assert output =~ "google_calendar"
    assert output =~ "missing"
  end
end
