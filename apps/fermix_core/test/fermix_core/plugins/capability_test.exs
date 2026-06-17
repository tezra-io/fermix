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

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_id: "client", client_secret: "desktop-secret"]
    })

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
        "google_calendar" => [auth_profile: "google_calendar:primary"]
      }
    )

    assert :ok =
             Store.write("google_calendar:primary", %{
               auth_mode: "oauth2",
               provider: "google",
               account: %{email: "suj@example.com"},
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
    assert "google_calendar_search_events" in names
    assert "google_calendar_create_event" in names

    assert {:ok, cap} = CapabilityRegistry.find(registry, "google_calendar_create_event")
    assert cap.kind == :builtin
    assert cap.policy_class == :external_api
    assert cap.description == "Create a Google Calendar event."
    assert byte_size(cap.description) <= 100
    assert cap.metadata.plugin == "google_calendar"
    assert cap.metadata.auth_profile == "google_calendar:primary"
    assert cap.metadata.when_to_use == "Create a Google Calendar event."
  end

  test "registers all ready-plugin tools regardless of granted scope", %{registry: registry} do
    Application.put_env(:fermix_core, :plugins,
      enabled: ["google_calendar"],
      entries: %{"google_calendar" => [auth_profile: "google_calendar:primary"]}
    )

    assert :ok =
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
               expires_at: DateTime.utc_now() |> DateTime.add(3600),
               last_refresh: nil,
               status: "ready"
             })

    assert {:ok, %{registered: names}} = Capabilities.reload(registry)
    assert "google_calendar_search_events" in names
    # calendar.events was NOT granted, but the write tool still registers so the
    # agent surfaces a graceful "reauthorize" error instead of the tool vanishing.
    assert "google_calendar_create_event" in names
  end

  test "unregisters plugin tools when plugin is disabled", %{registry: registry} do
    Application.put_env(:fermix_core, :plugins,
      enabled: [],
      entries: %{"google_calendar" => [enabled: false]}
    )

    assert {:ok, %{registered: []}} = Capabilities.reload(registry)
    assert :error = CapabilityRegistry.find(registry, "google_calendar_search_events")
  end

  test "mcp-rail tools never register as builtin capabilities", %{registry: registry} do
    checkout = FermixTestSupport.SafeRm.make_tmp_dir!("plugin-caps-devlocal")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(checkout) end)

    dir = Path.join(checkout, "vaultkit")
    File.mkdir_p!(dir)

    manifest = %{
      "schema_version" => 2,
      "name" => "vaultkit",
      "display_name" => "Vaultkit",
      "description" => "Vault tools",
      "category" => "productivity",
      "version" => "1.0.0",
      "plugin_api" => 2,
      "auth" => %{"type" => "none"},
      "runtime" => %{
        "kind" => "node",
        "min_version" => "20",
        "command" => "node",
        "args" => ["src/index.js"],
        "vendored" => false
      },
      "tools" => [
        %{
          "name" => "vaultkit_list",
          "description" => "List vault entries",
          "rail" => "http",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "request" => %{"method" => "GET", "url" => "https://example.com/list"}
        },
        %{
          "name" => "vaultkit_search",
          "description" => "Search the vault",
          "rail" => "mcp"
        }
      ]
    }

    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest))

    Application.put_env(:fermix_core, :plugins,
      enabled: ["vaultkit"],
      dev_local: checkout,
      entries: %{}
    )

    probe = [
      find_executable: fn _cmd -> "/usr/bin/node" end,
      version_fetch: fn _cmd -> {:ok, "v20.11.1\n"} end
    ]

    assert {:ok, %{registered: names}} = Capabilities.reload(registry, status: [probe: probe])
    assert "vaultkit_list" in names
    refute "vaultkit_search" in names
    assert :error = CapabilityRegistry.find(registry, "vaultkit_search")
  end
end
