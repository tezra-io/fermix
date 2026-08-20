defmodule FermixWebWeb.SetupLive do
  use FermixWebWeb, :live_view

  alias Fermix.CLI.Service
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.CodexLogin
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.XAILogin
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.ComputerHistory.InstalledApps
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Harness.Vendors, as: HarnessVendors
  alias FermixCore.Meetings
  alias FermixCore.Meetings.Config, as: MeetingsConfig
  alias FermixCore.Meetings.SidecarInstaller, as: MeetbotInstaller
  alias FermixCore.Meetings.SignIn
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Plugins.Auth, as: PluginAuth
  alias FermixCore.Plugins.Catalog, as: PluginCatalog
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Dist.Installer, as: DistInstaller
  alias FermixCore.Plugins.Health, as: PluginHealth
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Plugins.RemoteSetup
  alias FermixCore.Plugins.Status, as: PluginStatus
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ModelListing
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Providers.Selection
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Doctor
  alias FermixCore.Setup.Wizard
  alias FermixCore.SkillCuration.Delivery, as: SkillCurationDelivery
  alias FermixCore.Tools.Media.Registry, as: MediaRegistry
  alias FermixCore.Transcription.Local, as: LocalTranscription
  alias FermixCore.Transcription.Local.ModelStore, as: LocalModelStore
  alias FermixCore.Transcription.Local.SidecarInstaller, as: LocalSttInstaller
  alias FermixCore.Transcription.Registry, as: TranscriptionRegistry
  alias FermixWebWeb.SetupLive.Components

  # Computer use is a core feature, not a plugin whose branding we receive, so its
  # card name + logo are owned here. The SVG is inlined as a data URI at compile
  # time (the same shape plugin logos render as); @external_resource recompiles
  # this module whenever the asset changes.
  @computer_use_logo_path Path.join(__DIR__, "setup_live/computer_use_logo.svg")
  @external_resource @computer_use_logo_path
  @computer_use_logo_uri "data:image/svg+xml;base64," <>
                           Base.encode64(File.read!(@computer_use_logo_path))

  @computer_history_logo_path Path.join(__DIR__, "setup_live/computer_history_logo.svg")
  @external_resource @computer_history_logo_path
  @computer_history_logo_uri "data:image/svg+xml;base64," <>
                               Base.encode64(File.read!(@computer_history_logo_path))

  @meetings_logo_path Path.join(__DIR__, "setup_live/meetings_logo.svg")
  @external_resource @meetings_logo_path
  @meetings_logo_uri "data:image/svg+xml;base64," <>
                       Base.encode64(File.read!(@meetings_logo_path))

  @tabs [
    %{id: "provider", label: "Provider", component: "provider:*", description: "Model and key"},
    %{id: "realtime", label: "Realtime", component: "realtime:*", description: "Voice companion"},
    %{id: "channels", label: "Channels", component: "channel:*", description: "Message ingress"},
    %{id: "transcription", label: "Voice notes", component: nil, description: "Speech-to-text"},
    %{id: "plugins", label: "Plugins", component: nil, description: "Integrations"},
    %{id: "search", label: "Search", component: nil, description: "Web search"},
    %{id: "media", label: "Media", component: nil, description: "Image generation"},
    %{id: "sandbox", label: "Sandbox", component: nil, description: "Execution policy"},
    %{id: "coding", label: "Coding Agents", component: nil, description: "Delegated coding CLIs"},
    %{id: "memory", label: "Memory", component: nil, description: "Recall tuning"},
    %{
      id: "personalization",
      label: "Personalization",
      component: "personalization",
      description: "User profile"
    },
    %{id: "doctor", label: "Doctor", component: nil, description: "Final checks"}
  ]

  @default_plugin_auth_url_timeout_ms 300_000
  @local_installing_message "Installing on-device speech…"
  @local_ready_message "On-device speech is installed and ready."
  @meetbot_installing_message "Downloading the meeting notetaker…"
  @meetbot_ready_message "The meeting notetaker is installed."
  @meetbot_signin_running_message "A browser window is opening — sign the bot's Google account in there, and it closes when done."
  @meetbot_signin_done_message "The bot is signed in. Google Meet joins can use its account now."
  @meetbot_signin_cancelled_message "Sign-in was cancelled — the window closed before the account signed in."
  @meetbot_signin_timeout_message "Sign-in timed out. Open it again and complete the Google sign-in."
  # Providers the per-provider OAuth-client form supports — mirrors
  # FermixCore.Auth.OAuthProviders. Default ports: google 1455, github 1457,
  # notion 1458, x 1459, slack 1460.
  @oauth_client_providers ~w(google github notion x slack)
  # Derived from the descriptor registry: every provider setup field plus
  # each multi-auth-mode provider's auth_mode answer (M12 §6.2).
  @provider_restart_keys [:provider, :default_model, :reasoning_effort, :fast] ++
                           Enum.flat_map(
                             FermixCore.Providers.Descriptor.all(),
                             fn descriptor -> Enum.map(descriptor.setup_fields, & &1.key) end
                           ) ++
                           (FermixCore.Providers.Descriptor.all()
                            |> Enum.filter(&FermixCore.Providers.Descriptor.multi_auth_mode?/1)
                            |> Enum.map(&:"#{&1.id}_auth_mode"))
  @realtime_restart_keys [
    :realtime_enabled,
    :realtime_api_key,
    :realtime_model,
    :realtime_reasoning_effort,
    :realtime_voice,
    :realtime_max_session_minutes,
    :realtime_max_cost_cents,
    :realtime_persist_transcripts
  ]
  @channel_restart_keys [
    :telegram_bot_token,
    :telegram_owner_user_id,
    :whatsapp_access_token,
    :whatsapp_phone_number_id,
    :whatsapp_verify_token,
    :whatsapp_app_secret,
    :whatsapp_owner_user_id,
    :discord_bot_token,
    :discord_bot_user_id,
    :discord_owner_user_id,
    :slack_bot_token,
    :slack_signing_secret,
    :slack_owner_user_id,
    :signal_account,
    :signal_owner_user_id,
    # The ACP listener is a supervised transport child started at boot, so
    # flipping it needs a restart before the socket appears (or disappears).
    :acp_enabled
  ]
  # `default_vendor` gates which run tool advertises AND feeds the runtime prompt
  # steer (rendered from the cached profile), so a change wants a daemon restart
  # to fully take effect. Consent (`approved`) is read live at execute time AND
  # now gates whether the harness section renders at all (design §23.4), so it is
  # restart-flagged for the same cached-profile reason.
  @harness_restart_keys [:harness_default_vendor, :harness_approved]
  # Flipping skill curation adds/removes the Scheduler child (child-absent
  # gating), so it only takes effect on a daemon restart.
  @skill_curation_restart_keys [:skill_curation_enabled]
  # `[fermix_core.meetings]` is written as a section rather than through wizard
  # answers, so these never reach `runtime_restart_answers?/1`; they are the keys
  # `Meetings.ready?/0` reads, and tool registration reads it only at boot.
  @meetings_restart_keys [
    :enabled,
    :zoom_account_id,
    :zoom_client_id,
    :zoom_client_secret,
    :zoom_ws_subscription_id
  ]

  @impl true
  def mount(params, session, socket) do
    if AccessToken.session_authorized?(setup_authorization(session)) do
      mount_authorized(socket, requested_tab(params))
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  # push_patch from apply_restart sets `?tab=`; with no patch this is a no-op.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp mount_authorized(socket, requested_tab) do
    report = Wizard.report()

    socket =
      socket
      |> assign(:page_title, "Fermix setup")
      |> assign(:active_tab, requested_tab || next_action_tab(report))
      |> assign(:saved_flash, nil)
      |> assign(:doctor_result, nil)
      |> assign(:doctor_probe_pending, MapSet.new())
      |> assign(:doctor_probe_running?, false)
      |> assign(:restarting, false)
      |> assign(:restart_pending?, false)
      |> assign(:codex_auth_tasks, %{})
      |> assign(:codex_auth_url, nil)
      |> assign(:xai_auth_tasks, %{})
      |> assign(:xai_auth_url, nil)
      |> assign(:plugin_auth_tasks, %{})
      |> assign(:plugin_auth_url, nil)
      |> assign(:plugin_install_tasks, %{})
      |> assign(:local_install, nil)
      |> assign(:meetbot_install, nil)
      |> assign(:meetbot_signin, nil)
      |> assign(:oauth_modal, nil)
      |> assign(:resource_picker, nil)
      |> assign(:computer_history_picker, nil)
      |> assign(:meetings_config_open?, false)
      |> assign_report(report)

    {:ok, socket}
  end

  defp setup_authorization(session) do
    session["setup_authorized"] || session[:setup_authorized]
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab_id}, socket) do
    active_tab = if tab_known?(tab_id), do: tab_id, else: socket.assigns.active_tab
    {:noreply, assign(socket, :active_tab, active_tab) |> assign(:saved_flash, nil)}
  end

  def handle_event("next_step", _params, socket) do
    {:noreply, assign(socket, :active_tab, next_tab(socket.assigns.active_tab))}
  end

  def handle_event("previous_step", _params, socket) do
    {:noreply, assign(socket, :active_tab, previous_tab(socket.assigns.active_tab))}
  end

  def handle_event("provider_changed", %{"provider_form" => params}, socket) do
    current = socket.assigns.provider_form
    provider = parse_provider_field(Map.get(params, "provider"), current.provider)

    form =
      if provider == current.provider do
        edited_provider_form(current, params)
      else
        # Switched provider via the cards — load that provider's saved config.
        build_provider_form(socket.assigns.report.wizard.config_snapshot, provider)
      end

    {:noreply,
     socket
     |> assign(:provider_form, form)
     |> assign_model_sources(form)}
  end

  def handle_event("save_provider", %{"provider_form" => params} = root, socket) do
    case maybe_store_anthropic_setup_token(params) do
      :ok ->
        answers =
          []
          # :edit_provider (not :provider) — saving a provider's settings configures
          # THAT provider's block without promoting it to primary. Primary is set
          # only on initial setup (first provider) or via the "Set primary" action.
          |> maybe_put_string(:edit_provider, params["provider"])
          |> maybe_put_string(:default_model, params["default_model"])
          |> maybe_put_string(:reasoning_effort, params["reasoning_effort"])
          |> maybe_put_string(:fast, params["fast"])
          |> put_provider_field_answers(params)
          |> put_auth_mode_answer(params["provider"], params["auth_mode"])
          |> put_subagent_model_answer(params)

        {:noreply,
         save_answers(socket, answers, "Provider saved.", Map.get(root, "__nav"),
           restart_required?: runtime_restart_answers?(answers)
         )}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Anthropic sign-in failed: #{Redaction.format(reason)}")}
    end
  end

  # Flip the primary flag to an already-configured provider without re-entering
  # its credentials (the "Set primary" card action).
  def handle_event("set_primary", %{"provider" => provider_string}, socket) do
    provider = parse_provider_field(provider_string, socket.assigns.provider_form.provider)
    status = Enum.find(socket.assigns.provider_statuses, &(&1.provider == provider))

    if status && status.configured? && not status.primary? do
      {:noreply,
       save_answers(
         socket,
         # Flipping primary resets the sub-agent model to "same as main": a pin
         # chosen for the old primary (e.g. a Codex model) is not meaningful for
         # the new one, and the picker is scoped to the primary's pane. "" clears
         # the [fermix_core.routing] override (Wizard.put_subagent_model).
         [provider: provider_string, subagent_model: ""],
         "Primary provider set to #{provider}.",
         nil,
         restart_required?: true
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("codex_login", _params, socket) do
    if codex_auth_running?(socket.assigns.codex_auth_tasks) do
      {:noreply, flash_info(socket, "ChatGPT sign-in is already open.")}
    else
      {:noreply, start_codex_auth(socket)}
    end
  end

  def handle_event("xai_login", _params, socket) do
    if xai_auth_running?(socket.assigns.xai_auth_tasks) do
      {:noreply, flash_info(socket, "Grok sign-in is already open.")}
    else
      {:noreply, start_xai_auth(socket)}
    end
  end

  def handle_event("anthropic_import", _params, socket) do
    if anthropic_login_impl().claude_code_available?() do
      {:noreply, connect_anthropic(socket, fn -> anthropic_login_impl().import_claude_code() end)}
    else
      {:noreply, flash_error(socket, "No Claude Code login found to import.")}
    end
  end

  def handle_event("save_realtime", %{"realtime_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:realtime_enabled, params["enabled"])
      |> maybe_put_string(:realtime_api_key, params["api_key"])
      |> maybe_put_string(:realtime_model, params["model"])
      |> maybe_put_string(:realtime_reasoning_effort, params["reasoning_effort"])
      |> maybe_put_string(:realtime_voice, params["voice"])
      |> maybe_put_string(:realtime_max_session_minutes, params["max_session_minutes"])
      |> maybe_put_string(:realtime_max_cost_cents, params["max_cost_cents"])
      |> maybe_put_string(:realtime_persist_transcripts, params["persist_transcripts"])

    {:noreply,
     save_answers(socket, answers, "Realtime saved.", Map.get(root, "__nav"),
       restart_required?: runtime_restart_answers?(answers)
     )}
  end

  def handle_event("save_channels", %{"channels_form" => params} = root, socket) do
    editing = socket.assigns.channels_form.editing

    answers =
      []
      |> maybe_put_string(:telegram_bot_token, params["telegram_bot_token"])
      |> maybe_put_string(:telegram_owner_user_id, params["telegram_owner_user_id"])
      |> maybe_put_string(:whatsapp_access_token, params["whatsapp_access_token"])
      |> maybe_put_string(:whatsapp_phone_number_id, params["whatsapp_phone_number_id"])
      |> maybe_put_string(:whatsapp_verify_token, params["whatsapp_verify_token"])
      |> maybe_put_string(:whatsapp_app_secret, params["whatsapp_app_secret"])
      |> maybe_put_string(:whatsapp_owner_user_id, params["whatsapp_owner_user_id"])
      |> maybe_put_string(:discord_bot_token, params["discord_bot_token"])
      |> maybe_put_string(:discord_bot_user_id, params["discord_bot_user_id"])
      |> maybe_put_string(:discord_owner_user_id, params["discord_owner_user_id"])
      |> maybe_put_string(:slack_bot_token, params["slack_bot_token"])
      |> maybe_put_string(:slack_signing_secret, params["slack_signing_secret"])
      |> maybe_put_string(:slack_owner_user_id, params["slack_owner_user_id"])
      |> maybe_put_string(:signal_account, params["signal_account"])
      |> maybe_put_string(:signal_owner_user_id, params["signal_owner_user_id"])
      |> maybe_put_string(:acp_enabled, params["acp_enabled"])

    socket =
      save_answers(socket, answers, "Channels saved.", Map.get(root, "__nav"),
        restart_required?: runtime_restart_answers?(answers)
      )

    # assign_report rebuilds channels_form (editing -> default); keep the
    # operator on the channel they just saved.
    {:noreply, assign(socket, :channels_form, %{socket.assigns.channels_form | editing: editing})}
  end

  def handle_event("select_channel", %{"channel" => channel}, socket) do
    channel = parse_channel_field(channel, socket.assigns.channels_form.editing)
    {:noreply, assign(socket, :channels_form, %{socket.assigns.channels_form | editing: channel})}
  end

  def handle_event("search_changed", %{"search_form" => params}, socket) do
    backend = normalize_search_backend(Map.get(params, "backend"))
    {:noreply, assign(socket, :search_form, %{socket.assigns.search_form | backend: backend})}
  end

  def handle_event("save_search", %{"search_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:web_search_backend, params["backend"])
      |> maybe_put_string(:tavily_api_key, params["tavily_api_key"])
      |> maybe_put_string(:exa_api_key, params["exa_api_key"])
      |> maybe_put_string(:parallel_api_key, params["parallel_api_key"])
      |> maybe_put_string(:brave_api_key, params["brave_api_key"])
      |> maybe_put_string(:perplexity_api_key, params["perplexity_api_key"])
      |> maybe_put_string(:firecrawl_api_key, params["firecrawl_api_key"])

    {:noreply, save_answers(socket, answers, "Search saved.", Map.get(root, "__nav"))}
  end

  def handle_event("image_changed", %{"image_form" => params}, socket) do
    backend = normalize_image_backend(Map.get(params, "backend"))
    form = update_image_selection(socket.assigns.image_form, backend, Map.get(params, "model"))
    {:noreply, assign(socket, :image_form, form)}
  end

  def handle_event("save_image", %{"image_form" => params} = root, socket) do
    # The OpenAI/xAI key fields submit under their provider secret keys
    # (openai_api_key/xai_api_key), so put_provider_field_answers folds them
    # straight to providers.<p>.api_key — the same key those providers use for
    # chat. google_api_key is a tool-block secret, routed on its own line.
    answers =
      []
      |> maybe_put_string(:image_backend, params["backend"])
      |> maybe_put_string(:image_model, params["model"])
      |> maybe_put_string(:google_api_key, params["google_api_key"])
      |> put_provider_field_answers(params)

    {:noreply,
     save_answers(socket, answers, "Media saved.", Map.get(root, "__nav"),
       restart_required?: runtime_restart_answers?(answers)
     )}
  end

  def handle_event("transcription_changed", %{"transcription_form" => params}, socket) do
    previous = socket.assigns.transcription_form.backend
    backend = normalize_transcription_backend(Map.get(params, "backend"))

    form =
      update_transcription_selection(
        socket.assigns.transcription_form,
        backend,
        Map.get(params, "model")
      )

    {:noreply,
     socket
     |> assign(:transcription_form, form)
     |> maybe_install_local_stt(previous, backend)}
  end

  def handle_event("save_transcription", %{"transcription_form" => params} = root, socket) do
    # The single `api_key` field carries the selected backend's transcription key;
    # the wizard routes it to that backend's slot (openai/xai override the reused
    # chat key, deepgram is its only source). `model` is snapped to the selected
    # backend's default by the wizard when no explicit model rides along, so a
    # backend switch never leaves an OpenAI-shaped model on Deepgram (xai is
    # modelless and sends none).
    answers =
      []
      |> maybe_put_string(:transcription_backend, params["backend"])
      |> maybe_put_string(:transcription_model, params["model"])
      |> maybe_put_string(:transcription_api_key, params["api_key"])

    # Backends read [fermix_core.transcription] per call, so no daemon restart.
    {:noreply, save_answers(socket, answers, "Transcription saved.", Map.get(root, "__nav"))}
  end

  # Text and toggle values are always written (a cleared `announce_message` means
  # "use the built-in consent line", so blank is a real value here); the Zoom
  # secret is written only when the operator typed one, so an untouched password
  # field keeps the stored credential.
  def handle_event("save_meetings", %{"meetings_form" => params} = root, socket) do
    changes =
      [
        enabled: checked?(params["enabled"]),
        bot_name: safe_string(params["bot_name"]),
        announce: checked?(params["announce"]),
        announce_message: safe_string(params["announce_message"]),
        transcription_backend: normalize_meetings_backend(params["transcription_backend"]),
        zoom_account_id: safe_string(params["zoom_account_id"]),
        zoom_client_id: safe_string(params["zoom_client_id"]),
        zoom_ws_subscription_id: safe_string(params["zoom_ws_subscription_id"])
      ]
      |> maybe_put_string(:zoom_client_secret, params["zoom_client_secret"])

    {:noreply, save_meetings(socket, changes, Map.get(root, "__nav"))}
  end

  def handle_event(
        "save_oauth_client",
        %{"provider" => provider, "oauth_client_form" => params},
        socket
      )
      when provider in @oauth_client_providers do
    current = current_oauth_provider(socket, provider)

    opts = [
      client_id: present_or(params["client_id"], Keyword.get(current, :client_id)),
      client_secret: present_or(params["client_secret"], Keyword.get(current, :client_secret)),
      redirect_port:
        parse_int(
          params["redirect_port"],
          Keyword.get(current, :redirect_port, oauth_default_port(provider))
        )
    ]

    result = PluginConfig.set_oauth_provider(provider, opts)
    message = "#{oauth_display_name(provider)} OAuth client saved."
    {:noreply, save_oauth_client_result(result, socket, provider, message)}
  end

  # An unknown name is a not-yet-installed catalog plugin: pull it from the
  # plugin repo first (§11 install → enable), async so the page stays live.
  # Computer use is special-cased: it registers no tools, so it never enters the
  # plugin registry — enabling it means "ensure the sidecar binary, flip the
  # feature flag", not the generic install→register→enable path.
  # Computer-history is enabled through its app-picker modal (open_computer_history_apps),
  # never this generic handler — enabling it with no allowlist would be refused.
  def handle_event("plugin_enable", %{"name" => name}, socket) do
    if computer_use_plugin?(name) do
      {:noreply, enable_computer_use(socket)}
    else
      {:noreply, enable_registry_plugin(socket, name)}
    end
  end

  def handle_event("plugin_disable", %{"name" => name}, socket) do
    cond do
      computer_use_plugin?(name) -> {:noreply, set_computer_use_feature(socket, false)}
      computer_history_feature?(name) -> {:noreply, set_computer_history_feature(socket, false)}
      true -> {:noreply, disable_registry_plugin(socket, name)}
    end
  end

  # Raise the macOS Screen Recording + Accessibility prompts up front (registering the
  # sidecar bundle first) so the app appears in System Settings at enable time instead
  # of on the model's first screenshot. Re-probes after so the pane reflects reality.
  def handle_event("computer_use_grant", _params, socket) do
    {:noreply, request_computer_use_permissions(socket)}
  end

  # Computer-history's Accessibility grant (MILESTONE_32 §22.3) — the shared compux
  # driver, so the same TCC identity as computer-use.
  def handle_event("computer_history_grant", _params, socket) do
    {:noreply, request_computer_history_permissions(socket)}
  end

  # The app-allowlist picker (§22.7): Enable / Edit apps opens a modal listing the
  # host's installed apps; the operator checks the ones to record. Filter and toggles
  # are server-driven so the checked set survives searching. Save persists the selected
  # bundle ids and enables the feature in one act — an empty selection cannot be saved
  # (the Save button is disabled), since consent to capture nothing is not consent.
  def handle_event("open_computer_history_apps", _params, socket) do
    {:noreply, open_computer_history_picker(socket)}
  end

  def handle_event("computer_history_apps_filter", %{"q" => query}, socket) do
    {:noreply, update_computer_history_picker(socket, &%{&1 | query: query})}
  end

  def handle_event("toggle_computer_history_app", %{"bundle" => bundle}, socket) do
    {:noreply, update_computer_history_picker(socket, &toggle_picker_app(&1, bundle))}
  end

  def handle_event("close_computer_history_picker", _params, socket) do
    {:noreply, assign(socket, :computer_history_picker, nil)}
  end

  def handle_event("save_computer_history_apps", _params, socket) do
    {:noreply, save_computer_history_picker(socket)}
  end

  # The Meeting Notetaker config panel opens from the card's Configure button and
  # holds everything the removed Meetings tab did (the same mechanism the
  # computer-history app picker uses).
  def handle_event("open_meetings_config", _params, socket) do
    {:noreply, assign(socket, :meetings_config_open?, true)}
  end

  def handle_event("close_meetings_config", _params, socket) do
    {:noreply, assign(socket, :meetings_config_open?, false)}
  end

  # Meeting notetaker (M21 Phase 3) toggle. Both paths route through `save_meetings/3`,
  # which installs the meetbot sidecar on enable and asks for a restart (the tools are
  # boot-seeded). Only the `enabled` flag changes here; the rest of the config is
  # edited in the config panel.
  def handle_event("enable_meetings", _params, socket) do
    {:noreply, save_meetings(socket, [enabled: true], nil)}
  end

  # Opens the meetbot's headed browser so the operator signs the bot's Google
  # account in. A no-op while one is already running or if the sidecar isn't
  # installed yet (the button is disabled in that case — this is belt).
  def handle_event("meetbot_signin", _params, socket) do
    cond do
      installing?(socket.assigns.meetbot_signin) ->
        {:noreply, socket}

      not MeetbotInstaller.installed?() ->
        {:noreply, socket}

      true ->
        runner = meetbot_signin_runner()

        {:noreply,
         socket
         |> assign(:meetbot_signin, installing(@meetbot_signin_running_message))
         |> start_async(:meetbot_signin, runner)}
    end
  end

  def handle_event("disable_meetings", _params, socket) do
    {:noreply, save_meetings(socket, [enabled: false], nil)}
  end

  # The §4.4 Connect-time collection: the needs_config card form posts the
  # plugin's missing required manifest config entries.
  def handle_event(
        "save_plugin_config",
        %{"name" => name, "plugin_config_form" => params},
        socket
      ) do
    case save_plugin_settings(name, params) do
      :ok ->
        {:noreply, refresh_report(socket, "Plugin configuration saved.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Save failed: #{format_config_error(reason)}")}
    end
  end

  def handle_event("plugin_connect", %{"name" => name}, socket) do
    case PluginRegistry.find(name) do
      {:ok, plugin} -> {:noreply, start_plugin_auth_or_explain(socket, plugin)}
      :error -> {:noreply, flash_error(socket, "Plugin not found: #{name}")}
      {:error, reason} -> {:noreply, flash_error(socket, Redaction.format(reason))}
    end
  end

  # api_key plugins (M16): the card's secret form posts the keychained credential
  # (Discord bot token, AgentMail key). It is set, not redirected like OAuth.
  def handle_event(
        "set_plugin_secret",
        %{"name" => name, "plugin_secret_form" => %{"value" => value}},
        socket
      ) do
    case PluginConfig.set_plugin_secret(name, value) do
      {:ok, _snapshot} ->
        {:noreply, refresh_report(socket, "Plugin connected.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Save failed: #{Redaction.format(reason)}")}
    end
  end

  def handle_event("plugin_disconnect", %{"name" => name}, socket) do
    case disconnect_plugin(name) do
      :ok ->
        {:noreply, refresh_report(socket, "Plugin disconnected.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Disconnect failed: #{Redaction.format(reason)}")}
    end
  end

  def handle_event("plugin_check", %{"name" => name}, socket) do
    case PluginHealth.check(name) do
      {:ok, _result} ->
        {:noreply, flash_info(socket, "Plugin check passed.")}

      {:error, reason} ->
        {:noreply, flash_error(socket, "Plugin check failed: #{Redaction.format(reason)}")}
    end
  end

  # Open the OAuth-client modal on the credentials step (Connect on an
  # unconfigured provider, or Edit on a configured one — both land on :creds).
  def handle_event("open_oauth_modal", %{"provider" => provider}, socket)
      when provider in @oauth_client_providers do
    {:noreply, assign(socket, :oauth_modal, %{provider: provider, step: :creds})}
  end

  def handle_event("close_oauth_modal", _params, socket) do
    {:noreply, assign(socket, :oauth_modal, nil)}
  end

  # The M27 §7.5 step between "credential stored" and "ready": the operator picks
  # the access profile and the ONE resource the plugin will be scoped to.
  # Discovery is a network round trip, so it runs async and the picker opens on
  # its pending step — the pane never blocks on a hosted service.
  def handle_event("open_resource_picker", %{"name" => name}, socket) do
    case PluginRegistry.find(name) do
      {:ok, plugin} -> {:noreply, open_resource_picker(socket, plugin)}
      :error -> {:noreply, flash_error(socket, "Plugin not found: #{name}")}
      {:error, reason} -> {:noreply, flash_error(socket, Redaction.format(reason))}
    end
  end

  def handle_event("close_resource_picker", _params, socket) do
    {:noreply, assign(socket, :resource_picker, nil)}
  end

  # Selecting a non-default profile is a deliberate act, never a side effect of
  # picking a workspace: the card states what the profile widens before the
  # operator can commit it (§8.1).
  def handle_event("pick_access_profile", %{"profile" => profile}, socket) do
    {:noreply, put_picker_profile(socket, profile)}
  end

  def handle_event("select_workspace", %{"id" => id, "label" => label}, socket) do
    {:noreply, commit_workspace(socket, id, label)}
  end

  def handle_event("save_memory", %{"memory_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:compaction_threshold, params["compaction_threshold"])
      |> maybe_put_string(:review_interval_hours, params["review_interval_hours"])

    {:noreply, save_answers(socket, answers, "Memory saved.", Map.get(root, "__nav"))}
  end

  def handle_event("save_sandbox", %{"sandbox_form" => params} = root, socket) do
    current = socket.assigns.sandbox_form
    mode = parse_sandbox_mode(Map.get(params, "mode"), current.mode)
    profile = parse_sandbox_profile(Map.get(params, "profile"), current.profile)
    env_allow = parse_env_allow(Map.get(params, "env_allow", ""))

    result = Wizard.set_sandbox_overrides(mode, profile, env_allow)

    {:noreply,
     save_result(result, socket, "Sandbox saved.", Map.get(root, "__nav"),
       restart_required?: true
     )}
  end

  def handle_event("save_personalization", %{"personalization_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:bot_name, params["bot_name"])
      |> maybe_put_string(:user_name, params["user_name"])
      |> maybe_put_string(:timezone, params["timezone"])
      |> maybe_put_string(:communication_style, params["communication_style"])
      |> maybe_put_skill_curation_enabled(params)

    {:noreply,
     save_answers(socket, answers, "Personalization saved.", Map.get(root, "__nav"),
       restart_required?: runtime_restart_answers?(answers)
     )}
  end

  # The Coding Agents tab: consent (`approved`) + the default-vendor selector,
  # both routed through the same `[fermix_core.harness]` wizard reducers the
  # personalization card used before this tab existed.
  def handle_event("save_coding", %{"coding_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_harness_vendor(params)
      |> maybe_put_harness_approved(params)

    {:noreply,
     save_answers(socket, answers, "Coding agents saved.", Map.get(root, "__nav"),
       restart_required?: runtime_restart_answers?(answers)
     )}
  end

  def handle_event("run_doctor", _params, socket) do
    if socket.assigns.doctor_probe_running? do
      {:noreply, socket}
    else
      {:noreply, start_doctor_probe(socket)}
    end
  end

  def handle_event("apply_restart", _params, socket) do
    if Service.supervised?() do
      Process.send_after(self(), :perform_restart, 600)
      # Stamp the current tab into the URL so the post-restart reconnect lands
      # here instead of next_action_tab bouncing the operator to a partial tab.
      # push_patch keeps this process alive so :perform_restart still fires.
      {:noreply,
       socket
       |> assign(:restarting, true)
       |> push_patch(to: ~p"/setup?#{[tab: socket.assigns.active_tab]}")}
    else
      {:noreply,
       flash_error(
         socket,
         "Nothing to restart from here — no OS-supervised Fermix service is running this process. " <>
           "In dev, stop and re-run `mix fermix.dev`; an installed service restarts itself from this button."
       )}
    end
  end

  @impl true
  def handle_info({:codex_auth_url, url}, socket) do
    Process.send_after(self(), {:clear_codex_auth_url, url}, plugin_auth_url_timeout_ms())

    {:noreply,
     socket
     |> assign(:codex_auth_url, url)
     |> flash_info("Opening ChatGPT sign-in.")
     |> push_event("codex-auth-open", %{url: url})}
  end

  def handle_info({:clear_codex_auth_url, url}, socket) do
    {:noreply, maybe_clear_codex_auth_url(socket, url)}
  end

  def handle_info({:xai_auth_url, url}, socket) do
    Process.send_after(self(), {:clear_xai_auth_url, url}, plugin_auth_url_timeout_ms())

    {:noreply,
     socket
     |> assign(:xai_auth_url, url)
     |> flash_info("Opening Grok sign-in.")
     |> push_event("xai-auth-open", %{url: url})}
  end

  def handle_info({:clear_xai_auth_url, url}, socket) do
    {:noreply, maybe_clear_xai_auth_url(socket, url)}
  end

  def handle_info({:plugin_auth_url, name, url}, socket) do
    auth_url = %{name: name, display_name: plugin_display_name(name), url: url}
    Process.send_after(self(), {:clear_plugin_auth_url, name, url}, plugin_auth_url_timeout_ms())

    {:noreply,
     socket
     |> assign(:plugin_auth_url, auth_url)
     |> flash_info("Opening #{auth_url.display_name} sign-in.")
     |> push_event("plugin-auth-open", %{url: url})}
  end

  def handle_info({:clear_plugin_auth_url, name, url}, socket) do
    {:noreply, maybe_clear_plugin_auth_url(socket, name, url)}
  end

  def handle_info({:local_install_progress, event}, socket) do
    {:noreply, assign(socket, :local_install, installing(local_progress_message(event)))}
  end

  def handle_info({ref, result}, socket) when is_reference(ref) do
    {:noreply, finish_task(socket, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    {:noreply, fail_task(socket, ref, reason)}
  end

  def handle_info(:perform_restart, socket) do
    # Supervised release only (gated in apply_restart): exit non-zero so the OS
    # supervisor relaunches the daemon — launchd KeepAlive on any exit, systemd
    # Restart=on-failure on non-zero. The LiveView reconnects once it is back.
    System.stop(1)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:doctor_provider_probe, {:ok, result}, socket) do
    {:noreply, finish_doctor_provider_probe(socket, result)}
  end

  def handle_async(:doctor_provider_probe, {:exit, reason}, socket) do
    result = {:error, {:network, reason}}
    {:noreply, finish_doctor_provider_probe(socket, result)}
  end

  def handle_async({:doctor_channel_probe, channel}, {:ok, result}, socket) do
    {:noreply, finish_doctor_channel_probe(socket, channel, result)}
  end

  def handle_async({:doctor_channel_probe, channel}, {:exit, reason}, socket) do
    result = failed_channel_probe(socket, channel, reason)
    {:noreply, finish_doctor_channel_probe(socket, channel, result)}
  end

  def handle_async({:resource_discovery, name}, {:ok, result}, socket) do
    {:noreply, finish_resource_discovery(socket, name, result)}
  end

  def handle_async({:resource_discovery, name}, {:exit, reason}, socket) do
    {:noreply, finish_resource_discovery(socket, name, {:error, reason})}
  end

  def handle_async({:resource_selection, name}, {:ok, result}, socket) do
    {:noreply, finish_workspace_selection(socket, name, result)}
  end

  def handle_async({:resource_selection, name}, {:exit, reason}, socket) do
    {:noreply, finish_workspace_selection(socket, name, {:error, reason})}
  end

  # Re-read only the readiness line: rebuilding the whole report here would
  # throw away the backend the operator just picked but has not saved yet.
  def handle_async(:local_install, {:ok, :ok}, socket) do
    form = %{socket.assigns.transcription_form | local_state: LocalTranscription.configured?([])}

    {:noreply,
     socket
     |> assign(:local_install, done(@local_ready_message))
     |> assign(:transcription_form, form)}
  end

  def handle_async(:local_install, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :local_install, failed(local_install_error(reason)))}
  end

  def handle_async(:local_install, {:exit, reason}, socket) do
    {:noreply, assign(socket, :local_install, failed(local_install_error(reason)))}
  end

  def handle_async(:meetbot_install, {:ok, {:ok, _path}}, socket) do
    form = %{socket.assigns.meetings_form | sidecar_installed?: MeetbotInstaller.installed?()}

    {:noreply,
     socket
     |> assign(:meetbot_install, done(@meetbot_ready_message))
     |> assign(:meetings_form, form)}
  end

  def handle_async(:meetbot_install, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :meetbot_install, failed(meetbot_install_error(reason)))}
  end

  def handle_async(:meetbot_install, {:exit, reason}, socket) do
    {:noreply, assign(socket, :meetbot_install, failed(meetbot_install_error(reason)))}
  end

  def handle_async(:meetbot_signin, {:ok, {:ok, :signed_in}}, socket) do
    # The flow returning :signed_in IS the truth (it wrote the marker itself);
    # reflect it without re-reading, so the readiness pill flips immediately.
    form = %{socket.assigns.meetings_form | signed_in?: true}

    {:noreply,
     socket
     |> assign(:meetbot_signin, done(@meetbot_signin_done_message))
     |> assign(:meetings_form, form)}
  end

  def handle_async(:meetbot_signin, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :meetbot_signin, failed(meetbot_signin_error(reason)))}
  end

  def handle_async(:meetbot_signin, {:exit, reason}, socket) do
    {:noreply, assign(socket, :meetbot_signin, failed(meetbot_signin_error(reason)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Components.page
      active_tab={@active_tab}
      channels_form={@channels_form}
      doctor_result={@doctor_result}
      memory_form={@memory_form}
      personalization_form={@personalization_form}
      harness_setup={@harness_setup}
      codex_auth={@codex_auth}
      codex_auth_running?={codex_auth_running?(@codex_auth_tasks)}
      codex_auth_url={@codex_auth_url}
      xai_auth={@xai_auth}
      xai_auth_running?={xai_auth_running?(@xai_auth_tasks)}
      xai_auth_url={@xai_auth_url}
      anthropic_auth={@anthropic_auth}
      anthropic_import_available?={@anthropic_import_available?}
      doctor_probe_running?={@doctor_probe_running?}
      provider_form={@provider_form}
      provider_models={@provider_models}
      live_models={@live_models}
      provider_statuses={@provider_statuses}
      plugin_auth_url={@plugin_auth_url}
      plugin_summary={@plugin_summary}
      oauth_modal={@oauth_modal}
      resource_picker={@resource_picker}
      computer_history_picker={@computer_history_picker}
      installing_plugins={plugin_install_names(@plugin_install_tasks)}
      realtime_form={@realtime_form}
      report={@report}
      restart_pending?={@restart_pending?}
      restarting={@restarting}
      sandbox_form={@sandbox_form}
      search_form={@search_form}
      image_form={@image_form}
      transcription_form={@transcription_form}
      local_install={@local_install}
      meetings_form={@meetings_form}
      meetbot_install={@meetbot_install}
      meetbot_signin={@meetbot_signin}
      meetings_config_open?={@meetings_config_open?}
      saved_flash={@saved_flash}
      skill_summary={@skill_summary}
      tabs={@tabs}
      tool_summary={@tool_summary}
    />
    """
  end

  defp assign_report(socket, report) do
    snapshot = report.wizard.config_snapshot
    provider_form = build_provider_form(snapshot)

    socket
    |> assign(:report, report)
    |> assign(:tabs, @tabs)
    |> assign(:provider_form, provider_form)
    |> assign_model_sources(provider_form)
    |> assign(:provider_statuses, build_provider_statuses(snapshot))
    |> assign(:codex_auth, codex_auth_summary())
    |> assign(:xai_auth, xai_auth_summary())
    |> assign(:anthropic_auth, anthropic_auth_summary())
    |> assign(:anthropic_import_available?, anthropic_import_available?(snapshot))
    |> assign(:realtime_form, build_realtime_form(snapshot))
    |> assign(:channels_form, build_channels_form(snapshot))
    |> assign(:search_form, build_search_form(snapshot))
    |> assign(:image_form, build_image_form(snapshot))
    |> assign(:transcription_form, build_transcription_form(snapshot))
    |> assign(:meetings_form, build_meetings_form(snapshot))
    |> assign(:sandbox_form, build_sandbox_form(snapshot))
    |> assign(:memory_form, build_memory_form(snapshot))
    |> assign(:personalization_form, build_personalization_form(snapshot))
    |> assign(:harness_setup, build_harness_setup(snapshot))
    |> assign(:tool_summary, tool_summary())
    |> assign(:skill_summary, skill_summary())
    |> assign(:plugin_summary, plugin_summary(snapshot))
  end

  defp save_answers(socket, answers, message, nav, opts \\ []) do
    socket.assigns.report.wizard
    |> Wizard.save_answers(answers)
    |> save_result(socket, message, nav, opts)
  end

  defp save_result({:ok, report}, socket, message, nav, opts) do
    restart_required? = Keyword.get(opts, :restart_required?, false)

    socket
    |> assign_report(report)
    |> assign(:restart_pending?, socket.assigns.restart_pending? or restart_required?)
    |> flash_info(message, restart_required?: restart_required?)
    |> maybe_advance(nav)
  end

  defp save_result({:error, reason}, socket, _message, _nav, _opts) do
    flash_error(socket, "Save failed: #{format_config_error(reason)}")
  end

  defp save_config_result({:ok, _snapshot}, socket, message), do: refresh_report(socket, message)

  defp save_config_result({:error, reason}, socket, _message) do
    flash_error(socket, "Save failed: #{format_config_error(reason)}")
  end

  # save_oauth_client's own {:ok}/{:error} handling, kept out of the shared
  # save_config_result/3: on success advance the open modal to its sign-in
  # confirmation step (modal stays open); on failure leave it on :creds.
  defp save_oauth_client_result({:ok, _snapshot} = result, socket, provider, message) do
    socket
    |> assign(:oauth_modal, %{provider: provider, step: :signin})
    |> then(&save_config_result(result, &1, message))
  end

  defp save_oauth_client_result({:error, _reason} = result, socket, _provider, message) do
    save_config_result(result, socket, message)
  end

  defp format_config_error({:missing_oauth_client_field, provider, :client_id})
       when provider in @oauth_client_providers do
    "#{oauth_display_name(provider)} OAuth Client ID is required."
  end

  defp format_config_error({:missing_oauth_client_field, provider, :client_secret})
       when provider in @oauth_client_providers do
    "#{oauth_display_name(provider)} OAuth Client secret is required."
  end

  defp format_config_error({:unknown_config_key, key}),
    do: "#{key} is not a config key this plugin declares."

  defp format_config_error({:blank_config_value, key}), do: "#{key} requires a value."

  defp format_config_error(reason), do: Redaction.format(reason)

  # One commit per key — the form carries only the missing required entries,
  # typically one (e.g. a vault path). Any failure halts and surfaces loud.
  defp save_plugin_settings(name, params) when is_map(params) do
    Enum.reduce_while(params, :ok, fn {key, value}, :ok ->
      case PluginConfig.set_plugin_setting(name, key, value) do
        {:ok, _snapshot} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp oauth_display_name("google"), do: "Google"
  defp oauth_display_name("github"), do: "GitHub"
  defp oauth_display_name("notion"), do: "Notion"
  defp oauth_display_name("x"), do: "X"
  defp oauth_display_name("slack"), do: "Slack"

  defp oauth_default_port("google"), do: 1455
  defp oauth_default_port("github"), do: 1457
  defp oauth_default_port("notion"), do: 1458
  defp oauth_default_port("x"), do: 1459
  defp oauth_default_port("slack"), do: 1460

  defp refresh_report(socket, message, opts \\ []) do
    Wizard.report()
    |> then(&assign_report(socket, &1))
    |> flash_info(message, opts)
  end

  defp flash_info(socket, message, opts \\ []) do
    assign(socket, :saved_flash, %{
      kind: :info,
      message: message,
      restart_required?: Keyword.get(opts, :restart_required?, false)
    })
  end

  defp flash_error(socket, message),
    do: assign(socket, :saved_flash, %{kind: :error, message: message})

  defp runtime_restart_answers?(answers) do
    restart_keys =
      @provider_restart_keys ++
        @realtime_restart_keys ++
        @channel_restart_keys ++
        @harness_restart_keys ++
        @skill_curation_restart_keys

    Enum.any?(answers, fn {key, _value} -> key in restart_keys end)
  end

  defp start_doctor_probe(socket) do
    opts = doctor_probe_opts()
    channels = Doctor.channel_probe_specs()
    pending = doctor_probe_pending(channels)

    socket
    |> assign(:doctor_result, running_doctor_result(channels))
    |> assign(:doctor_probe_pending, pending)
    |> assign(:doctor_probe_running?, true)
    |> start_async(:doctor_provider_probe, fn -> Doctor.probe_active(opts) end)
    |> start_channel_probes(channels, opts)
  end

  defp doctor_probe_opts do
    Application.get_env(:fermix_web, :doctor_probe_opts, [])
  end

  defp doctor_probe_pending(channels) do
    channel_keys = Enum.map(channels, &{:channel, &1.config_key})
    MapSet.new([:provider | channel_keys])
  end

  defp running_doctor_result(channels) do
    %{
      provider: :running,
      channels: Enum.map(channels, &running_channel_probe/1),
      auth_tokens: auth_tokens_result(),
      computer_use: computer_use_permissions_result()
    }
  end

  # Computer-use OS-permission state — same definition as the CLI `fermix doctor`
  # `computer use` check (FermixCore.Setup.Doctor.computer_use_permissions/0). Only
  # the enabled+installed case spawns the sidecar to probe; off/uninstalled resolve
  # cheaply, so this stays on the synchronous up-front path like the token check.
  defp computer_use_permissions_result do
    case Doctor.computer_use_permissions() do
      {:ok, %{state: :disabled}} ->
        %{status: :ok, grant?: false, detail: "Off — computer use is disabled."}

      {:ok, %{state: :not_installed}} ->
        %{status: :warn, grant?: false, detail: "Enabled, but the helper isn't installed yet."}

      {:ok, %{state: :probed} = probe} ->
        computer_use_probe_detail(probe)

      {:error, reason} ->
        %{
          status: :error,
          grant?: false,
          detail: "Couldn't probe the helper: #{Redaction.format(reason)}"
        }
    end
  end

  # `grant?` drives the "Grant macOS permissions" button — offered only on macOS when
  # a grant is actually missing (the prompt is a no-op elsewhere).
  defp computer_use_probe_detail(%{screen_capture: true, input_control: true}) do
    %{status: :ok, grant?: false, detail: "Screen capture and input control are granted."}
  end

  defp computer_use_probe_detail(%{screen_capture: true, input_control: false} = probe) do
    %{
      status: :warn,
      grant?: macos_probe?(probe),
      detail:
        "Input control isn't granted — clicks and keystrokes are silently dropped. " <>
          "On macOS, grant Accessibility in System Settings → Privacy & Security."
    }
  end

  defp computer_use_probe_detail(%{screen_capture: false} = probe) do
    %{
      status: :warn,
      grant?: macos_probe?(probe),
      detail:
        "Screen capture isn't granted. On macOS, grant Screen Recording in " <>
          "System Settings → Privacy & Security."
    }
  end

  defp macos_probe?(%{platform: "macos"}), do: true
  defp macos_probe?(_probe), do: false

  # The token-freshness check is offline and instant, so it resolves up front
  # alongside the running provider/channel probes rather than going through the
  # async flow. Same definition of "stale" as the per-provider badge and the CLI
  # `fermix doctor` (FermixCore.Setup.Doctor.stale_token_profiles/0).
  defp auth_tokens_result do
    case Doctor.stale_token_profiles() do
      {:ok, []} ->
        %{status: :ok, detail: "All stored tokens are fresh."}

      {:ok, names} ->
        %{status: :warn, detail: "Reconnect needed: #{Enum.join(names, ", ")}"}

      {:error, reason} ->
        %{status: :error, detail: "Couldn't read the auth store: #{Redaction.format(reason)}"}
    end
  end

  defp running_channel_probe(%{config_key: key, name: name}) do
    %{channel: key, name: name, status: :running, detail: "Probe running..."}
  end

  defp start_channel_probes(socket, channels, opts) do
    Enum.reduce(channels, socket, fn channel, acc ->
      name = {:doctor_channel_probe, channel.config_key}
      start_async(acc, name, fn -> Doctor.probe_channel(channel, opts) end)
    end)
  end

  defp finish_doctor_provider_probe(socket, result) do
    socket
    |> put_doctor_provider_result(result)
    |> mark_doctor_probe_done(:provider)
  end

  defp finish_doctor_channel_probe(socket, channel, result) do
    socket
    |> put_doctor_channel_result(channel, result)
    |> mark_doctor_probe_done({:channel, channel})
  end

  defp put_doctor_provider_result(socket, result) do
    doctor_result = socket.assigns.doctor_result || %{provider: nil, channels: nil}
    assign(socket, :doctor_result, Map.put(doctor_result, :provider, result))
  end

  defp put_doctor_channel_result(socket, channel, result) do
    doctor_result = socket.assigns.doctor_result || %{provider: nil, channels: []}
    channels = Enum.map(doctor_result.channels || [], &replace_channel_probe(&1, channel, result))
    assign(socket, :doctor_result, Map.put(doctor_result, :channels, channels))
  end

  defp replace_channel_probe(%{channel: channel}, channel, result), do: result
  defp replace_channel_probe(probe, _channel, _result), do: probe

  defp mark_doctor_probe_done(socket, key) do
    pending = MapSet.delete(socket.assigns.doctor_probe_pending, key)

    socket
    |> assign(:doctor_probe_pending, pending)
    |> assign(:doctor_probe_running?, MapSet.size(pending) > 0)
  end

  defp failed_channel_probe(socket, channel, reason) do
    %{
      channel: channel,
      name: channel_probe_name(socket, channel),
      status: :error,
      detail: "probe failed: #{Redaction.format(reason)}"
    }
  end

  defp channel_probe_name(socket, channel) do
    socket.assigns.doctor_result
    |> Map.get(:channels, [])
    |> Enum.find(%{name: Atom.to_string(channel)}, &(&1.channel == channel))
    |> Map.fetch!(:name)
  end

  defp maybe_advance(socket, "next") do
    assign(socket, :active_tab, next_tab(socket.assigns.active_tab))
  end

  defp maybe_advance(socket, _nav), do: socket

  defp edited_provider_form(current, params) do
    %{
      provider: current.provider,
      default_model: present_or(Map.get(params, "default_model"), current.default_model),
      # "" (same as main) is a meaningful selection — keep it, don't fall back.
      subagent_model: Map.get(params, "subagent_model", current.subagent_model),
      reasoning_effort:
        parse_effort_field(Map.get(params, "reasoning_effort"), current.reasoning_effort),
      fast: parse_fast_field(Map.get(params, "fast"), current.fast),
      auth_mode: parse_auth_mode_field(Map.get(params, "auth_mode"), current.auth_mode),
      # Carry the plain setup fields (e.g. Ollama's base_url) across an in-place
      # edit; without this the re-render drops them and the input blanks out,
      # risking a saved value being wiped on the next submit (M12 §6.2).
      field_values: edited_field_values(current, params)
    }
  end

  defp edited_field_values(current, params) do
    Map.new(current.field_values || %{}, fn {key, prior} ->
      {key, present_or(Map.get(params, Atom.to_string(key)), prior)}
    end)
  end

  defp build_provider_form(snapshot),
    do: build_provider_form(snapshot, current_provider(snapshot))

  defp build_provider_form(snapshot, provider) do
    provider_block = provider_block(snapshot, provider)

    %{
      provider: provider,
      default_model:
        Keyword.get(provider_block, :default_model) || ModelCatalog.default_model_for(provider),
      subagent_model: routing_subagent_model(snapshot),
      reasoning_effort: Keyword.get(provider_block, :reasoning_effort, default_effort(provider)),
      fast: Keyword.get(provider_block, :fast, false),
      auth_mode: Keyword.get(provider_block, :auth_mode, :api_key),
      field_values: plain_field_values(provider, provider_block)
    }
  end

  # Saved values (or descriptor defaults) for the provider's non-secret
  # setup fields — e.g. Ollama's base_url (M12 §6.2).
  defp plain_field_values(provider, provider_block) do
    for field <- Descriptor.fetch!(provider).setup_fields, not field.secret?, into: %{} do
      {field.key, Keyword.get(provider_block, field.config_key) || field.default}
    end
  end

  # nil = "same as main model"; lives in [fermix_core.routing], not the provider
  # block (docs/design/SUBAGENT_MODEL_SELECTION.md §7c).
  defp routing_subagent_model(snapshot) do
    snapshot
    |> get_fermix_core(:routing)
    |> Keyword.get(:subagent_model)
  end

  defp build_provider_statuses(snapshot) do
    primary = current_provider(snapshot)

    Enum.map(ModelCatalog.providers(), fn provider ->
      block = provider_block(snapshot, provider)

      %{
        provider: provider,
        configured?: Selection.configured?(provider, block),
        primary?: provider == primary,
        model: Keyword.get(block, :default_model) || ModelCatalog.default_model_for(provider)
      }
    end)
  end

  # Anthropic has no `:none` (its floor is `:low`); its API default is high, so
  # the form pre-selects high. Other providers default to :none (omit the field).
  defp default_effort(:anthropic), do: :high
  defp default_effort(_provider), do: :none

  defp build_realtime_form(snapshot) do
    config = snapshot |> get_fermix_core(:realtime) |> RealtimeConfig.normalize()

    %{
      enabled: config.enabled?,
      model: config.model,
      models: RealtimeConfig.valid_models(),
      reasoning_effort: config.reasoning_effort,
      reasoning_efforts: RealtimeConfig.valid_reasoning_efforts(),
      voice: config.voice,
      voices: RealtimeConfig.valid_voices(),
      max_session_minutes: config.max_session_minutes,
      max_cost_cents: config.max_estimated_cost_cents_per_session,
      persist_transcripts: config.persist_transcripts?,
      api_key_set: api_key_configured?(snapshot)
    }
  end

  defp build_channels_form(snapshot) do
    channels = Map.get(snapshot, :fermix_channels, [])

    %{
      editing: :telegram,
      telegram: telegram_form(channels),
      whatsapp: whatsapp_form(channels),
      discord: discord_form(channels),
      slack: slack_form(channels),
      signal: signal_form(channels),
      acp: acp_form(channels)
    }
  end

  defp telegram_form(channels) do
    config = Keyword.get(channels, :telegram, [])

    %{
      enabled: channel_enabled?(config, true),
      bot_token_set: secret_set?(config, :bot_token),
      owner_user_id: safe_string(Keyword.get(config, :owner_user_id))
    }
  end

  defp whatsapp_form(channels) do
    config = Keyword.get(channels, :whatsapp, [])

    %{
      enabled: channel_enabled?(config, false),
      access_token_set: secret_set?(config, :access_token),
      phone_number_id: safe_string(Keyword.get(config, :phone_number_id)),
      verify_token_set: secret_set?(config, :verify_token),
      app_secret_set: secret_set?(config, :app_secret),
      owner_user_id: safe_string(Keyword.get(config, :owner_user_id))
    }
  end

  defp discord_form(channels) do
    config = Keyword.get(channels, :discord, [])

    %{
      enabled: channel_enabled?(config, false),
      bot_token_set: secret_set?(config, :bot_token),
      bot_user_id: safe_string(Keyword.get(config, :bot_user_id)),
      owner_user_id: safe_string(Keyword.get(config, :owner_user_id))
    }
  end

  defp slack_form(channels) do
    config = Keyword.get(channels, :slack, [])

    %{
      enabled: channel_enabled?(config, false),
      bot_token_set: secret_set?(config, :bot_token),
      signing_secret_set: secret_set?(config, :signing_secret),
      owner_user_id: safe_string(Keyword.get(config, :owner_user_id))
    }
  end

  defp signal_form(channels) do
    config = Keyword.get(channels, :signal, [])

    %{
      enabled: channel_enabled?(config, false),
      account: safe_string(Keyword.get(config, :account)),
      owner_user_id: safe_string(Keyword.get(config, :owner_user_id))
    }
  end

  # ACP carries no credential and no owner id — the toggle is the whole form.
  # The default mirrors config/config.exs: an install whose TOML predates the
  # surface has no acp section, and the toggle must show the surface as it is
  # actually running rather than offering to turn off something already on.
  defp acp_form(channels) do
    %{enabled: channel_enabled?(Keyword.get(channels, :acp, []), true)}
  end

  defp build_sandbox_form(snapshot) do
    sandbox = snapshot |> Map.get(:sandbox) |> SandboxConfig.normalize()

    %{
      mode: sandbox.mode,
      profile: sandbox.commands.profile,
      env_allow: Enum.join(sandbox.env.allow, "\n")
    }
  end

  defp build_search_form(snapshot) do
    web_search =
      snapshot
      |> get_fermix_core(:tools)
      |> Keyword.get(:web_search, [])

    %{
      backend: normalize_search_backend(Keyword.get(web_search, :backend)),
      tavily_api_key_set: secret_set?(web_search, :tavily_api_key),
      exa_api_key_set: secret_set?(web_search, :exa_api_key),
      parallel_api_key_set: secret_set?(web_search, :parallel_api_key),
      brave_api_key_set: secret_set?(web_search, :brave_api_key),
      perplexity_api_key_set: secret_set?(web_search, :perplexity_api_key),
      firecrawl_api_key_set: secret_set?(web_search, :firecrawl_api_key)
    }
  end

  defp build_image_form(snapshot) do
    generate_image =
      snapshot
      |> get_fermix_core(:tools)
      |> Keyword.get(:generate_image, [])

    backend = normalize_image_backend(Keyword.get(generate_image, :backend))
    [default | _rest] = options = image_models_for(backend)

    %{
      backend: backend,
      model_options: options,
      model: image_model_or_default(Keyword.get(generate_image, :model), options, default),
      openai_api_key_set: provider_api_key_set?(snapshot, :openai),
      xai_api_key_set: provider_api_key_set?(snapshot, :xai),
      google_api_key_set: secret_set?(generate_image, :google_api_key),
      codex_connected: codex_auth_summary().connected?
    }
  end

  # A backend switch resets the model to the new backend's default (a model from
  # the prior backend is invalid here); a same-backend change keeps the selected
  # model, snapped to a valid option.
  defp update_image_selection(form, backend, _model) when backend != form.backend do
    [default | _rest] = options = image_models_for(backend)
    %{form | backend: backend, model_options: options, model: default}
  end

  defp update_image_selection(form, backend, model) do
    [default | _rest] = form.model_options
    %{form | backend: backend, model: image_model_or_default(model, form.model_options, default)}
  end

  # Curated model ids ship with each backend; `normalize_image_backend/1`
  # guarantees a wired backend, so a `{:error, _}` here is a broken invariant —
  # fail loud (Rule #12), never silently degrade to an empty dropdown.
  defp image_models_for(backend) do
    {:ok, models} = MediaRegistry.supported_models(:image, Atom.to_string(backend))
    models
  end

  defp image_model_or_default(configured, options, default) do
    case to_string(configured || "") do
      "" -> default
      model -> if model in options, do: model, else: default
    end
  end

  defp provider_api_key_set?(snapshot, provider) do
    snapshot
    |> get_fermix_core(:providers)
    |> Keyword.get(provider, [])
    |> Keyword.get(:api_key)
    |> present?()
  end

  defp build_transcription_form(snapshot) do
    transcription = get_fermix_core(snapshot, :transcription)
    backend = normalize_transcription_backend(Keyword.get(transcription, :backend))
    options = transcription_models_for(backend)

    %{
      backend: backend,
      model_options: options,
      model: transcription_model_for_options(Keyword.get(transcription, :model), options),
      local_state: LocalTranscription.configured?([]),
      openai_api_key_set: secret_set?(transcription, :openai_api_key),
      xai_api_key_set: secret_set?(transcription, :xai_api_key),
      deepgram_api_key_set: secret_set?(transcription, :deepgram_api_key)
    }
  end

  # A backend switch resets the model to the new backend's default (the prior
  # backend's model is invalid on a single shared `model` key); a same-backend
  # change keeps the selected model, snapped to a valid option. A modelless
  # backend (xai, local) carries an empty option list and a `nil` model — the
  # card hides the model field.
  defp update_transcription_selection(form, backend, _model) when backend != form.backend do
    options = transcription_models_for(backend)
    %{form | backend: backend, model_options: options, model: default_model_for_options(options)}
  end

  defp update_transcription_selection(form, backend, model) do
    %{form | backend: backend, model: transcription_model_for_options(model, form.model_options)}
  end

  # `normalize_transcription_backend/1` guarantees a shipped backend, so a
  # `{:error, _}` here is a broken invariant — fail loud (Rule #12), never
  # silently degrade to an empty dropdown. A modelless backend (xai) resolves to
  # `{:ok, []}` — a known backend with no selectable model, not an error.
  defp transcription_models_for(backend) do
    {:ok, models} = TranscriptionRegistry.supported_models(Atom.to_string(backend))
    models
  end

  defp default_model_for_options([]), do: nil
  defp default_model_for_options([default | _rest]), do: default

  defp transcription_model_for_options(_configured, []), do: nil

  defp transcription_model_for_options(configured, [default | _rest] = options),
    do: transcription_model_or_default(configured, options, default)

  defp transcription_model_or_default(configured, options, default) do
    case to_string(configured || "") do
      "" -> default
      model -> if model in options, do: model, else: default
    end
  end

  # `transcription_backend` is a NAME string, blank meaning "whatever the
  # Transcription tab is set to" — so the picker offers a blank entry alongside
  # the shipped backend names rather than repeating the global default here.
  defp build_meetings_form(snapshot) do
    meetings = get_fermix_core(snapshot, :meetings)

    %{
      enabled: Keyword.get(meetings, :enabled, false) == true,
      bot_name: safe_string(Keyword.get(meetings, :bot_name, "Fermix Notetaker")),
      announce: Keyword.get(meetings, :announce, true) == true,
      announce_message: safe_string(Keyword.get(meetings, :announce_message)),
      transcription_backend:
        normalize_meetings_backend(Keyword.get(meetings, :transcription_backend)),
      backend_options: meetings_backend_options(),
      zoom_account_id: safe_string(Keyword.get(meetings, :zoom_account_id)),
      zoom_client_id: safe_string(Keyword.get(meetings, :zoom_client_id)),
      zoom_ws_subscription_id: safe_string(Keyword.get(meetings, :zoom_ws_subscription_id)),
      zoom_client_secret_set: secret_set?(meetings, :zoom_client_secret),
      sidecar_installed?: MeetbotInstaller.installed?(),
      signed_in?: MeetbotInstaller.signed_in?()
    }
  end

  defp meetings_backend_options do
    ["" | Enum.map(TranscriptionRegistry.backends(), fn {name, _module} -> to_string(name) end)]
  end

  # The picker only ever offers the shipped names plus the blank global-default
  # entry, so anything else off the wire is normalized back to the blank.
  defp normalize_meetings_backend(value) do
    name = safe_string(value)
    if name in meetings_backend_options(), do: name, else: ""
  end

  # `[fermix_core.meetings]` is written as a section rather than through wizard
  # answers: save then apply, the same two steps Wizard.commit_snapshot performs,
  # so the keyring securing in save_snapshot/1 still owns the Zoom secret.
  defp save_meetings(socket, changes, nav) do
    snapshot = ConfigStore.current_snapshot()
    meetings = snapshot |> get_fermix_core(:meetings) |> Keyword.merge(changes)
    updated = put_fermix_core(snapshot, :meetings, meetings)
    restart? = meetings_restart_required?(MeetingsConfig.load(), changes)

    case ConfigStore.save_snapshot(updated) do
      :ok ->
        :ok = ConfigStore.apply_snapshot(updated)

        socket
        |> assign(:restart_pending?, socket.assigns.restart_pending? or restart?)
        |> refresh_report(meetings_saved_message(restart?), restart_required?: restart?)
        |> maybe_install_meetbot(Keyword.fetch!(changes, :enabled))
        |> maybe_advance(nav)

      {:error, reason} ->
        flash_error(socket, "Save failed: #{format_config_error(reason)}")
    end
  end

  defp meetings_saved_message(true), do: "Meetings saved — restart to apply."
  defp meetings_saved_message(false), do: "Meetings saved."

  # The meetings tools are registered once, at boot, from `Meetings.ready?/0`
  # (enabled plus either the notetaker binary or the full Zoom credential set),
  # so a change to any of those keys only reaches the model after a restart —
  # the same boot-seeded gate the computer-use save asks a restart for. The
  # remaining keys (bot name, announcement, backend) are read per meeting. The
  # comparison runs against the loaded config so an unset key reads as its
  # default rather than as a change.
  defp meetings_restart_required?(%MeetingsConfig{} = previous, changes) do
    Enum.any?(@meetings_restart_keys, fn key ->
      Keyword.has_key?(changes, key) and Keyword.get(changes, key) != Map.fetch!(previous, key)
    end)
  end

  defp put_fermix_core(snapshot, key, value) do
    fermix_core = snapshot |> Map.get(:fermix_core, []) |> Keyword.put(key, value)
    Map.put(snapshot, :fermix_core, fermix_core)
  end

  # Enabling meetings is what fetches the Meet notetaker binary — the Zoom RTMS
  # lane needs no sidecar, so a refusal here never blocks the save.
  defp maybe_install_meetbot(socket, false), do: socket

  defp maybe_install_meetbot(socket, true) do
    cond do
      MeetbotInstaller.installed?() ->
        assign(socket, :meetbot_install, done(@meetbot_ready_message))

      installing?(socket.assigns.meetbot_install) ->
        socket

      true ->
        start_meetbot_install(socket)
    end
  end

  defp start_meetbot_install(socket) do
    install = meetbot_installer()

    socket
    |> assign(:meetbot_install, installing(@meetbot_installing_message))
    |> start_async(:meetbot_install, install)
  end

  # Injectable so a LiveView test never reaches the network (mirrors the
  # `:plugin_auth_runner` seam). Defaults to the real pinned download.
  defp meetbot_installer do
    Application.get_env(:fermix_web, :meetbot_installer, &MeetbotInstaller.install/0)
  end

  defp meetbot_install_error(:no_pinned_release),
    do: MeetbotInstaller.error_message(:no_pinned_release)

  defp meetbot_install_error({:unsupported_target, target}),
    do: "No meeting notetaker build for this machine (#{target})."

  defp meetbot_install_error(reason),
    do: "Meeting notetaker install failed: #{Redaction.format(reason)}"

  # Injectable so a LiveView test never launches a real browser (mirrors the
  # `:meetbot_installer` seam). Defaults to the real headed sign-in flow.
  defp meetbot_signin_runner do
    Application.get_env(:fermix_web, :meetbot_signin_runner, &SignIn.run/0)
  end

  defp meetbot_signin_error(:cancelled), do: @meetbot_signin_cancelled_message
  defp meetbot_signin_error(:timeout), do: @meetbot_signin_timeout_message

  defp meetbot_signin_error(:not_installed),
    do: "Enable the meeting notetaker first — it installs the sidecar the sign-in needs."

  defp meetbot_signin_error(reason),
    do: "Sign-in failed: #{Redaction.format(reason)}"

  # Choosing the on-device backend is the install trigger (§2b: nothing downloads
  # at boot, and hand-editing config.toml installs nothing). Already-installed
  # selects say so instead of re-running the installer.
  defp maybe_install_local_stt(socket, previous, :local) when previous != :local do
    cond do
      LocalTranscription.configured?([]) == :ok ->
        assign(socket, :local_install, done(@local_ready_message))

      installing?(socket.assigns.local_install) ->
        socket

      true ->
        start_local_install(socket)
    end
  end

  defp maybe_install_local_stt(socket, _previous, _backend), do: socket

  defp start_local_install(socket) do
    parent = self()
    install = local_installer()

    socket
    |> assign(:local_install, installing(@local_installing_message))
    |> start_async(:local_install, fn ->
      install.(progress: fn event -> send(parent, {:local_install_progress, event}) end)
    end)
  end

  # Injectable so a LiveView test never reaches the network, and so both
  # fail-loud refusals (`:no_release_pinned`, `:model_pins_missing`) can be
  # rendered without a half-installed host.
  defp local_installer do
    Application.get_env(:fermix_web, :local_installer, &LocalTranscription.ensure_installed/1)
  end

  defp local_progress_message({:sidecar, :downloading}), do: "Downloading the speech engine…"

  defp local_progress_message({:sidecar, :done}),
    do: "Speech engine installed. Fetching the model…"

  defp local_progress_message({:model, :downloading}), do: "Downloading the speech model…"
  defp local_progress_message({:model, :verifying}), do: "Verifying the speech model…"
  defp local_progress_message({:model, :done}), do: @local_ready_message

  defp local_install_error(:no_release_pinned),
    do: LocalSttInstaller.error_message(:no_release_pinned)

  defp local_install_error(:model_pins_missing),
    do: LocalModelStore.error_message(:model_pins_missing)

  defp local_install_error({:unsupported_target, target}),
    do: "No on-device speech build for this machine (#{target})."

  defp local_install_error(reason),
    do: "On-device speech install failed: #{Redaction.format(reason)}"

  defp installing(message), do: %{kind: :info, running?: true, message: message}
  defp done(message), do: %{kind: :info, running?: false, message: message}
  defp failed(message), do: %{kind: :error, running?: false, message: message}

  defp installing?(%{running?: true}), do: true
  defp installing?(_state), do: false

  defp build_memory_form(snapshot) do
    compaction = snapshot |> get_fermix_core(:compaction) |> CompactionConfig.normalize()
    memory = get_fermix_core(snapshot, :memory)

    %{
      compaction_threshold: safe_string(CompactionConfig.threshold(compaction)),
      review_interval_hours: safe_string(Keyword.get(memory, :review_interval_hours, 24))
    }
  end

  # The harness card (design §7.4): detected vendor CLIs + their network-free
  # auth state, plus the configured default_vendor. The detector is a `:fermix_web`
  # test seam (like `:doctor_probe_opts`): production defaults to the real
  # `Vendors.detect_all/0` (which probes each CLI's `--version` in a subprocess and
  # reads `~/.codex`/`~/.claude`), while `config/test.exs` overrides it with an
  # inert stub so `mix test` never spawns a vendor CLI or touches host auth.
  defp build_harness_setup(snapshot) do
    detections =
      harness_detector().()
      |> Map.values()
      |> Enum.sort_by(& &1.vendor)

    harness = get_fermix_core(snapshot, :harness)

    %{
      vendors: detections,
      both_detected?: length(detections) >= 2 and Enum.all?(detections, & &1.available?),
      default_vendor: Keyword.get(harness, :default_vendor),
      approved: Keyword.get(harness, :approved, false)
    }
  end

  defp harness_detector do
    Application.get_env(:fermix_web, :harness_detector, &HarnessVendors.detect_all/0)
  end

  defp build_personalization_form(snapshot) do
    personalization = get_fermix_core(snapshot, :personalization)

    %{
      # The bot's name is identity (the agent block), surfaced here so the field
      # shows the current name; blank on save keeps it.
      bot_name: snapshot |> get_fermix_core(:agent) |> Keyword.get(:name, ""),
      user_name: Keyword.get(personalization, :user_name, ""),
      # Default to New York so the form is never blank; the agent reads this
      # (via Application env) to stamp each turn with the current local date.
      timezone: Keyword.get(personalization, :timezone, "America/New_York"),
      communication_style: Keyword.get(personalization, :communication_style, ""),
      skill_curation_enabled:
        snapshot |> get_fermix_core(:skill_curation) |> Keyword.get(:enabled, true),
      skill_curation_destination: skill_curation_destination()
    }
  end

  # Names where proposals will actually arrive (§6.1) — the same ladder the
  # delivery pass uses, pure config reads.
  defp skill_curation_destination do
    case SkillCurationDelivery.resolve_target() do
      {:ok, target} -> "Proposals arrive in #{target.platform}."
      :no_delivery_target -> "Proposals wait in /skills proposals until a channel owner is set."
    end
  end

  defp tool_summary do
    if Process.whereis(CapabilityRegistry) do
      tools = CapabilityRegistry.list(CapabilityRegistry, kind: :builtin, include_hidden?: true)

      %{
        available: true,
        count: length(tools),
        hidden_count: Enum.count(tools, & &1.hidden_from_agent?),
        policy_counts: Enum.frequencies_by(tools, & &1.policy_class),
        web_search: Enum.any?(tools, &(&1.name == "web_search"))
      }
    else
      empty_tool_summary()
    end
  end

  defp empty_tool_summary do
    %{available: false, count: 0, hidden_count: 0, policy_counts: %{}, web_search: false}
  end

  defp skill_summary do
    if Process.whereis(SkillRegistry) do
      skills = SkillRegistry.list_detailed()

      %{
        available: true,
        count: length(skills),
        operator_count: Enum.count(skills, &(&1.trust == :operator)),
        guest_count: Enum.count(skills, &(&1.trust == :guest)),
        names: skills |> Enum.map(& &1.name) |> Enum.take(6)
      }
    else
      empty_skill_summary()
    end
  end

  defp empty_skill_summary do
    %{available: false, count: 0, operator_count: 0, guest_count: 0, names: []}
  end

  # The card grid is the §6 union: installed plugins (registry) plus the
  # not-yet-installed remainder of the distribution index as catalog cards.
  defp plugin_summary(snapshot) do
    case PluginCatalog.overview(plugins_dist_opts()) do
      {:ok, overview} ->
        # Core-feature cards (computer-use, computer-history) render in their own
        # "Native driver features" section (§22.6), NOT mixed with the integration
        # catalog — so drop computer-use from BOTH the installed and catalog lists
        # (it moves between them by sidecar-install state) and surface both there.
        plugins =
          overview
          |> installed_cards(snapshot)
          |> Enum.reject(&computer_use_plugin?(&1.name))

        catalog =
          overview.available
          |> Enum.reject(&computer_use_plugin?(&1.name))
          |> Enum.map(&catalog_card(&1, snapshot))

        %{
          available: true,
          oauth_clients: oauth_client_forms(snapshot, plugins ++ catalog),
          plugins: plugins,
          catalog: catalog,
          core_features: core_feature_cards(snapshot),
          index_error: format_index_error(overview.index_error)
        }

      {:error, reason} ->
        %{
          available: false,
          error: Redaction.format(reason),
          oauth_clients: %{},
          plugins: [],
          catalog: [],
          core_features: core_feature_cards(snapshot),
          index_error: nil
        }
    end
  end

  # The native-driver features: capabilities that run on a bundled sidecar rather
  # than a plugin, presented together so their toggles sit in one place instead of
  # scattered across tabs. Computer-history is macOS-only (`ComputerHistory.macos?/0`,
  # where its AXObserver capture runs); the speech and meeting notetakers install
  # their sidecar on enable and refuse loud until a release is pinned.
  defp core_feature_cards(snapshot) do
    [computer_use_card(snapshot)] ++
      if(ComputerHistory.macos?(), do: [computer_history_card(snapshot)], else: []) ++
      [meetings_card(snapshot)]
  end

  # Meeting notetaker (M21 Phase 3): enabling installs the meetbot sidecar and flips
  # the boot-seeded tool gate (hence the restart). Detailed config — bot name,
  # announcement, Zoom RTMS credentials — opens in the card's Configure panel.
  defp meetings_card(snapshot) do
    {enabled?, status} = meetings_card_state(snapshot)

    %{
      kind: :meetings,
      name: "meetings",
      display_name: "Meeting Notetaker",
      description: "Joins Google Meet or Zoom on your ask and summarizes it.",
      tooltip:
        "Fermix joins a Google Meet as a named bot — or a Zoom meeting over RTMS — transcribes " <>
          "it, and delivers the notes. Operator-only, off by default.",
      docs_url: "https://fermix.ai/docs/meetings/",
      enabled?: enabled?,
      status: status,
      version: nil,
      logo: @meetings_logo_uri,
      app_count: 0
    }
  end

  defp meetings_card_state(snapshot) do
    cond do
      not meetings_config_enabled?(snapshot) -> {false, :not_configured}
      Meetings.ready?() -> {true, :ready}
      true -> {true, :partial}
    end
  end

  defp meetings_config_enabled?(snapshot) do
    snapshot
    |> get_fermix_core(:meetings)
    |> Keyword.get(:enabled, false) == true
  end

  # Computer-use as a core-feature card (same clean shape as computer_history_card),
  # so both render through one component in the dedicated section.
  defp computer_use_card(snapshot) do
    {enabled?, status} = computer_use_card_state(snapshot)

    %{
      kind: :computer_use,
      name: SidecarInstaller.plugin_name(),
      display_name: "Computer Use",
      description: "Let Fermix drive the screen — click, type, and navigate apps.",
      tooltip:
        "Fermix sees your screen and controls the mouse and keyboard in the apps you drive. " <>
          "Operator-only, off by default.",
      docs_url: "https://fermix.ai/docs/computer-use/",
      enabled?: enabled?,
      status: status,
      version: compux_version(),
      logo: @computer_use_logo_uri,
      app_count: 0
    }
  end

  # The shared compux driver version (both features run on it). `Application.spec/2`
  # returns nil when compux isn't loaded — keep the nil so the card drops the version
  # rather than rendering a bare "v".
  defp compux_version do
    case Application.spec(:compux, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp installed_cards(overview, snapshot) do
    Enum.map(overview.installed, &plugin_card(&1, snapshot, overview.yanked_installed))
  end

  defp format_index_error(nil), do: nil
  defp format_index_error(reason), do: Redaction.format(reason)

  defp plugin_card(plugin, snapshot, yanked_installed) do
    {enabled?, status} = plugin_card_state(plugin, snapshot)

    %{
      name: plugin.name,
      display_name: card_display_name(plugin.name, plugin.display_name),
      description: plugin.description,
      category: plugin.category,
      provider: Map.get(plugin.auth, :provider),
      logo: plugin_card_logo(plugin),
      auth_type: plugin.auth.type,
      secret_prompt: Map.get(plugin.auth, :prompt),
      account: PluginStatus.account_label(plugin),
      enabled?: enabled?,
      status: status,
      checkable?: not computer_use_plugin?(plugin.name),
      # Manifest data, not a plugin name: a `resource_scope` is what earns the
      # card its workspace step (M27 §8.1).
      resource_scope?: plugin.resource_scope != nil,
      missing_config: missing_config_entries(plugin),
      yanked_version: Map.get(yanked_installed, plugin.name)
    }
  end

  # Computer use is config-gated (`[fermix_core.computer_use]`), not a registry
  # `enabled_plugins` entry, and it never registers as a plugin (no tools). Its card
  # mirrors the catalog card's flags instead of the generic registry status, which
  # would read `:not_configured` + "Enable" for an already-on feature. `checkable?` is
  # false for it too: the registry health check requires `Status.status == :ready`,
  # which a config-gated sidecar never reaches, so the Check button would mislead.
  defp plugin_card_state(plugin, snapshot) do
    if computer_use_plugin?(plugin.name) do
      computer_use_card_state(snapshot)
    else
      {plugin.name in enabled_plugins(snapshot), PluginStatus.status(plugin)}
    end
  end

  defp computer_use_card_state(snapshot) do
    cond do
      not computer_use_config_enabled?(snapshot) -> {false, :not_configured}
      ComputerUse.ready?() -> {true, :ready}
      true -> {true, :partial}
    end
  end

  # The card's config form (§4.4): one input per missing required manifest
  # config entry, labelled with the manifest prompt.
  defp missing_config_entries(plugin) do
    configured = PluginConfig.plugin_settings(plugin.name)

    plugin.config
    |> Enum.filter(&(&1.required and not Map.has_key?(configured, &1.key)))
    |> Enum.map(&Map.take(&1, [:key, :prompt]))
  end

  # A not-yet-installed catalog entry: branding straight from the index (§6 —
  # no artifact on disk yet, so the logo is the index's inline data URI).
  defp catalog_card(entry, snapshot) do
    %{
      name: entry.name,
      display_name: card_display_name(entry.name, entry.display_name),
      description: entry.description,
      category: entry.category,
      auth_type: entry.auth_type,
      provider: entry.provider,
      logo: catalog_card_logo(entry),
      latest: card_latest(entry),
      mcp?: "mcp" in entry.rails,
      # M27 §12 Stage 2: the index's additive runtime disclosure drives the
      # card's pre-install consent copy. `nil` on every pre-M27 entry.
      runtime_kind: entry.runtime_kind,
      compat: entry.compat,
      # Until its sidecar installs, computer use shows here as a catalog entry; the
      # config flag can already be on (enabled, then the binary removed), so reflect
      # its real state (Disable + Ready/Needs setup) instead of a bare "Enable".
      # Once installed it moves to the installed list and renders via plugin_card,
      # which mirrors these flags. False for every other catalog entry.
      enabled?: computer_use_plugin?(entry.name) and computer_use_config_enabled?(snapshot),
      ready?: computer_use_plugin?(entry.name) and ComputerUse.ready?()
    }
  end

  # The sidecar ships via the pinned compux release, not the plugin catalog;
  # the catalog entry predates that move, so its version is core-owned like
  # the card's name and logo. `Application.spec/2` returns nil when compux is
  # not loaded — keep that nil rather than collapsing it to `to_string(nil)`
  # ("", which the card's `:if={@entry.latest}` guard treats as truthy and
  # renders as a bare "v") so the version simply drops instead.
  defp card_latest(entry) do
    if computer_use_plugin?(entry.name) do
      case Application.spec(:compux, :vsn) do
        nil -> nil
        vsn -> to_string(vsn)
      end
    else
      entry.latest
    end
  end

  defp computer_use_config_enabled?(snapshot) do
    snapshot
    |> get_fermix_core(:computer_use)
    |> Keyword.get(:enabled, false) == true
  end

  defp index_logo_data_uri(%{"mime" => mime, "data_base64" => data}),
    do: "data:#{mime};base64,#{data}"

  defp index_logo_data_uri(_logo), do: nil

  defp plugin_asset_data_uri(plugin, key) do
    plugin.interface
    |> Map.get(key)
    |> asset_data_uri(Path.dirname(plugin.path))
  end

  # Computer use carries no plugin-supplied branding (toolless sidecar), so the
  # card name + logo are core-owned: "Computer Use" (not "…Sidecar") and the
  # bundled blue-monitor mark, on both the installed and not-yet-installed cards.
  defp card_display_name(name, fallback) do
    if computer_use_plugin?(name), do: "Computer Use", else: fallback
  end

  defp plugin_card_logo(plugin) do
    if computer_use_plugin?(plugin.name) do
      @computer_use_logo_uri
    else
      plugin_asset_data_uri(plugin, "logo") || plugin_asset_data_uri(plugin, "icon")
    end
  end

  defp catalog_card_logo(entry) do
    if computer_use_plugin?(entry.name) do
      @computer_use_logo_uri
    else
      index_logo_data_uri(entry.logo)
    end
  end

  defp asset_data_uri(nil, _plugin_dir), do: nil

  defp asset_data_uri(rel_path, plugin_dir) when is_binary(rel_path) do
    path = Path.join(plugin_dir, rel_path)
    mime = asset_mime!(Path.extname(path))

    "data:#{mime};base64,#{Base.encode64(File.read!(path))}"
  end

  defp asset_mime!(".png"), do: "image/png"
  defp asset_mime!(".svg"), do: "image/svg+xml"
  defp asset_mime!(ext), do: raise(ArgumentError, "unsupported plugin asset type: #{ext}")

  defp enabled_plugins(snapshot) do
    snapshot
    |> get_fermix_core(:plugins)
    |> Keyword.get(:enabled, [])
  end

  # One client form per distinct oauth2 provider among the installed ∪ catalog
  # cards (both shapes carry an atom `auth_type` and a `provider`), so the
  # client can be saved before its plugin is installed; Google's is always
  # present (its plugins ship bundled).
  defp oauth_client_forms(snapshot, cards) do
    cards
    |> Enum.filter(&(&1.auth_type == :oauth2 and &1.provider in @oauth_client_providers))
    |> Enum.map(& &1.provider)
    |> Kernel.++(["google"])
    |> Enum.uniq()
    |> Map.new(fn provider -> {provider, oauth_client_form(snapshot, provider)} end)
  end

  defp oauth_client_form(snapshot, provider) do
    config = snapshot |> get_fermix_core(:oauth) |> oauth_provider(provider)

    %{
      provider: provider,
      display_name: oauth_display_name(provider),
      client_id: Keyword.get(config, :client_id, ""),
      client_secret_set: Keyword.get(config, :client_secret) |> present?(),
      redirect_port: Keyword.get(config, :redirect_port, oauth_default_port(provider))
    }
  end

  defp current_oauth_provider(socket, provider) do
    socket.assigns.report.wizard.config_snapshot
    |> get_fermix_core(:oauth)
    |> oauth_provider(provider)
  end

  defp oauth_provider(oauth, provider) when is_map(oauth), do: Map.get(oauth, provider, [])

  defp oauth_provider(oauth, provider) when is_list(oauth) do
    Enum.find_value(oauth, [], fn {key, value} ->
      if to_string(key) == provider, do: value
    end)
  end

  defp oauth_provider(_oauth, _provider), do: []

  # OAuth plugins log out (clear the token store); api_key plugins forget their
  # credential — the OS-keychain item is deleted and only then is the config
  # reference dropped — returning to `:needs_secret`. Neither revokes anything
  # upstream; the operator must do that with the provider.
  defp disconnect_plugin(name) do
    case PluginRegistry.find(name) do
      {:ok, %{auth: %{type: :api_key}}} -> forget_plugin_secret(name)
      _other -> PluginAuth.logout(name)
    end
  end

  defp forget_plugin_secret(name) do
    case PluginConfig.forget_plugin_secret(name) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- resource picker (M27 §7.5 steps 3–7) -------------------------------

  # Discovery is a network round trip to a hosted service, so it runs async and
  # the picker opens on its pending step: the pane must stay live even when the
  # remote is slow or unreachable.
  defp open_resource_picker(socket, plugin) do
    socket
    |> assign(:resource_picker, new_picker(plugin))
    |> start_async({:resource_discovery, plugin.name}, fn ->
      RemoteSetup.discover_workspaces(plugin, remote_setup_opts())
    end)
  end

  # `Plugins.RemoteSetup`'s own seams (transport, MCP supervisor), forwarded
  # verbatim so this flow is exercisable without a socket or a live MCP tree.
  # Empty in production, exactly like `:computer_use_grant_impl`.
  defp remote_setup_opts, do: Application.get_env(:fermix_web, :remote_setup_opts, [])

  # Every word the picker renders comes from the manifest — profile names, their
  # display names, and which of them widens the credential's scope. No plugin
  # name appears in any conditional here or in the component, so a second plugin
  # declaring a `resource_scope` gets this step for free.
  defp new_picker(plugin) do
    %{
      plugin: plugin.name,
      display_name: plugin.display_name,
      step: :pending,
      profile: default_profile_name(plugin),
      profiles: profile_options(plugin),
      resources: [],
      error: nil
    }
  end

  defp profile_options(plugin) do
    Enum.map(plugin.tool_profiles, fn profile ->
      %{
        name: Map.get(profile, "name"),
        display_name: Map.get(profile, "display_name"),
        default?: Map.get(profile, "default") == true,
        write?: Map.get(profile, "required_credential_scope") == "write"
      }
    end)
  end

  defp default_profile_name(plugin) do
    plugin.tool_profiles
    |> Enum.find(%{}, &(Map.get(&1, "default") == true))
    |> Map.get("name")
  end

  # A late answer for a picker the operator already closed, or for a different
  # plugin, is dropped rather than rendered over the current one.
  defp finish_resource_discovery(socket, name, result) do
    case socket.assigns.resource_picker do
      %{plugin: ^name} = picker -> assign(socket, :resource_picker, settle_picker(picker, result))
      _closed_or_replaced -> socket
    end
  end

  defp settle_picker(picker, {:ok, resources}),
    do: %{picker | step: :choose, resources: resources, error: nil}

  defp settle_picker(picker, {:error, reason}),
    do: %{picker | step: :error, resources: [], error: setup_error(reason)}

  # Redacted like every other reason in this pane, and then bounded: a crashed
  # discovery task exits with a term that can carry a whole stacktrace, and a
  # modal is not a log viewer. The classified prefix is the part that names the
  # failure; the daemon log keeps the rest.
  defp setup_error(reason) do
    reason
    |> Redaction.format()
    |> String.slice(0, 200)
  end

  defp put_picker_profile(socket, profile) do
    case socket.assigns.resource_picker do
      %{profiles: profiles} = picker -> pick_profile(socket, picker, profiles, profile)
      nil -> socket
    end
  end

  defp pick_profile(socket, picker, profiles, profile) do
    if Enum.any?(profiles, &(&1.name == profile)),
      do: assign(socket, :resource_picker, %{picker | profile: profile}),
      else: flash_error(socket, "Unknown access profile: #{profile}")
  end

  defp commit_workspace(socket, id, label) do
    case socket.assigns.resource_picker do
      nil -> socket
      picker -> start_workspace_selection(socket, picker, id, label)
    end
  end

  # Selection is ASYNC for the same reason discovery is: it stops the old
  # client, persists, restarts, and then waits for the replacement to reach
  # `:ready` — up to the 60s remote startup budget. Run inline in the event
  # handler it blocks the LiveView process, so the operator sees no spinner, no
  # error, and no re-render until it returns: a click that appears to do
  # nothing. The in-flight step is what makes the wait legible.
  defp start_workspace_selection(socket, picker, id, label) do
    case fetch_plugin(picker.plugin) do
      {:ok, plugin} ->
        opts = selection_opts(picker, id, label)

        socket
        |> assign(:resource_picker, %{picker | step: :selecting, error: nil})
        |> start_async({:resource_selection, picker.plugin}, fn ->
          RemoteSetup.select_workspace(plugin, opts)
        end)

      {:error, reason} ->
        assign(socket, :resource_picker, %{picker | step: :error, error: setup_error(reason)})
    end
  end

  # Success means the replacement client reached `:ready` — authenticated and
  # contract-checked — not that a config value was written.
  defp finish_workspace_selection(socket, name, result) do
    case socket.assigns.resource_picker do
      %{plugin: ^name} = picker -> settle_selection(socket, picker, result)
      _closed_or_replaced -> socket
    end
  end

  defp settle_selection(socket, _picker, :ok) do
    socket
    |> assign(:resource_picker, nil)
    |> refresh_report("Workspace selected.")
  end

  # Back to `:choose`, not `:error`: the workspace list is still valid and the
  # operator's next move is to retry or pick another one. `:error` is for a
  # discovery that produced no list at all.
  defp settle_selection(socket, picker, {:error, reason}) do
    assign(socket, :resource_picker, %{picker | step: :choose, error: setup_error(reason)})
  end

  defp selection_opts(picker, id, label) do
    [access_profile: picker.profile, workspace_id: id, workspace_label: label] ++
      remote_setup_opts()
  end

  defp fetch_plugin(name) do
    case PluginRegistry.find(name) do
      {:ok, plugin} -> {:ok, plugin}
      :error -> {:error, {:unknown_plugin, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enable_or_connect_plugin(socket, %{auth: %{type: :oauth2}} = plugin) do
    start_plugin_auth_or_explain(socket, plugin)
  end

  defp enable_or_connect_plugin(socket, plugin) do
    case PluginConfig.enable(plugin.name) do
      {:ok, _snapshot} -> refresh_report(socket, "Plugin enabled.")
      {:error, reason} -> flash_error(socket, "Save failed: #{Redaction.format(reason)}")
    end
  end

  defp enable_registry_plugin(socket, name) do
    case PluginRegistry.find(name) do
      {:ok, plugin} -> enable_or_connect_plugin(socket, plugin)
      :error -> install_catalog_plugin(socket, name)
      {:error, reason} -> flash_error(socket, "Save failed: #{Redaction.format(reason)}")
    end
  end

  defp disable_registry_plugin(socket, name) do
    name
    |> PluginConfig.disable()
    |> save_config_result(socket, "Plugin disabled.")
  end

  # Computer use is NOT a registry plugin (it registers no tools, has no plugin.json),
  # so it never flows through find→enable. Enabling it = ensure the native sidecar
  # binary is present, then flip the feature flag. A dev_local build (or an already
  # downloaded binary) means `installed?` is already true → skip the fetch and just
  # flip the flag. Otherwise a fresh machine downloads the sidecar via the compux
  # library (`install_work`); `continue_after_install/2` flips the flag once it lands.
  defp enable_computer_use(socket) do
    if SidecarInstaller.installed?() do
      set_computer_use_feature(socket, true)
    else
      install_catalog_plugin(socket, SidecarInstaller.plugin_name())
    end
  end

  # Flips `[fermix_core.computer_use] enabled` so `ComputerUse.ready?/0` (tool
  # registration + the session supervisor) turns on/off. Re-reads the freshly
  # committed config first so a prior write isn't clobbered, then commits the
  # feature flag and asks for a restart (the accepted save+restart UX).
  defp set_computer_use_feature(socket, enabled?) do
    message =
      if enabled?,
        do: "Computer Use enabled — restart to apply.",
        else: "Computer Use disabled — restart to apply."

    socket
    |> assign_report(Wizard.report())
    |> save_answers([computer_use_enabled: enabled?], message, nil, restart_required?: true)
  end

  # Spawns the sidecar (as its own signed TCC identity) to raise the OS grant
  # dialogs, then refreshes the report so the permission pane re-probes. The prompts
  # are async, so a fresh grant may only show on the next probe.
  defp request_computer_use_permissions(socket) do
    case computer_use_grant_impl().() do
      {:ok, %{screen_capture: true, input_control: true}} ->
        refresh_report(socket, "macOS permissions granted.")

      {:ok, _partial} ->
        refresh_report(
          socket,
          "Approve the Screen Recording and Accessibility prompts, then the next " <>
            "computer-use action will use them."
        )

      {:error, reason} ->
        flash_error(socket, "Couldn't open the permission prompts: #{Redaction.format(reason)}")
    end
  end

  # Injectable so a LiveView test never fires a real OS permission dialog (mirrors the
  # `:plugin_auth_runner` seam). Defaults to the real prompt.
  defp computer_use_grant_impl do
    Application.get_env(:fermix_web, :computer_use_grant_impl, &ComputerUse.request_permissions/0)
  end

  defp computer_use_plugin?(name), do: name == SidecarInstaller.plugin_name()

  # --- computer history (MILESTONE_32 §22.3, a native-driver feature, macOS-only) ---

  @computer_history_name "computer_history"

  defp computer_history_feature?(name), do: name == @computer_history_name

  # Enable = ensure the SHARED compux sidecar, then flip the flag. Independent of
  # computer-use: this card installs the sidecar itself if computer-use has not.
  defp enable_computer_history(socket, extra_answers) do
    if SidecarInstaller.installed?() do
      set_computer_history_feature(socket, true, extra_answers)
    else
      # Sidecar missing: persist the chosen apps and install the shared driver; the
      # operator re-enables from the card once the async install finishes (mirrors
      # computer-use). Flipping enabled before the driver exists would only refuse
      # at runtime. Both steps set a flash, so state one accurate message last —
      # otherwise the generic "Downloading the Computer Use helper…" install flash
      # wins and names the wrong feature.
      socket
      |> persist_computer_history_answers(extra_answers)
      |> install_catalog_plugin(SidecarInstaller.plugin_name())
      |> flash_info(
        "Apps saved. Installing the capture driver — enable Computer History again once it finishes."
      )
    end
  end

  defp set_computer_history_feature(socket, enabled?, extra_answers \\ []) do
    message =
      if enabled?,
        do: "Computer History enabled — restart to apply.",
        else: "Computer History disabled — restart to apply."

    socket
    |> assign_report(Wizard.report())
    |> save_answers(
      [computer_history_enabled: enabled?] ++ extra_answers,
      message,
      nil,
      restart_required?: true
    )
  end

  defp persist_computer_history_answers(socket, []), do: socket

  defp persist_computer_history_answers(socket, answers) do
    save_answers(
      socket,
      answers,
      "App selection saved — finish installing the driver, then enable.",
      nil,
      restart_required?: false
    )
  end

  # Capture needs only the Accessibility grant (via the shared compux driver, so the
  # same TCC identity as computer-use). The prompt is async, so a fresh grant may
  # only show on the next probe.
  defp request_computer_history_permissions(socket) do
    case ComputerHistory.request_permissions() do
      {:ok, %{input_control: true}} ->
        refresh_report(socket, "Accessibility granted.")

      {:ok, _partial} ->
        refresh_report(
          socket,
          "Approve the Accessibility prompt, then restart to start capturing."
        )

      {:error, reason} ->
        flash_error(socket, "Couldn't open the Accessibility prompt: #{Redaction.format(reason)}")
    end
  end

  defp computer_history_card_state(snapshot) do
    cond do
      not computer_history_config_enabled?(snapshot) -> {false, :not_configured}
      ComputerHistory.operative?() and SidecarInstaller.installed?() -> {true, :ready}
      true -> {true, :partial}
    end
  end

  defp computer_history_config_enabled?(snapshot) do
    snapshot
    |> get_fermix_core(:computer_history)
    |> Keyword.get(:enabled, false) == true
  end

  # The card's data. Rendered ONLY on macOS (`ComputerHistory.macos?/0`); the
  # `apps` allowlist round-trips as a comma-separated string for a single clean
  # input, and the disclosure names the resolved summarizer provider (§22.4).
  defp computer_history_card(snapshot) do
    {enabled?, status} = computer_history_card_state(snapshot)
    config = get_fermix_core(snapshot, :computer_history)

    %{
      kind: :computer_history,
      name: @computer_history_name,
      display_name: "Computer History",
      description: "Passive activity memory from the apps you allow.",
      tooltip:
        "Opt-in activity memory from the apps you allow — titles, URLs, and typed text; " <>
          "passwords and secure fields are never captured. Summarized off-device by " <>
          "#{computer_history_summarizer_label()}; off by default.",
      docs_url: "https://fermix.ai/docs/computer-history/",
      enabled?: enabled?,
      status: status,
      version: compux_version(),
      logo: @computer_history_logo_uri,
      app_count: length(Keyword.get(config, :apps, []))
    }
  end

  # --- app-allowlist picker (§22.7) --------------------------------------

  defp open_computer_history_picker(socket) do
    config =
      socket.assigns.report.wizard.config_snapshot
      |> get_fermix_core(:computer_history)

    selected = config |> Keyword.get(:apps, []) |> MapSet.new()

    picker = %{
      apps: installed_apps_impl().(),
      selected: selected,
      query: "",
      save_label: computer_history_save_label(config)
    }

    assign(socket, :computer_history_picker, picker)
  end

  # Honest about what Save does: it flips the flag only when already enabled (edit) or
  # when the shared driver is present; with the driver missing it saves + installs and
  # the operator enables on a second pass, so don't promise "enable".
  defp computer_history_save_label(config) do
    cond do
      ComputerHistoryConfig.enabled?(config) -> "Save"
      SidecarInstaller.installed?() -> "Save & enable"
      true -> "Save & install driver"
    end
  end

  # Injectable so tests supply a fixed app list instead of scanning the host.
  defp installed_apps_impl,
    do: Application.get_env(:fermix_web, :installed_apps_impl, &InstalledApps.list/0)

  defp update_computer_history_picker(socket, fun) do
    case socket.assigns.computer_history_picker do
      nil -> socket
      picker -> assign(socket, :computer_history_picker, fun.(picker))
    end
  end

  defp toggle_picker_app(picker, bundle) do
    selected =
      if MapSet.member?(picker.selected, bundle),
        do: MapSet.delete(picker.selected, bundle),
        else: MapSet.put(picker.selected, bundle)

    %{picker | selected: selected}
  end

  defp save_computer_history_picker(%{assigns: %{computer_history_picker: nil}} = socket),
    do: socket

  defp save_computer_history_picker(socket) do
    apps = socket.assigns.computer_history_picker.selected |> MapSet.to_list() |> Enum.sort()

    if apps == [] do
      flash_error(socket, "Pick at least one app before enabling Computer History.")
    else
      socket
      |> assign(:computer_history_picker, nil)
      |> enable_computer_history(computer_history_apps: Enum.join(apps, ", "))
    end
  end

  # The model summarization runs on — the subagent tier (provider + model), shown
  # on the card so the operator sees exactly which model reads their activity (§22.3).
  defp computer_history_summarizer_label do
    provider =
      case ComputerHistoryConfig.default_summarizer_provider() do
        {:ok, p} -> to_string(p)
        {:error, _reason} -> "your default provider"
      end

    case Keyword.get(ComputerHistoryConfig.default_summarizer_route_opts(), :model) do
      nil -> provider
      model -> "#{provider} · #{model}"
    end
  end

  defp start_plugin_auth_or_explain(socket, plugin) do
    cond do
      missing_plugin_client_config?(plugin) ->
        provider = oauth_display_name(plugin.auth.provider)

        flash_error(
          socket,
          "Save a #{provider} OAuth client first, then connect #{plugin.display_name}."
        )

      plugin_auth_running?(socket, plugin.name) ->
        flash_info(socket, "#{plugin.display_name} sign-in is already open.")

      true ->
        start_plugin_auth(socket, plugin)
    end
  end

  defp start_plugin_auth(socket, plugin) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn ->
        plugin_auth_runner().(plugin.name,
          opener: plugin_auth_opener(parent, plugin.name),
          puts: fn _message -> :ok end
        )
      end)

    tasks = Map.put(socket.assigns.plugin_auth_tasks, task.ref, plugin_auth_task(plugin))

    socket
    |> assign(:plugin_auth_tasks, tasks)
    |> assign(:plugin_auth_url, nil)
    |> flash_info("Opening #{plugin.display_name} sign-in.")
  end

  defp plugin_auth_runner do
    Application.get_env(:fermix_web, :plugin_auth_runner, &PluginAuth.login/2)
  end

  defp plugin_auth_opener(parent, name) do
    fn url ->
      send(parent, {:plugin_auth_url, name, url})
      :ok
    end
  end

  defp plugin_auth_task(plugin), do: %{name: plugin.name, display_name: plugin.display_name}

  defp plugin_auth_running?(socket, name) do
    socket.assigns.plugin_auth_tasks
    |> Map.values()
    |> Enum.any?(&(&1.name == name))
  end

  defp finish_plugin_auth(socket, task, tasks, {:ok, _entry}) do
    socket
    |> assign(:plugin_auth_tasks, tasks)
    |> assign(:plugin_auth_url, nil)
    |> refresh_report("#{task.display_name} connected.")
  end

  defp finish_plugin_auth(socket, task, tasks, {:error, reason}) do
    fail_plugin_auth(socket, task, tasks, reason)
  end

  defp fail_plugin_auth(socket, task, tasks, reason) do
    socket
    |> assign(:plugin_auth_tasks, tasks)
    |> assign(:plugin_auth_url, nil)
    |> flash_error("#{task.display_name} sign-in failed: #{Redaction.format(reason)}")
  end

  defp maybe_clear_plugin_auth_url(socket, name, url) do
    case socket.assigns.plugin_auth_url do
      %{name: ^name, url: ^url} -> assign(socket, :plugin_auth_url, nil)
      _other -> socket
    end
  end

  defp plugin_auth_url_timeout_ms do
    case Application.get_env(:fermix_web, :plugin_auth_url_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_plugin_auth_url_timeout_ms
    end
  end

  defp missing_plugin_client_config?(%{auth: %{type: :oauth2, provider: provider}})
       when provider in @oauth_client_providers do
    config = PluginConfig.oauth_provider(provider)
    blank?(Keyword.get(config, :client_id)) or blank?(Keyword.get(config, :client_secret))
  end

  defp missing_plugin_client_config?(_plugin), do: false

  defp plugin_display_name(name) do
    case PluginRegistry.find(name) do
      {:ok, plugin} -> plugin.display_name
      _other -> name
    end
  end

  # --- catalog install (§11: enable on a not-installed card = install first) -

  defp install_catalog_plugin(socket, name) do
    if plugin_install_running?(socket, name) do
      flash_info(socket, "#{name} install is already running.")
    else
      start_plugin_install(socket, name)
    end
  end

  defp plugin_install_running?(socket, name) do
    socket.assigns.plugin_install_tasks
    |> Map.values()
    |> Enum.any?(&(&1.name == name))
  end

  defp start_plugin_install(socket, name) do
    {work, message} = install_work(name)
    task = Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, work)
    tasks = Map.put(socket.assigns.plugin_install_tasks, task.ref, %{name: name})

    socket
    |> assign(:plugin_install_tasks, tasks)
    |> flash_info(message)
  end

  # Computer-use installs its native helper via the compux library — a direct,
  # sha256-verified download of the compux release binary, NOT the signed plugin
  # catalog. Every other plugin uses the catalog pipeline. Both return the same
  # {:ok, _} | {:error, reason} shape, so the finish/continue machinery is shared.
  defp install_work(name) do
    if computer_use_plugin?(name) do
      {fn -> SidecarInstaller.install() end, "Downloading the Computer Use helper…"}
    else
      opts = plugins_dist_opts()

      {fn -> DistInstaller.run_install(name, opts) end,
       "Installing #{name} from the plugin catalog…"}
    end
  end

  defp finish_plugin_install(socket, task, tasks, {:ok, _status}) do
    socket
    |> assign(:plugin_install_tasks, tasks)
    |> continue_after_install(task.name)
  end

  defp finish_plugin_install(socket, task, tasks, {:error, reason}) do
    fail_plugin_install(socket, task, tasks, reason)
  end

  defp fail_plugin_install(socket, task, tasks, reason) do
    # Use the card's display name ("Computer Use"), not the raw registry name
    # ("computer_use_sidecar"), so the one place a user sees an error matches the
    # card they clicked.
    socket
    |> assign(:plugin_install_tasks, tasks)
    |> flash_error(
      "#{card_display_name(task.name, task.name)} install failed: #{install_error(reason)}"
    )
  end

  # Install done — continue with the same enable/connect sequence an installed
  # card uses. Config.commit hot-applies via Runtime.reload inside the daemon.
  # The computer-use sidecar never registers as a plugin (no tools), so after its
  # binary lands we flip the feature flag instead of looking it up in the registry.
  defp continue_after_install(socket, name) do
    if computer_use_plugin?(name) do
      set_computer_use_feature(socket, true)
    else
      continue_registry_plugin_after_install(socket, name)
    end
  end

  defp continue_registry_plugin_after_install(socket, name) do
    case PluginRegistry.find(name) do
      {:ok, plugin} ->
        enable_or_connect_plugin(socket, plugin)

      :error ->
        flash_error(socket, "#{name} installed but did not register — check the daemon logs.")

      {:error, reason} ->
        flash_error(socket, "Save failed: #{Redaction.format(reason)}")
    end
  end

  # Per-stage install error prose (§6) — same vocabulary as the CLI dist verbs.
  defp install_error({:download_failed, _reason, _url}), do: "download failed (network)."
  defp install_error({:download_status, status, _url}), do: "download failed (HTTP #{status})."
  defp install_error({:sha256_mismatch, _details}), do: "checksum mismatch — refusing."

  defp install_error({:verification_failed, :cosign_not_installed}),
    do: "cosign not found — install it to verify plugin signatures (e.g. `brew install cosign`)."

  defp install_error({:verification_failed, _reason}), do: "signature invalid — refusing."

  defp install_error({:incompatible, {:needs_newer_core, :min_core_version, floor}}),
    do: "needs Fermix ≥ #{floor} — run `fermix upgrade` first."

  defp install_error({:incompatible, {:needs_newer_core, :plugin_api, api}}),
    do: "needs a newer Fermix (plugin API #{api}) — run `fermix upgrade` first."

  defp install_error({:incompatible, {:plugin_too_old, :plugin_api, _api}}),
    do: "built for an older Fermix — awaiting a plugin update."

  defp install_error({:yanked, name, version}),
    do: "#{name} #{version} was yanked — not installing."

  defp install_error({:unknown_plugin, _name}),
    do: "not in the plugin catalog — run `fermix upgrade` to get the latest catalog."

  defp install_error({:no_build_for_target, target}), do: "no build for this machine (#{target})."

  # Computer-use (compux library) download errors.
  defp install_error({:no_checksum_for_target, _target}),
    do: "the Computer Use helper hasn't been published for this platform yet."

  defp install_error({:checksum_mismatch, _details}), do: "checksum mismatch — refusing."
  defp install_error({:http_status, status}), do: "download failed (HTTP #{status})."
  defp install_error({:http_error, _reason}), do: "download failed (network or timeout)."
  defp install_error({:untar, _reason}), do: "the downloaded Computer Use archive was invalid."

  defp install_error({:binary_not_in_archive, _name}),
    do: "the downloaded Computer Use archive was invalid."

  defp install_error({:unsupported_target, os, arch}),
    do: "no Computer Use build for this machine (#{os}-#{arch})."

  defp install_error({:unsupported_os, _os}),
    do: "Computer Use isn't supported on this operating system."

  defp install_error({:unsupported_arch, _arch}),
    do: "Computer Use isn't supported on this CPU architecture."

  defp install_error(reason), do: Redaction.format(reason)

  defp plugins_dist_opts do
    Application.get_env(:fermix_core, :plugins_dist_opts, [])
  end

  defp plugin_install_names(tasks), do: tasks |> Map.values() |> Enum.map(& &1.name)

  defp start_codex_auth(socket) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn ->
        run_codex_login(parent)
      end)

    tasks = Map.put(socket.assigns.codex_auth_tasks, task.ref, %{display_name: "ChatGPT"})

    socket
    |> assign(:codex_auth_tasks, tasks)
    |> assign(:codex_auth_url, nil)
    |> flash_info("Opening ChatGPT sign-in.")
  end

  defp run_codex_login(parent) do
    result =
      codex_login_runner().(
        oauth_opener: codex_auth_opener(parent),
        puts: fn _message -> :ok end
      )

    with {:ok, entry} <- result,
         :ok <- reload_codex_token_manager() do
      {:ok, entry}
    end
  end

  defp codex_login_runner do
    Application.get_env(:fermix_web, :codex_login_runner, &CodexLogin.login/1)
  end

  defp codex_auth_opener(parent) do
    fn url ->
      send(parent, {:codex_auth_url, url})
      :ok
    end
  end

  defp finish_task(socket, ref, result) do
    cond do
      Map.has_key?(socket.assigns.plugin_install_tasks, ref) ->
        {task, tasks} = Map.pop(socket.assigns.plugin_install_tasks, ref)
        Process.demonitor(ref, [:flush])
        finish_plugin_install(socket, task, tasks, result)

      Map.has_key?(socket.assigns.plugin_auth_tasks, ref) ->
        {task, tasks} = Map.pop(socket.assigns.plugin_auth_tasks, ref)
        finish_known_plugin_auth(socket, ref, task, tasks, result)

      Map.has_key?(socket.assigns.xai_auth_tasks, ref) ->
        finish_xai_auth_task(socket, ref, result)

      true ->
        finish_codex_auth_task(socket, ref, result)
    end
  end

  defp finish_known_plugin_auth(socket, ref, task, tasks, result) do
    Process.demonitor(ref, [:flush])
    finish_plugin_auth(socket, task, tasks, result)
  end

  defp finish_codex_auth_task(socket, ref, result) do
    case Map.pop(socket.assigns.codex_auth_tasks, ref) do
      {nil, _tasks} -> socket
      {task, tasks} -> finish_known_codex_auth(socket, ref, task, tasks, result)
    end
  end

  defp finish_known_codex_auth(socket, ref, task, tasks, result) do
    Process.demonitor(ref, [:flush])
    finish_codex_auth(socket, task, tasks, result)
  end

  defp fail_task(socket, ref, reason) do
    cond do
      Map.has_key?(socket.assigns.plugin_install_tasks, ref) ->
        {task, tasks} = Map.pop(socket.assigns.plugin_install_tasks, ref)
        fail_plugin_install(socket, task, tasks, reason)

      Map.has_key?(socket.assigns.plugin_auth_tasks, ref) ->
        {task, tasks} = Map.pop(socket.assigns.plugin_auth_tasks, ref)
        fail_plugin_auth(socket, task, tasks, reason)

      Map.has_key?(socket.assigns.xai_auth_tasks, ref) ->
        fail_xai_auth_task(socket, ref, reason)

      true ->
        fail_codex_auth_task(socket, ref, reason)
    end
  end

  defp fail_codex_auth_task(socket, ref, reason) do
    case Map.pop(socket.assigns.codex_auth_tasks, ref) do
      {nil, _tasks} -> socket
      {task, tasks} -> fail_codex_auth(socket, task, tasks, reason)
    end
  end

  defp finish_codex_auth(socket, task, tasks, {:ok, _entry}) do
    socket
    |> assign(:codex_auth_tasks, tasks)
    |> assign(:codex_auth_url, nil)
    |> connect_oauth_provider(:openai_codex, "#{task.display_name} OAuth connected.")
  end

  defp finish_codex_auth(socket, task, tasks, {:error, reason}) do
    fail_codex_auth(socket, task, tasks, reason)
  end

  defp fail_codex_auth(socket, task, tasks, reason) do
    socket
    |> assign(:codex_auth_tasks, tasks)
    |> assign(:codex_auth_url, nil)
    |> flash_error("#{task.display_name} sign-in failed: #{Redaction.format(reason)}")
  end

  # A completed OAuth connection in setup means the user chose this provider, so
  # persist it as primary now. Otherwise the credential is stored but the config
  # pointer the end-of-setup probe and runtime routing resolve through
  # PrimaryConfig.primary/0 is set only if a later "Save provider" submit happens
  # to carry the selection — the gap that left a freshly-connected Codex provider
  # reported "not configured". Idempotent with that save; Wizard.mark_primary
  # reads the current snapshot so an auth_mode the login flow just wrote stays.
  defp connect_oauth_provider(socket, provider, message) do
    case Wizard.mark_primary(provider) do
      {:ok, _report} ->
        refresh_report_preserving_provider_form(socket, message)

      {:error, reason} ->
        flash_error(
          socket,
          "#{provider} connected, but setting it as the primary provider failed: " <>
            Redaction.format(reason)
        )
    end
  end

  defp refresh_report_preserving_provider_form(socket, message) do
    provider_form = socket.assigns.provider_form

    socket
    |> refresh_report(message)
    |> assign(:provider_form, provider_form)
    |> assign_model_sources(provider_form)
  end

  defp codex_auth_running?(tasks), do: map_size(tasks) > 0

  defp maybe_clear_codex_auth_url(socket, url) do
    if socket.assigns.codex_auth_url == url do
      assign(socket, :codex_auth_url, nil)
    else
      socket
    end
  end

  defp codex_auth_summary do
    case Store.read(:openai_codex) do
      {:ok, entry} ->
        %{
          connected?: true,
          stale?: TokenExpiry.stale?(entry.expires_at),
          account: codex_account_label(entry),
          error: nil
        }

      {:error, reason} ->
        %{connected?: false, account: nil, error: codex_auth_error(reason)}
    end
  rescue
    error in ArgumentError ->
      %{connected?: false, account: nil, error: Exception.message(error)}
  end

  defp codex_auth_error(:no_auth_file), do: nil
  defp codex_auth_error({:provider_missing, _provider}), do: nil
  defp codex_auth_error(reason), do: Redaction.format(reason)

  defp codex_account_label(%{account: %{email: email}}) when is_binary(email) and email != "",
    do: email

  defp codex_account_label(%{account: %{display_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp codex_account_label(_entry), do: nil

  defp reload_codex_token_manager do
    case Process.whereis(TokenManager) do
      nil -> :ok
      _pid -> reload_running_codex_token_manager()
    end
  end

  defp reload_running_codex_token_manager do
    case TokenManager.reload(TokenManager) do
      {:ok, _token} -> :ok
      {:error, reason} -> {:error, {:token_manager_reload_failed, reason}}
    end
  end

  # --- xAI (Grok) loopback OAuth — mirrors the Codex flow -------------------

  defp start_xai_auth(socket) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn -> run_xai_login(parent) end)

    tasks = Map.put(socket.assigns.xai_auth_tasks, task.ref, %{display_name: "Grok"})

    socket
    |> assign(:xai_auth_tasks, tasks)
    |> assign(:xai_auth_url, nil)
    |> flash_info("Opening Grok sign-in.")
  end

  # Connecting also switches the config route to OAuth — a stored token is inert
  # until [providers.xai].auth_mode = oauth. Both land before we report success.
  defp run_xai_login(parent) do
    with {:ok, entry} <-
           xai_login_runner().(opener: xai_auth_opener(parent), puts: fn _msg -> :ok end),
         {:ok, _report} <- Wizard.set_provider_auth_mode(:xai, :oauth) do
      {:ok, entry}
    end
  end

  defp xai_login_runner do
    Application.get_env(:fermix_web, :xai_login_runner, &XAILogin.login/1)
  end

  defp xai_auth_opener(parent) do
    fn url ->
      send(parent, {:xai_auth_url, url})
      :ok
    end
  end

  defp finish_xai_auth_task(socket, ref, result) do
    case Map.pop(socket.assigns.xai_auth_tasks, ref) do
      {nil, _tasks} -> socket
      {task, tasks} -> finish_known_xai_auth(socket, ref, task, tasks, result)
    end
  end

  defp finish_known_xai_auth(socket, ref, task, tasks, result) do
    Process.demonitor(ref, [:flush])
    finish_xai_auth(socket, task, tasks, result)
  end

  defp finish_xai_auth(socket, task, tasks, {:ok, _entry}) do
    socket
    |> assign(:xai_auth_tasks, tasks)
    |> assign(:xai_auth_url, nil)
    |> assign(:restart_pending?, true)
    |> connect_oauth_provider(
      :xai,
      "#{task.display_name} OAuth connected. Restart the daemon to apply."
    )
  end

  defp finish_xai_auth(socket, task, tasks, {:error, reason}) do
    fail_xai_auth(socket, task, tasks, reason)
  end

  defp fail_xai_auth_task(socket, ref, reason) do
    case Map.pop(socket.assigns.xai_auth_tasks, ref) do
      {nil, _tasks} -> socket
      {task, tasks} -> fail_xai_auth(socket, task, tasks, reason)
    end
  end

  defp fail_xai_auth(socket, task, tasks, reason) do
    socket
    |> assign(:xai_auth_tasks, tasks)
    |> assign(:xai_auth_url, nil)
    |> flash_error("#{task.display_name} sign-in failed: #{Redaction.format(reason)}")
  end

  defp xai_auth_running?(tasks), do: map_size(tasks) > 0

  defp maybe_clear_xai_auth_url(socket, url) do
    if socket.assigns.xai_auth_url == url do
      assign(socket, :xai_auth_url, nil)
    else
      socket
    end
  end

  defp xai_auth_summary, do: oauth_profile_summary("xai_oauth")

  # --- Anthropic setup-token / Claude Code import (synchronous, no loopback) -

  defp connect_anthropic(socket, login_fun) do
    with {:ok, _entry} <- login_fun.(),
         {:ok, _report} <- Wizard.set_provider_auth_mode(:anthropic, :oauth) do
      socket
      |> assign(:restart_pending?, true)
      |> connect_oauth_provider(
        :anthropic,
        "Anthropic OAuth connected. Restart the daemon to apply."
      )
    else
      {:error, reason} ->
        flash_error(socket, "Anthropic sign-in failed: #{Redaction.format(reason)}")
    end
  end

  defp anthropic_auth_summary, do: oauth_profile_summary("anthropic_oauth")

  defp anthropic_login_impl do
    Application.get_env(:fermix_web, :anthropic_login_impl, AnthropicLogin)
  end

  # Probe only when Anthropic is the active provider — claude_code_available?
  # can shell out (keychain), so it should not run on every render.
  defp anthropic_import_available?(snapshot) do
    current_provider(snapshot) == :anthropic and anthropic_login_impl().claude_code_available?()
  end

  # Shared connected/error read for the oauth profiles, with the same gating as
  # codex_auth_summary: a missing auth file or missing provider is "not
  # connected, no error".
  defp oauth_profile_summary(profile) do
    case Store.read(profile) do
      {:ok, entry} ->
        %{connected?: true, stale?: TokenExpiry.stale?(entry.expires_at), error: nil}

      {:error, reason} ->
        %{connected?: false, error: codex_auth_error(reason)}
    end
  rescue
    error in ArgumentError ->
      %{connected?: false, error: Exception.message(error)}
  end

  defp parse_auth_mode_field("api_key", _default), do: :api_key
  defp parse_auth_mode_field("oauth", _default), do: :oauth
  defp parse_auth_mode_field(_other, default), do: default

  # Every descriptor setup field (secrets and plain fields alike) submits
  # under its answer-key name; blank values are dropped (keep-existing).
  defp put_provider_field_answers(answers, params) do
    Enum.reduce(Descriptor.all(), answers, fn descriptor, acc ->
      Enum.reduce(descriptor.setup_fields, acc, fn field, inner ->
        maybe_put_string(inner, field.key, params[Atom.to_string(field.key)])
      end)
    end)
  end

  # The radio submits one `auth_mode` for the currently selected provider;
  # route it to the per-provider answer key (only multi-auth-mode
  # descriptors expose the picker). Compile-time map — no runtime atom
  # creation from user input.
  @auth_mode_answer_keys FermixCore.Providers.Descriptor.all()
                         |> Enum.filter(&FermixCore.Providers.Descriptor.multi_auth_mode?/1)
                         |> Map.new(&{Atom.to_string(&1.id), :"#{&1.id}_auth_mode"})

  defp put_auth_mode_answer(answers, provider, mode) do
    case Map.fetch(@auth_mode_answer_keys, provider) do
      {:ok, answer_key} -> maybe_put_string(answers, answer_key, mode)
      :error -> answers
    end
  end

  # A pasted Anthropic setup token is stored to the auth store as part of "Save
  # provider" (no separate button); blank keeps the existing token. The radio
  # already routes auth_mode = oauth through `put_auth_mode_answer`.
  defp maybe_store_anthropic_setup_token(%{
         "provider" => "anthropic",
         "auth_mode" => "oauth",
         "anthropic_setup_token" => token
       }) do
    case String.trim(token || "") do
      "" -> :ok
      trimmed -> store_result(anthropic_login_impl().store_setup_token(trimmed))
    end
  end

  defp maybe_store_anthropic_setup_token(_params), do: :ok

  defp store_result(:ok), do: :ok
  defp store_result({:ok, _entry}), do: :ok
  defp store_result({:error, reason}), do: {:error, reason}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # Primary flag first, legacy agent.provider as migration input. Multiple
  # hand-edited primaries map to the default so the setup page stays usable
  # as the repair surface.
  defp current_provider(snapshot) do
    chosen =
      PrimaryConfig.chosen_in(
        get_fermix_core(snapshot, :providers),
        get_fermix_core(snapshot, :agent)
      )

    case chosen do
      {:ok, provider} -> normalize_provider(provider)
      {:error, :multiple_primary} -> normalize_provider(nil)
    end
  end

  defp get_fermix_core(snapshot, key) do
    snapshot |> Map.get(:fermix_core, []) |> Keyword.get(key, [])
  end

  defp normalize_provider(provider) when is_atom(provider) and not is_nil(provider) do
    if provider in Descriptor.ids(), do: provider, else: :openai
  end

  defp normalize_provider(provider) when is_binary(provider) do
    Enum.find(Descriptor.ids(), :openai, &(Atom.to_string(&1) == provider))
  end

  defp normalize_provider(_provider), do: :openai

  defp parse_provider_field(value, default) when is_binary(value) do
    Enum.find(Descriptor.ids(), default, &(Atom.to_string(&1) == value))
  end

  defp parse_provider_field(_value, default), do: default

  defp parse_channel_field("telegram", _default), do: :telegram
  defp parse_channel_field("whatsapp", _default), do: :whatsapp
  defp parse_channel_field("discord", _default), do: :discord
  defp parse_channel_field("slack", _default), do: :slack
  defp parse_channel_field("signal", _default), do: :signal
  defp parse_channel_field("acp", _default), do: :acp
  defp parse_channel_field(_, default), do: default

  defp parse_effort_field(field, default) do
    case ReasoningEffort.parse(field) do
      {:ok, level} -> level
      :error -> default
    end
  end

  defp parse_fast_field("true", _default), do: true
  defp parse_fast_field("false", _default), do: false
  defp parse_fast_field(_field, default), do: default

  defp parse_sandbox_mode("strict", _default), do: :strict
  defp parse_sandbox_mode("standard", _default), do: :standard
  defp parse_sandbox_mode("open", _default), do: :open
  defp parse_sandbox_mode(_value, default), do: default

  defp parse_sandbox_profile("bare", _default), do: :bare
  defp parse_sandbox_profile("assistant", _default), do: :assistant
  defp parse_sandbox_profile("extended", _default), do: :extended
  defp parse_sandbox_profile(_value, default), do: default

  defp normalize_search_backend(nil), do: :duckduckgo
  defp normalize_search_backend(:duckduckgo), do: :duckduckgo
  defp normalize_search_backend(:tavily), do: :tavily
  defp normalize_search_backend(:exa), do: :exa
  defp normalize_search_backend(:parallel), do: :parallel
  defp normalize_search_backend(:brave), do: :brave
  defp normalize_search_backend(:perplexity), do: :perplexity
  defp normalize_search_backend(:firecrawl), do: :firecrawl
  defp normalize_search_backend("duckduckgo"), do: :duckduckgo
  defp normalize_search_backend("tavily"), do: :tavily
  defp normalize_search_backend("exa"), do: :exa
  defp normalize_search_backend("parallel"), do: :parallel
  defp normalize_search_backend("brave"), do: :brave
  defp normalize_search_backend("perplexity"), do: :perplexity
  defp normalize_search_backend("firecrawl"), do: :firecrawl
  defp normalize_search_backend(_value), do: :duckduckgo

  # Image generation has no keyless default, so the form defaults its selection
  # to OpenAI (most operators already hold an OpenAI key from the Provider tab).
  # Nothing is written to config until the operator saves the Media tab.
  defp normalize_image_backend(nil), do: :openai
  defp normalize_image_backend(:openai), do: :openai
  defp normalize_image_backend(:xai), do: :xai
  defp normalize_image_backend(:google), do: :google
  defp normalize_image_backend("openai"), do: :openai
  defp normalize_image_backend("xai"), do: :xai
  defp normalize_image_backend("google"), do: :google
  defp normalize_image_backend(:openai_codex), do: :openai_codex
  defp normalize_image_backend("openai_codex"), do: :openai_codex
  defp normalize_image_backend(_value), do: :openai

  # Transcription has no keyless default; the form defaults to OpenAI (most
  # operators already hold an OpenAI key). Nothing is written until the operator
  # saves the Transcription tab. The on-device `local` backend is not offered
  # here (it ships in a later phase).
  defp normalize_transcription_backend(nil), do: :openai
  defp normalize_transcription_backend(:openai), do: :openai
  defp normalize_transcription_backend(:xai), do: :xai
  defp normalize_transcription_backend(:deepgram), do: :deepgram
  defp normalize_transcription_backend(:local), do: :local
  defp normalize_transcription_backend("openai"), do: :openai
  defp normalize_transcription_backend("xai"), do: :xai
  defp normalize_transcription_backend("deepgram"), do: :deepgram
  defp normalize_transcription_backend("local"), do: :local
  defp normalize_transcription_backend(_value), do: :openai

  defp parse_env_allow(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp present_or(nil, default), do: default
  defp present_or("", default), do: default
  defp present_or(value, _default) when is_binary(value), do: value

  defp provider_block(snapshot, provider) do
    snapshot
    |> get_fermix_core(:providers)
    |> Keyword.get(provider, [])
  end

  # Static catalog options always; live listing (installed Ollama models /
  # the upstream OpenRouter catalog) layered on for the providers that
  # have one. Synchronous with a tight timeout — setup page only.
  defp assign_model_sources(socket, provider_form) do
    provider = provider_form.provider

    socket
    |> assign(:provider_models, models_for_safe(provider))
    |> assign_live_listing(provider, provider_form)
  end

  defp assign_live_listing(socket, provider, provider_form) do
    impl = model_listing_impl()

    if impl.live?(provider) do
      assign(
        socket,
        :live_models,
        impl.live_models(provider, listing_opts(provider, provider_form))
      )
    else
      assign(socket, :live_models, nil)
    end
  end

  defp listing_opts(:ollama, provider_form) do
    case Map.get(provider_form.field_values || %{}, :ollama_base_url) do
      url when is_binary(url) and url != "" -> [base_url: url]
      _absent -> []
    end
  end

  defp listing_opts(_provider, _provider_form), do: []

  defp model_listing_impl do
    Application.get_env(:fermix_web, :model_listing_impl, ModelListing)
  end

  defp models_for_safe(provider) do
    if provider in Descriptor.ids() do
      ModelCatalog.models_for(provider)
    else
      ModelCatalog.models_for(:openai)
    end
  end

  defp api_key_configured?(snapshot), do: provider_api_key_set?(snapshot, :openai)

  defp secret_set?(config, key), do: config |> Keyword.get(key) |> present?()
  defp channel_enabled?(config, default), do: Keyword.get(config, :enabled, default) == true

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?("@keyring"), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(_), do: true

  # A toggle posts a hidden "false" ahead of its checked "true"; the last value
  # wins, so anything other than the literal "true" is off.
  defp checked?("true"), do: true
  defp checked?(_value), do: false

  defp maybe_put_string(answers, _key, nil), do: answers
  defp maybe_put_string(answers, _key, ""), do: answers

  defp maybe_put_string(answers, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      answers
    else
      [{key, value} | answers]
    end
  end

  # The harness default-vendor <select> is rendered only when BOTH vendor CLIs
  # are detected, so its param is present exactly when the operator could choose.
  # Pass it through even when blank ("" = no preference) so the wizard clears an
  # existing pin; absence (selector not rendered) preserves it (design §7.4).
  defp maybe_put_harness_vendor(answers, params) do
    case Map.fetch(params, "harness_default_vendor") do
      {:ok, value} when is_binary(value) -> [{:harness_default_vendor, value} | answers]
      _absent -> answers
    end
  end

  # The harness consent toggle (design §22). A hidden "false" input pairs with the
  # checkbox so the param is present both ways — checked posts "true", unchecked
  # posts "false" — letting the operator both grant and revoke consent from the
  # card. Absent (card not rendered) preserves the existing value.
  # The skill-curation personalization toggle (MILESTONE_26_SKILL_CURATION
  # §6.1). Same hidden-false pairing as the harness consent checkbox; the
  # wizard reducer writes `enabled = false` on decline and deletes the key on
  # accept (default already true).
  defp maybe_put_skill_curation_enabled(answers, params) do
    case Map.fetch(params, "skill_curation_enabled") do
      {:ok, "true"} -> [{:skill_curation_enabled, true} | answers]
      {:ok, "false"} -> [{:skill_curation_enabled, false} | answers]
      _absent -> answers
    end
  end

  defp maybe_put_harness_approved(answers, params) do
    case Map.fetch(params, "harness_approved") do
      {:ok, "true"} -> [{:harness_approved, true} | answers]
      {:ok, "false"} -> [{:harness_approved, false} | answers]
      _absent -> answers
    end
  end

  # The sub-agent model <select> always submits ("" = same as main). Pass it
  # through even when blank so the wizard clears an existing pin
  # (docs/design/SUBAGENT_MODEL_SELECTION.md §7a/§7c).
  defp put_subagent_model_answer(answers, params) do
    case Map.fetch(params, "subagent_model") do
      {:ok, value} -> [{:subagent_model, value} | answers]
      :error -> answers
    end
  end

  defp tab_known?(tab_id), do: Enum.any?(@tabs, &(&1.id == tab_id))

  # Honor an explicit `?tab=` only when it names a real tab; otherwise fall
  # through to next_action_tab. Lets apply_restart return the operator to the
  # tab they restarted from rather than the first incomplete tab.
  defp requested_tab(%{"tab" => tab}) when is_binary(tab) do
    if tab_known?(tab), do: tab, else: nil
  end

  defp requested_tab(_params), do: nil

  defp next_action_tab(report) do
    Enum.find_value(@tabs, "provider", fn tab ->
      if tab_status(tab, report) == :partial, do: tab.id
    end)
  end

  defp next_tab(tab_id), do: adjacent_tab(tab_id, 1)
  defp previous_tab(tab_id), do: adjacent_tab(tab_id, -1)

  defp adjacent_tab(tab_id, delta) do
    index = Enum.find_index(@tabs, &(&1.id == tab_id)) || 0
    next_index = index + delta
    next_index = max(0, min(next_index, length(@tabs) - 1))
    Enum.at(@tabs, next_index).id
  end

  defp tab_status(%{component: nil}, _report), do: :ready
  defp tab_status(%{component: "provider:*"}, report), do: status_by_prefix(report, "provider:")
  defp tab_status(%{component: "channel:*"}, report), do: status_by_prefix(report, "channel:")
  defp tab_status(%{component: "realtime:*"}, report), do: status_by_prefix(report, "realtime:")

  defp tab_status(%{component: component}, report) do
    if Enum.any?(report.wizard.validation_errors, &(&1.component == component)) do
      :partial
    else
      :ready
    end
  end

  defp status_by_prefix(report, prefix) do
    if Enum.any?(report.wizard.validation_errors, &String.starts_with?(&1.component, prefix)) do
      :partial
    else
      :ready
    end
  end

  defp safe_string(nil), do: ""
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value), do: to_string(value)
end
