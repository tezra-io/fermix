defmodule FermixWebWeb.SetupLiveTest do
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Fermix.CLI.Upgrade.Manifest
  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Dist.Installer, as: DistInstaller
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Plugins.Status, as: PluginStatus
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.DistFetcherStub
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.DistVerifierStub
  alias FermixWebWeb.SetupLive.Components

  # Hermetic Anthropic backend stub — writes the auth store (tmp FERMIX_HOME) but
  # never touches the real keychain / ~/.claude. Injected via :anthropic_login_impl.
  defmodule AnthropicLoginStub do
    alias FermixCore.Auth.Store
    alias FermixCore.Capabilities.MCP.RuntimeStatus
    alias FermixCore.Plugins.CanonicalJson

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

  # The transport module double `Remote.Session` exposes: canned responses in
  # order. No socket, no TLS chain, no DNS answer.
  defmodule FakeRemoteTransport do
    def open(endpoint, opts),
      do: {:ok, %{agent: Keyword.fetch!(opts, :agent), endpoint: endpoint}}

    def request(conn, _method, _headers, _body, _timeout_ms) do
      conn.agent
      |> Agent.get_and_update(fn state ->
        case state do
          [next | rest] -> {next, rest}
          [] -> {{:error, :no_canned_response}, []}
        end
      end)
      |> case do
        {:ok, response} -> {:ok, conn, response}
        {:error, reason} -> {:error, conn, reason}
      end
    end

    def close(_conn), do: :ok
  end

  # Stands in for the source-qualified MCP supervisor: the reconnect is only
  # proven when the replacement generation reaches :ready.
  defmodule ReadySupervisor do
    alias FermixCore.Capabilities.MCP.RuntimeStatus

    def stop_server(_source_id), do: :ok

    def restart_server(source_id, _spec) do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, generation} = RuntimeStatus.register_owner(RuntimeStatus, source_id, owner)
      :ok = RuntimeStatus.put(RuntimeStatus, source_id, generation, :ready, nil)
      {:ok, owner}
    end
  end

  # The replacement client comes up but lands on a terminal status instead of
  # `:ready` — the shape of a real contract mismatch or a rejected credential.
  defmodule MismatchSupervisor do
    alias FermixCore.Capabilities.MCP.RuntimeStatus

    def stop_server(_source_id), do: :ok

    def restart_server(source_id, _spec) do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, generation} = RuntimeStatus.register_owner(RuntimeStatus, source_id, owner)

      :ok =
        RuntimeStatus.put(
          RuntimeStatus,
          source_id,
          generation,
          :upstream_contract_mismatch,
          :descriptor_changed
        )

      {:ok, owner}
    end
  end

  setup %{conn: conn} do
    providers = Application.fetch_env(:fermix_core, :providers)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    secret_writer = Application.get_env(:fermix_core, :secret_writer)
    tools = Application.get_env(:fermix_core, :tools, [])
    transcription = Application.get_env(:fermix_core, :transcription, [])
    plugins = Application.get_env(:fermix_core, :plugins, [])
    computer_history = Application.get_env(:fermix_core, :computer_history)
    plugins_dist_opts = Application.get_env(:fermix_core, :plugins_dist_opts)
    oauth = Application.get_env(:fermix_core, :oauth, %{})
    plugin_auth_runner = Application.get_env(:fermix_web, :plugin_auth_runner)
    plugin_auth_url_timeout_ms = Application.get_env(:fermix_web, :plugin_auth_url_timeout_ms)
    codex_login_runner = Application.get_env(:fermix_web, :codex_login_runner)
    xai_login_runner = Application.get_env(:fermix_web, :xai_login_runner)
    anthropic_login_impl = Application.get_env(:fermix_web, :anthropic_login_impl)
    doctor_probe_opts = Application.get_env(:fermix_web, :doctor_probe_opts)
    computer_use_grant_impl = Application.get_env(:fermix_web, :computer_use_grant_impl)
    harness_detector = Application.get_env(:fermix_web, :harness_detector)
    harness = Application.get_env(:fermix_core, :harness, [])
    mobile = Application.fetch_env(:fermix_channels, :mobile)
    fermix_home = System.get_env("FERMIX_HOME")

    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live")
    System.put_env("FERMIX_HOME", tmp_home)
    FermixTestSupport.SecretWriterStub.reset()

    # Force readiness to :setup_required so commit_snapshot/1 skips
    # prompt-file seeding; these tests do not exercise the memory repo.
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
    Application.delete_env(:fermix_channels, :telegram)

    Application.put_env(:fermix_channels, :mobile,
      enabled: false,
      mode: :listener,
      port: 4031,
      bind: "0.0.0.0",
      advertise_mdns: true,
      streaming: "draft",
      max_media_bytes: 20_971_520,
      push: [enabled: false, environment: "production"]
    )

    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    Application.put_env(:fermix_core, :tools, [])
    # Deterministic transcription baseline so the card's default backend/model
    # are stable regardless of any leaked env.
    Application.put_env(:fermix_core, :transcription,
      backend: "openai",
      model: "gpt-4o-mini-transcribe",
      max_file_mb: 20
    )

    # Clean harness baseline (the card reads `approved`/`default_vendor` from the
    # app-env snapshot): a persisted "approved = true" applies to app env, so reset
    # it here regardless of any leaked env, mirroring the transcription baseline.
    Application.put_env(:fermix_core, :harness, [])
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :plugins_dist_opts, [])
    Application.put_env(:fermix_core, :oauth, %{})
    Application.delete_env(:fermix_web, :plugin_auth_runner)
    Application.delete_env(:fermix_web, :plugin_auth_url_timeout_ms)
    Application.delete_env(:fermix_web, :codex_login_runner)
    Application.delete_env(:fermix_web, :xai_login_runner)
    Application.delete_env(:fermix_web, :anthropic_login_impl)
    Application.delete_env(:fermix_web, :doctor_probe_opts)
    Application.delete_env(:fermix_web, :computer_use_grant_impl)
    # Hermetic harness detection: never spawn the real codex/claude `--version`
    # subprocesses at mount. Tests that exercise the card override this seam.
    Application.put_env(:fermix_web, :harness_detector, fn -> harness_detections(false, false) end)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      restore_env(:fermix_core, :secret_writer, secret_writer)
      Application.put_env(:fermix_core, :tools, tools)
      Application.put_env(:fermix_core, :transcription, transcription)
      Application.put_env(:fermix_core, :plugins, plugins)
      restore_env(:fermix_core, :computer_history, computer_history)
      restore_env(:fermix_core, :plugins_dist_opts, plugins_dist_opts)
      Application.put_env(:fermix_core, :oauth, oauth)
      restore_env(:fermix_web, :plugin_auth_runner, plugin_auth_runner)
      restore_env(:fermix_web, :plugin_auth_url_timeout_ms, plugin_auth_url_timeout_ms)
      restore_env(:fermix_web, :codex_login_runner, codex_login_runner)
      restore_env(:fermix_web, :xai_login_runner, xai_login_runner)
      restore_env(:fermix_web, :anthropic_login_impl, anthropic_login_impl)
      restore_env(:fermix_web, :doctor_probe_opts, doctor_probe_opts)
      restore_env(:fermix_web, :computer_use_grant_impl, computer_use_grant_impl)
      restore_env(:fermix_web, :harness_detector, harness_detector)
      Application.put_env(:fermix_core, :harness, harness)
      restore_env(:fermix_channels, :mobile, mobile)

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
      assert html =~ ~s(aria-label="Fermix")
      assert html =~ ConfigStore.path()
    end

    test "renders setup categories without a read-only tools step", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      for label <-
            [
              "Provider",
              "Realtime",
              "Channels",
              "Plugins",
              "Search",
              "Media",
              "Sandbox",
              "Coding Agents",
              "Memory",
              "Personalization",
              "Doctor"
            ] do
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
            {"media", "Image generation"},
            {"sandbox", "Sandbox policy"},
            {"coding", "Coding agents"},
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
      # Provider groups carry an info "i" linking to where to create the client.
      assert html =~ "How to get google OAuth credentials"
      refute html =~ "Available from the catalog"
      refute html =~ "Plugin catalog ships with Fermix"
      refute html =~ ~s(phx-click="catalog_refresh")
      refute html =~ "coming later"
      refute html =~ "data-plugin-auth-trigger"
      refute html =~ "Installed skills"
    end

    test "an api_key plugin card prompts for the credential and connects on submit", %{conn: conn} do
      checkout = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-apikey")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(checkout) end)
      File.mkdir_p!(Path.join(checkout, "discord"))

      File.write!(
        Path.join([checkout, "discord", "plugin.json"]),
        Jason.encode!(%{
          "schema_version" => 2,
          "name" => "discord",
          "display_name" => "Discord",
          "description" => "Discord api_key fixture",
          "category" => "communication",
          "version" => "1.0.0",
          "min_core_version" => "0.1.0",
          "plugin_api" => 2,
          "auth" => %{
            "type" => "api_key",
            "header" => "authorization",
            "scheme" => "Bot",
            "prompt" => "Discord token",
            "help_url" => "https://discord.com/developers/docs",
            "scopes" => []
          },
          "tools" => [],
          "skills" => []
        })
      )

      Application.put_env(:fermix_core, :plugins, enabled: ["discord"], dev_local: checkout)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      # An api_key plugin renders the keychained-secret form, not just enable/disable.
      assert html =~ ~s(data-plugin-name="discord")
      assert html =~ "Needs key"
      assert html =~ ~s(phx-submit="set_plugin_secret")
      assert html =~ ~s(name="plugin_secret_form[value]")
      assert html =~ "Discord token"

      # Submitting the secret keychains it (via the stub) and the plugin connects.
      view
      |> form(~s|#plugin-secret-form-discord|, %{
        "plugin_secret_form" => %{"value" => "xoxb-secret"}
      })
      |> render_submit()

      assert {:ok, "xoxb-secret"} = FermixTestSupport.SecretWriterStub.get(:discord_plugin_secret)
    end

    test "an installed computer-use sidecar card reflects the feature flag, not registry enablement",
         %{conn: conn} do
      checkout = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-cu")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(checkout) end)
      write_cu_dev_local(checkout)

      # The signed sidecar is installed (a registry plugin), but the feature lives
      # under [fermix_core.computer_use], never the [fermix_core.plugins] enabled
      # list. With no binary on disk ComputerUse.ready?/0 is false => "Needs setup".
      prev_cu = Application.get_env(:fermix_core, :computer_use)
      on_exit(fn -> restore_env(:fermix_core, :computer_use, prev_cu) end)
      Application.put_env(:fermix_core, :plugins, dev_local: checkout)
      Application.put_env(:fermix_core, :computer_use, enabled: true)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      card = view |> element(~s|section[data-feature-name="computer_use_sidecar"]|) |> render()

      assert card =~ "Disable"
      assert card =~ "Needs setup"
      # Pre-fix this read [fermix_core.plugins] and rendered the install-time
      # "Enable" with the status pill hidden (:not_configured).
      refute card =~ ~s(phx-click="plugin_enable")

      # Core owns the branding: "Computer Use" (not the manifest's "…Sidecar"),
      # with the bundled blue-monitor logo rather than a letter fallback.
      assert card =~ "Computer Use"
      refute card =~ "Sidecar"
      assert card =~ "data:image/svg+xml"
      # No inline description: the details ride the info-icon tooltip (data-tip) and
      # the icon links to the docs page. Asserted here because this card renders on
      # every platform (the computer-history card is macOS-gated).
      assert card =~ ~s(data-tip="Fermix sees your screen)
      assert card =~ "Operator-only, off by default."
      assert card =~ ~s(href="https://fermix.ai/docs/computer-use/")
    end

    test "the computer-use native-driver card shows the compux release version, not the catalog entry",
         %{conn: conn} do
      # The sidecar ships via the pinned compux release; the bundled catalog
      # still carries the pre-compux 0.1.0 entry, whose version must not leak
      # onto the card (name and logo are already core-owned the same way).
      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      card = view |> element(~s|section[data-feature-name="computer_use_sidecar"]|) |> render()

      compux_vsn = to_string(Application.spec(:compux, :vsn))
      assert card =~ "v" <> compux_vsn
      refute card =~ "v0.1.0"
    end

    # The Ready state requires an installed sidecar, and the installed-check
    # resolves through Compux.Binary.target/0 — impossible on hosts compux
    # ships no artifact for (e.g. the linux-aarch64 CI leg).
    case Compux.Binary.target() do
      {:ok, _target} ->
        :ok

      {:error, reason} ->
        @tag skip: "compux sidecar unsupported on this host: #{inspect(reason)}"
    end

    test "a ready computer-use sidecar card shows Ready without a registry health check",
         %{conn: conn} do
      checkout = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-cu-ready")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(checkout) end)
      write_cu_dev_local(checkout)
      write_cu_dev_local_binary(checkout)

      prev_cu = Application.get_env(:fermix_core, :computer_use)
      on_exit(fn -> restore_env(:fermix_core, :computer_use, prev_cu) end)
      Application.put_env(:fermix_core, :plugins, dev_local: checkout)
      Application.put_env(:fermix_core, :computer_use, enabled: true)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      card = view |> element(~s|section[data-feature-name="computer_use_sidecar"]|) |> render()

      assert card =~ "Ready"
      assert card =~ "Disable"
      # The config-gated sidecar's registry status is :not_configured, so the
      # generic Check button would flash "not ready"; it must not render.
      refute card =~ ~s(phx-click="plugin_check")
    end

    # The computer-history card renders only on macOS (its AXObserver capture does
    # not port). Compile the assertion in only there so Linux CI stays green.
    if :os.type() == {:unix, :darwin} do
      test "the computer-history native-driver card renders info tooltip + docs link + controls (§22.3)",
           %{conn: conn} do
        {:ok, view, _html} = live(conn, "/setup")
        view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

        card = view |> element(~s|section[data-feature-name="computer_history"]|) |> render()

        assert card =~ "Computer History"
        # No visible description paragraph: the privacy posture rides the info-icon
        # tooltip (data-tip) — anchored to the attribute so a regression back to a
        # visible <p> would fail — and the icon links to the docs page.
        assert card =~
                 ~r/data-tip="[^"]*passwords and secure fields are never captured[^"]*off-device/

        assert card =~ ~s(href="https://fermix.ai/docs/computer-history/")
        # The allowlist is no longer an inline text field — Enable opens the app
        # picker modal — and the Accessibility grant action is present.
        refute card =~ ~s(name="computer_history_apps")
        assert card =~ ~s(phx-click="open_computer_history_apps")
        assert card =~ ~s(phx-click="computer_history_grant")
      end
    end

    test "the app-picker modal lists installed apps by name, toggles a selection, and filters",
         %{conn: conn} do
      # Inject a fixed app list so the modal never scans the host (hermetic).
      Application.put_env(:fermix_web, :installed_apps_impl, fn ->
        [
          %{name: "Safari", bundle_id: "com.apple.Safari"},
          %{name: "Notes", bundle_id: "com.apple.Notes"}
        ]
      end)

      on_exit(fn -> Application.delete_env(:fermix_web, :installed_apps_impl) end)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      # The card's Enable/Edit-apps button dispatches this; drive it directly so the
      # modal flow runs on every platform, not only where the macOS card renders.
      modal = render_hook(view, "open_computer_history_apps", %{})

      assert modal =~ "Apps to record"
      # The search form intercepts Enter (phx-submit) so a native submit can't reload
      # the LiveView and wipe the transient picker selection.
      assert modal =~ ~s(phx-submit="computer_history_apps_filter")
      assert modal =~ "Safari"
      assert modal =~ "com.apple.Safari"
      assert modal =~ "Notes"
      # Nothing selected yet → Save is disabled, and saving is refused with guidance.
      assert modal =~ ~r/phx-click="save_computer_history_apps"[^>]*disabled/
      assert render_hook(view, "save_computer_history_apps", %{}) =~ "Pick at least one app"

      # Toggle Safari on → one selected.
      assert render_hook(view, "toggle_computer_history_app", %{"bundle" => "com.apple.Safari"}) =~
               "1 selected"

      # Filtering to a non-match shows the empty state but keeps the selection.
      filtered = render_hook(view, "computer_history_apps_filter", %{"q" => "zzz"})
      assert filtered =~ "No app matches your search."
      assert filtered =~ "1 selected"

      # Cancelling closes the modal.
      refute render_hook(view, "close_computer_history_picker", %{}) =~ "Apps to record"
    end

    # The core consent transaction: with the shared sidecar installed, saving the
    # picker writes the chosen apps AND flips enabled in one act. Needs a resolvable
    # sidecar target, so it is skipped on hosts compux ships no artifact for.
    case Compux.Binary.target() do
      {:ok, _target} ->
        :ok

      {:error, reason} ->
        @tag skip: "compux sidecar unsupported on this host: #{inspect(reason)}"
    end

    test "saving the picker with the sidecar installed enables Computer History with the chosen apps",
         %{conn: conn} do
      checkout = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-ch-enable")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(checkout) end)
      write_cu_dev_local(checkout)
      write_cu_dev_local_binary(checkout)

      prev_plugins = Application.get_env(:fermix_core, :plugins)
      on_exit(fn -> restore_env(:fermix_core, :plugins, prev_plugins) end)
      Application.put_env(:fermix_core, :plugins, dev_local: checkout)

      Application.put_env(:fermix_web, :installed_apps_impl, fn ->
        [%{name: "Safari", bundle_id: "com.apple.Safari"}]
      end)

      on_exit(fn -> Application.delete_env(:fermix_web, :installed_apps_impl) end)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()
      render_hook(view, "open_computer_history_apps", %{})
      render_hook(view, "toggle_computer_history_app", %{"bundle" => "com.apple.Safari"})
      saved = render_hook(view, "save_computer_history_apps", %{})

      # Modal closes and the flash confirms the enable path (not the install path).
      refute saved =~ "Apps to record"
      assert saved =~ "Computer History enabled — restart to apply."

      # The apps + enabled flag are persisted together.
      assert {:ok, persisted} = ConfigStore.load_runtime_config(resolve_secrets: false)
      ch = persisted[:fermix_core][:computer_history]
      assert ch[:enabled] == true
      assert "com.apple.Safari" in ch[:apps]
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

      assert html =~ "Save a Google OAuth client first"
      refute_receive {:unexpected_plugin_auth, _name}, 50
      plugins = Application.get_env(:fermix_core, :plugins, [])
      refute "google_calendar" in Keyword.get(plugins, :enabled, [])
    end

    test "saving Google OAuth requires a desktop secret before auth opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      view
      |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
      |> render_click()

      html =
        view
        |> form("#oauth-client-form-google",
          oauth_client_form: %{client_id: "123.apps.googleusercontent.com", redirect_port: "1455"}
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

      view
      |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
      |> render_click()

      html =
        view
        |> form("#oauth-client-form-google",
          oauth_client_form: %{
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
      |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
      |> render_click()

      view
      |> form("#oauth-client-form-google",
        oauth_client_form: %{
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
      |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
      |> render_click()

      view
      |> form("#oauth-client-form-google",
        oauth_client_form: %{
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

      # The link is dropped by a 20 ms expiry timer. Sleeping a fixed 60 ms
      # asserted that this host fired that timer AND re-rendered inside a 3x
      # margin — on a loaded CI runner it does not, and the refute failed with
      # the link still on screen. Poll the actual condition instead, bounded.
      assert render_until_missing(view, "https://auth.example/google_calendar"),
             "the expired sign-in link is still rendered"
    end

    test "the OAuth client modal stays closed until Connect, then opens on credentials", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      # The compact row replaces the always-visible client form; the form only
      # exists once the modal is opened.
      refute html =~ ~s(id="oauth-client-form-google")
      assert html =~ "Not set up — required to connect"

      modal_html =
        view
        |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
        |> render_click()

      assert modal_html =~ ~s(role="dialog")
      assert modal_html =~ "Connect Google"
      assert modal_html =~ ~s(id="oauth-client-form-google")
    end

    test "saving the OAuth client advances the modal to the sign-in confirmation step", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      view
      |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
      |> render_click()

      html =
        view
        |> form("#oauth-client-form-google",
          oauth_client_form: %{
            client_id: "123.apps.googleusercontent.com",
            client_secret: "desktop-secret",
            redirect_port: "1455"
          }
        )
        |> render_submit()

      # The modal stays open on its confirmation step and the plugin cards now
      # carry the popup pre-open trigger (client configured).
      assert html =~ "Google OAuth client saved."
      assert html =~ "Connect each Google integration"
      assert html =~ ~s(phx-click="close_oauth_modal")
      assert html =~ ~s(data-plugin-auth-trigger="true")
    end

    test "closing the OAuth client modal removes the credentials form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"plugins\"]") |> render_click()

      opened =
        view
        |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
        |> render_click()

      assert opened =~ ~s(id="oauth-client-form-google")

      closed = render_click(view, "close_oauth_modal", %{})
      refute closed =~ ~s(id="oauth-client-form-google")
    end

    test "doctor pane keeps read-only skill count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"doctor\"]") |> render_click()

      assert html =~ "Skill summary"
      assert html =~ "Operator trusted"
      assert html =~ "Guest scoped"
    end

    test "doctor pane surfaces a computer-use permission section", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"doctor\"]") |> render_click()

      assert html =~ "Computer use"
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

    test "ChatGPT OAuth badge warns 'Reconnect needed' when the stored token is stale", %{
      conn: conn
    } do
      Store.write(:openai_codex, %{
        auth_mode: "chatgpt",
        provider: "openai",
        tokens: %{access_token: "cx-at", refresh_token: "cx-rt"},
        expires_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        last_refresh: nil,
        status: "ready"
      })

      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openai_codex"})
        |> render_change()

      assert html =~ "Reconnect needed"
    end

    test "ChatGPT OAuth badge shows 'Connected' when the stored token is fresh", %{conn: conn} do
      Store.write(:openai_codex, %{
        auth_mode: "chatgpt",
        provider: "openai",
        tokens: %{access_token: "cx-at", refresh_token: "cx-rt"},
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        last_refresh: nil,
        status: "ready"
      })

      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openai_codex"})
        |> render_change()

      assert html =~ "Connected"
      refute html =~ "Reconnect needed"
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

    test "reasoning effort options follow the selected model (max only for gpt-5.6)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")

      older =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{provider: "openai", default_model: "gpt-5.5"}
        )
        |> render_change()

      assert older =~ ~s(value="xhigh")
      refute older =~ ~s(value="max")

      newer =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{provider: "openai", default_model: "gpt-5.6-sol"}
        )
        |> render_change()

      assert newer =~ ~s(value="max")
    end

    test "provider pane offers a Sub-agent model select that persists to routing", %{conn: conn} do
      routing = Application.get_env(:fermix_core, :routing, [])
      on_exit(fn -> Application.put_env(:fermix_core, :routing, routing) end)

      {:ok, view, _html} = live(conn, "/setup")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openai"})
        |> render_change()

      assert html =~ "Sub-agent model"
      assert html =~ "Same as main model"

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "openai",
          openai_api_key: "sk-x",
          subagent_model: "gpt-5.4-mini"
        }
      )
      |> render_submit()

      assert {:ok, persisted} = ConfigStore.load_runtime_config(resolve_secrets: false)
      routing_cfg = Keyword.get(persisted.fermix_core, :routing, [])
      assert Keyword.get(routing_cfg, :subagent_model) == "gpt-5.4-mini"
    end

    test "a sub-agent model not in the primary's catalog is not surfaced as current", %{
      conn: conn
    } do
      routing = Application.get_env(:fermix_core, :routing, [])
      on_exit(fn -> Application.put_env(:fermix_core, :routing, routing) end)
      # claude-haiku-4-5 is an Anthropic model; the primary pane (openai) doesn't list
      # it. Sub-agents run on the primary, so a stale cross-provider pin is NOT shown
      # as "(current)" — the select falls back to "Same as main" and self-heals on save.
      Application.put_env(:fermix_core, :routing, subagent_model: "claude-haiku-4-5")

      {:ok, view, _html} = live(conn, "/setup")

      html = render(view)
      refute html =~ "claude-haiku-4-5"
      assert html =~ "Same as main model"
    end

    test "the sub-agent model select appears only on the primary provider's pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      # The default pane is openai (the primary via agent.provider) -> select shown.
      assert render(view) =~ "Sub-agent model"

      # Switch to a non-primary provider pane -> the global select is hidden there.
      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "anthropic"})
        |> render_change()

      refute html =~ "Sub-agent model"
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

    test "selecting Firecrawl reveals only its key field and persists it", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view
      |> element("button[phx-value-tab=\"search\"]")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_search\"]", search_form: %{backend: "firecrawl"})
        |> render_change()

      assert html =~ "search_form[firecrawl_api_key]"
      refute html =~ "search_form[tavily_api_key]"
      refute html =~ "search_form[perplexity_api_key]"

      view
      |> form("form[phx-submit=\"save_search\"]",
        search_form: %{backend: "firecrawl", firecrawl_api_key: "fc-live-test"}
      )
      |> render_submit()

      web_search =
        :fermix_core
        |> Application.get_env(:tools, [])
        |> Keyword.get(:web_search, [])

      assert Keyword.get(web_search, :backend) == :firecrawl
      assert Keyword.get(web_search, :firecrawl_api_key) == "fc-live-test"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(backend = "firecrawl")
      assert contents =~ ~s(firecrawl_api_key = "@keyring")
    end

    # MILESTONE_31 §14.1: one key, two consumers. Reaching `place_search` must not
    # cost the operator their web backend — a field that renders only under the
    # Brave radio would make selecting Brave the price of entering the key.
    test "the Brave key is enterable without making Brave the web backend (M31 §14.1)", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"search\"]") |> render_click()

      assert html =~ "search_form[brave_api_key]"

      view
      |> form("form[phx-submit=\"save_search\"]",
        search_form: %{backend: "duckduckgo", brave_api_key: "brave-place-only"}
      )
      |> render_submit()

      web_search =
        :fermix_core
        |> Application.get_env(:tools, [])
        |> Keyword.get(:web_search, [])

      assert Keyword.get(web_search, :backend) == :duckduckgo
      assert Keyword.get(web_search, :brave_api_key) == "brave-place-only"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(backend = "duckduckgo")
      assert contents =~ ~s(brave_api_key = "@keyring")
    end

    test "the Brave key is labelled for both consumers (M31 §14.1)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"search\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_search\"]", search_form: %{backend: "brave"})
        |> render_change()

      assert html =~ "Brave Search API key (web and place search)"
      refute html =~ ">Brave API key<"
    end

    test "the place posture is stated whatever the web backend (M31 §13.4)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"search\"]") |> render_click()

      # DuckDuckGo is selected: place_search readiness and its posture are still
      # stated, because the Brave key does not require Brave as the web backend.
      assert html =~ "place_search"
      assert html =~ "metered separately"
      assert html =~ "transient"
      assert html =~ "https://api-dashboard.search.brave.com"
    end

    test "place readiness follows the saved Brave key", %{conn: conn} do
      Application.put_env(:fermix_core, :tools, web_search: [brave_api_key: "brave-secret"])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"search\"]") |> render_click()

      assert html =~ ~s(data-place-search="ready")
      refute html =~ "brave-secret"
    end

    test "place readiness reports the missing key", %{conn: conn} do
      Application.put_env(:fermix_core, :tools, web_search: [])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"search\"]") |> render_click()

      assert html =~ ~s(data-place-search="unconfigured")
    end
  end

  describe "Media form (M15)" do
    test "selecting Google reveals its key field and persists it", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      # OpenAI (default) shows its own key field — no Gemini key field.
      refute render(view) =~ "image_form[google_api_key]"

      # Selecting Google reveals only the Gemini key field.
      html =
        view
        |> form("form[phx-submit=\"save_image\"]", image_form: %{backend: "google"})
        |> render_change()

      assert html =~ "image_form[google_api_key]"

      view
      |> form("form[phx-submit=\"save_image\"]",
        image_form: %{
          backend: "google",
          model: "gemini-2.5-flash-image",
          google_api_key: "gm-live-test"
        }
      )
      |> render_submit()

      assert render(view) =~ "Media saved."

      generate_image =
        :fermix_core
        |> Application.get_env(:tools, [])
        |> Keyword.get(:generate_image, [])

      assert Keyword.get(generate_image, :backend) == "google"
      assert Keyword.get(generate_image, :model) == "gemini-2.5-flash-image"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.tools.generate_image]"
      assert contents =~ ~s(backend = "google")
      assert contents =~ ~s(google_api_key = "@keyring")
      refute contents =~ "gm-live-test"
    end

    test "selecting OpenAI shows its own key field and persists the backend", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_image\"]", image_form: %{backend: "openai"})
        |> render_change()

      refute html =~ "image_form[google_api_key]"
      assert html =~ "image_form[openai_api_key]"

      view
      |> form("form[phx-submit=\"save_image\"]",
        image_form: %{backend: "openai", model: "gpt-image-2"}
      )
      |> render_submit()

      generate_image =
        :fermix_core
        |> Application.get_env(:tools, [])
        |> Keyword.get(:generate_image, [])

      assert Keyword.get(generate_image, :backend) == "openai"
      assert Keyword.get(generate_image, :model) == "gpt-image-2"
      refute Keyword.has_key?(generate_image, :google_api_key)

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(backend = "openai")
      refute contents =~ "google_api_key"
    end

    test "the model field is a dropdown of the backend's supported models", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      # OpenAI (default): a real <select> carrying both curated entries.
      assert html =~ ~r{<select[^>]*name="image_form\[model\]"}
      assert html =~ "gpt-image-2"
      assert html =~ "gpt-image-1.5"

      # Switching backend swaps the options to that backend's model and drops
      # the OpenAI-only secondary tier.
      html =
        view
        |> form("form[phx-submit=\"save_image\"]", image_form: %{backend: "xai"})
        |> render_change()

      assert html =~ "grok-imagine-image-quality"
      refute html =~ "gpt-image-1.5"
    end

    test "shows an editable OpenAI key field, marked configured when the key is set", %{
      conn: conn
    } do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-live-openai"])

      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      # The field name IS the provider secret key, so saving folds it straight to
      # providers.openai.api_key — the same key OpenAI uses for chat.
      assert html =~ "image_form[openai_api_key]"
      assert html =~ "Already configured"
      # The secret itself never reaches the browser.
      refute html =~ "sk-live-openai"
    end

    test "shows an empty OpenAI key field when no key is set", %{conn: conn} do
      # The harness forces providers to [] — OpenAI has no key.
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      assert html =~ "image_form[openai_api_key]"
      refute html =~ "Already configured"
    end

    test "switching to xAI reveals its own editable key field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_image\"]", image_form: %{backend: "xai"})
        |> render_change()

      assert html =~ "image_form[xai_api_key]"
      refute html =~ "image_form[openai_api_key]"
    end

    test "saving an OpenAI key persists it to the provider block via the keyring sentinel", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_image\"]",
        image_form: %{
          backend: "openai",
          model: "gpt-image-2",
          openai_api_key: "sk-live-openai-key"
        }
      )
      |> render_submit()

      assert render(view) =~ "Media saved."

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.providers.openai]"
      assert contents =~ ~s(api_key = "@keyring")
      # The secret lands in the keyring (stub), never the config file.
      refute contents =~ "sk-live-openai-key"

      assert {:ok, "sk-live-openai-key"} =
               FermixTestSupport.SecretWriterStub.get(:openai_api_key)
    end

    test "saving an xAI key persists it to the xAI provider block", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      # Switch first so the model select carries the xAI option (it is validated
      # against the rendered options on submit).
      view
      |> form("form[phx-submit=\"save_image\"]", image_form: %{backend: "xai"})
      |> render_change()

      view
      |> form("form[phx-submit=\"save_image\"]",
        image_form: %{
          backend: "xai",
          model: "grok-imagine-image-quality",
          xai_api_key: "xai-live-key"
        }
      )
      |> render_submit()

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.providers.xai]"
      assert contents =~ ~s(api_key = "@keyring")
      # The key landed in the keyring (stub); OpenAI was never touched.
      refute contents =~ "[fermix_core.providers.openai]"
      refute contents =~ "xai-live-key"

      assert {:ok, "xai-live-key"} = FermixTestSupport.SecretWriterStub.get(:xai_api_key)
    end

    test "setting an image key never flips an already-configured primary", %{conn: conn} do
      # OpenAI is the established primary, carried by an explicit `primary = true`
      # flag (not the legacy agent.provider) — exactly what an image save must not flip.
      # Persisted to disk (with its keyring-backed secret) first, the way a prior setup
      # would leave it: the save's secret-retention guard then sees openai as a real,
      # already-configured provider rather than dropping an unbacked sentinel.
      :ok = FermixTestSupport.SecretWriterStub.put(:openai_api_key, "sk-primary-key")
      Application.put_env(:fermix_core, :providers, openai: [api_key: "@keyring", primary: true])
      Application.put_env(:fermix_core, :agent, name: "fermix")
      :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())

      {:ok, view, _html} = live(conn, "/setup")

      # Set an xAI image key from the Media tab.
      view |> element("button[phx-value-tab=\"media\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_image\"]", image_form: %{backend: "xai"})
      |> render_change()

      view
      |> form("form[phx-submit=\"save_image\"]",
        image_form: %{
          backend: "xai",
          model: "grok-imagine-image-quality",
          xai_api_key: "xai-live-key"
        }
      )
      |> render_submit()

      # OpenAI keeps its primary flag; xAI is configured but only a fallback.
      assert {:ok, persisted} = ConfigStore.load_runtime_config(resolve_secrets: false)
      providers = Keyword.get(persisted.fermix_core, :providers, [])
      assert Keyword.get(Keyword.get(providers, :openai, []), :primary) == true
      refute Keyword.get(Keyword.get(providers, :xai, []), :primary) == true
    end
  end

  describe "Transcription form (M21)" do
    test "every backend shows a key field; Deepgram's key persists as a sentinel", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"transcription\"]") |> render_click()

      # OpenAI (default) now shows its own key field (an override for the chat key),
      # under the shared `api_key` field name.
      assert html =~ "transcription_form[api_key]"
      assert html =~ "OpenAI API key"

      # Selecting Deepgram relabels the same key field.
      html =
        view
        |> form("form[phx-submit=\"save_transcription\"]",
          transcription_form: %{backend: "deepgram"}
        )
        |> render_change()

      assert html =~ "transcription_form[api_key]"
      assert html =~ "Deepgram API key"

      view
      |> form("form[phx-submit=\"save_transcription\"]",
        transcription_form: %{
          backend: "deepgram",
          model: "nova-3",
          api_key: "dg-live-test"
        }
      )
      |> render_submit()

      assert render(view) =~ "Transcription saved."

      transcription =
        :fermix_core
        |> Application.get_env(:transcription, [])
        |> then(&Keyword.take(&1, [:backend, :model, :deepgram_api_key]))

      assert Keyword.get(transcription, :backend) == "deepgram"
      assert Keyword.get(transcription, :model) == "nova-3"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.transcription]"
      assert contents =~ ~s(backend = "deepgram")
      # The key rode to the deepgram slot, secured to the keyring.
      assert contents =~ ~s(deepgram_api_key = "@keyring")
      # The plaintext key never reaches config.toml.
      refute contents =~ "dg-live-test"

      assert {:ok, "dg-live-test"} = FermixTestSupport.SecretWriterStub.get(:deepgram_api_key)
    end

    test "openai and xai each expose a transcription key field; xai stays modelless",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"transcription\"]") |> render_click()

      html =
        view
        |> form("form[phx-submit=\"save_transcription\"]", transcription_form: %{backend: "xai"})
        |> render_change()

      # SpaceXAI now takes its own key (the Grok OAuth token won't work for STT).
      assert html =~ "transcription_form[api_key]"
      assert html =~ "SpaceXAI API key"
      assert html =~ "OAuth won&#39;t work here"
      # xai is modelless — the model dropdown is hidden.
      refute html =~ ~r{<select[^>]*name="transcription_form\[model\]"}

      # OpenAI's field is optional — it can reuse the chat key.
      openai_html =
        view
        |> form("form[phx-submit=\"save_transcription\"]",
          transcription_form: %{backend: "openai"}
        )
        |> render_change()

      assert openai_html =~ "OpenAI API key"
      assert openai_html =~ "reuse your OpenAI chat key"
    end

    test "the SpaceXAI transcription key persists to its own slot", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      view |> element("button[phx-value-tab=\"transcription\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_transcription\"]",
        transcription_form: %{backend: "xai", api_key: "xai-live-test"}
      )
      |> render_submit()

      assert render(view) =~ "Transcription saved."

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(backend = "xai")
      assert contents =~ ~s(xai_api_key = "@keyring")
      refute contents =~ "xai-live-test"

      assert {:ok, "xai-live-test"} =
               FermixTestSupport.SecretWriterStub.get(:transcription_xai_api_key)
    end

    test "the model field is a dropdown that swaps options on backend change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("button[phx-value-tab=\"transcription\"]") |> render_click()

      # OpenAI (default): a real <select> carrying its curated entries.
      assert html =~ ~r{<select[^>]*name="transcription_form\[model\]"}
      assert html =~ "gpt-4o-mini-transcribe"
      assert html =~ "whisper-1"

      # Switching backend swaps the options to Deepgram's models and drops the
      # OpenAI-only entries.
      html =
        view
        |> form("form[phx-submit=\"save_transcription\"]",
          transcription_form: %{backend: "deepgram"}
        )
        |> render_change()

      assert html =~ "nova-3"
      refute html =~ "whisper-1"
    end
  end

  describe "Realtime form" do
    test "submitting persists voice companion settings", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")

      realtime_html =
        view
        |> element("button[phx-value-tab=\"realtime\"]")
        |> render_click()

      # The model, voice, and reasoning-effort dropdowns display their supported
      # values (model: mini at the top; voice: the curated list; effort: the
      # Realtime levels) — all sourced from the common Config lists.
      assert realtime_html =~ ~s(name="realtime_form[model]")
      assert realtime_html =~ ~s(name="realtime_form[voice]")
      assert realtime_html =~ ~s(name="realtime_form[reasoning_effort]")

      for value <-
            FermixCore.Realtime.Config.valid_models() ++
              FermixCore.Realtime.Config.valid_voices() ++
              FermixCore.Realtime.Config.valid_reasoning_efforts() do
        assert realtime_html =~ value
      end

      view
      |> form("form[phx-submit=\"save_realtime\"]",
        realtime_form: %{
          enabled: "true",
          model: "gpt-realtime-2.1-mini",
          reasoning_effort: "high",
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
      assert Keyword.get(realtime, :model) == "gpt-realtime-2.1-mini"
      assert Keyword.get(realtime, :reasoning_effort) == "high"
      assert Keyword.get(realtime, :voice) == "cedar"
      assert Keyword.get(realtime, :max_session_minutes) == 20
      assert Keyword.get(realtime, :max_estimated_cost_cents_per_session) == 125
      assert Keyword.get(realtime, :persist_transcripts) == true

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ ~s(model = "gpt-realtime-2.1-mini")
      assert contents =~ ~s(reasoning_effort = "high")
      assert contents =~ ~s(voice = "cedar")
      assert contents =~ "max_session_minutes = 20"
    end
  end

  describe "channel cards" do
    test "renders a selectable card per channel with status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=channels")

      for title <- ["Telegram", "WhatsApp", "Discord", "Slack", "Signal", "ACP"] do
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

    test "the acp channel renders a single enable toggle and saves it", %{conn: conn} do
      acp = Application.fetch_env(:fermix_channels, :acp)
      on_exit(fn -> restore_env(:fermix_channels, :acp, acp) end)
      Application.put_env(:fermix_channels, :acp, enabled: false)

      {:ok, view, _html} = live(conn, "/setup?tab=channels")

      html =
        view
        |> element(~s(button[phx-click="select_channel"][phx-value-channel="acp"]))
        |> render_click()

      assert html =~ ~s(name="channels_form[acp_enabled]")
      refute html =~ ~s(name="channels_form[telegram_bot_token]")

      html =
        view
        |> form("form[phx-submit=\"save_channels\"]", channels_form: %{acp_enabled: "true"})
        |> render_submit()

      assert html =~ "Channels saved."
      assert Keyword.get(Application.get_env(:fermix_channels, :acp, []), :enabled) == true
    end

    # The mobile channel ships feature-flagged with NO setup surface: hand-editing
    # `[fermix_channels.mobile] enabled = true` in config.toml is the only enable
    # path, so the Channels page must not offer the channel at all — including on
    # an install where the operator already hand-enabled it.
    test "the channels page offers no mobile tab and no mobile field", %{conn: conn} do
      Application.put_env(:fermix_channels, :mobile,
        enabled: true,
        mode: :listener,
        port: 4031,
        push: [
          enabled: true,
          team_id: "ABCDE12345",
          key_id: "KEY987",
          key: "private-key-must-not-render",
          topic: "io.tezra.fermix.app",
          environment: "production"
        ]
      )

      {:ok, view, html} = live(conn, "/setup?tab=channels")

      refute html =~ ~s(phx-value-channel="mobile")
      refute html =~ "Mobile (iOS)"
      refute html =~ "channels_form[mobile_"
      refute html =~ "APNs"
      refute html =~ "private-key-must-not-render"
      refute html =~ "fermix pair"

      # No selector click can reach it either — the tab simply does not exist.
      assert view
             |> element(~s(button[phx-click="select_channel"][phx-value-channel="mobile"]))
             |> has_element?() == false
    end

    test "mobile params injected into a save POST are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=channels")

      html =
        render_submit(view, "save_channels", %{
          "channels_form" => %{
            "telegram_owner_user_id" => "owner-1",
            "mobile_enabled" => "true",
            "mobile_port" => "4040",
            "mobile_push_enabled" => "true",
            "mobile_push_team_id" => "ABCDE12345",
            "mobile_push_key_id" => "KEY987",
            "mobile_push_key" => "private-key-must-not-persist",
            "mobile_push_topic" => "io.tezra.fermix.app",
            "mobile_push_environment" => "development"
          }
        })

      assert html =~ "Channels saved."

      mobile = Application.get_env(:fermix_channels, :mobile, [])
      assert Keyword.get(mobile, :enabled) == false
      assert Keyword.get(mobile, :port) == 4031

      contents = File.read!(ConfigStore.path())
      refute contents =~ "private-key-must-not-persist"
      refute contents =~ "ABCDE12345"
      refute contents =~ "io.tezra.fermix.app"
    end

    # Web setup round-trips the whole live config to disk on every save. A
    # section the form no longer owns is only safe if the pipeline preserves it —
    # otherwise saving Telegram would silently un-enable a hand-enabled channel.
    test "a hand-enabled mobile section survives a channels save", %{conn: conn} do
      Application.put_env(:fermix_channels, :mobile,
        enabled: true,
        mode: :listener,
        port: 4040,
        bind: "127.0.0.1",
        advertise_mdns: false,
        push: [
          enabled: true,
          team_id: "ABCDE12345",
          key_id: "KEY987",
          topic: "io.tezra.fermix.app",
          environment: "development"
        ]
      )

      {:ok, view, _html} = live(conn, "/setup?tab=channels")

      html =
        view
        |> form("form[phx-submit=\"save_channels\"]",
          channels_form: %{telegram_owner_user_id: "owner-1"}
        )
        |> render_submit()

      assert html =~ "Channels saved."

      assert {:ok, saved} = ConfigStore.load_runtime_config()
      mobile = Keyword.fetch!(saved.fermix_channels, :mobile)
      push = Keyword.fetch!(mobile, :push)

      assert Keyword.get(mobile, :enabled) == true
      assert Keyword.get(mobile, :port) == 4040
      assert Keyword.get(mobile, :bind) == "127.0.0.1"
      assert Keyword.get(mobile, :advertise_mdns) == false
      assert Keyword.get(push, :enabled) == true
      assert Keyword.get(push, :team_id) == "ABCDE12345"
      assert Keyword.get(push, :key_id) == "KEY987"
      assert Keyword.get(push, :topic) == "io.tezra.fermix.app"
      assert Keyword.get(push, :environment) == "development"
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
        anthropic: [api_key: "sk-ant", default_model: "claude-opus-4-8"]
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

      assert html =~ "Configuring Anthropic"
      assert html =~ ~s(name="provider_form[anthropic_api_key]")
    end

    test "an unconfigured provider can be selected to configure (nothing disabled)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "xai"})
        |> render_change()

      assert html =~ "Configuring SpaceXAI"
    end

    test "ollama pane shows a keyless base_url field and saves it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "ollama"})
        |> render_change()

      assert html =~ "Configuring Ollama"
      # Keyless: a base_url plain field, no secret input, no auth-mode picker.
      assert html =~ ~s(name="provider_form[ollama_base_url]")
      refute html =~ ~s(name="provider_form[ollama_api_key]")
      refute html =~ ~s(name="provider_form[auth_mode]")

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "ollama",
          ollama_base_url: "http://tail.example:11434/v1",
          default_model: "qwen3:32b"
        }
      )
      |> render_submit()

      {:ok, persisted} = ConfigStore.load_runtime_config()
      providers = Keyword.get(persisted.fermix_core, :providers, [])

      assert Keyword.get(providers[:ollama], :base_url) == "http://tail.example:11434/v1"
      assert Keyword.get(providers[:ollama], :default_model) == "qwen3:32b"
      # Editing a non-primary pane never steals primary (openai stays).
      assert Keyword.get(providers[:openai], :primary) == true
    end

    test "an in-place edit keeps the ollama base_url input populated", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      view
      |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "ollama"})
      |> render_change()

      # Type a base_url AND change another field in the same change event: the
      # in-place re-render must not blank out the base_url the user just typed.
      html =
        view
        |> form("form[phx-submit=\"save_provider\"]",
          provider_form: %{
            provider: "ollama",
            ollama_base_url: "http://tail.example:11434/v1",
            default_model: "gpt-oss:20b"
          }
        )
        |> render_change()

      assert html =~ ~s(value="http://tail.example:11434/v1")
    end

    test "openrouter pane saves its API key through the generic field plumbing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openrouter"})
        |> render_change()

      assert html =~ "Configuring OpenRouter"
      assert html =~ ~s(name="provider_form[openrouter_api_key]")

      view
      |> form("form[phx-submit=\"save_provider\"]",
        provider_form: %{
          provider: "openrouter",
          openrouter_api_key: "sk-or-live",
          default_model: "openai/gpt-5.5"
        }
      )
      |> render_submit()

      {:ok, persisted} = ConfigStore.load_runtime_config()
      providers = Keyword.get(persisted.fermix_core, :providers, [])

      assert Keyword.get(providers[:openrouter], :api_key) == "sk-or-live"
      assert Keyword.get(providers[:openrouter], :default_model) == "openai/gpt-5.5"
    end

    test "Model behavior panel is hidden for effort-less providers", %{conn: conn} do
      {:ok, view, html} = live(conn, "/setup?tab=provider")

      # openai (effort-capable) shows the panel…
      assert html =~ "Model behavior"

      # …openrouter and ollama (no effort, no fast) hide it entirely.
      for provider <- ["openrouter", "ollama"] do
        html =
          view
          |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: provider})
          |> render_change()

        refute html =~ "Model behavior"
        refute html =~ ~s(name="provider_form[reasoning_effort]")
      end
    end

    test "ollama pane lists only the installed models and shows the detected banner", %{
      conn: conn
    } do
      defmodule OllamaUpListing do
        def live?(:ollama), do: true
        def live?(_provider), do: false

        def live_models(:ollama, _opts) do
          {:ok,
           [
             %{id: "qwen3:32b", label: "qwen3:32b (32.8B)", context_window: 128_000},
             %{id: "tinyllama:1b", label: "tinyllama:1b", context_window: nil}
           ]}
        end
      end

      Application.put_env(:fermix_web, :model_listing_impl, OllamaUpListing)

      on_exit(fn ->
        Application.put_env(
          :fermix_web,
          :model_listing_impl,
          FermixWebWeb.TestSupport.StaticModelListing
        )
      end)

      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "ollama"})
        |> render_change()

      assert html =~ "Ollama server detected"
      assert html =~ "2 installed model(s)"
      assert html =~ "qwen3:32b (32.8B)"
      assert html =~ "tinyllama:1b"
      # Installed models only — no static catalog guesses.
      refute html =~ "gpt-oss:20b"
    end

    test "unreachable ollama server renders install/serve guidance and a manual input", %{
      conn: conn
    } do
      defmodule OllamaDownListing do
        def live?(:ollama), do: true
        def live?(_provider), do: false

        def live_models(:ollama, _opts),
          do: {:error, "connection refused at http://localhost:11434/api/tags"}
      end

      Application.put_env(:fermix_web, :model_listing_impl, OllamaDownListing)

      on_exit(fn ->
        Application.put_env(
          :fermix_web,
          :model_listing_impl,
          FermixWebWeb.TestSupport.StaticModelListing
        )
      end)

      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "ollama"})
        |> render_change()

      assert html =~ "No Ollama server responded"
      assert html =~ "ollama serve"
      assert html =~ "ollama.com"
      assert html =~ "connection refused"
      # Manual model input instead of a select of uninstalled guesses.
      assert html =~ ~s(type="text" name="provider_form[default_model]")
    end

    test "openrouter pane lists the live upstream catalog", %{conn: conn} do
      defmodule OpenRouterLiveListing do
        def live?(:openrouter), do: true
        def live?(_provider), do: false

        def live_models(:openrouter, _opts) do
          {:ok,
           [
             %{id: "vendor/brand-new", label: "Brand New", context_window: 2_000_000},
             %{
               id: "anthropic/claude-sonnet-4.6",
               label: "Claude Sonnet 4.6",
               context_window: 1_000_000
             }
           ]}
        end
      end

      Application.put_env(:fermix_web, :model_listing_impl, OpenRouterLiveListing)

      on_exit(fn ->
        Application.put_env(
          :fermix_web,
          :model_listing_impl,
          FermixWebWeb.TestSupport.StaticModelListing
        )
      end)

      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      html =
        view
        |> form("form[phx-submit=\"save_provider\"]", provider_form: %{provider: "openrouter"})
        |> render_change()

      assert html =~ "vendor/brand-new"
      assert html =~ "Brand New"
      # The static curated entries are replaced by the live catalog.
      refute html =~ "Kimi K2.6"
      # Searchable: a free-text model field backed by a <datalist> of live ids.
      assert html =~ ~s(name="provider_form[default_model]")
      assert html =~ "<datalist"
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

    test "Set primary resets the sub-agent model pin to same-as-main", %{conn: conn} do
      # A sub-agent model pinned while the old provider was primary (e.g. a Codex
      # model) must not linger on the new primary's pane.
      prior_routing = Application.get_env(:fermix_core, :routing)

      on_exit(fn ->
        if prior_routing,
          do: Application.put_env(:fermix_core, :routing, prior_routing),
          else: Application.delete_env(:fermix_core, :routing)
      end)

      Application.put_env(:fermix_core, :routing, subagent_model: "gpt-5.4-mini")
      :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())

      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      view
      |> element(~s(button[phx-click="set_primary"][phx-value-provider="anthropic"]))
      |> render_click()

      {:ok, persisted} = ConfigStore.load_runtime_config()
      routing = Keyword.get(persisted.fermix_core, :routing, [])
      refute Keyword.has_key?(routing, :subagent_model)

      providers = Keyword.get(persisted.fermix_core, :providers, [])
      assert Keyword.get(providers[:anthropic], :primary) == true
    end

    test "Set primary applies to configured OpenRouter (keyed) and Ollama (keyless) too", %{
      conn: conn
    } do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-openai", primary: true, default_model: "gpt-5.5"],
        openrouter: [api_key: "sk-or", default_model: "anthropic/claude-sonnet-4.6"],
        ollama: [base_url: "http://localhost:11434/v1", default_model: "llama3.1"]
      )

      :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())

      {:ok, view, _html} = live(conn, "/setup?tab=provider")

      # Both a keyed and a keyless configured fallback expose Set primary.
      assert has_element?(
               view,
               ~s(button[phx-click="set_primary"][phx-value-provider="openrouter"])
             )

      assert has_element?(view, ~s(button[phx-click="set_primary"][phx-value-provider="ollama"]))

      view
      |> element(~s(button[phx-click="set_primary"][phx-value-provider="ollama"]))
      |> render_click()

      {:ok, persisted} = ConfigStore.load_runtime_config()
      providers = Keyword.get(persisted.fermix_core, :providers, [])
      assert Keyword.get(providers[:ollama], :primary) == true
      refute Keyword.get(providers[:openai], :primary) == true
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

    test "the personalization pane no longer renders the harness card", %{conn: conn} do
      Application.put_env(:fermix_web, :harness_detector, fn -> harness_detections(true, true) end)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"personalization\"]") |> render_click()

      refute html =~ "Allow coding agents to run on this machine"
      refute html =~ ~s(name="personalization_form[harness_default_vendor]")
      refute html =~ ~s(name="coding_form[harness_approved]")
    end

    test "the skill-curation toggle renders checked by default and names the destination", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"personalization\"]") |> render_click()

      assert html =~ "Suggest new skills from tasks you repeat"
      assert html =~ ~s(name="personalization_form[skill_curation_enabled]")
      assert html =~ ~s(data-skill-curation="true")
      # No channel owner configured in the test home -> the honest fallback.
      assert html =~ "/skills proposals"
    end

    test "declining skill curation persists enabled=false; re-accepting deletes the key", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"personalization\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_personalization\"]",
        personalization_form: %{skill_curation_enabled: "false"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Personalization saved."
      # The Scheduler is a child-absent gate, so the change offers a restart.
      assert html =~ "Apply &amp; restart"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "[fermix_core.skill_curation]"
      assert contents =~ "enabled = false"

      # Re-accepting writes NOTHING — the default is already true.
      view
      |> form("form[phx-submit=\"save_personalization\"]",
        personalization_form: %{skill_curation_enabled: "true"}
      )
      |> render_submit()

      refute File.read!(Path.join(tmp_home, "config.toml")) =~ "[fermix_core.skill_curation]"
    end
  end

  describe "Coding Agents form" do
    test "coding pane renders detected vendor CLIs and their auth state", %{conn: conn} do
      Application.put_env(:fermix_web, :harness_detector, fn ->
        harness_detections(true, false)
      end)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      assert html =~ "Coding agents"
      assert html =~ "codex 1.0.0"
      assert html =~ "authenticated"
      assert html =~ "not installed"
      # The cloud rail is off this release — a static note, no cloud control.
      assert html =~ "Cloud runs (Codex cloud) are off in this release"
    end

    test "coding pane shows the CLI dropdown when both CLIs are detected", %{
      conn: conn
    } do
      Application.put_env(:fermix_web, :harness_detector, fn -> harness_detections(true, true) end)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      assert html =~ ~s(name="coding_form[harness_default_vendor]")
    end

    test "coding pane still shows the CLI dropdown with a single detected CLI", %{
      conn: conn
    } do
      Application.put_env(:fermix_web, :harness_detector, fn ->
        harness_detections(true, false)
      end)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      # The dropdown doubles as the vendor/auth status display, so it renders
      # whenever any CLI is installed; the uninstalled vendor is a disabled option.
      assert html =~ ~s(name="coding_form[harness_default_vendor]")
      assert html =~ "not installed"
    end

    test "coding pane disables the consent toggle and prompts to install when no CLI is detected",
         %{conn: conn} do
      Application.put_env(:fermix_web, :harness_detector, fn ->
        harness_detections(false, false)
      end)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      refute html =~ ~s(name="coding_form[harness_default_vendor]")
      refute html =~ ~s(name="coding_form[harness_approved]")
      assert html =~ "No coding CLI detected"
      assert html =~ "disabled"
    end

    test "selecting a harness default vendor persists it to config", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      Application.put_env(:fermix_web, :harness_detector, fn -> harness_detections(true, true) end)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_coding\"]",
        coding_form: %{harness_default_vendor: "codex"}
      )
      |> render_submit()

      assert render(view) =~ "Coding agents saved."

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "default_vendor"
      assert contents =~ "codex"
    end

    test "coding pane renders the first-use consent toggle and status", %{conn: conn} do
      Application.put_env(:fermix_web, :harness_detector, fn ->
        harness_detections(true, false)
      end)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      assert html =~ "Allow coding agents to run on this machine"
      assert html =~ ~s(name="coding_form[harness_approved]")
      assert html =~ "Off — approve before the first coding run."
    end

    test "toggling harness consent on persists approved=true to config", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      Application.put_env(:fermix_web, :harness_detector, fn ->
        harness_detections(true, false)
      end)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"coding\"]") |> render_click()

      view
      |> form("form[phx-submit=\"save_coding\"]",
        coding_form: %{harness_approved: "true"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Coding agents saved."
      # Consent gates whether the harness section renders in the (per-profile
      # cached) runtime prompt, so granting it offers the restart (design §23.4).
      assert html =~ "Apply &amp; restart"

      contents = File.read!(Path.join(tmp_home, "config.toml"))
      assert contents =~ "approved = true"
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

      # The provider and channel probes are INDEPENDENTLY async and land in either
      # order, so waiting on one and asserting the other is a race: on a loaded
      # runner the channel probe arrives first and the provider assertion fires
      # against a view that has not received it yet (observed on macos-arm64 CI,
      # green on the same commit in another run). Wait for each signal on its own —
      # the view's state is cumulative, so the last render carries both.
      render_until(view, "openai gpt-5.5 responded")
      html = render_until(view, "bot @fermix_test authenticated")

      assert html =~ "openai gpt-5.5 responded"
      assert html =~ "bot @fermix_test authenticated"
    end

    test "run probe reports stale stored auth tokens", %{conn: conn} do
      Req.Test.set_req_test_to_shared()
      stub_setup_doctor_probe()

      Store.write(:openai_codex, %{
        auth_mode: "chatgpt",
        provider: "openai",
        tokens: %{access_token: "cx-at", refresh_token: "cx-rt"},
        expires_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        last_refresh: nil,
        status: "ready"
      })

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-live-test", default_model: "gpt-5.5"]
      )

      Application.put_env(:fermix_web, :doctor_probe_opts,
        req_options: [plug: {Req.Test, :setup_doctor_probe}]
      )

      {:ok, view, _html} = live(conn, "/setup")
      view |> element("button[phx-value-tab=\"doctor\"]") |> render_click()

      html = view |> element("button", "Run probe") |> render_click()

      assert html =~ "Auth tokens"
      assert html =~ "Reconnect needed: openai_codex"
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

      assert error_html =~ "Save a Google OAuth client first"
      assert error_html =~ ~s(role="alert")
      assert error_html =~ "bg-error"
      assert error_html =~ "hero-x-circle"

      view
      |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="google"]|)
      |> render_click()

      ok_html =
        view
        |> form("#oauth-client-form-google",
          oauth_client_form: %{
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

  describe "plugin catalog" do
    setup %{tmp_home: tmp_home} do
      DistFetcherStub.init()
      DistVerifierStub.init()

      on_exit(fn ->
        DistFetcherStub.cleanup()
        DistVerifierStub.cleanup()
      end)

      %{fixtures: Path.join(tmp_home, "fixtures")}
    end

    test "renders available catalog plugins with branding and the static catalog line", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        fixtures
        |> wire_catalog_plugin("hackerdemo", "1.0.0")
        |> Map.merge(%{
          "description" => "Demo news reader from the catalog",
          "logo" => %{"mime" => "image/png", "data_base64" => Base.encode64("png-bytes")}
        })

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-catalog-name="hackerdemo")
      assert html =~ "Available"
      assert html =~ "Demo news reader from the catalog"
      assert html =~ "data:image/png;base64,#{Base.encode64("png-bytes")}"

      refute html =~ "Available from the catalog"
      refute html =~ "Plugin catalog ships with Fermix"
      refute html =~ ~s(phx-click="catalog_refresh")
      refute html =~ "coming later"
    end

    test "enable on a catalog plugin installs from the index then enables", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry = wire_catalog_plugin(fixtures, "hackerdemo", "1.0.0")
      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      html =
        view
        |> element(~s|button[phx-click="plugin_enable"][phx-value-name="hackerdemo"]|)
        |> render_click()

      assert html =~ "Installing hackerdemo"

      html = render_until(view, "Plugin enabled.")
      assert html =~ ~s(data-plugin-name="hackerdemo")
      refute html =~ ~s(data-catalog-name="hackerdemo")

      plugins = Application.get_env(:fermix_core, :plugins, [])
      assert "hackerdemo" in Keyword.get(plugins, :enabled, [])
    end

    test "a download failure surfaces per-stage prose", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry = wire_catalog_plugin(fixtures, "hackerdemo", "1.0.0")
      url = "https://example.com/hackerdemo-1.0.0.tar.gz"
      DistFetcherStub.set(url, {:error, {:download_failed, :nxdomain, url}})
      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="hackerdemo"]|)
      |> render_click()

      html = render_until(view, "download failed (network)")
      assert html =~ "hackerdemo install failed"
    end

    test "a checksum mismatch refuses the install and never enables", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        wire_catalog_plugin(fixtures, "hackerdemo", "1.0.0", index_sha: String.duplicate("f", 64))

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="hackerdemo"]|)
      |> render_click()

      html = render_until(view, "checksum mismatch")
      assert html =~ "refusing"
      # Still a catalog card, never an installed one; nothing enabled.
      assert html =~ ~s(data-catalog-name="hackerdemo")
      refute html =~ ~s(data-plugin-name="hackerdemo")
      plugins = Application.get_env(:fermix_core, :plugins, [])
      refute "hackerdemo" in Keyword.get(plugins, :enabled, [])
    end

    test "a missing cosign binary reports a cosign-specific message, not a bad signature", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry = wire_catalog_plugin(fixtures, "hackerdemo", "1.0.0")
      # Download + checksum pass; the verifier reports cosign is absent. This is an
      # environment problem, not an invalid signature — the prose must say so.
      DistVerifierStub.fail("hackerdemo", "1.0.0", :cosign_not_installed)
      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="hackerdemo"]|)
      |> render_click()

      html = render_until(view, "cosign not found")
      assert html =~ "hackerdemo install failed"
      refute html =~ "signature invalid"
      # Never enabled; still a catalog card.
      assert html =~ ~s(data-catalog-name="hackerdemo")
      plugins = Application.get_env(:fermix_core, :plugins, [])
      refute "hackerdemo" in Keyword.get(plugins, :enabled, [])
    end

    test "an incompatible catalog plugin renders greyed without an enable action", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        fixtures
        |> wire_catalog_plugin("needs_core", "1.0.0")
        |> put_in(["versions", Access.at(0), "min_core_version"], "9.9.9")

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-catalog-name="needs_core")
      assert html =~ "Incompatible"
      assert html =~ "needs Fermix"
      assert html =~ "9.9.9"

      refute has_element?(
               view,
               ~s|button[phx-click="plugin_enable"][phx-value-name="needs_core"]|
             )
    end

    test "installing a name missing from the catalog points at fermix upgrade", %{
      conn: conn,
      tmp_home: tmp_home
    } do
      seed_catalog(tmp_home, [])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      render_click(view, "plugin_enable", %{"name" => "ghost"})

      html = render_until(view, "ghost install failed")
      assert html =~ "not in the plugin catalog — run `fermix upgrade` to get the latest catalog."
    end

    test "an installed github-provider plugin renders a GitHub client form that persists", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      install_github_plugin(tmp_home, fixtures)

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-plugin-group="github")

      modal_html =
        view
        |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="github"]|)
        |> render_click()

      assert modal_html =~ ~s(id="oauth-client-form-github")
      # github default redirect port pre-fills the form.
      assert modal_html =~ ~s(value="1457")

      html =
        view
        |> form("#oauth-client-form-github",
          oauth_client_form: %{client_id: "Iv1.github-client", client_secret: "gh-secret"}
        )
        |> render_submit()

      assert html =~ "GitHub OAuth client saved."
      github = PluginConfig.oauth_provider("github")
      assert Keyword.get(github, :client_id) == "Iv1.github-client"
      assert Keyword.get(github, :client_secret) == "gh-secret"
    end

    test "a catalog-only github plugin renders a GitHub client form that persists", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        wire_catalog_plugin(fixtures, "github", "1.0.0",
          auth_type: "oauth2",
          auth_provider: "github"
        )

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      # Nothing installed: the provider group renders the client form plus the
      # plugin's Connect card together (the catalog card lives inside the group,
      # not split off into the bottom catalog list).
      assert html =~ ~s(data-plugin-group="github")
      assert html =~ ~s(data-catalog-name="github")
      refute html =~ ~s(data-plugin-name="github")
      refute html =~ "Used when connecting GitHub"

      modal_html =
        view
        |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="github"]|)
        |> render_click()

      assert modal_html =~ ~s(id="oauth-client-form-github")

      html =
        view
        |> form("#oauth-client-form-github",
          oauth_client_form: %{client_id: "Iv1.github-client", client_secret: "gh-secret"}
        )
        |> render_submit()

      assert html =~ "GitHub OAuth client saved."
      github = PluginConfig.oauth_provider("github")
      assert Keyword.get(github, :client_id) == "Iv1.github-client"
      assert Keyword.get(github, :client_secret) == "gh-secret"
    end

    test "an unconfigured github card routes Connect to the modal and still guards direct auth",
         %{
           conn: conn,
           tmp_home: tmp_home,
           fixtures: fixtures
         } do
      parent = self()

      Application.put_env(:fermix_web, :plugin_auth_runner, fn name, _opts ->
        send(parent, {:unexpected_plugin_auth, name})
        {:error, :unexpected_auth_start}
      end)

      install_github_plugin(tmp_home, fixtures)

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      # The single github card folds in the OAuth client: Connect opens the modal
      # rather than starting auth against a not-yet-configured client.
      modal_html =
        view
        |> element(~s|button[phx-click="open_oauth_modal"][phx-value-provider="github"]|)
        |> render_click()

      assert modal_html =~ "Connect GitHub"
      assert modal_html =~ ~s(id="oauth-client-form-github")

      # The server-side pre-flight still refuses a direct enable without a client.
      guard_html = render_click(view, "plugin_enable", %{"name" => "github"})
      assert guard_html =~ "Save a GitHub OAuth client first, then connect GitHub."
      refute_receive {:unexpected_plugin_auth, _name}, 50
    end

    test "an installed version marked yanked warns loud on the card", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry = wire_catalog_plugin(fixtures, "demo", "1.0.0")
      opts = seed_catalog(tmp_home, [entry])
      assert {:ok, :installed} = DistInstaller.run_install("demo", opts)

      seed_catalog(tmp_home, [Map.put(entry, "yanked", ["1.0.0"])])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-plugin-name="demo")
      assert html =~ "was yanked"
    end

    test "an mcp catalog plugin renders enabled actions and the local-process line", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        fixtures
        |> wire_catalog_plugin("obsidian", "1.0.0")
        |> Map.put("rails", ["mcp"])

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-catalog-name="obsidian")
      refute html =~ "MCP plugin support lands in a later Fermix"
      assert html =~ "Runs a local process with direct access to the folders you configure."
      # `runtime_kind` is additive: an entry without it keeps exactly this copy
      # and never grows the hosted-runtime disclosure.
      refute html =~ "Before you connect"

      assert has_element?(
               view,
               ~s|button[phx-click="plugin_enable"][phx-value-name="obsidian"]|
             )
    end

    test "a local_stdio catalog entry keeps the local-process consent line", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        fixtures
        |> wire_catalog_plugin("localnotes", "1.0.0")
        |> Map.merge(%{"rails" => ["mcp"], "runtime_kind" => "local_stdio"})

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-catalog-name="localnotes")
      assert html =~ "Runs a local process with direct access to the folders you configure."
      refute html =~ "hosted MCP service"
      refute html =~ "Before you connect"
    end

    test "a remote_mcp catalog entry discloses hosted execution before connect", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        fixtures
        |> wire_catalog_plugin("hostednotes", "1.0.0")
        |> Map.merge(%{"rails" => ["mcp"], "runtime_kind" => "remote_mcp"})

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      assert html =~ ~s(data-catalog-name="hostednotes")
      # Consent splits on the index's runtime_kind, not on the rail: this entry
      # is `rails: ["mcp"]` exactly like the local one above.
      assert html =~
               "Connects to a hosted MCP service and sends selected requests and content to it."

      refute html =~ "Runs a local process with direct access to the folders you configure."

      # M27 §10.3, every clause, and all of it before the operator hands over a
      # credential — the card is still an uninstalled catalog card here.
      assert html =~ "hostednotes is a hosted service"
      assert html =~ "queries and content Fermix selects are sent to it"
      assert html =~ "may require a paid plan"
      assert html =~ "credits"
      assert html =~ "authorizes more upstream than Fermix exposes"
      assert html =~ "prefer a read-only"
      assert html =~ "third-party model providers"
      assert html =~ "configured model provider"
      assert html =~ "conversation history"
      assert html =~ "local trace content and the configured Opik exporter"
      assert html =~ "rights to the content you save"

      assert has_element?(
               view,
               ~s|button[phx-click="plugin_enable"][phx-value-name="hostednotes"]|
             )
    end

    test "an unknown runtime_kind fails the index loud instead of degrading to neutral copy", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        fixtures
        |> wire_catalog_plugin("hackerdemo", "1.0.0")
        |> Map.put("runtime_kind", "remote_sse")

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      # The index ships inside the verified binary, so an unreadable runtime kind
      # is a catalog bug: refuse the index rather than show a card whose consent
      # copy we cannot honestly write.
      assert html =~ "Catalog index unavailable"
      refute html =~ ~s(data-catalog-name="hackerdemo")
    end

    test "a plugin needing config renders the config form and saving clears it", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        wire_catalog_plugin(fixtures, "vaultdemo", "1.0.0",
          manifest_extra: %{
            "config" => [
              %{"key" => "DEMO_VAULT_PATH", "prompt" => "Path to your vault", "required" => true}
            ]
          }
        )

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="vaultdemo"]|)
      |> render_click()

      html = render_until(view, "Plugin enabled.")
      assert html =~ ~s(data-plugin-name="vaultdemo")
      assert html =~ "Needs config"
      assert html =~ "Path to your vault"
      assert html =~ ~s(id="plugin-config-form-vaultdemo")

      html =
        view
        |> form("#plugin-config-form-vaultdemo",
          plugin_config_form: %{"DEMO_VAULT_PATH" => "/tmp/demo-vault"}
        )
        |> render_submit()

      assert html =~ "Plugin configuration saved."
      refute html =~ ~s(id="plugin-config-form-vaultdemo")
      refute html =~ "Needs config"

      assert PluginConfig.plugin_settings("vaultdemo") == %{
               "DEMO_VAULT_PATH" => "/tmp/demo-vault"
             }
    end

    test "a blank config value fails loud and keeps the form", %{
      conn: conn,
      tmp_home: tmp_home,
      fixtures: fixtures
    } do
      entry =
        wire_catalog_plugin(fixtures, "vaultdemo", "1.0.0",
          manifest_extra: %{
            "config" => [
              %{"key" => "DEMO_VAULT_PATH", "prompt" => "Path to your vault", "required" => true}
            ]
          }
        )

      seed_catalog(tmp_home, [entry])

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="plugin_enable"][phx-value-name="vaultdemo"]|)
      |> render_click()

      render_until(view, "Plugin enabled.")

      html =
        view
        |> form("#plugin-config-form-vaultdemo", plugin_config_form: %{"DEMO_VAULT_PATH" => " "})
        |> render_submit()

      assert html =~ "DEMO_VAULT_PATH requires a value."
      assert html =~ ~s(id="plugin-config-form-vaultdemo")
      assert PluginConfig.plugin_settings("vaultdemo") == %{}
    end
  end

  # M27 §7.5 steps 3–7: the per-plugin workspace step, the first custom setup
  # step in this pane. Nothing here touches a socket — the remote calls run
  # against `Plugins.RemoteSetup`'s transport and MCP-supervisor seams.
  describe "remote plugin workspace picker" do
    setup do
      checkout = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-remote")
      secrets = Application.get_env(:fermix_core, :plugin_secrets, %{})

      on_exit(fn ->
        Application.put_env(:fermix_core, :plugin_secrets, secrets)
        Application.delete_env(:fermix_web, :remote_setup_opts)
        RuntimeStatus.clear(RuntimeStatus, {:plugin, "eden"})
        DistVerifierStub.cleanup()
        FermixTestSupport.SafeRm.rm_rf(checkout)
      end)

      Application.put_env(:fermix_core, :plugin_secrets, %{})
      # `Registry.list()` inside the LiveView takes no options, so the artifact
      # must land in the DEFAULT store under this test's tmp FERMIX_HOME.
      write_remote_plugin(ConfigStore.workspace_paths().plugins)
      Application.put_env(:fermix_core, :plugins, enabled: ["eden"])

      %{checkout: checkout}
    end

    test "the picker only appears once the credential is stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      # Credential first: the workspace step is meaningless without a token to
      # ask with, so the card offers the key form and nothing else.
      assert html =~ ~s(data-plugin-name="eden")
      assert html =~ "Needs key"
      refute html =~ ~s(phx-click="open_resource_picker")

      html =
        view
        |> form(~s|#plugin-secret-form-eden|, %{
          "plugin_secret_form" => %{"value" => "eden_pat_0123456789abcdef"}
        })
        |> render_submit()

      assert html =~ "Needs workspace"
      assert html =~ ~s(phx-click="open_resource_picker")
      assert html =~ "Choose workspace"
    end

    test "choosing a workspace persists the selection and reaches Ready", %{conn: conn} do
      store_credential()
      agent = canned_session(workspaces_result())

      Application.put_env(:fermix_web, :remote_setup_opts,
        transport: FakeRemoteTransport,
        connect_opts: [agent: agent],
        resolver: fn "eden" -> "eden_pat_0123456789abcdef" end,
        mcp_supervisor: ReadySupervisor
      )

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="open_resource_picker"][phx-value-name="eden"]|)
      |> render_click()

      html = render_until(view, "Beta")
      assert html =~ ~s(id="resource-picker")
      assert html =~ "Alpha"
      # The signed default profile is preselected; the write profile states what
      # it widens before it can be chosen.
      assert html =~ "Retrieval only"
      assert html =~ "Needs a read/write token and exposes write tools."

      # Selection is async (it stops, persists, restarts, and waits for the
      # replacement client to reach `:ready`), so the click only starts it.
      view
      |> element(~s|button[phx-click="select_workspace"][phx-value-id="ws_alpha"]|)
      |> render_click()

      html = render_until(view, "Workspace selected.")
      assert html =~ "Workspace selected."
      refute html =~ ~s(id="resource-picker")
      assert html =~ "Ready"

      entry =
        :fermix_core
        |> Application.get_env(:plugins, [])
        |> Keyword.get(:entries, %{})
        |> Map.get("eden", [])

      assert Keyword.get(entry, :workspace_id) == "ws_alpha"
      assert Keyword.get(entry, :workspace_label) == "Alpha"
      assert Keyword.get(entry, :access_profile) == "retrieval"
    end

    # The bug this pins: selection used to run inline in the event handler and
    # report failure through a page flash, so the operator saw NOTHING — the
    # LiveView could not re-render while it blocked, and the flash landed under
    # the still-open modal.
    test "a failing selection reports the reason inside the modal", %{conn: conn} do
      store_credential()
      agent = canned_session(workspaces_result())

      Application.put_env(:fermix_web, :remote_setup_opts,
        transport: FakeRemoteTransport,
        connect_opts: [agent: agent],
        resolver: fn "eden" -> "eden_pat_0123456789abcdef" end,
        mcp_supervisor: MismatchSupervisor
      )

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="open_resource_picker"][phx-value-name="eden"]|)
      |> render_click()

      render_until(view, "Beta")

      view
      |> element(~s|button[phx-click="select_workspace"][phx-value-id="ws_alpha"]|)
      |> render_click()

      html = render_until(view, "Could not select that workspace")

      # Visible, inside the modal, with the list still usable for a retry.
      assert html =~ ~s(id="resource-picker")
      assert html =~ "Could not select that workspace"
      assert html =~ "upstream_contract_mismatch"
      assert html =~ "Alpha"
      refute html =~ "Workspace selected."
    end

    test "a discovery failure renders a redacted error and persists nothing", %{conn: conn} do
      store_credential()
      agent = canned_session({:error, :nxdomain})

      Application.put_env(:fermix_web, :remote_setup_opts,
        transport: FakeRemoteTransport,
        connect_opts: [agent: agent],
        resolver: fn "eden" -> "eden_pat_0123456789abcdef" end,
        mcp_supervisor: ReadySupervisor
      )

      {:ok, view, _html} = live(conn, "/setup")
      view |> element(~s|button[phx-value-tab="plugins"]|) |> render_click()

      view
      |> element(~s|button[phx-click="open_resource_picker"][phx-value-name="eden"]|)
      |> render_click()

      # The classified transport failure, and nothing else: no credential, no
      # endpoint, no process state.
      html = render_until(view, "Could not list workspaces")
      assert html =~ "Could not list workspaces: :nxdomain"
      refute html =~ "eden_pat_"

      entry =
        :fermix_core
        |> Application.get_env(:plugins, [])
        |> Keyword.get(:entries, %{})
        |> Map.get("eden", [])

      assert Keyword.get(entry, :workspace_id) == nil
      assert PluginStatus.status("eden") == :needs_workspace
    end
  end

  # The remote-MCP half of the status vocabulary (M27 §12 Stage 3). It has no
  # runtime source to read yet, so it is listed here — and this list is the
  # contract the remote lifecycle work has to satisfy.
  @remote_statuses [
    :needs_workspace,
    :insufficient_credential_scope,
    :invalid_remote_config,
    :connecting,
    :remote_unreachable,
    :upstream_contract_mismatch,
    :capability_conflict,
    :remote_security_blocked,
    :remote_protocol_error,
    :reauthorization_required
  ]

  # Statuses the operator can actually fix from the card, so the fix-it button
  # must not fall back to the generic "Enable".
  @actionable_statuses [
    :not_installed,
    :missing_host_runtime,
    :needs_workspace,
    :insufficient_credential_scope,
    :invalid_remote_config,
    :remote_unreachable
  ]

  # `status_pill_class/1` + `status_pill_label/1` are the only place a status atom
  # becomes UI, and a missing clause is silent — the pill just reads "Unknown".
  # Per the CLAUDE.md "gate on the whole feature surface" rule, the invariant is
  # written over the WHOLE vocabulary, and its local half is read from
  # `Plugins.Status`'s own source (via the module's compile-time path, so no repo
  # layout is assumed) instead of being spelled out: a status added there later
  # either joins this test or fails it.
  describe "status vocabulary" do
    test "no status Plugins.Status returns, and no remote status, renders as Unknown" do
      statuses = plugins_status_returns()

      # Anchors: a silently-broken extraction would otherwise pass an empty loop.
      assert length(statuses) >= 11
      assert :ready in statuses
      assert :missing_host_runtime in statuses
      assert :not_installed in statuses

      for status <- statuses ++ @remote_statuses do
        assert Components.status_pill_label(status) != "Unknown",
               "#{inspect(status)} has no pill label and renders as a grey Unknown"

        assert Components.status_pill_class(status) =~ "badge-",
               "#{inspect(status)} has no pill class"
      end
    end

    test "every pill label is sentence-cased" do
      for status <- plugins_status_returns() ++ @remote_statuses do
        label = Components.status_pill_label(status)
        first = String.first(label)

        assert first == String.upcase(first),
               "#{inspect(status)} renders the lowercase label #{inspect(label)}"
      end
    end

    test "a status the operator can fix carries its own action verb" do
      for status <- @actionable_statuses do
        assert Components.plugin_action_label(status) != "Enable",
               "#{inspect(status)} falls back to the generic Enable verb"
      end
    end
  end

  # Every atom `Plugins.Status` can return: each of its clause/branch returns is
  # written `-> :atom`, so the returns are exactly the atoms in that position.
  defp plugins_status_returns do
    source = to_string(PluginStatus.module_info(:compile)[:source])
    assert File.exists?(source), "Plugins.Status source not found at #{source}"

    ~r/->\s*:([a-z_]+)\b/
    |> Regex.scan(File.read!(source))
    |> Enum.map(fn [_match, name] -> String.to_existing_atom(name) end)
    |> Enum.uniq()
  end

  # Build + wire a catalog plugin artifact behind the dist stubs; returns the
  # index entry map. Verification is allowed by default (the stub default-denies).
  defp wire_catalog_plugin(fixtures, name, version, opts \\ []) do
    File.mkdir_p!(fixtures)
    {build_opts, wire_opts} = Keyword.split(opts, [:manifest_extra])
    {tgz, sha} = DistFixtures.build_tarball(fixtures, name, version, build_opts)
    DistVerifierStub.allow(name, version)
    DistFixtures.wire(fixtures, name, version, tgz, sha, wire_opts)
  end

  # Install an oauth2/github-provider plugin through the dist seam so the
  # plugins pane renders it as an installed card in the GitHub group.
  defp install_github_plugin(tmp_home, fixtures) do
    entry =
      wire_catalog_plugin(fixtures, "github", "1.0.0",
        manifest_extra: %{
          "display_name" => "GitHub",
          "auth" => %{"type" => "oauth2", "provider" => "github", "scopes" => ["repo"]},
          "health_check" => %{"kind" => "local_readiness", "requires_auth" => true}
        }
      )

    opts = seed_catalog(tmp_home, [entry])
    assert {:ok, :installed} = DistInstaller.run_install("github", opts)
  end

  # A dev_local checkout of the computer-use sidecar (manifest only): the registry
  # discovers it as an installed plugin, but with no binary the sidecar is not
  # runnable, mirroring "installed via catalog, OS permissions still pending".
  defp write_cu_dev_local(checkout) do
    File.mkdir_p!(Path.join(checkout, "computer_use_sidecar"))

    File.write!(
      Path.join([checkout, "computer_use_sidecar", "plugin.json"]),
      Jason.encode!(%{
        "schema_version" => 2,
        "name" => "computer_use_sidecar",
        "display_name" => "Computer Use Sidecar",
        "description" => "Computer-use sidecar fixture",
        "category" => "system",
        "version" => "0.1.0",
        "min_core_version" => "0.1.0",
        "plugin_api" => 2,
        "auth" => %{"type" => "none"},
        "tools" => []
      })
    )
  end

  # Drop an executable sidecar binary at the host-target path so
  # SidecarInstaller.installed?/0 (hence ComputerUse.ready?/0) turns true.
  defp write_cu_dev_local_binary(checkout) do
    {:ok, {os, arch}} = Manifest.target_for_host()
    bin_dir = Path.join([checkout, "computer_use_sidecar", "bin", "#{os}-#{arch}"])
    File.mkdir_p!(bin_dir)
    binary = Path.join(bin_dir, "compux")
    File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, 0o755)
  end

  # Write the seed index and point the :plugins_dist_opts seam at it. The seam
  # root tmp_home/plugins equals ConfigStore.workspace_paths().plugins (FERMIX_HOME
  # is tmp_home), so default-rooted paths inside the LiveView stay aligned.
  defp seed_catalog(tmp_home, entries) do
    seed = DistFixtures.write_index(Path.join(tmp_home, "fixtures/seed-index.json"), entries)
    root = Path.join(tmp_home, "plugins")

    dist_opts = [
      root: root,
      fetcher: DistFetcherStub,
      verifier: DistVerifierStub,
      index_opts: [seed_path: seed],
      lock_opts: [attempts: 3, delay_ms: 10]
    ]

    Application.put_env(:fermix_core, :plugins_dist_opts, dist_opts)
    dist_opts
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

  # Hermetic harness detection map (the `:harness_detector` seam shape) — no real
  # `codex`/`claude --version` subprocess is ever spawned in these tests.
  defp harness_detections(codex_available?, claude_available?) do
    %{
      "codex" => harness_detection("codex", codex_available?),
      "claude" => harness_detection("claude", claude_available?)
    }
  end

  defp harness_detection(vendor, false) do
    %{vendor: vendor, binary: nil, available?: false, version: nil, auth: :absent}
  end

  defp harness_detection(vendor, true) do
    %{
      vendor: vendor,
      binary: "/usr/bin/#{vendor}",
      available?: true,
      version: "#{vendor} 1.0.0",
      auth: :authenticated
    }
  end

  # --- remote-plugin picker fixtures --------------------------------------

  defp store_credential do
    Application.put_env(:fermix_core, :plugin_secrets, %{"eden" => "eden_pat_0123456789abcdef"})
  end

  # initialize -> initialized -> tools/list -> tools/call -> teardown.
  defp canned_session(call_response) do
    responses = [
      remote_json(
        200,
        remote_rpc(1, %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}),
        [
          {"mcp-session-id", "sess-web-1"}
        ]
      ),
      {:ok, %{status: 202, headers: [], body: {:empty, ""}}},
      remote_json(200, remote_rpc(2, %{"tools" => [remote_live_descriptor()]})),
      call_response,
      {:ok, %{status: 200, headers: [], body: {:empty, ""}}}
    ]

    {:ok, agent} = Agent.start_link(fn -> responses end)
    agent
  end

  defp workspaces_result do
    body = %{
      "ok" => true,
      "workspaces" => [
        %{"id" => "ws_alpha", "name" => "Alpha"},
        %{"id" => "ws_beta", "name" => "Beta"}
      ]
    }

    remote_json(
      200,
      remote_rpc(3, %{"content" => [%{"type" => "text", "text" => Jason.encode!(body)}]})
    )
  end

  defp remote_json(status, body, headers \\ []) do
    {:ok,
     %{
       status: status,
       headers: [{"content-type", "application/json"}] ++ headers,
       body: {:json, Jason.encode!(body)}
     }}
  end

  defp remote_rpc(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp remote_live_descriptor do
    %{
      "name" => "eden_list_workspaces",
      "description" => "List workspaces.",
      "inputSchema" => remote_workspaces_parameters()
    }
  end

  defp remote_workspaces_parameters, do: %{"type" => "object", "properties" => %{}}

  # A plugin-api-3 `remote_mcp` plugin named `eden`, the one plugin with a
  # registered `SecretPaths` entry, so the credential form is the real one.
  # Nothing in the picker keys on that name.
  #
  # INSTALLED, not dev_local: a remote manifest with no publisher signature is
  # refused by the provenance gate (M27 §9.3), so a dev_local fixture would
  # exercise a path the product does not have.
  defp write_remote_plugin(store) do
    manifest = %{
      "schema_version" => 2,
      "plugin_api" => 3,
      "min_core_version" => "0.1.0",
      "name" => "eden",
      "display_name" => "Eden",
      "description" => "Remote MCP fixture with a single-workspace resource scope.",
      "category" => "productivity",
      "version" => "1.0.0",
      "auth" => %{
        "type" => "api_key",
        "key_name" => "EDEN_PERSONAL_ACCESS_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste an Eden personal access token"
      },
      "runtime" => %{
        "kind" => "remote_mcp",
        "transport" => "streamable_http",
        "protocol_version" => "2025-06-18",
        "base_url" => "https://mcp.eden.so",
        "mcp_path" => "/mcp",
        "tool_name_mode" => "preserve"
      },
      "tool_profiles" => [
        %{
          "name" => "retrieval",
          "display_name" => "Retrieval only",
          "default" => true,
          "required_credential_scope" => "read",
          "scope_visibility" => "none",
          "tools" => ["eden_search"]
        },
        %{
          "name" => "capture",
          "display_name" => "Retrieval and capture",
          "default" => false,
          "required_credential_scope" => "write",
          "scope_visibility" => "none",
          "tools" => ["eden_search", "eden_append"]
        }
      ],
      "setup_tools" => ["eden_list_workspaces"],
      "resource_scope" => %{
        "kind" => "single_workspace",
        "discovery_tool" => "eden_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      "budgets" => %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      "result_contract" => %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      "tools" => [
        sign_remote_tool(%{
          "name" => "eden_list_workspaces",
          "description" => "List workspaces available to the connected token.",
          "policy_class" => "external_api",
          "read_only" => true,
          "replay_safe" => false,
          "required_credential_scope" => "read",
          "rail" => "mcp",
          "collection_policy" => nil,
          "argument_guards" => [],
          "parameters" => remote_workspaces_parameters(),
          "output_schema" => nil,
          "upstream_annotations" => nil
        }),
        sign_remote_tool(%{
          "name" => "eden_search",
          "description" => "Search a workspace.",
          "policy_class" => "external_api",
          "read_only" => true,
          "replay_safe" => true,
          "required_credential_scope" => "read",
          "rail" => "mcp",
          "collection_policy" => nil,
          "argument_guards" => [],
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "workspaceId" => %{"type" => "string"},
              "query" => %{"type" => "string"}
            }
          },
          "output_schema" => nil,
          "upstream_annotations" => nil
        }),
        sign_remote_tool(%{
          "name" => "eden_append",
          "description" => "Append to a note.",
          "policy_class" => "external_api",
          "read_only" => false,
          "replay_safe" => false,
          "required_credential_scope" => "write",
          "rail" => "mcp",
          "collection_policy" => nil,
          "argument_guards" => [],
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "workspaceId" => %{"type" => "string"},
              "text" => %{"type" => "string"}
            }
          },
          "output_schema" => nil,
          "upstream_annotations" => nil
        })
      ],
      "skills" => []
    }

    fixtures = Path.join(store, "fixtures")
    File.mkdir_p!(fixtures)
    DistStore.ensure!(store)
    DistVerifierStub.init()
    :ok = DistFixtures.install_remote_plugin(store, fixtures, "eden", "1.0.0", manifest)
    :ok = DistVerifierStub.allow("eden", "1.0.0")
  end

  defp sign_remote_tool(tool) do
    {:ok, digest} =
      CanonicalJson.descriptor_digest(
        Map.fetch!(tool, "name"),
        Map.fetch!(tool, "parameters"),
        Map.get(tool, "output_schema"),
        Map.get(tool, "upstream_annotations")
      )

    Map.put(tool, "descriptor_sha256", digest)
  end

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

  # The inverse of `render_until/3`: poll until `expected` is GONE. Returns
  # false once the budget is spent, so the caller still asserts.
  defp render_until_missing(view, expected, attempts \\ 40)

  defp render_until_missing(_view, _expected, 0), do: false

  defp render_until_missing(view, expected, attempts) do
    if render(view) =~ expected do
      Process.sleep(25)
      render_until_missing(view, expected, attempts - 1)
    else
      true
    end
  end

  describe "computer-use grant prompt" do
    # The grant impl is injected so the handler never fires a real macOS OS dialog.
    test "a full grant flashes success", %{conn: conn} do
      Application.put_env(:fermix_web, :computer_use_grant_impl, fn ->
        {:ok, %{screen_capture: true, input_control: true}}
      end)

      {:ok, view, _html} = live(conn, "/setup")
      assert render_hook(view, "computer_use_grant", %{}) =~ "macOS permissions granted."
    end

    test "a partial grant flashes the approve-the-prompts guidance", %{conn: conn} do
      Application.put_env(:fermix_web, :computer_use_grant_impl, fn ->
        {:ok, %{screen_capture: true, input_control: false}}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      assert render_hook(view, "computer_use_grant", %{}) =~
               "Approve the Screen Recording and Accessibility prompts"
    end

    test "a sidecar error flashes the failure instead of crashing", %{conn: conn} do
      Application.put_env(:fermix_web, :computer_use_grant_impl, fn ->
        {:error, {:sidecar_missing, "/nope"}}
      end)

      {:ok, view, _html} = live(conn, "/setup")

      # (apostrophe in "Couldn't" is HTML-escaped in the rendered flash)
      assert render_hook(view, "computer_use_grant", %{}) =~ "open the permission prompts"
    end
  end
end
