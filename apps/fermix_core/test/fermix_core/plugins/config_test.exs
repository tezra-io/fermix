defmodule FermixCore.Plugins.ConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenRegistry
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Config
  alias FermixCore.Setup.ConfigStore

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugin-config")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :oauth, %{})
    TokenSupervisor.stop_profile("google_calendar:primary")

    on_exit(fn ->
      TokenSupervisor.stop_profile("google_calendar:primary")

      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "enables and disables a plugin while retaining auth profile config", %{home: home} do
    assert {:ok, _snapshot} = Config.enable("google_calendar")

    plugins = Application.get_env(:fermix_core, :plugins)
    assert Keyword.get(plugins, :enabled) == ["google_calendar"]
    entries = Keyword.fetch!(plugins, :entries)
    assert Keyword.get(entries["google_calendar"], :auth_profile) == "google_calendar:primary"

    assert {:ok, _snapshot} = Config.disable("google_calendar")

    plugins = Application.get_env(:fermix_core, :plugins)
    assert Keyword.get(plugins, :enabled) == []
    entries = Keyword.fetch!(plugins, :entries)
    assert Keyword.get(entries["google_calendar"], :enabled) == false
    assert Keyword.get(entries["google_calendar"], :auth_profile) == "google_calendar:primary"

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.plugins.google_calendar]"
    assert contents =~ "enabled = false"
  end

  test "disabling a plugin stops its retained credential refresh manager" do
    if is_nil(Process.whereis(TokenSupervisor)) do
      start_supervised!(TokenSupervisor)
    end

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_id: "123.apps.googleusercontent.com", client_secret: "desktop-secret"]
    })

    :ok =
      Store.write("google_calendar:primary", %{
        auth_mode: "oauth2",
        provider: "google",
        account: %{email: "suj@example.com"},
        granted_scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
        tokens: %{access_token: "AT", refresh_token: "RT"},
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        last_refresh: DateTime.utc_now(),
        status: "ready"
      })

    assert {:ok, "AT"} = TokenManager.get_token("google_calendar:primary")
    assert Registry.lookup(TokenRegistry, "google_calendar:primary") != []

    assert {:ok, _snapshot} = Config.enable("google_calendar")
    assert {:ok, _snapshot} = Config.disable("google_calendar")

    assert Registry.lookup(TokenRegistry, "google_calendar:primary") == []
  end

  test "stores google oauth client config without auth tokens" do
    assert {:ok, _snapshot} =
             Config.set_oauth_provider("google",
               client_id: "123.apps.googleusercontent.com",
               client_secret: "desktop-secret",
               redirect_port: 1455
             )

    oauth = Application.get_env(:fermix_core, :oauth)
    google = Map.fetch!(oauth, "google")
    assert Keyword.get(google, :client_id) == "123.apps.googleusercontent.com"
    assert Keyword.get(google, :client_secret) == "desktop-secret"
    assert Keyword.get(google, :redirect_port) == 1455
    refute File.exists?(Store.path())
  end

  test "rejects non-desktop google oauth client config" do
    assert {:error, {:invalid_oauth_client_type, "google", "web"}} =
             Config.set_oauth_provider("google",
               client_type: "web",
               client_id: "123.apps.googleusercontent.com"
             )

    assert Application.get_env(:fermix_core, :oauth) == %{}
    refute File.exists?(Path.join(System.fetch_env!("FERMIX_HOME"), "config.toml"))
  end

  test "rejects google oauth config without the desktop secret" do
    assert {:error, {:missing_oauth_client_field, "google", :client_secret}} =
             Config.set_oauth_provider("google",
               client_id: "123.apps.googleusercontent.com",
               redirect_port: 1455
             )

    assert Application.get_env(:fermix_core, :oauth) == %{}
    refute File.exists?(Path.join(System.fetch_env!("FERMIX_HOME"), "config.toml"))
  end

  test "rejects unknown plugins without writing config" do
    assert {:error, {:unknown_plugin, "missing"}} = Config.enable("missing")

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.get(loaded.fermix_core, :plugins) == []
  end
end
