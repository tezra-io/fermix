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
    providers = Application.get_env(:fermix_core, :providers, [])
    tools = Application.get_env(:fermix_core, :tools, [])
    telegram = Application.get_env(:fermix_channels, :telegram, [])
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})
    secret_writer = Application.get_env(:fermix_core, :secret_writer)

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :tools, [])
    Application.put_env(:fermix_channels, :telegram, [])
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :oauth, %{})
    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    TokenSupervisor.stop_profile("google_calendar:primary")

    on_exit(fn ->
      TokenSupervisor.stop_profile("google_calendar:primary")

      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :tools, tools)
      Application.put_env(:fermix_channels, :telegram, telegram)
      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      restore_secret_writer(secret_writer)
      FermixTestSupport.SecretWriterStub.reset()
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

  test "stores google oauth client config without auth tokens", %{home: home} do
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

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ ~s(client_secret = "@keyring")
    refute contents =~ "desktop-secret"

    assert {:ok, "desktop-secret"} =
             FermixTestSupport.SecretWriterStub.get(:google_oauth_client_secret)
  end

  test "stores github, notion, and x oauth client config like google", %{home: home} do
    assert {:ok, _snapshot} =
             Config.set_oauth_provider("github",
               client_id: "gh-client-id",
               client_secret: "gh-client-secret"
             )

    assert {:ok, _snapshot} =
             Config.set_oauth_provider("notion",
               client_id: "n-client-id",
               client_secret: "n-client-secret"
             )

    assert {:ok, _snapshot} =
             Config.set_oauth_provider("x",
               client_id: "x-client-id",
               client_secret: "x-client-secret"
             )

    oauth = Application.get_env(:fermix_core, :oauth)
    assert Keyword.get(Map.fetch!(oauth, "github"), :client_id) == "gh-client-id"
    assert Keyword.get(Map.fetch!(oauth, "notion"), :client_id) == "n-client-id"
    assert Keyword.get(Map.fetch!(oauth, "x"), :client_id) == "x-client-id"

    contents = File.read!(Path.join(home, "config.toml"))
    refute contents =~ "gh-client-secret"
    refute contents =~ "n-client-secret"
    refute contents =~ "x-client-secret"

    assert {:ok, "gh-client-secret"} =
             FermixTestSupport.SecretWriterStub.get(:github_oauth_client_secret)

    assert {:ok, "n-client-secret"} =
             FermixTestSupport.SecretWriterStub.get(:notion_oauth_client_secret)

    assert {:ok, "x-client-secret"} =
             FermixTestSupport.SecretWriterStub.get(:x_oauth_client_secret)
  end

  test "rejects github, notion, and x oauth client config missing fields" do
    assert {:error, {:missing_oauth_client_field, "github", :client_secret}} =
             Config.set_oauth_provider("github", client_id: "gh-client-id")

    assert {:error, {:missing_oauth_client_field, "x", :client_secret}} =
             Config.set_oauth_provider("x", client_id: "x-client-id")

    assert {:error, {:missing_oauth_client_field, "notion", :client_id}} =
             Config.set_oauth_provider("notion", client_secret: "n-client-secret")

    assert {:error, {:invalid_oauth_client_type, "notion", "web"}} =
             Config.set_oauth_provider("notion",
               client_type: "web",
               client_id: "n-client-id",
               client_secret: "n-client-secret"
             )

    assert Application.get_env(:fermix_core, :oauth) == %{}
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

  describe "plugin settings" do
    setup %{home: home} do
      seed_dev_local_plugin(home)
      :ok
    end

    test "sets a declared config value and persists it under the plugin entry", %{home: home} do
      assert {:ok, _snapshot} =
               Config.set_plugin_setting("vaultdemo", "DEMO_VAULT_PATH", "/tmp/demo-vault")

      assert Config.plugin_settings("vaultdemo") == %{"DEMO_VAULT_PATH" => "/tmp/demo-vault"}

      contents = File.read!(Path.join(home, "config.toml"))
      assert contents =~ "[fermix_core.plugins.vaultdemo]"
      assert contents =~ ~s(DEMO_VAULT_PATH = "/tmp/demo-vault")
    end

    test "refuses an undeclared config key without writing config" do
      assert {:error, {:unknown_config_key, "NOT_DECLARED"}} =
               Config.set_plugin_setting("vaultdemo", "NOT_DECLARED", "value")

      assert {:error, {:unknown_config_key, "GMAIL_VAULT"}} =
               Config.set_plugin_setting("gmail", "GMAIL_VAULT", "value")

      refute File.exists?(Path.join(System.fetch_env!("FERMIX_HOME"), "config.toml"))
    end

    test "refuses unknown plugins and blank values" do
      assert {:error, {:unknown_plugin, "missing"}} =
               Config.set_plugin_setting("missing", "DEMO_VAULT_PATH", "/tmp/demo-vault")

      assert {:error, {:blank_config_value, "DEMO_VAULT_PATH"}} =
               Config.set_plugin_setting("vaultdemo", "DEMO_VAULT_PATH", "   ")
    end

    test "a saved setting survives disable then enable" do
      assert {:ok, _snapshot} =
               Config.set_plugin_setting("vaultdemo", "DEMO_VAULT_PATH", "/tmp/demo-vault")

      assert {:ok, _snapshot} = Config.enable("vaultdemo")
      assert {:ok, _snapshot} = Config.disable("vaultdemo")
      assert {:ok, _snapshot} = Config.enable("vaultdemo")

      assert Config.plugin_settings("vaultdemo") == %{"DEMO_VAULT_PATH" => "/tmp/demo-vault"}

      plugins = Application.get_env(:fermix_core, :plugins)
      assert Keyword.get(plugins, :enabled) == ["vaultdemo"]
      entry = plugins |> Keyword.fetch!(:entries) |> Map.fetch!("vaultdemo")
      refute Keyword.get(entry, :enabled) == false
    end

    test "a setting written before enable round-trips through a TOML reload" do
      assert {:ok, _snapshot} =
               Config.set_plugin_setting("vaultdemo", "DEMO_VAULT_PATH", "/tmp/demo-vault")

      assert {:ok, loaded} = ConfigStore.load_runtime_config()
      :ok = ConfigStore.apply_snapshot(loaded)

      assert Config.plugin_settings("vaultdemo") == %{"DEMO_VAULT_PATH" => "/tmp/demo-vault"}

      # Overwriting after the reload replaces the string-keyed loaded entry.
      assert {:ok, _snapshot} =
               Config.set_plugin_setting("vaultdemo", "DEMO_VAULT_PATH", "/tmp/other-vault")

      assert Config.plugin_settings("vaultdemo") == %{"DEMO_VAULT_PATH" => "/tmp/other-vault"}
    end
  end

  # A dev_local plugin with a manifest `config` block — the registry seam that
  # needs no install pipeline (dist fixtures) inside this config-focused suite.
  defp seed_dev_local_plugin(home) do
    plugin_dir = Path.join([home, "dev-plugins", "vaultdemo"])
    File.mkdir_p!(plugin_dir)

    manifest = %{
      "schema_version" => 2,
      "name" => "vaultdemo",
      "display_name" => "Vault Demo",
      "description" => "vaultdemo test plugin",
      "category" => "notes",
      "version" => "1.0.0",
      "plugin_api" => 2,
      "min_core_version" => "0.1.0",
      "auth" => %{"type" => "none"},
      "config" => [
        %{"key" => "DEMO_VAULT_PATH", "prompt" => "Path to your vault", "required" => true}
      ],
      "tools" => []
    }

    File.write!(Path.join(plugin_dir, "plugin.json"), Jason.encode!(manifest))
    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
  end

  defp restore_secret_writer(nil), do: Application.delete_env(:fermix_core, :secret_writer)
  defp restore_secret_writer(value), do: Application.put_env(:fermix_core, :secret_writer, value)
end
