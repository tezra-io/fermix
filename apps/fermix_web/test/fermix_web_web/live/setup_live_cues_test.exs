defmodule FermixWebWeb.SetupLiveCuesTest do
  # The setup page's Cues tab (M60 §15, lane G). Every save goes through the
  # config store under a temp FERMIX_HOME and every secret through the stub;
  # the watcher and source rows come from a private temp Repo.
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Cues.Door
  alias FermixCore.Cues.FilterChoices
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Webhook
  alias FermixCore.Management.Cues.SourceForm
  alias FermixCore.Management.Settings.Cues, as: SettingsCues
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.CueDeliveryFixtures
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-17 12:00:00Z]
  @cue_text "Invented outside text 7781 that must stay off the owner page"
  @drop_reason "Invented filter reason 4410"
  # The X sign-in the X accounts form reads, so no test reaches a token store.
  @x_signed_out {:error, :no_token}

  setup %{conn: conn} do
    saved = %{
      core:
        Map.new(
          ~w(providers agent secret_writer tools transcription realtime meetings harness routing
             plugins plugins_dist_opts oauth cues personalization)a,
          &{&1, Application.fetch_env(:fermix_core, &1)}
        ),
      web:
        Map.new(
          ~w(harness_detector imessage_macos? local_transcription_opts cues_pane_opts)a,
          &{&1, Application.fetch_env(:fermix_web, &1)}
        ),
      channels:
        Map.new(~w(telegram imessage)a, &{&1, Application.fetch_env(:fermix_channels, &1)}),
      home: System.get_env("FERMIX_HOME")
    }

    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-cues")
    System.put_env("FERMIX_HOME", tmp_home)
    SecretWriterStub.reset()

    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.put_env(:fermix_core, :tools, [])

    Application.put_env(:fermix_core, :transcription,
      backend: "openai",
      model: "gpt-4o-mini-transcribe",
      max_file_mb: 20
    )

    Application.put_env(:fermix_core, :realtime, [])
    Application.put_env(:fermix_core, :meetings, enabled: false)
    Application.put_env(:fermix_core, :harness, [])
    Application.put_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :plugins_dist_opts, [])
    Application.put_env(:fermix_core, :oauth, %{})
    Application.put_env(:fermix_core, :cues, [])
    Application.put_env(:fermix_core, :personalization, [])
    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :imessage, enabled: false)
    Application.put_env(:fermix_web, :imessage_macos?, false)

    Application.put_env(:fermix_web, :local_transcription_opts,
      releases: FermixTestSupport.SttPins.for_this_host()
    )

    Application.put_env(:fermix_web, :harness_detector, fn -> %{} end)
    put_pane_opts([])

    on_exit(fn ->
      Enum.each(saved.core, fn {key, value} -> restore_env(:fermix_core, key, value) end)
      Enum.each(saved.web, fn {key, value} -> restore_env(:fermix_web, key, value) end)
      Enum.each(saved.channels, fn {key, value} -> restore_env(:fermix_channels, key, value) end)

      case saved.home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    %{conn: authorize_setup(conn), tmp_home: tmp_home}
  end

  describe "the tab" do
    test "sits after Personalization and before Doctor", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      order =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[phx-value-tab]")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "phx-value-tab"))
        |> Enum.uniq()
        |> Enum.filter(&(&1 in ~w(personalization cues doctor)))

      assert order == ~w(personalization cues doctor)
    end

    test "renders Run cues, the door, how watchers judge items and the docs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      html = open_cues(view)

      assert html =~ "Run cues"
      assert html =~ "Door port"
      assert html =~ "Not running"
      assert html =~ "Filter model"
      refute html =~ "never falls back to your main model"
      assert html =~ "Memory is off"
      assert html =~ ~s(href="https://fermix.ai/docs/cues/")

      # Every explanation lives behind a tooltip, so each one takes keyboard
      # focus; a tooltip around a button rides the button's own focus.
      tips =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#cues-pane [data-tip]")
        |> Enum.reject(&(LazyHTML.to_html(&1) =~ "<button"))

      assert tips != []
      assert Enum.all?(tips, &(LazyHTML.attribute(&1, "tabindex") == ["0"]))
    end

    test "a first run shows one card with the three steps in place of the empty lists", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      page = view |> open_cues() |> LazyHTML.from_fragment()

      card = LazyHTML.query(page, "#cues-first-run")
      assert card |> LazyHTML.query("h3") |> LazyHTML.text() =~ "Nothing is watched yet"

      assert card |> LazyHTML.query("ol li") |> Enum.map(&squish(LazyHTML.text(&1))) == [
               "Add something to watch: a blog, X accounts, GitHub or your scripts.",
               "In chat, tell Fermix what to look for. It makes a watcher.",
               "When something matches, your task runs, and asks you before it acts."
             ]

      button = LazyHTML.query(card, ~s(button[phx-click="cues_new_source"]))
      assert button |> LazyHTML.text() |> String.trim() == "Add a source"
      assert button |> LazyHTML.attribute("class") |> hd() =~ "btn-primary"

      for section <- ~w(#cues-sources #cues-watchers #cues-mandates),
          do: refute(page |> LazyHTML.query(section) |> Enum.any?(), section)

      # Add a source asks what to watch where the card was; Cancel brings it back.
      html = new_source(view)
      refute html =~ ~s(id="cues-first-run")
      assert html =~ ~s(id="cue-source-choices")

      html =
        view
        |> element(~s(#cue-source-choices button[phx-click="cues_close_source"]))
        |> render_click()

      assert html =~ ~s(id="cues-first-run")
    end

    test "the first-run card is only for a list with no source in it", %{conn: conn} do
      put_cues(sources: %{"eng-blogs" => [preset: "rss", url: "https://blog.example.org/feed"]})
      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      refute html =~ ~s(id="cues-first-run")
      refute html =~ "Nothing is watched yet"
      assert html =~ ~s(id="cue-source-eng-blogs")
    end

    test "watchers appear once a source or a watcher exists, mandates once a watcher or a mandate does",
         %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_sections")
      put_pane_opts(repo: repo)

      {:ok, _view, html} = live(conn, "/setup?tab=cues")
      refute html =~ ~s(id="cues-watchers")
      refute html =~ ~s(id="cues-mandates")

      put_cues(sources: %{"eng-blogs" => [preset: "rss", url: "https://blog.example.org/feed"]})
      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert section_text(html, "#cues-watchers") =~
               "No watchers yet. Ask Fermix in chat to watch for something."

      refute html =~ ~s(id="cues-mandates")

      # A mandate shows its section with no watcher yet.
      put_cues(
        mandates: %{
          "release-issues" => [job: "job_release", mode: "auto", tools: ["acme_create_issue"]]
        }
      )

      {:ok, _view, html} = live(conn, "/setup?tab=cues")
      refute html =~ ~s(id="cues-watchers")
      assert html =~ ~s(id="cues-mandates")

      # A watcher shows both, with no source and no mandate.
      put_cues([])
      CueDeliveryFixtures.watcher(db, %{name: "release-notes", sources: ["eng-blogs"]})
      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert section_text(html, "#cues-watchers") =~ "release-notes"
      assert section_text(html, "#cues-mandates") =~ "No mandates."
      assert html =~ ~s(id="cues-first-run")
    end
  end

  describe "settings" do
    test "one form holds Run cues, the watchers' switch, the door's port, the Screen and the filter model, with one Save",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      html = open_cues(view)
      page = LazyHTML.from_fragment(html)

      assert settings_fields(html) ==
               ~w(enabled mandates_enabled door_port screen filter_provider)

      assert page |> LazyHTML.query("#cues-settings-form button") |> Enum.map(&button_type/1) ==
               ["submit"]

      assert page |> LazyHTML.query("#cues-settings-form button") |> LazyHTML.text() =~ "Save"

      # Screen and the filter model sit under one heading, in that order, and
      # the door's port under Advanced.
      assert page |> LazyHTML.query("#cues-judging h3") |> LazyHTML.text() |> String.trim() ==
               "How watchers judge items"

      cards = page |> LazyHTML.query("#cues-judging > div[id]") |> LazyHTML.attribute("id")
      assert cards == ~w(cues-screen cues-filter)

      assert page
             |> LazyHTML.query(~s(#cues-switches-advanced input[name="cues_settings[door_port]"]))
             |> Enum.any?()

      # No other form in the pane saves a setting.
      forms = page |> LazyHTML.query("#cues-pane form") |> LazyHTML.attribute("id")
      assert forms == ["cues-settings-form"]
    end

    test "the watchers' switch takes its label and info from the engine's cues section", %{
      conn: conn
    } do
      put_cues(
        mandates: %{
          "release-issues" => [job: "job_release", mode: "auto", tools: ["acme_create_issue"]]
        }
      )

      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      row =
        "cues"
        |> SettingsCues.rows(ConfigStore.current_snapshot())
        |> Enum.find(&(&1["key"] == "cues_mandates_enabled"))

      label =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#cues-settings-mandates_enabled")

      assert label |> LazyHTML.text() =~ row["label"]

      assert label |> LazyHTML.query("[data-tip]") |> LazyHTML.attribute("data-tip") == [
               row["info"]
             ]

      # The Mandates head has no switch of its own.
      refute html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#cues-mandates input")
             |> Enum.any?()
    end

    test "one Save writes every changed setting, and asks for a restart when cues or the door move",
         %{conn: conn} do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "invented-key-2207"])
      model = hd(ModelCatalog.models_for(:openai)).id
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      # Choosing a provider brings its model box; it saves nothing.
      view
      |> form("#cues-settings-form", cues_settings: %{filter_provider: "openai"})
      |> render_change()

      assert persisted(:routing) == []

      html =
        view
        |> form("#cues-settings-form",
          cues_settings: %{
            enabled: "true",
            mandates_enabled: "false",
            door_port: "4040",
            screen: "decision_model",
            filter_provider: "openai",
            filter_model: model
          }
        )
        |> render_submit()

      assert html =~ "Cues saved. Restart to apply."
      assert html =~ "Apply &amp; restart"

      cues = persisted_cues()
      assert Keyword.get(cues, :enabled) == true
      assert Keyword.get(cues, :mandates_enabled) == false
      assert Keyword.get(cues, :door_port) == 4040
      assert Keyword.get(cues, :screen) == :decision_model
      assert %{provider: :openai, model: ^model} = RoutingOverrides.filter()
      assert Keyword.get(persisted(:routing), :filter_model) == model

      # Back to keyword match and the main model: live, no restart.
      view
      |> form("#cues-settings-form", cues_settings: %{filter_provider: ""})
      |> render_change()

      html =
        view
        |> form("#cues-settings-form", cues_settings: %{screen: "", filter_provider: ""})
        |> render_submit()

      # The door still says it waits for the restart the first Save asked for.
      assert html =~ "Cues saved."
      refute html =~ "Cues saved. Restart to apply."
      refute Keyword.has_key?(persisted_cues(), :screen)
      assert %{provider: nil, model: nil} = RoutingOverrides.filter()
      refute Keyword.has_key?(persisted(:routing), :filter_provider)
    end

    test "Save sends only what the owner changed, and with nothing changed writes nothing", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      put_cues(door_port: 4040)
      config = Path.join(tmp_home, "config.toml")
      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      before = File.read!(config)
      html = view |> form("#cues-settings-form") |> render_submit()

      assert html =~ "Nothing changed."
      assert File.read!(config) == before

      # The watchers' switch moves elsewhere after the page drew it; a Save that
      # changes only Run cues leaves it as it is now.
      put_cues(door_port: 4040, mandates_enabled: false)

      view
      |> form("#cues-settings-form", cues_settings: %{enabled: "true"})
      |> render_submit()

      cues = persisted_cues()
      assert Keyword.get(cues, :enabled) == true
      assert Keyword.get(cues, :mandates_enabled) == false
      assert Keyword.get(cues, :door_port) == 4040
    end

    test "a refused value is said under its field and nothing is written", %{conn: conn} do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "invented-key-2207"])
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      html =
        view
        |> form("#cues-settings-form",
          cues_settings: %{enabled: "true", screen: "decision_model", door_port: "80"}
        )
        |> render_submit()

      assert alert_with(html, "Save failed:")
      assert settings_refusal(html, "cues_door_port") =~ "door_port"
      assert settings_refusal(html, "cues_screen") == nil
      assert persisted_cues() == []

      # A model with no provider, said under the filter model.
      html =
        view
        |> element("#cues-settings-form")
        |> render_submit(%{cues_settings: %{filter_provider: "", filter_model: "some-model"}})

      assert settings_refusal(html, "filter_provider") ==
               "Pick a provider and a model, or clear both."

      assert persisted(:routing) == []

      # The next change clears it.
      html =
        view
        |> form("#cues-settings-form", cues_settings: %{door_port: "4032"})
        |> render_change()

      assert settings_refusal(html, "filter_provider") == nil
    end

    test "the filter model offers the main model first and only providers that are set up, and its list follows the provider",
         %{conn: conn} do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "invented-key-2207"])
      {:ok, view, _html} = live(conn, "/setup")
      html = open_cues(view)

      assert html =~ ~r/<option value="" selected[^>]*>\s*Default: your main model \(OpenAI/

      assert html =~
               "Judges each item on its own, so a smaller, faster model works well and costs " <>
                 "much less than your main model."

      assert html =~ ~s(<option value="openai")
      refute html =~ ~s(<option value="anthropic")
      refute html =~ "(not set up)"
      # The model box belongs to a chosen provider; the main model has its own.
      refute html =~ ~s(name="cues_settings[filter_model]")

      html =
        view
        |> form("#cues-settings-form", cues_settings: %{filter_provider: "openai"})
        |> render_change()

      assert html =~ ~s(name="cues_settings[filter_model]")

      models =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#cues-filter-models option")
        |> LazyHTML.attribute("value")

      assert models == Enum.map(FilterChoices.models("openai"), & &1.id)
      assert models != []
    end

    test "the Screen offers keyword match and the decision model, and names the one Fermix uses",
         %{conn: conn} do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "invented-key-2207"])
      {:ok, view, _html} = live(conn, "/setup")
      html = open_cues(view)

      assert html =~ "How items are checked before the filter model reads them."
      assert html =~ ~r/<option value="" selected[^>]*>\s*Keyword match/
      assert html =~ ~r/<option value="decision_model"[^>]*>\s*Decision model/
      refute html =~ "Uses OpenAI · gpt-6-luna"

      html =
        view
        |> form("#cues-settings-form", cues_settings: %{screen: "decision_model"})
        |> render_submit()

      assert html =~ ~r/<option value="decision_model" selected[^>]*>\s*Decision model/
      assert html =~ "Uses OpenAI · gpt-6-luna"
    end

    test "the decision model is refused under the Screen while none is set up, and nothing is written",
         %{conn: conn} do
      Application.put_env(:fermix_core, :providers, anthropic: [api_key: "invented-key-2207"])
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      html =
        view
        |> form("#cues-settings-form", cues_settings: %{screen: "decision_model"})
        |> render_submit()

      assert settings_refusal(html, "cues_screen") ==
               "Set up OpenAI, OpenRouter or Venice first: a decision model runs on one of them."

      assert persisted_cues() == []
    end

    test "a running door shows where it listens", %{conn: conn} do
      name = :"setup_cues_door_#{System.unique_integer([:positive])}"
      start_supervised!({Door, port: 0, name: name, schedule: fn _message, _ms -> :ok end})
      {:listening, {_ip, port}} = Door.status(name)
      put_pane_opts(door: name)

      {:ok, view, _html} = live(conn, "/setup")

      assert open_cues(view) =~ "Listening on 127.0.0.1:#{port}"
    end
  end

  describe "adding a source" do
    test "starts from what to watch: the featured four, then the other three under Something else",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      html = new_source(view)

      assert choice_ids(html, "#cue-source-choices") ==
               ~w(rss x_accounts github local_push feed stream webhook)

      assert choice_ids(html, "#cue-source-something-else") == ~w(feed stream webhook)

      # Each row is the engine's label and line; nothing to type yet.
      for choice <- SourceForm.choices() do
        row =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(~s(button[phx-value-choice="#{choice["id"]}"]))
          |> LazyHTML.text()
          |> squish()

        assert row =~ choice["label"]
        assert row =~ choice["sentence"]
      end

      assert field_names(html, "#cues-sources") == []
    end

    test "a choice opens only what it needs, with the name and the rest under More options",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)

      expected = %{
        "rss" => {~w(url), ~w(ref interval daily_budget)},
        "x_accounts" => {~w(handles), ~w(ref interval daily_budget)},
        "github" =>
          {[], ~w(ref verify header algorithm prefix id_header id type_header daily_budget)},
        "local_push" => {[], ~w(ref daily_budget)},
        "feed" => {~w(url interval), ~w(ref daily_budget)},
        "stream" =>
          {~w(url key secret subscribe_message id_path),
           ~w(ref key_header secret_header auth_message type_path item_types error_types
              items_path revision_path time_path subject_path daily_budget)},
        "webhook" =>
          {~w(verify header id_header id secret),
           ~w(ref algorithm prefix type_header daily_budget)}
      }

      for {choice, {open, folded}} <- expected do
        html = pick(view, choice)

        assert source_form_text(html, "h4") == choice(choice)["label"]
        assert kind_line(html) =~ choice(choice)["sentence"]
        assert open_fields(html) == open, "#{choice} opens #{inspect(open_fields(html))}"
        assert folded_fields(html) == folded, "#{choice} folds #{inspect(folded_fields(html))}"
        refute required_field?(html, "ref")
        assert primary_buttons(html) == ["Add source"]

        # Back returns to the list.
        html = view |> element(~s(button[phx-click="cues_back_to_choices"])) |> render_click()
        assert html =~ ~s(id="cue-source-choices")
        refute html =~ ~s(id="cue-source-form")
      end
    end

    test "every word on the form is the engine's", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "rss")

      name = SourceForm.name_row("rss")
      assert placeholder(html, "ref") == name.example
      assert html =~ escaped(name.label)
      assert html =~ escaped(name.info)
      assert html =~ SourceForm.url_label("rss")
      assert html =~ SourceForm.field_words("interval_minutes").label
      assert html =~ SourceForm.field_words("daily_budget").label
      assert html =~ escaped(SourceForm.field_words("daily_budget").info)
      refute html =~ "Poll every"
      refute html =~ "Daily budget"

      view |> element(~s(button[phx-click="cues_back_to_choices"])) |> render_click()
      html = pick(view, "webhook")

      assert html =~ SourceForm.field_words("verify").label
      assert html =~ SourceForm.webhook_secret_label("hmac")

      for key <- ~w(header algorithm prefix id_header type_header content_hash),
          do: assert(html =~ escaped(SourceForm.field_words(key).label), key)

      assert html =~ escaped(SourceForm.field_words("content_hash").info)

      {:ok, %{"rows" => rows}} = SourceForm.form("webhook", nil, nil)
      verify = Enum.find(rows, &(&1["key"] == "verify"))
      assert verify_options(html) == Enum.map(verify["options"], &{&1["value"], &1["label"]})
    end

    test "each choice's notes sit behind its line's info, as the form answer gives them", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)

      for choice <- SourceForm.choices() do
        html = pick(view, choice["id"])

        assert kind_line_info(html) == form_notes(choice["kind"], choice["preset"]),
               choice["id"]

        view |> element(~s(button[phx-click="cues_back_to_choices"])) |> render_click()
      end

      # The ones that have notes say where items come in and how.
      assert form_notes("webhook", "github") =~ "tunnel"
      assert form_notes("webhook", "github") =~ "application/json"
      assert form_notes("local_push", nil) =~ "CloudEvent"
      assert form_notes("feed", "rss") == nil
    end

    test "the name is optional: an unnamed source takes the name Fermix makes, and the tab shows it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "rss")

      html =
        view
        |> form("#cue-source-form", cue_source: %{url: "https://news.ycombinator.com/rss"})
        |> render_submit()

      assert html =~ "Source ycombinator saved."
      assert html =~ ~s(id="cue-source-ycombinator")

      assert Keyword.get(persisted_source("ycombinator"), :url) ==
               "https://news.ycombinator.com/rss"

      # A second one gets a name of its own.
      new_source(view)
      pick(view, "rss")

      html =
        view
        |> form("#cue-source-form", cue_source: %{url: "https://news.ycombinator.com/best"})
        |> render_submit()

      assert html =~ "Source ycombinator-2 saved."
      assert html =~ ~s(id="cue-source-ycombinator-2")
    end

    test "the form as it opens saves with a name and an address", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "rss")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "blog-notes", url: "https://notes.example.org/feed.xml"}
        )
        |> render_submit()

      assert html =~ "Source blog-notes saved."
      section = persisted_source("blog-notes")
      assert Keyword.get(section, :preset) == "rss"
      assert Keyword.get(section, :url) == "https://notes.example.org/feed.xml"
    end

    test "a submit that names another kind or preset than the choice is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "rss")

      html =
        view
        |> element("#cue-source-form")
        |> render_submit(%{
          cue_source: %{preset: "", url: "https://notes.example.org/feed.xml", interval: "600"}
        })

      assert html =~ "Save failed: A source&#39;s kind cannot change."
      assert persisted_cues() == []
    end

    # A stream is the general WebSocket source: its own fields and two typed
    # secrets.
    test "a stream draws the general source's fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "stream")

      refute "dids" in field_names(html, "#cue-source-form")
      refute "collections" in field_names(html, "#cue-source-form")
      assert required_field?(html, "id_path")

      # The management form's words, its literals' backticks dropped.
      info = Enum.find(SourceForm.general_stream_rows(), &(&1.field == :key_header)).info
      assert html =~ info |> String.replace("`", "") |> escaped()

      # Each empty field shows the management form's example, and the API key
      # and secret come straight after the address, by the names the app gives
      # them, ahead of the fields that name their headers.
      for row <- SourceForm.general_stream_rows(),
          do: assert(placeholder(html, Atom.to_string(row.field)) == row.example, "#{row.field}")

      assert Enum.take(open_fields(html), 3) == ~w(url key secret)
      assert html =~ "API key"
      assert html =~ "Paste the API secret"
    end

    test "a stream with no preset saves its fields and its typed key and secret", %{conn: conn} do
      key = "PK3W9QZ7RT"
      secret = "invented-secret-8840"
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "stream")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{
            ref: "live-news",
            url: "wss://stream.example.com/v2/news",
            key_header: "X-Feed-Key",
            auth_message: ~s({"action":"auth","secret":"{{secret}}"}),
            id_path: "id",
            type_path: "T",
            item_types: "n, update",
            error_types: "error",
            key: key,
            secret: secret
          }
        )
        |> render_submit()

      assert html =~ "Source live-news saved."
      refute html =~ key
      refute html =~ secret

      source = persisted_source("live-news")
      assert source[:kind] == :stream
      assert source[:key_header] == "X-Feed-Key"
      assert source[:item_types] == ["n", "update"]
      assert source[:key] == "@keyring"
      assert source[:secret] == "@keyring"
      refute Keyword.has_key?(source, :dids)
      assert {:ok, ^key} = SecretWriter.get({:cue_source, "live-news", :key}, store: :keyring)
    end

    # M60_X_ACCOUNTS_SOURCE.md §4: X accounts builds its own address from the
    # handles and reads with the X plugin's sign-in.
    test "X accounts asks for the accounts, says how it signs in, and saves them", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "x_accounts")

      assert open_fields(html) == ~w(handles)
      assert required_field?(html, "handles")
      assert html =~ SourceForm.handles_row().label
      assert placeholder(html, "handles") == SourceForm.handles_row().example

      # The note on X's sign-in and billing sits behind the line's info.
      assert kind_line_info(html) == SourceForm.preset_note("x_accounts")

      html =
        view
        |> form("#cue-source-form", cue_source: %{ref: "space-posts", handles: "@NASA, esa"})
        |> render_submit()

      assert html =~ "Source space-posts saved."
      section = persisted_source("space-posts")
      assert Keyword.get(section, :preset) == "x_accounts"
      assert Keyword.get(section, :handles) == ["nasa", "esa"]
      refute Keyword.has_key?(section, :url)
      refute Keyword.has_key?(section, :interval)

      view
      |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="space-posts"]))
      |> render_click()

      html =
        view
        |> form("#cue-source-form", cue_source: %{handles: "nasa, not-a-handle"})
        |> render_submit()

      assert html =~ "not-a-handle"
      assert Keyword.get(persisted_source("space-posts"), :handles) == ["nasa", "esa"]
    end

    test "X accounts says whether X is signed in, and links to the X plugin when it is not", %{
      conn: conn
    } do
      put_pane_opts(x_sign_in: fn -> :ready end)
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "x_accounts")

      ready = SourceForm.requirement("x_accounts", x_sign_in: fn -> :ready end)
      assert source_form_text(html, "#cue-source-requirement") == ready["sentence"]
      refute html |> source_form_nodes(~s(#cue-source-requirement button)) |> Enum.any?()

      put_pane_opts(x_sign_in: fn -> @x_signed_out end)
      view |> element(~s(button[phx-click="cues_back_to_choices"])) |> render_click()
      html = pick(view, "x_accounts")

      signed_out = SourceForm.requirement("x_accounts", x_sign_in: fn -> @x_signed_out end)
      assert source_form_text(html, "#cue-source-requirement") =~ signed_out["sentence"]
      # The add stays open either way.
      assert html |> source_form_nodes(~s(button[type="submit"])) |> Enum.any?()

      html =
        view
        |> element(~s(#cue-source-requirement button[phx-click="select_tab"]))
        |> render_click()

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s(button[phx-value-tab="plugins"][aria-current="step"]))
             |> Enum.any?()
    end

    test "GitHub asks for nothing, and its save shows the secret Fermix made once, with the address and GitHub's steps",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "github")

      assert open_fields(html) == []
      refute "secret" in field_names(html, "#cue-source-form")

      html = view |> form("#cue-source-form") |> render_submit()

      {:ok, secret} = SecretWriter.get({:cue_source, "github", :secret}, store: :keyring)
      {:ok, random} = SecretWriter.get({:cue_source, "github", :path_secret}, store: :keyring)

      assert html =~ "Source github saved."
      refute alert_with(html, secret)
      assert reveal_text(html, "#cues-reveal-secret") == secret

      assert reveal_text(html, "#cues-reveal-value") ==
               "http://127.0.0.1:4032/cues/hooks/github/#{random}"

      steps =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#cues-reveal-steps li")
        |> Enum.map(&squish(LazyHTML.text(&1)))

      # GitHub's steps, in the engine's words.
      assert steps == SourceForm.github_steps()
      assert length(steps) == 3

      section = persisted_source("github")
      assert Keyword.get(section, :preset) == "github"
      assert Keyword.get(section, :secret) == "@keyring"
      assert Keyword.get(section, :path_secret) == "@keyring"

      # Shown once: Done takes it off the page and out of the page's state.
      html =
        view
        |> element(~s(#cues-reveal button[phx-click="cues_dismiss_reveal"]))
        |> render_click()

      refute html =~ secret
      assert cues_assigns(view).reveal == nil

      {:ok, _view, fresh} = live(conn, "/setup?tab=cues")
      refute fresh =~ secret
      assert fresh =~ ~s(id="cue-source-github")
    end

    test "a value shown once leaves the page's state when the owner opens another tab", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "github")
      view |> form("#cue-source-form") |> render_submit()

      {:ok, secret} = SecretWriter.get({:cue_source, "github", :secret}, store: :keyring)
      assert cues_assigns(view).reveal.secret == secret

      view
      |> element(~s(button[phx-click="select_tab"][phx-value-tab="plugins"]))
      |> render_click()

      assert cues_assigns(view).reveal == nil
    end

    test "a field the kind needs and no preset fills is marked, and its absence is refused in the editor",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "feed")

      assert required_field?(html, "url")
      assert required_field?(html, "interval")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "blog-notes", url: "https://notes.example.org/feed.xml"}
        )
        |> render_submit()

      assert persisted_cues() == []
      assert alert_with(html, "Save failed: Fill in the fields marked as needed.")

      # Said again beside Save, where the owner is looking, without a second
      # announcement, and under the field that is missing.
      editor = source_form_text(html, "#cue-source-refusal")
      assert editor =~ "Fill in the fields marked as needed."
      refute html |> source_form_nodes("#cue-source-refusal[role]") |> Enum.any?()
      assert field_refusal(html, "interval") == "Needed when no preset fills it."
      assert field_refusal(html, "url") == nil

      assert html
             |> source_form_nodes(~s(input[name="cue_source[interval]"][aria-invalid="true"]))
             |> Enum.any?()

      # The mark goes once the field holds a value.
      html = view |> form("#cue-source-form", cue_source: %{interval: "600"}) |> render_change()

      assert field_refusal(html, "interval") == nil
      refute html |> source_form_nodes(~s([aria-invalid="true"])) |> Enum.any?()
    end

    test "a method's and a stream's own needs are marked and refused under their field", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      # A webhook checked by HMAC names its signature header.
      new_source(view)
      html = pick(view, "webhook")
      assert required_field?(html, "header")

      html =
        view
        |> form("#cue-source-form", cue_source: %{ref: "shop-orders", id_header: "X-Delivery"})
        |> render_submit()

      assert field_refusal(html, "header") == "Needed when no preset fills it."

      assert source_form_text(html, "#cue-source-refusal") =~
               "Fill in the fields marked as needed."

      # It also names how items are told apart: either way out is named.
      html =
        view
        |> form("#cue-source-form", cue_source: %{header: "X-Shop-Signature", id_header: ""})
        |> render_submit()

      assert field_refusal(html, "id_header") ==
               "Give a delivery id header, or have Fermix identify items by their content."

      assert field_refusal(html, "header") == nil
      assert persisted_cues() == []

      # Identifying items by their content answers it.
      html = view |> form("#cue-source-form", cue_source: %{id: "true"}) |> render_change()
      assert field_refusal(html, "id_header") == nil

      # A stream names where each message keeps its id.
      view |> element(~s(button[phx-click="cues_back_to_choices"])) |> render_click()
      html = pick(view, "stream")
      assert required_field?(html, "id_path")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "live-news", url: "wss://stream.example.com/v2/news"}
        )
        |> render_submit()

      assert field_refusal(html, "id_path") == "Needed when no preset fills it."
      assert persisted_cues() == []
    end

    test "a local-push source gets a token shown once, stored through the writer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "local_push")

      html =
        view
        |> form("#cue-source-form", cue_source: %{ref: "home-alerts"})
        |> render_submit()

      assert html =~ "Source home-alerts saved."
      {:ok, token} = SecretWriter.get({:cue_source, "home-alerts", :token}, store: :keyring)
      assert html =~ token
      assert html =~ "curl"
      assert html =~ "http://127.0.0.1:4032/cues/v1/home-alerts"

      section = persisted_source("home-alerts")
      assert Keyword.get(section, :kind) == :local_push
      assert Keyword.get(section, :token) == "@keyring"

      # Shown once: the next event and a fresh page never carry it again.
      refute view |> element(~s(button[phx-click="cues_refresh"])) |> render_click() =~ token
      {:ok, _view, fresh} = live(conn, "/setup?tab=cues")
      refute fresh =~ token
      assert fresh =~ "home-alerts"
    end

    test "a value shown once appears in the Sources section, where the owner saved, and takes focus",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      new_source(view)
      pick(view, "local_push")

      token =
        view
        |> form("#cue-source-form", cue_source: %{ref: "home-alerts"})
        |> render_submit()

      new_source(view)
      pick(view, "github")
      github = view |> form("#cue-source-form") |> render_submit()

      for html <- [token, github] do
        page = LazyHTML.from_fragment(html)
        assert page |> LazyHTML.query("#cues-sources #cues-reveal") |> Enum.any?()
        # Brought into view: its heading takes focus as it appears.
        heading = LazyHTML.query(page, ~s(#cues-reveal h3[tabindex="-1"][phx-mounted]))
        assert Enum.any?(heading)
      end
    end

    test "a feed source is added, edited and removed through the config store", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "rss")

      view
      |> form("#cue-source-form",
        cue_source: %{
          ref: "eng-blogs",
          url: "https://blog.example.org/releases.atom",
          interval: "",
          daily_budget: "50"
        }
      )
      |> render_submit()

      section = persisted_source("eng-blogs")
      assert Keyword.get(section, :preset) == "rss"
      assert Keyword.get(section, :url) == "https://blog.example.org/releases.atom"
      assert Keyword.get(section, :daily_budget) == 50
      # The preset's interval stays the preset's, and a new source is on.
      refute Keyword.has_key?(section, :interval)
      refute Keyword.has_key?(section, :enabled)

      view
      |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="eng-blogs"]))
      |> render_click()

      view
      |> form("#cue-source-form",
        cue_source: %{
          enabled: "false",
          url: "https://blog.example.org/releases.atom",
          interval: "600",
          daily_budget: "50"
        }
      )
      |> render_submit()

      section = persisted_source("eng-blogs")
      assert Keyword.get(section, :interval) == 600
      assert Keyword.get(section, :enabled) == false

      html =
        view
        |> element(~s(button[phx-click="cues_remove_source"][phx-value-ref="eng-blogs"]))
        |> render_click()

      assert html =~ "Source eng-blogs removed."
      assert Keyword.get(persisted_cues(), :sources) == nil
    end

    test "a refused source shows the config's sentence and writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "feed")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{
            ref: "plain-feed",
            url: "http://plain.example.org/feed.xml",
            interval: "300",
            daily_budget: ""
          }
        )
        |> render_submit()

      assert html =~ "Save failed:"
      assert html =~ "must start with https://"
      assert source_form_text(html, "#cue-source-refusal") =~ "must start with https://"
      assert persisted_cues() == []
    end

    test "a webhook source's secret is written through the writer and never shown", %{conn: conn} do
      signing = "invented-signing-secret-5531"
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "webhook")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{
            ref: "shop-orders",
            header: "X-Shop-Signature",
            id_header: "X-Shop-Delivery",
            secret: signing
          }
        )
        |> render_submit()

      assert html =~ "Source shop-orders saved."
      refute html =~ signing

      assert {:ok, ^signing} =
               SecretWriter.get({:cue_source, "shop-orders", :secret}, store: :keyring)

      assert Keyword.get(persisted_source("shop-orders"), :secret) == "@keyring"

      {:ok, _view, fresh} = live(conn, "/setup?tab=cues")
      refute fresh =~ signing
      assert fresh =~ ~s(id="cue-source-shop-orders")
      refute fresh =~ "Needs a secret"
    end

    test "a new webhook source shows its URL as soon as it is saved, and an edit does not", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "webhook")

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{
            ref: "deploy-hooks",
            header: "X-Deploy-Signature",
            id_header: "X-Deploy-Delivery",
            secret: "invented-signing-4417"
          }
        )
        |> render_submit()

      {:ok, random} =
        SecretWriter.get({:cue_source, "deploy-hooks", :path_secret}, store: :keyring)

      assert html =~ "Source deploy-hooks saved."
      assert html =~ "URL for deploy-hooks"
      assert html =~ "http://127.0.0.1:4032/cues/hooks/deploy-hooks/#{random}"
      assert Keyword.get(persisted_source("deploy-hooks"), :path_secret) == "@keyring"
      refute view |> element(~s(button[phx-click="cues_refresh"])) |> render_click() =~ random

      view
      |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="deploy-hooks"]))
      |> render_click()

      html =
        view
        |> form("#cue-source-form", cue_source: %{daily_budget: "20"})
        |> render_submit()

      assert html =~ "Source deploy-hooks saved."
      assert Keyword.get(persisted_source("deploy-hooks"), :daily_budget) == 20
      refute html =~ "URL for deploy-hooks"
      refute html =~ random
    end

    test "a webhook with no preset shows the fields of the method it shows, and saves that method",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      html = pick(view, "webhook")
      assert html =~ "Paste the secret"
      refute html =~ "Paste the secret the service signs with"

      # Before Verification is touched: HMAC is chosen, and the fields it
      # needs, which no preset fills, are drawn open, not under More options.
      assert selected(html, "cue_source[verify]") == "hmac"
      assert open_fields(html) == ~w(verify header id_header id secret)

      # A save that never posts Verification stores the method the page showed.
      view
      |> element("#cue-source-form")
      |> render_submit(%{
        cue_source: %{
          ref: "shop-orders",
          header: "X-Shop-Signature",
          id_header: "X-Shop-Delivery"
        }
      })

      section = persisted_source("shop-orders")
      assert Keyword.get(section, :verify) == :hmac
      assert Keyword.get(section, :header) == "X-Shop-Signature"
      assert Keyword.get(section, :id_header) == "X-Shop-Delivery"

      # GitHub brings its own method and folds what it fills.
      new_source(view)
      html = pick(view, "github")

      assert selected(html, "cue_source[verify]") == ""
      assert "verify" in folded_fields(html)
      assert "header" in folded_fields(html)
    end

    test "a new webhook whose URL cannot be made stays saved, and the page says so", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "webhook")

      # No secret is typed, so the save writes none; the URL's random part is
      # the first write the locked store refuses.
      SecretWriterStub.set_verdict(%{store: :keyring, state: :locked, sentence: "locked"})
      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{
            ref: "deploy-hooks",
            header: "X-Deploy-Signature",
            id_header: "X-Deploy-Delivery"
          }
        )
        |> render_submit()

      assert html =~ "Source deploy-hooks saved, but its URL could not be made."
      assert html =~ "The URL for deploy-hooks could not be stored."
      refute html =~ "Save failed"

      # The page's banner says it in the error tone, not the green one.
      banner = alert_with(html, "Source deploy-hooks saved, but its URL could not be made.")
      assert banner, "the banner is an alert"
      assert banner |> LazyHTML.attribute("class") |> hd() =~ "text-error"
      refute banner |> LazyHTML.attribute("class") |> hd() =~ "text-success"
      # The banner announces it; the block below it does not announce it again.
      assert html |> LazyHTML.from_fragment() |> LazyHTML.query("#cues-reveal") |> Enum.any?()

      refute html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#cues-reveal[role]")
             |> Enum.any?()

      refute html =~ "/cues/hooks/deploy-hooks/"
      assert html =~ ~s(id="cue-source-deploy-hooks")

      section = persisted_source("deploy-hooks")
      assert Keyword.get(section, :verify) == :hmac
      refute Keyword.has_key?(section, :path_secret)
    end

    test "a new GitHub source whose URL meets an outside change says how to recover and still shows its secret",
         %{conn: conn, tmp_home: tmp_home} do
      # The settings file is edited outside Fermix between the source's save and
      # the save of its URL: the URL's save goes through the write guard as the
      # daemon's does, and the guard refuses it.
      config = Path.join(tmp_home, "config.toml")

      persist = fn ref, sentinel ->
        File.write!(config, File.read!(config) <> "\n[fermix_core.compaction]\nthreshold = 0.5\n")
        snapshot = Webhook.put_path_sentinel(ConfigStore.current_snapshot(), ref, sentinel)

        case Wizard.commit_snapshot(snapshot) do
          {:ok, _report} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      # The guard's state is this VM's; the next test starts from agreement.
      on_exit(fn -> :ok = RestartState.record_persisted_baseline() end)

      put_pane_opts(webhook_opts: [persist: persist])

      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "github")

      html =
        view |> form("#cue-source-form", cue_source: %{ref: "deploy-hooks"}) |> render_submit()

      assert alert_with(html, "Source deploy-hooks saved, but its URL could not be made.")

      reveal =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#cues-reveal") |> LazyHTML.text()

      assert reveal =~ "The settings file changed outside Fermix."
      assert reveal =~ "Reload settings from disk, then save again."
      refute reveal =~ "external_change"
      assert html =~ ~s(phx-click="reload_settings")

      # The secret Fermix made cannot be shown again, so it is shown now.
      {:ok, secret} = SecretWriter.get({:cue_source, "deploy-hooks", :secret}, store: :keyring)
      assert reveal_text(html, "#cues-reveal-secret") == secret

      section = persisted_source("deploy-hooks")
      assert Keyword.get(section, :preset) == "github"
      refute Keyword.has_key?(section, :path_secret)
    end

    test "a secret the store refuses leaves the config as it was", %{conn: conn} do
      SecretWriterStub.set_verdict(%{store: :keyring, state: :locked, sentence: "locked"})
      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      new_source(view)
      pick(view, "local_push")

      html =
        view
        |> form("#cue-source-form", cue_source: %{ref: "home-alerts"})
        |> render_submit()

      assert html =~ "Save failed: The token for home-alerts could not be stored"
      assert persisted_cues() == []

      # GitHub's made secret is refused the same way: never a source without it.
      view |> element(~s(button[phx-click="cues_back_to_choices"])) |> render_click()
      pick(view, "github")
      html = view |> form("#cue-source-form") |> render_submit()

      assert html =~ "Save failed: The secret for github could not be stored"
      assert persisted_cues() == []
      refute html =~ ~s(id="cues-reveal")
    end
  end

  describe "sources" do
    # The JSON paths are a general stream's fields on this page; a feed's own,
    # written by hand, stay as they were when the feed is edited here.
    test "editing a JSON API feed keeps the paths it was written with", %{conn: conn} do
      put_cues(
        sources: %{
          "api-feed" => [
            kind: "feed",
            url: "https://api.example.com/items",
            interval: 300,
            items_path: "data",
            id_path: "id"
          ]
        }
      )

      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      view
      |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="api-feed"]))
      |> render_click()

      view
      |> form("#cue-source-form", cue_source: %{interval: "600"})
      |> render_submit()

      source = persisted_source("api-feed")
      assert source[:interval] == 600
      assert source[:items_path] == "data"
      assert source[:id_path] == "id"
    end

    test "editing a source says where its items come from, in the engine's words", %{conn: conn} do
      put_cues(
        sources: %{
          "home-alerts" => [kind: "local_push", token: "@keyring"],
          "repo-events" => [preset: "github", secret: "@keyring"]
        }
      )

      {:ok, view, html} = live(conn, "/setup?tab=cues")
      assert view |> element("#cue-source-repo-events") |> render() =~ "GitHub"
      refute html =~ ">github<"

      html =
        view
        |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="home-alerts"]))
        |> render_click()

      assert kind_line(html) == choice("local_push")["sentence"]
      assert kind_line_info(html) == form_notes("local_push", nil)

      html =
        view
        |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="repo-events"]))
        |> render_click()

      assert fixed_choice(html) =~ SourceForm.kind_label("webhook")
      assert fixed_choice(html) =~ SourceForm.preset_label("github")
      assert kind_line(html) == choice("github")["sentence"]
      assert kind_line_info(html) == form_notes("webhook", "github")
      # Its secret can be replaced here, by the engine's name for it.
      assert "secret" in field_names(html, "#cue-source-form")
      assert html =~ SourceForm.webhook_secret_label("hmac")
    end

    test "editing shows a source's kind and preset as text, and a save that changes them is refused",
         %{conn: conn} do
      put_cues(sources: %{"repo-events" => [preset: "github", secret: "@keyring"]})
      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      html =
        view
        |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="repo-events"]))
        |> render_click()

      refute html =~ ~s(name="cue_source[kind]")
      refute html =~ ~s(name="cue_source[preset]")
      assert primary_buttons(html) == ["Save source"]
      assert fixed_choice(html) =~ "Kind"
      assert fixed_choice(html) =~ "Webhook"
      assert fixed_choice(html) =~ "GitHub"

      # A submit that names another kind or drops the preset anyway is refused,
      # and the section stays as it was.
      for change <- [
            %{kind: "feed", url: "https://feed.example.org/items.xml", interval: "600"},
            %{preset: ""}
          ] do
        html = view |> element("#cue-source-form") |> render_submit(%{cue_source: change})

        assert LazyHTML.text(LazyHTML.from_fragment(html)) =~
                 "Save failed: A source's kind cannot change. Remove it and add a new one."

        section = persisted_source("repo-events")
        assert Keyword.get(section, :preset) == "github"
        refute Keyword.has_key?(section, :kind)
        refute Keyword.has_key?(section, :url)
      end
    end

    test "a new token replaces the stored one and is shown once", %{conn: conn} do
      put_cues(sources: %{"home-alerts" => [kind: "local_push", token: "@keyring"]})
      :ok = SecretWriter.put({:cue_source, "home-alerts", :token}, "old-token", store: :keyring)

      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      html =
        view
        |> element(~s(button[phx-click="cues_new_token"][phx-value-ref="home-alerts"]))
        |> render_click()

      {:ok, token} = SecretWriter.get({:cue_source, "home-alerts", :token}, store: :keyring)
      refute token == "old-token"
      assert html =~ token
      assert html =~ "The old one stops working within a minute."
      refute view |> element(~s(button[phx-click="cues_refresh"])) |> render_click() =~ token
    end

    test "editing keeps the fields the form does not show", %{conn: conn} do
      put_cues(
        sources: %{
          "status-api" => [
            kind: "feed",
            url: "https://status.example.org/api/items",
            interval: 300,
            items_path: "data.items",
            id_path: "id"
          ]
        }
      )

      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      view
      |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="status-api"]))
      |> render_click()

      view
      |> form("#cue-source-form",
        cue_source: %{
          enabled: "true",
          url: "https://status.example.org/api/items",
          interval: "120",
          daily_budget: ""
        }
      )
      |> render_submit()

      section = persisted_source("status-api")
      assert Keyword.get(section, :interval) == 120
      assert Keyword.get(section, :items_path) == "data.items"
      assert Keyword.get(section, :id_path) == "id"
    end

    test "a source missing its secret says so, and only then", %{conn: conn} do
      put_cues(
        sources: %{
          "repo-events" => [preset: "github"],
          "home-alerts" => [kind: "local_push"],
          "desk-alerts" => [kind: "local_push", token: "@keyring"]
        }
      )

      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      assert view |> element("#cue-source-repo-events") |> render() =~ "Needs a secret"
      assert view |> element("#cue-source-home-alerts") |> render() =~ "Needs a token"
      refute view |> element("#cue-source-desk-alerts") |> render() =~ "Needs a token"
    end

    test "a webhook source's URL is made on request and shown with the door's port", %{
      conn: conn
    } do
      put_cues(sources: %{"repo-events" => [preset: "github", secret: "@keyring"]})
      :ok = SecretWriter.put({:cue_source, "repo-events", :secret}, "s3cret", store: :keyring)

      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      html =
        view
        |> element(~s(button[phx-click="cues_webhook_url"][phx-value-ref="repo-events"]))
        |> render_click()

      {:ok, random} =
        SecretWriter.get({:cue_source, "repo-events", :path_secret}, store: :keyring)

      assert html =~ "http://127.0.0.1:4032/cues/hooks/repo-events/#{random}"
      assert Keyword.get(persisted_source("repo-events"), :path_secret) == "@keyring"
      refute view |> element(~s(button[phx-click="cues_refresh"])) |> render_click() =~ random
    end

    test "a source's live status comes from its row", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_sources")
      put_pane_opts(repo: repo)
      put_cues(sources: %{"eng-blogs" => [preset: "rss", url: "https://blog.example.org/feed"]})

      CueFixtures.exec!(
        db,
        """
        INSERT INTO cue_sources (source_ref, status, last_good_at, items_today, items_day,
          reject_counts, updated_at)
        VALUES ('eng-blogs', 'polling', '2026-10-17T11:45:00.000000Z', 7, '2026-10-17',
          '{"rate_limited": 3}', '2026-10-17T11:45:00.000000Z')
        """
      )

      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert html =~ "Polling"
      # The full time rides the pill's title; the row itself stays short.
      assert html =~ ~s(title="Last good 2026-10-17 11:45 UTC")
      assert html =~ "7 today"
      assert html =~ "rate_limited 3"
    end

    test "an X accounts source waiting for the X sign-in says so in its pill", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_x_sign_in")
      put_pane_opts(repo: repo)
      put_cues(sources: %{"space-posts" => [preset: "x_accounts", handles: ["nasa"]]})

      CueFixtures.exec!(
        db,
        """
        INSERT INTO cue_sources (source_ref, status, stop_reason, items_today, items_day,
          reject_counts, updated_at)
        VALUES ('space-posts', 'auth_failed', 'x_sign_in', 0, '2026-10-17', '{}',
          '2026-10-17T11:45:00.000000Z')
        """
      )

      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert html =~ "Needs X sign-in"
      refute html =~ "Credential refused"
    end

    test "a source row shows its last item as a short time in the owner's zone", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_source_times")
      put_pane_opts(repo: repo)
      Application.put_env(:fermix_core, :personalization, timezone: "Asia/Tokyo")

      put_cues(
        sources: %{
          "feed-today" => [preset: "rss", url: "https://today.example.org/feed"],
          "feed-yesterday" => [preset: "rss", url: "https://yesterday.example.org/feed"],
          "feed-older" => [preset: "rss", url: "https://older.example.org/feed"]
        }
      )

      # @now is 21:00 on Oct 17 in Tokyo.
      for {ref, accepted} <- [
            {"feed-today", "2026-10-17T11:30:00.000000Z"},
            {"feed-yesterday", "2026-10-15T20:00:00.000000Z"},
            {"feed-older", "2026-10-12T03:00:00.000000Z"}
          ] do
        CueFixtures.exec!(
          db,
          """
          INSERT INTO cue_sources (source_ref, status, last_accepted_at, items_today, items_day,
            reject_counts, updated_at)
          VALUES (?, 'polling', ?, 1, '2026-10-17', '{}', ?)
          """,
          [ref, accepted, accepted]
        )
      end

      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      today = view |> element("#cue-source-feed-today") |> render()
      assert today =~ "last item 20:30"
      assert today =~ ~s(title="2026-10-17 20:30 JST")
      refute today =~ "2026-10-17T11:30"

      assert view |> element("#cue-source-feed-yesterday") |> render() =~ "last item yesterday"
      assert view |> element("#cue-source-feed-older") |> render() =~ "last item Oct 12"
    end
  end

  describe "watchers" do
    test "show counts and ids, never cue text", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_watchers")
      put_pane_opts(repo: repo)

      watcher =
        CueDeliveryFixtures.watcher(db, %{name: "release-notes", sources: ["eng-blogs"]})

      CueFixtures.exec!(
        db,
        "UPDATE cue_watchers SET filter_failures = 3, listen_for = '[\"release\"]' WHERE id = ?",
        [watcher.id]
      )

      for {state, hours} <- [{"pending", 1}, {"passed", 2}, {"dropped", 3}, {"dropped", 30}] do
        received = DateTime.add(@now, -hours * 3_600, :second)

        cue =
          CueDeliveryFixtures.cue(db, %{
            source_ref: "eng-blogs",
            received_at: received,
            text: @cue_text
          })

        CueDeliveryFixtures.delivery(db, cue, %{
          watcher_id: watcher.id,
          source_ref: "eng-blogs",
          received_at: received,
          state: state,
          reason: @drop_reason
        })
      end

      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert html =~ "release-notes"
      assert html =~ "eng-blogs"
      assert html =~ watcher.job_id
      assert html =~ "Held"
      assert html =~ "Model filter"
      assert html =~ "Watchers are made and changed in chat with Fermix"
      assert html =~ ~s(data-watcher-waiting="1")
      assert html =~ ~s(data-watcher-passed="1")
      # The dropped delivery 30 hours ago is outside the last day.
      assert html =~ ~s(data-watcher-dropped="1")
      refute html =~ @cue_text
      refute html =~ @drop_reason
    end

    # M60_CUE_INTAKE_AT_SCALE.md §3.1 and §3.4: a watcher stored before the
    # rules says what it needs, and a stream's offers are counted, not stored.
    test "one stored before the rules says what it needs; offers are counted", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_watchers_rules")
      put_pane_opts(repo: repo)
      watcher = CueDeliveryFixtures.watcher(db, %{name: "old-news", sources: ["eng-blogs"]})

      row = %{
        scope: "watcher",
        ref: watcher.id,
        hour: CuesSql.hour_of(@now),
        incarnation: "inc-a",
        counts: %{"offered" => 7}
      }

      {:ok, 1} = Repo.cues_call(CuesSql, {:counts_put, [row], @now}, server: repo)

      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert html =~ "Needs update"
      assert html =~ "Needs keywords to listen for: update it in chat."
      assert html =~ ~s(data-watcher-offered="7")
    end
  end

  describe "mandates" do
    test "an inactive mandate shows its reason and offers no Approve", %{conn: conn} do
      put_cues(
        mandates: %{
          "release-issues" => [job: "job_release", mode: "auto", tools: ["acme_create_issue"]]
        }
      )

      {:ok, _view, html} = live(conn, "/setup?tab=cues")

      assert html =~ "release-issues"
      assert html =~ "Inactive: acme_create_issue is not an http plugin tool"
      refute html =~ ~s(phx-click="cues_approve_mandate")
    end

    test "Approve stores the owner's approval and shows when", %{conn: conn} do
      %{repo: repo} = CueFixtures.start_repo("setup_mandates")
      put_pane_opts(repo: repo, mandate_opts: [plugin_tool: &acme_tool/1, get_job: &cue_job/1])

      put_cues(
        mandates: %{
          "release-issues" => [
            job: "job_release",
            mode: "auto",
            tools: ["acme_create_issue"],
            pin_args: %{"repo" => "ops"}
          ]
        }
      )

      {:ok, view, html} = live(conn, "/setup?tab=cues")
      assert html =~ "Needs approval"

      html =
        view
        |> element(~s(button[phx-click="cues_approve_mandate"][phx-value-name="release-issues"]))
        |> render_click()

      assert html =~ "Mandate release-issues approved."
      assert html =~ "Approved 2026-10-17 12:00 UTC from the setup page."
      # Approved as it is now, so there is nothing left to approve.
      refute html =~ ~s(phx-click="cues_approve_mandate")

      assert {:ok, %{state: :approved, approved_from: "setup page"}} =
               Pins.status("release-issues",
                 config: Application.get_env(:fermix_core, :cues),
                 repo: repo,
                 plugin_tool: &acme_tool/1,
                 get_job: &cue_job/1
               )
    end

    test "Approve digests the mandate as the daemon reads it now, not as the page last showed it",
         %{conn: conn} do
      %{repo: repo} = CueFixtures.start_repo("setup_mandates_live")
      seams = [plugin_tool: &acme_tool/1, get_job: &cue_job/1]
      put_pane_opts(repo: repo, mandate_opts: seams)

      mandate = [job: "job_release", mode: "auto", tools: ["acme_create_issue"]]
      put_cues(mandates: %{"release-issues" => mandate ++ [pin_args: %{"repo" => "ops"}]})
      {:ok, view, _html} = live(conn, "/setup?tab=cues")

      # The live settings change after the page last read them.
      put_cues(mandates: %{"release-issues" => mandate ++ [pin_args: %{"repo" => "web"}]})

      view
      |> element(~s(button[phx-click="cues_approve_mandate"][phx-value-name="release-issues"]))
      |> render_click()

      live_seams = [config: Application.get_env(:fermix_core, :cues), repo: repo] ++ seams
      assert {:ok, %{state: :approved}} = Pins.status("release-issues", live_seams)
    end

    test "a mandate is added, edited and removed through the config store", %{conn: conn} do
      with_a_watcher("setup_mandates_edit")
      {:ok, view, _html} = live(conn, "/setup?tab=cues")
      view |> element(~s(button[phx-click="cues_new_mandate"])) |> render_click()

      html =
        view
        |> form("#cue-mandate-form",
          cue_mandate: %{
            name: "release-issues",
            job: "job_release",
            mode: "auto",
            tools: "acme_create_issue",
            read_tools: "acme_search_issues, acme_get_issue",
            max_cue_age: "10m",
            pin_args: ~s(repo = "ops"\ncount = 3),
            enabled: "true"
          }
        )
        |> render_submit()

      assert html =~ "Mandate release-issues saved."
      section = persisted_mandate("release-issues")
      assert Keyword.get(section, :job) == "job_release"
      assert Keyword.get(section, :mode) == :auto
      assert Keyword.get(section, :tools) == ["acme_create_issue"]
      assert Keyword.get(section, :read_tools) == ["acme_search_issues", "acme_get_issue"]
      assert Keyword.get(section, :max_cue_age) == "10m"
      assert Keyword.get(section, :pin_args) == %{"repo" => "ops", "count" => 3}
      refute Keyword.has_key?(section, :enabled)

      view
      |> element(~s(button[phx-click="cues_edit_mandate"][phx-value-name="release-issues"]))
      |> render_click()

      view
      |> form("#cue-mandate-form", cue_mandate: %{mode: "approve", pin_args: ""})
      |> render_submit()

      section = persisted_mandate("release-issues")
      assert Keyword.get(section, :mode) == :approve
      refute Keyword.has_key?(section, :pin_args)
      assert Keyword.get(section, :read_tools) == ["acme_search_issues", "acme_get_issue"]

      html =
        view
        |> element(~s(button[phx-click="cues_remove_mandate"][phx-value-name="release-issues"]))
        |> render_click()

      assert html =~ "Mandate release-issues removed."
      assert Keyword.get(persisted_cues(), :mandates) == nil
    end

    test "a malformed pinned argument is refused before anything is written", %{conn: conn} do
      with_a_watcher("setup_mandates_pins")
      {:ok, view, _html} = live(conn, "/setup?tab=cues")
      view |> element(~s(button[phx-click="cues_new_mandate"])) |> render_click()

      html =
        view
        |> form("#cue-mandate-form",
          cue_mandate: %{
            name: "release-issues",
            job: "job_release",
            tools: "acme_create_issue",
            pin_args: "repo ops"
          }
        )
        |> render_submit()

      assert html =~ "Each pinned argument is one line: name = value."
      assert persisted_cues() == []
    end
  end

  defp acme_tool(_name) do
    {:ok,
     %{
       plugin: "acme",
       tool: %{"parameters" => %{"properties" => %{"repo" => %{"type" => "string"}}}}
     }}
  end

  defp cue_job(id) do
    {:ok,
     %{
       id: id,
       name: "Release watch",
       schedule_kind: "cue",
       task_prompt: "File an issue for a new release.",
       skill_name: nil,
       allowed_tools: [],
       provider: nil,
       model: nil
     }}
  end

  # Mandates show once a watcher exists, which a private Repo holds.
  defp with_a_watcher(tag) do
    %{repo: repo, conn: db} = CueFixtures.start_repo(tag)
    put_pane_opts(repo: repo)
    CueDeliveryFixtures.watcher(db, %{name: "release-notes", sources: ["eng-blogs"]})
  end

  defp put_pane_opts(opts) do
    defaults = [now: fn -> @now end, x_sign_in: fn -> @x_signed_out end]
    Application.put_env(:fermix_web, :cues_pane_opts, Keyword.merge(defaults, opts))
  end

  defp persisted_mandate(name) do
    persisted_cues() |> Keyword.fetch!(:mandates) |> Map.fetch!(name)
  end

  defp open_cues(view) do
    view |> element(~s(button[phx-value-tab="cues"])) |> render_click()
  end

  defp new_source(view) do
    view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
  end

  defp pick(view, choice) do
    view
    |> element(~s(button[phx-click="cues_pick_source"][phx-value-choice="#{choice}"]))
    |> render_click()
  end

  defp choice(id), do: Enum.find(SourceForm.choices(), &(&1["id"] == id))

  defp choice_ids(html, scope) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(scope <> ~s( button[phx-click="cues_pick_source"]))
    |> LazyHTML.attribute("phx-value-choice")
  end

  # The settings form's fields, in page order, by their key.
  defp settings_fields(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#cues-settings-form [name^=cues_settings]")
    |> Enum.reject(&(LazyHTML.attribute(&1, "type") == ["hidden"]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "name"))
    |> Enum.map(&String.replace(&1, ~r/\Acues_settings\[(.+)\]\z/, "\\1"))
  end

  # The refusal said under the settings field a row key names, or nil.
  defp settings_refusal(html, row) do
    case html
         |> LazyHTML.from_fragment()
         |> LazyHTML.query("#cues-settings-#{row}-refusal")
         |> Enum.to_list() do
      [] -> nil
      [node | _rest] -> node |> LazyHTML.text() |> String.trim()
    end
  end

  defp button_type(node), do: node |> LazyHTML.attribute("type") |> List.first()

  # The words of the source form's primary buttons; the first is a submit,
  # and only Back and Cancel follow it.
  defp primary_buttons(html) do
    buttons =
      html
      |> source_form_nodes("button")
      |> Enum.map(fn node ->
        {node |> LazyHTML.text() |> String.trim(),
         node |> LazyHTML.attribute("class") |> hd() =~ "btn-primary", button_type(node)}
      end)

    {_before, [first | rest]} =
      Enum.split_while(buttons, fn {_text, primary?, _type} -> !primary? end)

    assert {_text, true, "submit"} = first
    assert Enum.map(rest, &elem(&1, 0)) -- ["Back", "Cancel"] == []

    for {text, true, _type} <- buttons, do: text
  end

  # The cue_source fields drawn in `scope`, in page order, by their key.
  defp field_names(html, scope) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(scope <> " [name^=cue_source]")
    |> Enum.reject(&(LazyHTML.attribute(&1, "type") == ["hidden"]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "name"))
    |> Enum.map(&String.replace(&1, ~r/\Acue_source\[(.+)\]\z/, "\\1"))
  end

  # The source form's fields drawn open and those folded under More options.
  defp open_fields(html), do: field_names(html, "#cue-source-form") -- folded_fields(html)
  defp folded_fields(html), do: field_names(html, "#cue-source-form #cue-source-more")

  defp placeholder(html, name) do
    html
    |> source_form_nodes(~s([name="cue_source[#{name}]"]))
    |> LazyHTML.attribute("placeholder")
    |> List.first()
  end

  defp verify_options(html) do
    html
    |> source_form_nodes(~s(select[name="cue_source[verify]"] option))
    |> Enum.map(&{option_value(&1), String.trim(LazyHTML.text(&1))})
    |> Enum.reject(fn {value, _label} -> value == "" end)
  end

  defp selected(html, name) do
    html
    |> source_form_nodes(~s(select[name="#{name}"] option[selected]))
    |> Enum.map(&option_value/1)
    |> List.first()
  end

  defp kind_line(html) do
    html
    |> source_form_nodes("#cue-source-kind-line > span:first-child")
    |> LazyHTML.text()
    |> String.trim()
  end

  # The info behind the kind line, or nil when it has none.
  defp kind_line_info(html) do
    html
    |> source_form_nodes("#cue-source-kind-line [data-tip]")
    |> LazyHTML.attribute("data-tip")
    |> List.first()
  end

  # The engine's notes for a kind and preset, as one info.
  defp form_notes(kind, preset) do
    {:ok, %{"notes" => notes}} = SourceForm.form(kind, preset, nil, x_sign_in: fn -> :ready end)

    case notes do
      [] -> nil
      notes -> Enum.join(notes, " ")
    end
  end

  defp source_form_nodes(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("#cue-source-form " <> selector)
  end

  defp option_value(node), do: node |> LazyHTML.attribute("value") |> List.first()

  defp required_field?(html, name) do
    html |> source_form_nodes(~s(input[name="cue_source[#{name}]"][required])) |> Enum.any?()
  end

  defp field_refusal(html, name) do
    case html |> source_form_nodes("#cue-source-#{name}-refusal") |> Enum.to_list() do
      [] -> nil
      [node | _rest] -> node |> LazyHTML.text() |> String.trim()
    end
  end

  defp source_form_text(html, selector) do
    html |> source_form_nodes(selector) |> LazyHTML.text() |> squish()
  end

  defp fixed_choice(html) do
    html |> source_form_nodes("#cue-source-choice") |> LazyHTML.text() |> String.trim()
  end

  defp reveal_text(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  end

  defp section_text(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  end

  defp cues_assigns(view), do: :sys.get_state(view.pid).socket.assigns.cues

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp alert_with(html, text) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([role="alert"]))
    |> Enum.find(&(LazyHTML.text(&1) =~ text))
  end

  defp put_cues(cues) do
    snapshot = ConfigStore.current_snapshot()
    core = Keyword.put(snapshot.fermix_core, :cues, cues)
    :ok = ConfigStore.save_snapshot(%{snapshot | fermix_core: core})
    :ok = ConfigStore.apply_snapshot(%{snapshot | fermix_core: core})
  end

  defp persisted(key) do
    {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)
    Keyword.get(snapshot.fermix_core, key, [])
  end

  defp persisted_cues, do: persisted(:cues)

  defp persisted_source(ref) do
    persisted_cues() |> Keyword.fetch!(:sources) |> Map.fetch!(ref)
  end

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
