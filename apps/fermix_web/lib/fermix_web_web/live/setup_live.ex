defmodule FermixWebWeb.SetupLive do
  use FermixWebWeb, :live_view

  alias Fermix.CLI.Service
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.Doctor
  alias FermixCore.Setup.Wizard
  alias FermixWebWeb.SetupLive.Components

  @tabs [
    %{id: "provider", label: "Provider", component: "provider:*", description: "Model and key"},
    %{id: "realtime", label: "Realtime", component: "realtime:*", description: "Voice companion"},
    %{id: "channels", label: "Channels", component: "channel:*", description: "Message ingress"},
    %{id: "skills", label: "Skills", component: nil, description: "Agent skills"},
    %{id: "search", label: "Search", component: nil, description: "Web search"},
    %{id: "sandbox", label: "Sandbox", component: nil, description: "Execution policy"},
    %{id: "memory", label: "Memory", component: nil, description: "Recall tuning"},
    %{
      id: "personalization",
      label: "Personalization",
      component: "personalization",
      description: "User profile"
    },
    %{id: "doctor", label: "Doctor", component: nil, description: "Final checks"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    report = Wizard.report()

    socket =
      socket
      |> assign(:page_title, "Fermix setup")
      |> assign(:active_tab, next_action_tab(report))
      |> assign(:saved_flash, nil)
      |> assign(:doctor_result, nil)
      |> assign(:restarting, false)
      |> assign_report(report)

    {:ok, socket}
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
    default_model = present_or(Map.get(params, "default_model"), current.default_model)

    reasoning_effort =
      parse_effort_field(Map.get(params, "reasoning_effort"), current.reasoning_effort)

    form = %{provider: provider, default_model: default_model, reasoning_effort: reasoning_effort}

    {:noreply,
     socket
     |> assign(:provider_form, form)
     |> assign(:provider_models, models_for_safe(provider))}
  end

  def handle_event("save_provider", %{"provider_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:provider, params["provider"])
      |> maybe_put_string(:default_model, params["default_model"])
      |> maybe_put_string(:reasoning_effort, params["reasoning_effort"])
      |> maybe_put_string(:openai_api_key, params["openai_api_key"])

    {:noreply, save_answers(socket, answers, "Provider saved.", Map.get(root, "__nav"))}
  end

  def handle_event("save_realtime", %{"realtime_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:realtime_enabled, params["enabled"])
      |> maybe_put_string(:realtime_api_key, params["api_key"])
      |> maybe_put_string(:realtime_voice, params["voice"])
      |> maybe_put_string(:realtime_max_session_minutes, params["max_session_minutes"])
      |> maybe_put_string(:realtime_max_cost_cents, params["max_cost_cents"])
      |> maybe_put_string(:realtime_persist_transcripts, params["persist_transcripts"])

    {:noreply, save_answers(socket, answers, "Realtime saved.", Map.get(root, "__nav"))}
  end

  def handle_event("save_channels", %{"channels_form" => params} = root, socket) do
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

    {:noreply, save_answers(socket, answers, "Channels saved.", Map.get(root, "__nav"))}
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

    {:noreply, save_answers(socket, answers, "Search saved.", Map.get(root, "__nav"))}
  end

  def handle_event("save_memory", %{"memory_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:compaction_threshold, params["compaction_threshold"])
      |> maybe_put_string(:extraction_timeout_ms, params["extraction_timeout_ms"])

    {:noreply, save_answers(socket, answers, "Memory saved.", Map.get(root, "__nav"))}
  end

  def handle_event("save_sandbox", %{"sandbox_form" => params} = root, socket) do
    current = socket.assigns.sandbox_form
    mode = parse_sandbox_mode(Map.get(params, "mode"), current.mode)
    profile = parse_sandbox_profile(Map.get(params, "profile"), current.profile)
    env_allow = parse_env_allow(Map.get(params, "env_allow", ""))

    result = Wizard.set_sandbox_overrides(mode, profile, env_allow)
    {:noreply, save_result(result, socket, "Sandbox saved.", Map.get(root, "__nav"))}
  end

  def handle_event("save_personalization", %{"personalization_form" => params} = root, socket) do
    answers =
      []
      |> maybe_put_string(:user_name, params["user_name"])
      |> maybe_put_string(:timezone, params["timezone"])
      |> maybe_put_string(:communication_style, params["communication_style"])

    {:noreply, save_answers(socket, answers, "Personalization saved.", Map.get(root, "__nav"))}
  end

  def handle_event("run_doctor", _params, socket) do
    {:noreply, assign(socket, :doctor_result, Doctor.probe_active())}
  end

  def handle_event("apply_restart", _params, socket) do
    if Service.supervised?() do
      Process.send_after(self(), :perform_restart, 600)
      {:noreply, assign(socket, :restarting, true)}
    else
      {:noreply,
       assign(
         socket,
         :saved_flash,
         "Nothing to restart from here — no OS-supervised Fermix service is running this process. " <>
           "In dev, stop and re-run `mix fermix.dev`; an installed service restarts itself from this button."
       )}
    end
  end

  @impl true
  def handle_info(:perform_restart, socket) do
    # Supervised release only (gated in apply_restart): exit non-zero so the OS
    # supervisor relaunches the daemon — launchd KeepAlive on any exit, systemd
    # Restart=on-failure on non-zero. The LiveView reconnects once it is back.
    System.stop(1)
    {:noreply, socket}
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
      provider_form={@provider_form}
      provider_models={@provider_models}
      realtime_form={@realtime_form}
      report={@report}
      restarting={@restarting}
      sandbox_form={@sandbox_form}
      search_form={@search_form}
      saved_flash={@saved_flash}
      skill_summary={@skill_summary}
      tabs={@tabs}
      tool_summary={@tool_summary}
    />
    """
  end

  defp assign_report(socket, report) do
    snapshot = report.wizard.config_snapshot

    socket
    |> assign(:report, report)
    |> assign(:tabs, @tabs)
    |> assign(:provider_form, build_provider_form(snapshot))
    |> assign(:provider_models, models_for_safe(current_provider(snapshot)))
    |> assign(:realtime_form, build_realtime_form(snapshot))
    |> assign(:channels_form, build_channels_form(snapshot))
    |> assign(:search_form, build_search_form(snapshot))
    |> assign(:sandbox_form, build_sandbox_form(snapshot))
    |> assign(:memory_form, build_memory_form(snapshot))
    |> assign(:personalization_form, build_personalization_form(snapshot))
    |> assign(:tool_summary, tool_summary())
    |> assign(:skill_summary, skill_summary())
  end

  defp save_answers(socket, answers, message, nav) do
    socket.assigns.report.wizard
    |> Wizard.save_answers(answers)
    |> save_result(socket, message, nav)
  end

  defp save_result({:ok, report}, socket, message, nav) do
    socket
    |> assign_report(report)
    |> assign(:saved_flash, message)
    |> maybe_advance(nav)
  end

  defp save_result({:error, reason}, socket, _message, _nav) do
    assign(socket, :saved_flash, "Save failed: #{inspect(reason)}")
  end

  defp maybe_advance(socket, "next") do
    assign(socket, :active_tab, next_tab(socket.assigns.active_tab))
  end

  defp maybe_advance(socket, _nav), do: socket

  defp build_provider_form(snapshot) do
    provider = current_provider(snapshot)
    provider_block = provider_block(snapshot, provider)

    %{
      provider: provider,
      default_model:
        Keyword.get(provider_block, :default_model) || ModelCatalog.default_model_for(provider),
      reasoning_effort: Keyword.get(provider_block, :reasoning_effort, :none)
    }
  end

  defp build_realtime_form(snapshot) do
    config = snapshot |> get_fermix_core(:realtime) |> RealtimeConfig.normalize()

    %{
      enabled: config.enabled?,
      voice: config.voice,
      max_session_minutes: config.max_session_minutes,
      max_cost_cents: config.max_estimated_cost_cents_per_session,
      persist_transcripts: config.persist_transcripts?,
      api_key_set: api_key_configured?(snapshot)
    }
  end

  defp build_channels_form(snapshot) do
    channels = Map.get(snapshot, :fermix_channels, [])

    %{
      telegram: telegram_form(channels),
      whatsapp: whatsapp_form(channels),
      discord: discord_form(channels),
      slack: slack_form(channels),
      signal: signal_form(channels)
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
      parallel_api_key_set: secret_set?(web_search, :parallel_api_key)
    }
  end

  defp build_memory_form(snapshot) do
    compaction = snapshot |> get_fermix_core(:compaction) |> CompactionConfig.normalize()
    memory = get_fermix_core(snapshot, :memory)

    %{
      compaction_threshold: safe_string(CompactionConfig.threshold(compaction)),
      extraction_timeout_ms: safe_string(Keyword.get(memory, :extraction_timeout_ms, 90_000))
    }
  end

  defp build_personalization_form(snapshot) do
    personalization = get_fermix_core(snapshot, :personalization)

    %{
      user_name: Keyword.get(personalization, :user_name, ""),
      timezone: Keyword.get(personalization, :timezone, ""),
      communication_style: Keyword.get(personalization, :communication_style, "")
    }
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

  defp current_provider(snapshot) do
    snapshot
    |> get_fermix_core(:agent)
    |> Keyword.get(:provider)
    |> normalize_provider()
  end

  defp get_fermix_core(snapshot, key) do
    snapshot |> Map.get(:fermix_core, []) |> Keyword.get(key, [])
  end

  defp normalize_provider(nil), do: :openai

  defp normalize_provider(provider) when provider in [:openai, :openai_codex, :anthropic],
    do: provider

  defp normalize_provider("openai"), do: :openai
  defp normalize_provider("openai_codex"), do: :openai_codex
  defp normalize_provider("anthropic"), do: :anthropic
  defp normalize_provider(_provider), do: :openai

  defp parse_provider_field("openai", _default), do: :openai
  defp parse_provider_field("openai_codex", _default), do: :openai_codex
  defp parse_provider_field("anthropic", _default), do: :anthropic
  defp parse_provider_field(_, default), do: default

  defp parse_effort_field(field, _default)
       when field in ~w(none minimal low medium high xhigh) do
    String.to_existing_atom(field)
  end

  defp parse_effort_field(_, default), do: default

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
  defp normalize_search_backend("duckduckgo"), do: :duckduckgo
  defp normalize_search_backend("tavily"), do: :tavily
  defp normalize_search_backend("exa"), do: :exa
  defp normalize_search_backend("parallel"), do: :parallel
  defp normalize_search_backend(_value), do: :duckduckgo

  defp parse_env_allow(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp present_or(nil, default), do: default
  defp present_or("", default), do: default
  defp present_or(value, _default) when is_binary(value), do: value

  defp provider_block(snapshot, provider) do
    snapshot
    |> get_fermix_core(:providers)
    |> Keyword.get(provider, [])
  end

  defp models_for_safe(provider) when provider in [:openai, :openai_codex, :anthropic] do
    ModelCatalog.models_for(provider)
  end

  defp models_for_safe(_), do: ModelCatalog.models_for(:openai)

  defp api_key_configured?(snapshot) do
    snapshot
    |> get_fermix_core(:providers)
    |> Keyword.get(:openai, [])
    |> Keyword.get(:api_key)
    |> present?()
  end

  defp secret_set?(config, key), do: config |> Keyword.get(key) |> present?()
  defp channel_enabled?(config, default), do: Keyword.get(config, :enabled, default) == true

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(_), do: true

  defp maybe_put_string(answers, _key, nil), do: answers
  defp maybe_put_string(answers, _key, ""), do: answers

  defp maybe_put_string(answers, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      answers
    else
      [{key, value} | answers]
    end
  end

  defp tab_known?(tab_id), do: Enum.any?(@tabs, &(&1.id == tab_id))

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
