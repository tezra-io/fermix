defmodule FermixWebWeb.SetupLiveTest do
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Setup.ConfigStore

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    secret_writer = Application.get_env(:fermix_core, :secret_writer)
    tools = Application.get_env(:fermix_core, :tools, [])
    fermix_home = System.get_env("FERMIX_HOME")

    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live")
    System.put_env("FERMIX_HOME", tmp_home)
    FermixTestSupport.SecretWriterStub.reset()

    # Force readiness to :setup_required so commit_snapshot/1 skips
    # prompt-file seeding; these tests do not exercise the memory repo.
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    Application.put_env(:fermix_core, :tools, [])

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      restore_env(:fermix_core, :secret_writer, secret_writer)
      Application.put_env(:fermix_core, :tools, tools)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    %{tmp_home: tmp_home}
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
            ~w(Provider Realtime Channels Skills Search Sandbox Memory Personalization Doctor) do
        assert html =~ label
      end

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
            {"skills", "Installed skills"},
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

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
