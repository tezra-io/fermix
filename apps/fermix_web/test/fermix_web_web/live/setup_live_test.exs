defmodule FermixWebWeb.SetupLiveTest do
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.ConfigStore

  # Hermetic Anthropic backend stub — writes the auth store (tmp FERMIX_HOME) but
  # never touches the real keychain / ~/.claude. Injected via :anthropic_login_impl.
  defmodule AnthropicLoginStub do
    alias FermixCore.Auth.Store

    @entry %{
      auth_mode: "setup_token",
      provider: "anthropic",
      tokens: %{access_token: "ant-at", refresh_token: nil},
      expires_at: nil,
      last_refresh: nil,
      status: "ready"
    }

    def store_setup_token(_token, _opts \\ []) do
      :ok = Store.write("anthropic_oauth", @entry)
      {:ok, @entry}
    end

    def import_claude_code(_opts \\ []) do
      :ok = Store.write("anthropic_oauth", @entry)
      {:ok, @entry}
    end

    def claude_code_available?(_opts \\ []), do: true
  end

  setup %{conn: conn} do
    providers = Application.fetch_env(:fermix_core, :providers)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    secret_writer = Application.get_env(:fermix_core, :secret_writer)
    tools = Application.get_env(:fermix_core, :tools, [])
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})
    plugin_auth_runner = Application.get_env(:fermix_web, :plugin_auth_runner)
    plugin_auth_url_timeout_ms = Application.get_env(:fermix_web, :plugin_auth_url_timeout_ms)
    codex_login_runner = Application.get_env(:fermix_web, :codex_login_runner)
    xai_login_runner = Application.get_env(:fermix_web, :xai_login_runner)
    anthropic_login_impl = Application.get_env(:fermix_web, :anthropic_login_impl)
    doctor_probe_opts = Application.get_env(:fermix_web, :doctor_probe_opts)
    fermix_home = System.get_env("FERMIX_HOME")

    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live")
    System.put_env("FERMIX_HOME", tmp_home)
    FermixTestSupport.SecretWriterStub.reset()

    # Force readiness to :setup_required so commit_snapshot/1 skips
    # prompt-file seeding; these tests do not exercise the memory repo.
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    Application.put_env(:fermix_core, :tools, [])
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :oauth, %{})
    Application.delete_env(:fermix_web, :plugin_auth_runner)
    Application.delete_env(:fermix_web, :plugin_auth_url_timeout_ms)
    Application.delete_env(:fermix_web, :codex_login_runner)
    Application.delete_env(:fermix_web, :xai_login_runner)
    Application.delete_env(:fermix_web, :anthropic_login_impl)
    Application.delete_env(:fermix_web, :doctor_probe_opts)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      restore_env(:fermix_core, :secret_writer, secret_writer)
      Application.put_env(:fermix_core, :tools, tools)
      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      restore_env(:fermix_web, :plugin_auth_runner, plugin_auth_runner)
      restore_env(:fermix_web, :plugin_auth_url_timeout_ms, plugin_auth_url_timeout_ms)
      restore_env(:fermix_web, :codex_login_runner, codex_login_runner)
      restore_env(:fermix_web, :xai_login_runner, xai_login_runner)
      restore_env(:fermix_web, :anthropic_login_impl, anthropic_login_impl)
      restore_env(:fermix_web, :doctor_probe_opts, doctor_probe_opts)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    %{conn: authorize_setup(conn), tmp_home: tmp_home}
  end

  describe "/setup shell" do
    test "renders the onboarding header and config path", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert html =~ "Fermix setup"
      assert html =~ "Step 1 of"
      assert html =~ "Guided onboarding"
      assert html =~ ConfigStore.path()
    end

    test "renders setup categories without a read-only tools step", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      for label <-
            ~w(Provider Realtime Channels Plugins Search Sandbox Memory Personalization Doctor) do
        assert html =~ label
      end

      refute html =~ "Agent skills"
      refute html =~ ~s(phx-value-tab="tools")
    end

    test "guided navigation changes panes without placeholder content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      # Provider pane is the default
      assert render(view) =~ "Provider &amp; Model"

      html = view |> element("button[phx-value-tab=\"realtime\"]") |> render_click()
      assert html =~ "Voice companion"

      # Switch to Personalization
      html = view |> element("button[phx-value-tab=\"personalization\"]") |> render_click()
      assert html =~ "Personalization"
      assert html =~ "Your name"

      for {tab, expected} <- [
            {"channels", "Channel coverage"},
            {"plugins", "Integrations"},
            {"search", "Search backend"},
            {"sandbox", "Sandbox policy"},
            {"memory", "Memory tuning"},
            {"doctor", "Readiness doctor"}
          ] do
        html = view |> element("button[phx-value-tab=\"#{tab}\"]") |> render_click()
        assert html =~ expected
        refute html =~ "coming soon"
        refute html =~ "later M10 stage"
      end
    end

    test "channels pane marks unconfigured channels as not configured, not ready", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"channels\"]") |> render_click()

      # Disabled/unconfigured channels must not render a green "Ready" pill.
      assert html =~ "Not configured"
    end

    test "channels pane does not treat unresolved keyring markers as stored secrets", %{
      conn: conn
    } do
      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        bot_token: "@keyring",
        owner_user_id: "111"
      )

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"channels\"]") |> render_click()

      assert html =~ ~s(name="channels_form[telegram_bot_token]")
      assert html =~ ~s(placeholder="paste secret")
      refute html =~ "stored - leave blank to keep"
    end

    test "plugins pane renders bundled plugin cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      assert html =~ ~s(data-plugin-group="google")
      assert html =~ ~s(data-plugin-name="google_calendar")
      assert html =~ ~s(data-plugin-name="gmail")
      assert html =~ ~s(data-plugin-name="google_drive")
      # Cards show short names under the Google group ("Google Calendar" -> "Calendar").
      assert html =~ "Calendar"
      assert html =~ "Gmail"
      assert html =~ "Drive"
      assert html =~ "data:image/"
      refute html =~ "Weather"
      assert html =~ "OAuth desktop client"
      assert html =~ "coming later"
      refute html =~ "data-plugin-auth-trigger"
      refute html =~ "Installed skills"
    end

    test "oauth plugin connect requires Google client config before enabling", %{conn: conn} do
      parent = self()

      Application.put_env(:fermix_web, :plugin_auth_runner, fn name, _opts ->
        send(parent, {:unexpected_plugin_auth, name})
        {:error, :unexpected_auth_start}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      html =
        view
        |> element(~s|button[phx-click="plugin_enable"][phx-value-name="google_calendar"]|)
        |> render_click()

      assert html =~ "Save a Google OAuth desktop client first"
      refute_receive {:unexpected_plugin_auth, _name}, 50
      plugins = Application.get_env(:fermix_core, :plugins, [])
      refute "google_calendar" in Keyword.get(plugins, :enabled, [])
    end

    test "saving Google OAuth requires a desktop secret before auth opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_google_oauth\"]",
          google_oauth_form: %{client_id: "123.apps.googleusercontent.com", redirect_port: "1455"}
        )
        |> render_submit()

      assert html =~ "Google OAuth Client secret is required."
      refute html =~ ~s(data-plugin-auth-trigger="true")
      assert Application.get_env(:fermix_core, :oauth, %{}) == %{}
    end

    test "plugins pane saves OAuth config and enables plugins after auth succeeds", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      parent = self()

      Application.put_env(:fermix_web, :plugin_auth_runner, fn name, opts ->
        Keyword.fetch!(opts, :opener).("https://auth.example/#{name}")
        :ok = write_ready_plugin_auth(name)
        {:ok, _snapshot} = PluginConfig.enable(name)
        send(parent, {:plugin_auth_started, name})
        {:ok, %{status: "ready"}}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_google_oauth\"]",
          google_oauth_form: %{
            client_id: "123.apps.googleusercontent.com",
            client_secret: "desktop-secret",
            redirect_port: "1455"
          }
        )
        |> render_submit()

      assert html =~ "Google OAuth client saved."
      google = Application.get_env(:fermix_core, :oauth) |> Map.fetch!("google")
      assert Keyword.get(google, :client_id) == "123.apps.googleusercontent.com"
      assert Keyword.get(google, :client_secret) == "desktop-secret"
      assert render(view) =~ ~s(data-plugin-auth-trigger="true")

      html =
        view
        |> element(~s|button[phx-click="plugin_enable"][phx-value-name="google_drive"]|)
        |> render_click()

      assert html =~ "Opening Google Drive sign-in"
      assert_receive {:plugin_auth_started, "google_drive"}
      html = render(view)
      assert html =~ "Google Drive connected."
      assert html =~ "Ready"
      refute html =~ "https://auth.example/google_drive"

      plugins = Application.get_env(:fermix_core, :plugins)
      assert "google_drive" in Keyword.get(plugins, :enabled, [])

      html =
        view
        |> element(~s|button[phx-click="plugin_enable"][phx-value-name="google_calendar"]|)
        |> render_click()

      assert html =~ "Opening Google Calendar sign-in"
      assert_receive {:plugin_auth_started, "google_calendar"}
      html = render(view)
      assert html =~ "Google Calendar connected."
      assert html =~ "Ready"
      refute html =~ "https://auth.example/google_calendar"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.oauth.google]"
      assert contents =~ ~s(client_id = "123.apps.googleusercontent.com")
      assert contents =~ "[fermix_core.plugins.google_drive]"
      assert contents =~ ~s(enabled = ["google_drive", "google_calendar"])
    end

    test "oauth plugin enable clears the fallback URL after auth completes", %{
      conn: conn
    } do
      parent = self()

      Application.put_env(:fermix_web, :plugin_auth_runner, fn name, opts ->
        send(parent, {:plugin_auth_started, name})
        Keyword.fetch!(opts, :opener).("https://auth.example/#{name}")
        {:ok, %{status: "ready"}}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_google_oauth\"]",
        google_oauth_form: %{
          client_id: "123.apps.googleusercontent.com",
          client_secret: "desktop-secret",
          redirect_port: "1455"
        }
      )
      |> render_submit()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="google_calendar"]|)
      |> render_click()

      assert_receive {:plugin_auth_started, "google_calendar"}
      refute render(view) =~ "https://auth.example/google_calendar"
    end

    test "oauth fallback sign-in link expires while auth is pending", %{conn: conn} do
      parent = self()
      Application.put_env(:fermix_web, :plugin_auth_url_timeout_ms, 20)

      Application.put_env(:fermix_web, :plugin_auth_runner, fn name, opts ->
        Keyword.fetch!(opts, :opener).("https://auth.example/#{name}")
        send(parent, {:plugin_auth_started, name})
        Process.sleep(200)
        {:error, :cancelled}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_google_oauth\"]",
        google_oauth_form: %{
          client_id: "123.apps.googleusercontent.com",
          client_secret: "desktop-secret",
          redirect_port: "1455"
        }
      )
      |> render_submit()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="google_calendar"]|)
      |> render_click()

      assert_receive {:plugin_auth_started, "google_calendar"}
      assert render(view) =~ "https://auth.example/google_calendar"

      Process.sleep(60)
      refute render(view) =~ "https://auth.example/google_calendar"
    end

    test "doctor pane keeps read-only skill count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"doctor\"]") |> render_click()

      assert html =~ "Skill summary"
      assert html =~ "Operator trusted"
      assert html =~ "Guest scoped"
    end

    test "Save & next saves the current step and advances", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      assert render(view) =~ "Provider &amp; Model"

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openai_codex"})
        |> render_submit(%{"__nav" => "next"})

      assert html =~ "Provider saved."
      assert html =~ "Voice companion"
    end

    test "provider pane offers canonical reasoning effort levels (xhigh, not minimal)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openai_codex"})
        |> render_change()

      assert html =~ "Reasoning effort"
      assert html =~ ~s(value="xhigh")
      refute html =~ ~s(value="minimal")
    end

    test "selecting a new keyed backend persists its key", %{conn: conn, tmp_home: tmp_home} do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> element("button[phx-value-tab=\"search\"]")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_search\"]", search_form: %{backend: "brave"})
        |> render_change()

      assert html =~ "search_form[brave_api_key]"
      refute html =~ "search_form[perplexity_api_key]"

      view
      |> form("form[phx-submit=\"save_search\"]",
        search_form: %{backend: "brave", brave_api_key: "brave-live-test"}
      )
      |> render_submit()

      web_search =
        :fermix_core
        |> Application.get_env(:tools, [])
        |> Keyword.get(:web_search, [])

      assert Keyword.get(web_search, :backend) == :brave
      assert Keyword.get(web_search, :brave_api_key) == "brave-live-test"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(backend = "brave")
      assert contents =~ ~s(brave_api_key = "@keyring")
    end

    test "Save & next persists the backend (same as Save search, then advances)", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"search\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_search\"]", search_form: %{backend: "duckduckgo"})
      |> render_submit(%{"__nav" => "next"})

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.tools.web_search]"
      assert contents =~ ~s(backend = "duckduckgo")
    end
  end

  describe "restart navigation" do
    test "an explicit ?tab= lands the operator on that tab, not next_action_tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=doctor")

      # Provider is unconfigured here, so next_action_tab would normally choose
      # the provider tab; an explicit ?tab=doctor must win.
      assert html =~ "Readiness doctor"
      refute html =~ "Provider &amp; Model"
    end

    test "no tab param falls through to next_action_tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert html =~ "Provider &amp; Model"
    end

    test "an unknown tab param falls back to next_action_tab without crashing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=bogus")

      assert html =~ "Provider &amp; Model"
    end
  end

  describe "Search form" do
    test "selecting a backend reveals only that key and persists it", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> element("button[phx-value-tab=\"search\"]")
      |> render_click()

      # DuckDuckGo (default) exposes no key field.
      refute render(view) =~ "search_form[tavily_api_key]"

      # Selecting Tavily reveals only the Tavily key field.
      html =
        view
        |> form("form[phx-submit=\"save_search\"]", search_form: %{backend: "tavily"})
        |> render_change()

      assert html =~ "search_form[tavily_api_key]"
      refute html =~ "search_form[exa_api_key]"
      refute html =~ "search_form[parallel_api_key]"

      view
      |> form("form[phx-submit=\"save_search\"]",
        search_form: %{backend: "tavily", tavily_api_key: "tvly-live-test"}
      )
      |> render_submit()

      assert render(view) =~ "Search saved."

      web_search =
        :fermix_core
        |> Application.get_env(:tools, [])
        |> Keyword.get(:web_search, [])

      assert Keyword.get(web_search, :backend) == :tavily
      assert Keyword.get(web_search, :tavily_api_key) == "tvly-live-test"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.tools.web_search]"
      assert contents =~ ~s(backend = "tavily")
      assert contents =~ ~s(tavily_api_key = "@keyring")
    end
  end

  describe "Realtime form" do
    test "submitting persists voice companion settings", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> element("button[phx-value-tab=\"realtime\"]")
      |> render_click()

      view
      |> form("form[phx-submit=\"save_realtime\"]",
        realtime_form: %{
          enabled: "true",
          voice: "cedar",
          max_session_minutes: "20",
          max_cost_cents: "125",
          persist_transcripts: "true"
        }
      )
      |> render_submit()

      assert render(view) =~ "Realtime saved."
      assert render(view) =~ "Apply &amp; restart"

      realtime = Application.get_env(:fermix_core, :realtime, [])
      assert Keyword.get(realtime, :enabled) == true
      assert Keyword.get(realtime, :voice) == "cedar"
      assert Keyword.get(realtime, :max_session_minutes) == 20
      assert Keyword.get(realtime, :max_estimated_cost_cents_per_session) == 125
      assert Keyword.get(realtime, :persist_transcripts) == true

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(voice = "cedar")
      assert contents =~ "max_session_minutes = 20"
    end
  end

  describe "channel cards" do
    test "renders a selectable card per channel with status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=channels")

      for title <- ~w(Telegram WhatsApp Discord Slack Signal) do
        assert html =~ title
      end

      assert html =~ ~s(phx-click="select_channel")
      assert html =~ "Not configured"
    end

    test "selecting a channel loads its fields into the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=channels")

      html =
        view
        |> element(~s(button[phx-click="select_channel"][phx-value-channel="whatsapp"]))
        |> render_click()

      assert html =~ ~s(name="channels_form[whatsapp_access_token]")
      refute html =~ ~s(name="channels_form[telegram_bot_token]")
    end

    test "saving a channel keeps that channel selected, not bounced to telegram", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=channels")

      view
      |> element(~s(button[phx-click="select_channel"][phx-value-channel="discord"]))
      |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_channels\"]",
          channels_form: %{discord_bot_token: "tok", discord_owner_user_id: "1"}
        )
        |> render_submit()

      assert html =~ "Channels saved."
      assert html =~ ~s(name="channels_form[discord_bot_token]")
      refute html =~ ~s(name="channels_form[telegram_bot_token]")
    end
  end

  describe "primary provider cards" do
    setup do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-openai", primary: true, default_model: "gpt-5.5"],
        anthropic: [api_key: "sk-ant", default_model: "claude-opus-4-7"]
      )

      # Persist to disk so the keys are real config, not env-only secrets that a
      # later primary-only save would strip.
      :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())

      :ok
    end

    test "render each provider with its primary/fallback/not-configured status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=provider")

      # openai = configured + primary; anthropic = configured fallback;
      # openai_codex + xai = unconfigured.
      assert html =~ "Fallback"
      assert html =~ "Not configured"
    end

    test "selecting a provider loads it into the configure form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "anthropic"})
        |> render_change()

      assert html =~ "Configuring anthropic"
      assert html =~ ~s(name="provider_form[anthropic_api_key]")
    end

    test "an unconfigured provider can be selected to configure (nothing disabled)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "xai"})
        |> render_change()

      assert html =~ "Configuring xai"
    end

    test "Set primary flips the flag to a configured fallback without re-entering creds", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> element(~s(button[phx-click="set_primary"][phx-value-provider="anthropic"]))
        |> render_click()

      assert html =~ "Primary provider set to anthropic"

      {:ok, persisted} = ConfigStore.load_runtime_config()
      providers = Keyword.get(persisted.fermix_core, :providers, [])
      assert Keyword.get(providers[:anthropic], :primary) == true
      refute Keyword.get(providers[:openai], :primary) == true
      # Credentials are untouched by a Set-primary flip.
      assert Keyword.get(providers[:anthropic], :api_key) == "sk-ant"
    end

    test "the primary provider and unconfigured providers expose no Set primary button", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      # openai is already primary; xai is unconfigured.
      refute has_element?(view, ~s(button[phx-click="set_primary"][phx-value-provider="openai"]))
      refute has_element?(view, ~s(button[phx-click="set_primary"][phx-value-provider="xai"]))
    end
  end

  describe "Provider form" do
    test "phx-change updates the model list without crashing the LV", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      # Submit a change with provider=anthropic but keep the model+effort at
      # their initial (openai-rendered) values so form validation passes. The
      # LV's re-render after handle_event/3 should swap the model list.
      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{
            provider: "anthropic",
            default_model: "gpt-5.5",
            reasoning_effort: "none"
          }
        )
        |> render_change()

      assert html =~ "claude-sonnet-4-6"
      assert html =~ ~s(name="provider_form[anthropic_api_key]")
      refute html =~ "gpt-5.5</option>"
    end

    test "submitting persists provider, model, reasoning effort and api key", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "openai",
          default_model: "gpt-5.5",
          reasoning_effort: "high",
          openai_api_key: "sk-from-live-test"
        }
      )
      |> render_submit()

      assert render(view) =~ "Provider saved."
      assert render(view) =~ "Apply &amp; restart"

      providers = Application.get_env(:fermix_core, :providers, [])
      openai = Keyword.get(providers, :openai, [])

      assert Keyword.get(openai, :default_model) == "gpt-5.5"
      assert Keyword.get(openai, :reasoning_effort) == :high

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(default_model = "gpt-5.5")
      assert contents =~ ~s(reasoning_effort = "high")
    end

    test "submitting persists Anthropic model and api key", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "anthropic",
          default_model: "gpt-5.5",
          reasoning_effort: "none"
        }
      )
      |> render_change()

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "anthropic",
          default_model: "claude-sonnet-4-6",
          anthropic_api_key: "sk-ant-from-live-test"
        }
      )
      |> render_submit()

      assert render(view) =~ "Provider saved."

      providers = Application.get_env(:fermix_core, :providers, [])
      anthropic = Keyword.get(providers, :anthropic, [])

      assert Keyword.get(anthropic, :default_model) == "claude-sonnet-4-6"
      assert Keyword.get(anthropic, :api_key) == "sk-ant-from-live-test"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.providers.anthropic]"
      assert contents =~ ~s(api_key = "@keyring")
    end

    test "phx-change to xAI swaps in xAI models and the xAI api-key field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{
            provider: "xai",
            default_model: "gpt-5.5",
            reasoning_effort: "none"
          }
        )
        |> render_change()

      # The form actually switches to xAI (not falling back to OpenAI): xAI
      # models replace OpenAI models, and the xAI secret field renders.
      assert html =~ "grok-4.3"
      assert html =~ ~s(name="provider_form[xai_api_key]")
      refute html =~ "gpt-5.5</option>"
      # xAI supports reasoning effort (like the CLI wizard), so the field shows.
      assert html =~ "Reasoning effort"
    end

    test "submitting persists xAI model, reasoning effort, and api key", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{provider: "xai", default_model: "gpt-5.5", reasoning_effort: "none"}
      )
      |> render_change()

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "xai",
          default_model: "grok-4.3",
          reasoning_effort: "high",
          xai_api_key: "xai-from-live-test"
        }
      )
      |> render_submit()

      assert render(view) =~ "Provider saved."

      providers = Application.get_env(:fermix_core, :providers, [])
      xai = Keyword.get(providers, :xai, [])

      assert Keyword.get(xai, :default_model) == "grok-4.3"
      assert Keyword.get(xai, :reasoning_effort) == :high
      assert Keyword.get(xai, :api_key) == "xai-from-live-test"

      assert Keyword.get(xai, :primary) == true

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.providers.xai]"
    end

    test "submitting persists Codex fast mode as a boolean", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{
            provider: "openai_codex",
            default_model: "gpt-5.5",
            reasoning_effort: "high"
          }
        )
        |> render_change()

      assert html =~ "Fast mode"

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "openai_codex",
          default_model: "gpt-5.5",
          reasoning_effort: "high",
          fast: "true"
        }
      )
      |> render_submit()

      assert render(view) =~ "Provider saved."

      providers = Application.get_env(:fermix_core, :providers, [])
      codex = Keyword.get(providers, :openai_codex, [])

      assert Keyword.get(codex, :fast) == true

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.providers.openai_codex]"
      assert contents =~ "fast = true"
    end

    test "selecting Codex offers ChatGPT OAuth login", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{
            provider: "openai_codex",
            default_model: "gpt-5.5",
            reasoning_effort: "high"
          }
        )
        |> render_change()

      assert html =~ "Sign in with ChatGPT"
      assert html =~ ~s(phx-click="codex_login")
      assert html =~ ~s(data-auth-trigger="true")
    end

    test "Codex OAuth login persists through the secure auth store", %{conn: conn} do
      parent = self()

      Application.put_env(:fermix_web, :codex_login_runner, fn opts ->
        Keyword.fetch!(opts, :oauth_opener).("https://auth.openai.test/codex")
        entry = codex_auth_entry()
        :ok = Store.write(:openai_codex, entry)
        send(parent, {:codex_login_started, Keyword.keys(opts)})
        {:ok, entry}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "openai_codex",
          default_model: "gpt-5.5",
          reasoning_effort: "high"
        }
      )
      |> render_change()

      html = view |> element(~s|button[phx-click="codex_login"]|) |> render_click()
      assert html =~ "Opening ChatGPT sign-in"
      assert_receive {:codex_login_started, keys}
      assert :oauth_opener in keys

      html = render_until(view, "ChatGPT OAuth connected.")
      assert html =~ "ChatGPT OAuth connected."
      assert html =~ "Connected"
      refute html =~ "https://auth.openai.test/codex"

      assert {:ok, entry} = Store.read(:openai_codex)
      assert entry.auth_mode == "chatgpt"
      assert entry.tokens.access_token == "codex_access_token"
    end

    test "Codex OAuth completion marks it primary without an explicit save", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      parent = self()

      Application.put_env(:fermix_web, :codex_login_runner, fn opts ->
        Keyword.fetch!(opts, :oauth_opener).("https://auth.openai.test/codex")
        entry = codex_auth_entry()
        :ok = Store.write(:openai_codex, entry)
        send(parent, {:codex_login_started, Keyword.keys(opts)})
        {:ok, entry}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      # Select Codex and complete OAuth — but never submit "Save provider".
      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "openai_codex",
          default_model: "gpt-5.5",
          reasoning_effort: "high"
        }
      )
      |> render_change()

      view |> element(~s|button[phx-click="codex_login"]|) |> render_click()
      assert_receive {:codex_login_started, _keys}
      render_until(view, "ChatGPT OAuth connected.")

      # Regression: connecting Codex must leave it the primary provider so the
      # end-of-setup probe (PrimaryConfig.primary) resolves to it. Previously the
      # flag was set only by a later save carrying provider=openai_codex, so a
      # connect-then-probe flow reported "provider not configured".
      assert PrimaryConfig.primary() == {:ok, :openai_codex}

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.providers.openai_codex]"
      assert contents =~ "primary = true"
    end

    test "shows the API key / OAuth picker for xAI and anthropic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "xai"})
        |> render_change()

      assert html =~ "Authentication"
      assert html =~ ~s(name="provider_form[auth_mode]")
    end

    test "xAI OAuth connect stores the token and switches auth_mode to oauth", %{conn: conn} do
      parent = self()

      Application.put_env(:fermix_web, :xai_login_runner, fn opts ->
        Keyword.fetch!(opts, :opener).("https://auth.x.ai/grok")
        send(parent, {:xai_login_started, Keyword.keys(opts)})

        :ok =
          Store.write("xai_oauth", %{
            auth_mode: "oauth_pkce",
            provider: "xai",
            tokens: %{access_token: "xai-at", refresh_token: "xai-rt"},
            expires_at: nil,
            last_refresh: nil,
            status: "ready"
          })

        {:ok, %{provider: "xai"}}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "xai"})
      |> render_change()

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{provider: "xai", auth_mode: "oauth"}
      )
      |> render_change()

      html = view |> element(~s|button[phx-click="xai_login"]|) |> render_click()
      assert html =~ "Opening Grok sign-in"
      assert_receive {:xai_login_started, keys}
      assert :opener in keys

      html = render_until(view, "Grok OAuth connected.")
      assert html =~ "Grok OAuth connected"
      assert {:ok, _entry} = Store.read("xai_oauth")
      assert provider_auth_mode(:xai) == :oauth
    end

    test "Anthropic OAuth: pasting a token and Save provider stores it and sets auth_mode", %{
      conn: conn
    } do
      Application.put_env(:fermix_web, :anthropic_login_impl, AnthropicLoginStub)

      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "anthropic"})
      |> render_change()

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{provider: "anthropic", auth_mode: "oauth"}
      )
      |> render_change()

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{
            provider: "anthropic",
            auth_mode: "oauth",
            anthropic_setup_token: "sk-ant-oat01"
          }
        )
        |> render_submit()

      assert html =~ "Provider saved"
      assert {:ok, _entry} = Store.read("anthropic_oauth")
      assert provider_auth_mode(:anthropic) == :oauth
    end

    test "Anthropic OAuth: Save provider with a blank token keeps existing and sets auth_mode", %{
      conn: conn
    } do
      Application.put_env(:fermix_web, :anthropic_login_impl, AnthropicLoginStub)

      {:ok, view, _html} = live(conn, "/setup")

      view
      |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "anthropic"})
      |> render_change()

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{provider: "anthropic", auth_mode: "oauth"}
      )
      |> render_change()

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{provider: "anthropic", auth_mode: "oauth", anthropic_setup_token: ""}
        )
        |> render_submit()

      assert html =~ "Provider saved"
      assert provider_auth_mode(:anthropic) == :oauth
    end
  end

  defp provider_auth_mode(provider) do
    {:ok, snapshot} = ConfigStore.load_runtime_config()

    snapshot.fermix_core
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(:auth_mode)
  end

  describe "Personalization form" do
    test "defaults the timezone field to America/New_York when none is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> element("button[phx-value-tab=\"personalization\"]")
        |> render_click()

      assert html =~ "America/New_York"
    end

    test "submitting persists name, timezone, and communication style", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> element("button[phx-value-tab=\"personalization\"]")
      |> render_click()

      view
      |> form("form[phx-submit=\"save_personalization\"]",
        personalization_form: %{
          user_name: "Sujeeth",
          timezone: "Asia/Singapore",
          communication_style: "concise and direct"
        }
      )
      |> render_submit()

      assert render(view) =~ "Personalization saved."

      personalization = Application.get_env(:fermix_core, :personalization, [])
      assert Keyword.get(personalization, :user_name) == "Sujeeth"
      assert Keyword.get(personalization, :timezone) == "Asia/Singapore"
      assert Keyword.get(personalization, :communication_style) == "concise and direct"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "Sujeeth"
      assert contents =~ "Asia/Singapore"
    end
  end

  describe "doctor probes" do
    test "run probe returns immediately while provider and channel probes finish async", %{
      conn: conn
    } do
      Req.Test.set_req_test_to_shared()
      stub_setup_doctor_probe()

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-live-test", default_model: "gpt-5.5"]
      )

      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        bot_token: "telegram-token",
        owner_user_id: "111",
        allowed_user_ids: ["111"],
        req_options: [plug: {Req.Test, :setup_doctor_probe}]
      )

      Application.put_env(:fermix_web, :doctor_probe_opts,
        req_options: [plug: {Req.Test, :setup_doctor_probe}]
      )

      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"doctor\"]") |> render_click()

      html = view |> element("button", "Run probe") |> render_click()

      assert html =~ "Provider probe is running."
      assert html =~ "Probe running"

      html = render_until(view, "bot @fermix_test authenticated")
      assert html =~ "openai gpt-5.5 responded"
      assert html =~ "bot @fermix_test authenticated"
    end
  end

  describe "restart" do
    test "Doctor step offers Apply & restart; in dev it reports no supervised service", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"doctor\"]") |> render_click()
      assert html =~ "Apply &amp; restart"

      html = view |> element("button", "Apply & restart") |> render_click()
      assert html =~ "Nothing to restart from here"
    end

    test "saving channels keeps an inline restart action visible", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"channels\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_channels\"]",
          channels_form: %{
            telegram_bot_token: "bot-token",
            telegram_owner_user_id: "111"
          }
        )
        |> render_submit()

      assert html =~ "Channels saved."
      assert html =~ "Apply &amp; restart"
      assert html =~ ~s(phx-click="apply_restart")
    end

    test "saving sandbox settings keeps an inline restart action visible", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"sandbox\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_sandbox\"]",
          sandbox_form: %{
            mode: "standard",
            profile: "assistant",
            env_allow: "FERMIX_ALLOWED"
          }
        )
        |> render_submit()

      assert html =~ "Sandbox saved."
      assert html =~ "Apply &amp; restart"
      assert html =~ ~s(phx-click="apply_restart")
    end
  end

  describe "notification banner" do
    test "styles errors and successes distinctly and no longer nags about restart", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      error_html =
        view
        |> element(~s|button[phx-click="plugin_enable"][phx-value-name="google_calendar"]|)
        |> render_click()

      assert error_html =~ "Save a Google OAuth desktop client first"
      assert error_html =~ ~s(role="alert")
      assert error_html =~ "bg-error"
      assert error_html =~ "hero-x-circle"

      ok_html =
        view
        |> form("form[phx-submit=\"save_google_oauth\"]",
          google_oauth_form: %{
            client_id: "123.apps.googleusercontent.com",
            client_secret: "desktop-secret",
            redirect_port: "1455"
          }
        )
        |> render_submit()

      assert ok_html =~ "Google OAuth client saved."
      assert ok_html =~ ~s(role="status")
      assert ok_html =~ "bg-success"
      assert ok_html =~ "hero-check-circle"
      refute ok_html =~ "Changes need a restart to take effect"
    end
  end

  defp write_ready_plugin_auth(name) do
    {:ok, plugin} = PluginRegistry.find(name)

    Store.write(PluginConfig.default_auth_profile(plugin), %{
      auth_mode: "oauth2",
      provider: plugin.auth.provider,
      account: %{email: "#{name}@example.com"},
      scope_profile: "default",
      granted_scopes: [],
      tokens: %{access_token: "AT", refresh_token: "RT"},
      expires_at: DateTime.utc_now() |> DateTime.add(3600),
      last_refresh: nil,
      status: "ready"
    })
  end

  defp codex_auth_entry do
    %{
      auth_mode: "chatgpt",
      tokens: %{access_token: "codex_access_token", refresh_token: "codex_refresh_token"},
      expires_at: DateTime.utc_now() |> DateTime.add(3600),
      last_refresh: DateTime.utc_now(),
      status: "ready"
    }
  end

  defp stub_setup_doctor_probe do
    Req.Test.stub(:setup_doctor_probe, fn conn ->
      Process.sleep(100)

      case conn.request_path do
        "/v1/responses" ->
          Req.Test.json(conn, %{"id" => "resp_live_test"})

        "/bottelegram-token/getMe" ->
          Req.Test.json(conn, %{"ok" => true, "result" => %{"username" => "fermix_test"}})

        _other ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)
  end

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp render_until(view, expected, attempts \\ 20)

  defp render_until(view, expected, attempts) when attempts > 0 do
    html = render(view)

    if html =~ expected do
      html
    else
      Process.sleep(25)
      render_until(view, expected, attempts - 1)
    end
  end

  defp render_until(view, expected, 0) do
    render(view)
    flunk("expected rendered LiveView to include #{inspect(expected)}")
  end
end
