defmodule FermixWebWeb.SetupLiveTest do
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Setup.ConfigStore

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

      html = render(view)
      assert html =~ "ChatGPT OAuth connected."
      assert html =~ "Connected"
      refute html =~ "https://auth.openai.test/codex"

      assert {:ok, entry} = Store.read(:openai_codex)
      assert entry.auth_mode == "chatgpt"
      assert entry.tokens.access_token == "codex_access_token"
    end
  end

  describe "Personalization form" do
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

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
