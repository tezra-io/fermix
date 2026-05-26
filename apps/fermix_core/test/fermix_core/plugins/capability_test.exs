defmodule FermixCore.Plugins.CapabilityTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Capabilities

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugin-capabilities")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})
    registry = :"plugin_caps_#{System.unique_integer([:positive])}"

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :oauth, %{"google" => [client_id: "client"]})
    start_supervised!({CapabilityRegistry, name: registry})

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{registry: registry}
  end

  test "registers enabled plugin tools as builtin capabilities with plugin metadata", %{
    registry: registry
  } do
    Application.put_env(:fermix_core, :plugins,
      enabled: ["google_calendar"],
      entries: %{
        "google_calendar" => [
          scope_profile: "events_write",
          auth_profile: "google_calendar:primary"
        ]
      }
    )

    assert :ok =
             Store.write("google_calendar:primary", %{
               auth_mode: "oauth2",
               provider: "google",
               account: %{email: "suj@example.com"},
               scope_profile: "events_write",
               granted_scopes: [
                 "openid",
                 "email",
                 "profile",
                 "https://www.googleapis.com/auth/calendar.readonly",
                 "https://www.googleapis.com/auth/calendar.events"
               ],
               tokens: %{access_token: "AT", refresh_token: "RT"},
               expires_at: DateTime.utc_now() |> DateTime.add(3600),
               last_refresh: nil,
               status: "ready"
             })

    assert {:ok, %{registered: names}} = Capabilities.reload(registry)
    assert "google_calendar.search_events" in names
    assert "google_calendar.create_event" in names

    assert {:ok, cap} = CapabilityRegistry.find(registry, "google_calendar.create_event")
    assert cap.kind == :builtin
    assert cap.policy_class == :external_api
    assert cap.metadata.plugin == "google_calendar"
    assert cap.metadata.auth_profile == "google_calendar:primary"
    assert cap.metadata.scope_profile == "events_write"
  end

  test "unregisters plugin tools when plugin is disabled", %{registry: registry} do
    Application.put_env(:fermix_core, :plugins,
      enabled: [],
      entries: %{"google_calendar" => [enabled: false, scope_profile: "readonly"]}
    )

    assert {:ok, %{registered: []}} = Capabilities.reload(registry)
    assert :error = CapabilityRegistry.find(registry, "google_calendar.search_events")
  end
end
