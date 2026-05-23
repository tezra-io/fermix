defmodule FermixWebWeb.SetupLiveTest do
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Setup.ConfigStore

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    fermix_home = System.get_env("FERMIX_HOME")

    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live")
    System.put_env("FERMIX_HOME", tmp_home)

    # Force readiness to :setup_required so commit_snapshot/1 skips
    # prompt-file seeding; these tests do not exercise the memory repo.
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    %{tmp_home: tmp_home}
  end

  describe "/setup shell" do
    test "renders the ASCII FERMIX header and config path", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert html =~ "FERMIX" or html =~ "█████"
      assert html =~ "FERMIX setup" or html =~ "Fermix setup"
      assert html =~ ConfigStore.path()
    end

    test "renders all ten category tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      for label <- ~w(Provider Realtime Channels Tools Skills Search Sandbox Memory Personalization Doctor) do
        assert html =~ label
      end
    end

    test "tab switching changes the visible pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      # Provider pane is the default
      assert render(view) =~ "Provider &amp; Model"

      # Switch to Personalization
      html = view |> element("button[phx-value-tab=\"personalization\"]") |> render_click()
      assert html =~ "Personalization"
      assert html =~ "Your name"

      # Switch to a placeholder tab
      html = view |> element("button[phx-value-tab=\"tools\"]") |> render_click()
      assert html =~ "coming soon" or html =~ "later M10 stage"
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

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
