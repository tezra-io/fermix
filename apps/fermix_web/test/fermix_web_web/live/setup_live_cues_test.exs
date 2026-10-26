defmodule FermixWebWeb.SetupLiveCuesTest do
  # The setup page's Cues tab (M60 §15, lane G). Every save goes through the
  # config store under a temp FERMIX_HOME and every secret through the stub;
  # the watcher and source rows come from a private temp Repo.
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Cues.Door
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Webhook
  alias FermixCore.Management.Cues.SourceForm
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
  alias FermixWebWeb.SetupLive.CuesState

  @now ~U[2026-10-17 12:00:00Z]
  @cue_text "Invented outside text 7781 that must stay off the owner page"
  @drop_reason "Invented filter reason 4410"

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
    Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end)

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
    test "is absent from a build that does not admit cues, and sits before Doctor when it does" do
      base = [%{id: "memory"}, %{id: "personalization"}, %{id: "doctor"}]

      assert CuesState.visible_tabs(base, false) == base

      assert Enum.map(CuesState.visible_tabs(base, true), & &1.id) ==
               ["memory", "personalization", "cues", "doctor"]
    end

    test "renders the switches, the door, the filter model and the chat-made watchers", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      html = open_cues(view)

      assert html =~ "Run cues"
      assert html =~ "Let mandates act"
      assert html =~ "Door port"
      assert html =~ "Not running"
      assert html =~ "Filter model"
      refute html =~ "never falls back to your main model"
      assert html =~ "Watchers are made and changed in chat with Fermix"
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
  end

  describe "switches" do
    test "turning cues on saves, round-trips and asks for a restart", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      html =
        view
        |> form("#cues-switches-form",
          cues_switches: %{enabled: "true", mandates_enabled: "true", door_port: "4040"}
        )
        |> render_submit()

      assert html =~ "Cues saved. Restart to apply."
      assert html =~ "Apply &amp; restart"

      cues = persisted_cues()
      assert Keyword.get(cues, :enabled) == true
      assert Keyword.get(cues, :door_port) == 4040
      # On is the default, so a save that leaves it on writes nothing for it.
      refute Keyword.has_key?(cues, :mandates_enabled)
    end

    test "the mandates switch alone applies live", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      html =
        view
        |> form("#cues-switches-form",
          cues_switches: %{enabled: "false", mandates_enabled: "false", door_port: "4032"}
        )
        |> render_submit()

      assert html =~ "Cues saved."
      refute html =~ "Restart to apply"
      refute html =~ "Apply &amp; restart"
      assert Keyword.get(persisted_cues(), :mandates_enabled) == false
    end

    test "a refused door port names the key and writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      html =
        view
        |> form("#cues-switches-form",
          cues_switches: %{enabled: "true", mandates_enabled: "true", door_port: "80"}
        )
        |> render_submit()

      assert html =~ "Save failed:"
      assert html =~ "door_port"
      assert persisted_cues() == []
    end

    test "a running door shows where it listens", %{conn: conn} do
      name = :"setup_cues_door_#{System.unique_integer([:positive])}"
      start_supervised!({Door, port: 0, name: name, schedule: fn _message, _ms -> :ok end})
      {:listening, {_ip, port}} = Door.status(name)
      Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end, door: name)

      {:ok, view, _html} = live(conn, "/setup")

      assert open_cues(view) =~ "Listening on 127.0.0.1:#{port}"
    end
  end

  describe "default filter model" do
    test "offers the main model first and only the providers that are set up", %{conn: conn} do
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
      refute html =~ ~s(name="cues_filter[model]")

      html =
        view
        |> form("#cues-filter-form", cues_filter: %{provider: "openai"})
        |> render_change()

      assert html =~ ~s(name="cues_filter[model]")
    end

    test "saves the provider and model and clears them", %{conn: conn} do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "invented-key-2207"])
      model = hd(ModelCatalog.models_for(:openai)).id
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      view
      |> form("#cues-filter-form", cues_filter: %{provider: "openai"})
      |> render_change()

      html =
        view
        |> form("#cues-filter-form", cues_filter: %{provider: "openai", model: model})
        |> render_submit()

      assert html =~ "Filter model saved."
      assert %{provider: :openai, model: ^model} = RoutingOverrides.filter()
      routing = persisted(:routing)
      assert Keyword.get(routing, :filter_provider) == "openai"
      assert Keyword.get(routing, :filter_model) == model

      # Choosing the main model takes the model box away, so the save posts no model.
      html =
        view
        |> form("#cues-filter-form", cues_filter: %{provider: ""})
        |> render_change()

      refute html =~ ~s(name="cues_filter[model]")

      html =
        view
        |> form("#cues-filter-form", cues_filter: %{provider: ""})
        |> render_submit()

      assert html =~ "Filter model set to the main model."
      assert %{provider: nil, model: nil} = RoutingOverrides.filter()
      routing = persisted(:routing)
      refute Keyword.has_key?(routing, :filter_provider)
      refute Keyword.has_key?(routing, :filter_model)
    end

    test "a model without a provider is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      # The page draws no model box for the main model; the save refuses the
      # pair on its own all the same.
      html =
        view
        |> element("#cues-filter-form")
        |> render_submit(%{cues_filter: %{provider: "", model: "some-model"}})

      assert html =~ "Pick a provider and a model, or clear both."
      assert persisted(:routing) == []
    end
  end

  describe "sources" do
    test "the form opens on Feed, says where each kind's items come from, and offers that kind's presets by name",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      html = view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

      # Each kind opens on its first preset, as the Mac sheet does; No preset
      # stays in the menu.
      assert selected(html, "cue_source[kind]") == "feed"
      assert selected(html, "cue_source[preset]") == "rss"
      assert kind_line(html) =~ "Fermix checks the feed's URL for new items on a schedule."
      assert preset_options(html) == [{"", "No preset"}, {"rss", "RSS, Atom or JSON Feed"}]
      assert html =~ ~s(name="cue_source[url]")

      html = view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()

      assert kind_line(html) =~
               "A service sends items to Fermix. Saving makes its URL. Give the service that URL and the secret you enter here."

      assert preset_options(html) == [{"", "No preset"}, {"github", "GitHub"}]
      assert selected(html, "cue_source[preset]") == "github"
      refute html =~ ~s(name="cue_source[url]")
      # GitHub fills the method and its headers, so none of them is drawn open.
      refute open_field?(html, "header")
      refute open_field?(html, "id_header")

      html =
        view |> form("#cue-source-form", cue_source: %{kind: "local_push"}) |> render_change()

      assert kind_line(html) =~
               "Your own scripts on this machine send items to Fermix. Saving makes a token, shown once."

      assert preset_options(html) == []

      # A preset stays with its kind: choosing another kind brings that kind's.
      view |> form("#cue-source-form", cue_source: %{kind: "feed"}) |> render_change()
      view |> form("#cue-source-form", cue_source: %{preset: ""}) |> render_change()
      html = view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()
      assert selected(html, "cue_source[preset]") == "github"

      # A stream has no preset to offer.
      html = view |> form("#cue-source-form", cue_source: %{kind: "stream"}) |> render_change()
      assert preset_options(html) == []

      assert kind_line(html) =~
               "Fermix keeps a connection open to a WebSocket (wss://) address and takes items " <>
                 "as they arrive."
    end

    # A stream is the general WebSocket source: its own fields and two typed
    # secrets.
    test "a stream draws the general source's fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      html = view |> form("#cue-source-form", cue_source: %{kind: "stream"}) |> render_change()

      for name <- ~w(url key_header secret_header auth_message subscribe_message id_path type_path
                     item_types error_types key secret),
          do: assert(open_field?(html, name), name)

      refute open_field?(html, "dids")
      refute open_field?(html, "collections")
      assert required_field?(html, "id_path")

      # The management form's words, its literals' backticks dropped.
      info = Enum.find(SourceForm.general_stream_rows(), &(&1.field == :key_header)).info

      assert html =~
               info
               |> String.replace("`", "")
               |> Phoenix.HTML.html_escape()
               |> Phoenix.HTML.safe_to_string()

      assert source_form_nodes(html, ~s(input[name="cue_source[items_path]"])) |> Enum.any?()

      # Each empty field shows the management form's example, and the API key
      # and secret come straight after the address, by the names the app gives
      # them, ahead of the fields that name their headers.
      for row <- SourceForm.general_stream_rows() do
        placeholder =
          html
          |> source_form_nodes(~s(input[name="cue_source[#{row.field}]"]))
          |> LazyHTML.attribute("placeholder")

        assert placeholder == [row.example], "#{row.field}"
      end

      names =
        html
        |> source_form_nodes("input[name^=cue_source]")
        |> LazyHTML.attribute("name")
        |> Enum.filter(&(&1 in ~w(cue_source[url] cue_source[key] cue_source[secret]
                                    cue_source[key_header])))

      assert names ==
               ~w(cue_source[url] cue_source[key] cue_source[secret] cue_source[key_header])

      assert html =~ "API key"
      assert html =~ "Paste the API secret"
    end

    test "a stream with no preset saves its fields and its typed key and secret", %{conn: conn} do
      key = "PK3W9QZ7RT"
      secret = "invented-secret-8840"
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "stream"}) |> render_change()

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

    test "the form as it opens saves with a name and a URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

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

    test "a field the kind needs and no preset fills is marked, and its absence is refused in the editor",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      html = view |> form("#cue-source-form", cue_source: %{preset: ""}) |> render_change()

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

      # The mark goes with its condition: RSS fills the interval.
      html = view |> form("#cue-source-form", cue_source: %{preset: "rss"}) |> render_change()

      assert field_refusal(html, "interval") == nil
      refute html |> source_form_nodes(~s([aria-invalid="true"])) |> Enum.any?()
    end

    test "a method's and a stream's own needs are marked and refused under their field", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)

      # A webhook checked by HMAC names its signature header.
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()
      html = view |> form("#cue-source-form", cue_source: %{preset: ""}) |> render_change()
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
               "Give a delivery id header, or turn on No delivery id."

      assert field_refusal(html, "header") == nil
      assert persisted_cues() == []

      # Turning on No delivery id answers it.
      html = view |> form("#cue-source-form", cue_source: %{id: "true"}) |> render_change()
      assert field_refusal(html, "id_header") == nil

      # A stream names where each message keeps its id.
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      html = view |> form("#cue-source-form", cue_source: %{kind: "stream"}) |> render_change()
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

    test "editing a source says where its items come from, not what a new one makes", %{
      conn: conn
    } do
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

      assert kind_line(html) =~ "Your own scripts on this machine send items to Fermix."
      refute kind_line(html) =~ "Saving makes"

      html =
        view
        |> element(~s(button[phx-click="cues_edit_source"][phx-value-ref="repo-events"]))
        |> render_click()

      assert fixed_choice(html) =~ "Webhook"
      assert fixed_choice(html) =~ "GitHub"
      assert kind_line(html) =~ "A service sends items to Fermix."
      refute kind_line(html) =~ "Saving makes"
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

    test "a local-push source gets a token shown once, stored through the writer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "home-alerts", preset: "", kind: "local_push", enabled: "true"}
        )
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

      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

      token =
        view
        |> form("#cue-source-form", cue_source: %{ref: "home-alerts", kind: "local_push"})
        |> render_submit()

      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()

      url =
        view
        |> form("#cue-source-form", cue_source: %{ref: "deploy-hooks", secret: "invented-4471"})
        |> render_submit()

      for html <- [token, url] do
        page = LazyHTML.from_fragment(html)
        assert page |> LazyHTML.query("#cues-sources #cues-reveal") |> Enum.any?()
        # Brought into view: its heading takes focus as it appears.
        heading = LazyHTML.query(page, ~s(#cues-reveal h3[tabindex="-1"][phx-mounted]))
        assert Enum.any?(heading)
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

    test "a feed source is added, edited and removed through the config store", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

      view
      |> form("#cue-source-form", cue_source: %{ref: "eng-blogs", preset: "rss"})
      |> render_change()

      view
      |> form("#cue-source-form",
        cue_source: %{
          ref: "eng-blogs",
          preset: "rss",
          enabled: "true",
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
      # The preset's interval stays the preset's.
      refute Keyword.has_key?(section, :interval)

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

    test "a refused source shows the config's sentence and writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

      view
      |> form("#cue-source-form", cue_source: %{ref: "plain-feed", preset: "", kind: "feed"})
      |> render_change()

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{
            ref: "plain-feed",
            preset: "",
            kind: "feed",
            enabled: "true",
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

    test "a webhook source's signing secret is written through the writer and never shown", %{
      conn: conn
    } do
      signing = "invented-signing-secret-5531"
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()

      view
      |> form("#cue-source-form", cue_source: %{ref: "repo-events", preset: "github"})
      |> render_change()

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "repo-events", preset: "github", enabled: "true", secret: signing}
        )
        |> render_submit()

      assert html =~ "Source repo-events saved."
      refute html =~ signing

      assert {:ok, ^signing} =
               SecretWriter.get({:cue_source, "repo-events", :secret}, store: :keyring)

      assert Keyword.get(persisted_source("repo-events"), :secret) == "@keyring"

      {:ok, _view, fresh} = live(conn, "/setup?tab=cues")
      refute fresh =~ signing
      assert fresh =~ ~s(id="cue-source-repo-events")
      refute fresh =~ "Needs a signing secret"
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

      assert view |> element("#cue-source-repo-events") |> render() =~ "Needs a signing secret"
      assert view |> element("#cue-source-home-alerts") |> render() =~ "Needs a token"
      refute view |> element("#cue-source-desk-alerts") |> render() =~ "Needs a token"
    end

    test "a new webhook source shows its URL as soon as it is saved, and an edit does not", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "deploy-hooks", secret: "invented-signing-4417"}
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
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()
      html = view |> form("#cue-source-form", cue_source: %{preset: ""}) |> render_change()
      assert html =~ "Paste the secret"
      refute html =~ "Paste the secret the service signs with"

      # Before Verification is touched: HMAC is chosen, and the fields it
      # needs, which no preset fills, are drawn open, not under More options.
      assert selected(html, "cue_source[verify]") == "hmac"

      for name <- ~w(header id_header id) do
        assert open_field?(html, name), "#{name} is drawn outside More options"
      end

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

      # A preset brings its own method, as the Mac sheet does, and folds what
      # it fills.
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()
      view |> form("#cue-source-form", cue_source: %{preset: ""}) |> render_change()
      html = view |> form("#cue-source-form", cue_source: %{preset: "github"}) |> render_change()

      assert selected(html, "cue_source[verify]") == ""
      refute open_field?(html, "header")
    end

    test "a new webhook whose URL cannot be made stays saved, and the page says so", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()

      # No secret is typed, so the save writes none; the URL's random part is
      # the first write the locked store refuses.
      SecretWriterStub.set_verdict(%{store: :keyring, state: :locked, sentence: "locked"})
      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "deploy-hooks"}
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
      assert Keyword.get(section, :preset) == "github"
      refute Keyword.has_key?(section, :path_secret)
    end

    test "a new webhook whose URL meets an outside change says how to recover, with the banner",
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

      Application.put_env(:fermix_web, :cues_pane_opts,
        now: fn -> @now end,
        webhook_opts: [persist: persist]
      )

      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()
      view |> form("#cue-source-form", cue_source: %{kind: "webhook"}) |> render_change()

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "deploy-hooks"}
        )
        |> render_submit()

      assert alert_with(html, "Source deploy-hooks saved, but its URL could not be made.")

      reveal =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#cues-reveal") |> LazyHTML.text()

      assert reveal =~ "The settings file changed outside Fermix."
      assert reveal =~ "Reload settings from disk, then save again."
      refute reveal =~ "external_change"
      assert html =~ ~s(phx-click="reload_settings")

      section = persisted_source("deploy-hooks")
      assert Keyword.get(section, :preset) == "github"
      refute Keyword.has_key?(section, :path_secret)
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

    test "a secret the store refuses leaves the config as it was", %{conn: conn} do
      SecretWriterStub.set_verdict(%{store: :keyring, state: :locked, sentence: "locked"})
      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      {:ok, view, _html} = live(conn, "/setup")
      open_cues(view)
      view |> element(~s(button[phx-click="cues_new_source"])) |> render_click()

      html =
        view
        |> form("#cue-source-form",
          cue_source: %{ref: "home-alerts", preset: "", kind: "local_push", enabled: "true"}
        )
        |> render_submit()

      assert html =~ "Save failed: The token for home-alerts could not be stored"
      assert persisted_cues() == []
    end

    test "a source's live status comes from its row", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_sources")
      Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end, repo: repo)
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

    test "a source row shows its last item as a short time in the owner's zone", %{conn: conn} do
      %{repo: repo, conn: db} = CueFixtures.start_repo("setup_source_times")
      Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end, repo: repo)
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
      Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end, repo: repo)

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
      Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end, repo: repo)
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
      assert html =~ "Needs words to listen for: update it in chat."
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

      Application.put_env(:fermix_web, :cues_pane_opts,
        now: fn -> @now end,
        repo: repo,
        mandate_opts: [plugin_tool: &acme_tool/1, get_job: &cue_job/1]
      )

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

      Application.put_env(:fermix_web, :cues_pane_opts,
        now: fn -> @now end,
        repo: repo,
        mandate_opts: seams
      )

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

  defp persisted_mandate(name) do
    persisted_cues() |> Keyword.fetch!(:mandates) |> Map.fetch!(name)
  end

  defp open_cues(view) do
    view |> element(~s(button[phx-value-tab="cues"])) |> render_click()
  end

  # The preset menu as {value, label} pairs, and a select's selected value.
  defp preset_options(html) do
    html
    |> source_form_nodes(~s(select[name="cue_source[preset]"] option))
    |> Enum.map(&{option_value(&1), String.trim(LazyHTML.text(&1))})
  end

  defp selected(html, name) do
    html
    |> source_form_nodes(~s(select[name="#{name}"] option[selected]))
    |> Enum.map(&option_value/1)
    |> List.first()
  end

  defp kind_line(html) do
    html |> source_form_nodes("#cue-source-kind-line") |> LazyHTML.text() |> String.trim()
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
    html |> source_form_nodes(selector) |> LazyHTML.text() |> String.trim()
  end

  defp fixed_choice(html) do
    html |> source_form_nodes("#cue-source-choice") |> LazyHTML.text() |> String.trim()
  end

  # A source form field drawn in the form's main grid, not folded under More options.
  defp open_field?(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#cue-source-form > div [name="cue_source[#{name}]"]))
    |> Enum.any?()
  end

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
