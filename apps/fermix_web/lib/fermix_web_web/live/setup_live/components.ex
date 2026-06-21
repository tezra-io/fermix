defmodule FermixWebWeb.SetupLive.Components do
  use FermixWebWeb, :html

  alias FermixCore.Auth.Redaction
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ReasoningEffort

  @channels [
    {:telegram, "Telegram"},
    {:whatsapp, "WhatsApp"},
    {:discord, "Discord"},
    {:slack, "Slack"},
    {:signal, "Signal"}
  ]

  attr :active_tab, :string, required: true
  attr :channels_form, :map, required: true
  attr :codex_auth, :map, required: true
  attr :codex_auth_running?, :boolean, required: true
  attr :codex_auth_url, :string, default: nil
  attr :xai_auth, :map, required: true
  attr :xai_auth_running?, :boolean, required: true
  attr :xai_auth_url, :string, default: nil
  attr :anthropic_auth, :map, required: true
  attr :anthropic_import_available?, :boolean, default: false
  attr :doctor_result, :any, required: true
  attr :doctor_probe_running?, :boolean, default: false
  attr :memory_form, :map, required: true
  attr :personalization_form, :map, required: true
  attr :provider_form, :map, required: true
  attr :provider_models, :list, required: true
  attr :live_models, :any, default: nil
  attr :plugin_auth_url, :map, default: nil
  attr :plugin_summary, :map, required: true
  attr :oauth_modal, :map, default: nil
  attr :installing_plugins, :list, default: []
  attr :realtime_form, :map, required: true
  attr :report, :map, required: true
  attr :restart_pending?, :boolean, default: false
  attr :sandbox_form, :map, required: true
  attr :search_form, :map, required: true
  attr :image_form, :map, required: true
  attr :restarting, :boolean, default: false
  attr :saved_flash, :map, default: nil
  attr :skill_summary, :map, required: true
  attr :tabs, :list, required: true
  attr :tool_summary, :map, required: true
  attr :provider_statuses, :list, required: true

  def page(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200/40 text-base-content">
      <div
        :if={@restarting}
        class="fixed inset-0 z-50 grid place-items-center bg-base-300/80 backdrop-blur-sm"
      >
        <div class="flex items-center gap-4 rounded-box border border-base-300 bg-base-100 px-6 py-5 shadow-lg">
          <span class="loading loading-spinner loading-md text-primary" />
          <div>
            <p class="font-medium">Restarting Fermix…</p>
            <p class="text-sm text-base-content/60">This page reconnects automatically.</p>
          </div>
        </div>
      </div>

      <div class="mx-auto max-w-6xl gap-6 px-4 py-6 sm:px-6 lg:grid lg:grid-cols-[16rem_minmax(0,1fr)] lg:items-start lg:px-8">
        <.setup_sidebar
          active_tab={@active_tab}
          provider_form={@provider_form}
          report={@report}
          tabs={@tabs}
        />

        <section class="mt-6 min-w-0 lg:mt-0">
          <div :if={@saved_flash} class="mb-4">
            <.flash_banner flash={@saved_flash} />
          </div>

          <div
            id={"setup-pane-#{@active_tab}"}
            phx-hook="UnsavedHint"
            class="relative rounded-box border border-base-300 bg-base-100 p-6 shadow-sm sm:p-8"
          >
            <%!-- Client-only dirty hint: the hook reveals this badge on the first
                  input edit and clears it on submit. The ignore island keeps
                  morphdom from resetting it on phx-change re-renders; the active_tab
                  in the id remounts (and clears) it when you switch panes. --%>
            <div :if={form_pane?(@active_tab)} id={"unsaved-#{@active_tab}"} phx-update="ignore">
              <span
                data-unsaved-badge
                class="absolute right-4 top-4 z-10 hidden items-center gap-1.5 rounded-full border border-warning/40 bg-warning/10 px-2.5 py-1 text-xs font-medium text-warning"
              >
                <span class="size-1.5 rounded-full bg-current"></span> Unsaved changes
              </span>
            </div>
            <.active_pane
              active_tab={@active_tab}
              channels_form={@channels_form}
              codex_auth={@codex_auth}
              codex_auth_running?={@codex_auth_running?}
              codex_auth_url={@codex_auth_url}
              xai_auth={@xai_auth}
              xai_auth_running?={@xai_auth_running?}
              xai_auth_url={@xai_auth_url}
              anthropic_auth={@anthropic_auth}
              anthropic_import_available?={@anthropic_import_available?}
              doctor_result={@doctor_result}
              doctor_probe_running?={@doctor_probe_running?}
              memory_form={@memory_form}
              personalization_form={@personalization_form}
              provider_form={@provider_form}
              provider_models={@provider_models}
              live_models={@live_models}
              provider_statuses={@provider_statuses}
              plugin_auth_url={@plugin_auth_url}
              plugin_summary={@plugin_summary}
              oauth_modal={@oauth_modal}
              installing_plugins={@installing_plugins}
              realtime_form={@realtime_form}
              report={@report}
              restart_pending?={@restart_pending?}
              sandbox_form={@sandbox_form}
              search_form={@search_form}
              image_form={@image_form}
              skill_summary={@skill_summary}
              tabs={@tabs}
              tool_summary={@tool_summary}
            />
          </div>
        </section>
      </div>
    </main>
    """
  end

  attr :active_tab, :string, required: true
  attr :provider_form, :map, required: true
  attr :report, :map, required: true
  attr :tabs, :list, required: true

  defp setup_sidebar(assigns) do
    ~H"""
    <aside class="lg:sticky lg:top-6">
      <div class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
        <div class="flex items-center gap-2.5 px-1">
          <img
            src={~p"/images/fermix-mascot.png"}
            alt=""
            class="size-9 shrink-0 [filter:drop-shadow(0_0_1px_rgba(0,0,0,0.28))]"
          />
          <.fermix_wordmark class="h-5 w-auto text-base-content" />
        </div>

        <div class="mt-4 px-1">
          <div class="flex items-center justify-between text-xs">
            <span class="text-base-content/55">
              Step {current_step_number(@active_tab, @tabs)} of {length(@tabs)}
            </span>
            <span class={status_badge_class(@report.status)}>{format_status(@report.status)}</span>
          </div>
          <div class="mt-2 h-1.5 overflow-hidden rounded-full bg-base-200">
            <div
              class="h-full rounded-full bg-primary transition-all duration-300"
              style={"width: #{setup_progress(@active_tab, @tabs)}%"}
            />
          </div>
        </div>

        <nav class="mt-4" aria-label="Setup steps">
          <ol class="space-y-0.5">
            <li :for={{tab, index} <- Enum.with_index(@tabs)}>
              <button
                type="button"
                phx-click="select_tab"
                phx-value-tab={tab.id}
                class={sidebar_step_class(tab.id, @active_tab)}
                aria-current={if tab.id == @active_tab, do: "step", else: "false"}
              >
                <.step_marker tab={tab} index={index} active_tab={@active_tab} report={@report} />
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium">{tab.label}</span>
                  <span class="block truncate text-xs text-base-content/50">{tab.description}</span>
                </span>
              </button>
            </li>
          </ol>
        </nav>

        <div class="mt-4 flex items-center justify-between gap-3 border-t border-base-300 px-1 pt-3">
          <span class="text-xs font-medium text-base-content/55">Theme</span>
          <Layouts.theme_toggle />
        </div>

        <div class="mt-3 px-1 text-xs text-base-content/55">
          <p class="truncate">
            {provider_label(@provider_form.provider)} · {@provider_form.default_model}
          </p>
          <code class="mt-1 block truncate font-mono text-[11px] text-base-content/45">
            {@report.config_path}
          </code>
        </div>
      </div>
    </aside>
    """
  end

  attr :tab, :map, required: true
  attr :index, :integer, required: true
  attr :active_tab, :string, required: true
  attr :report, :map, required: true

  defp step_marker(assigns) do
    ~H"""
    <span class={step_marker_class(@tab, @active_tab, @report)}>
      <.icon :if={step_done?(@tab, @active_tab, @report)} name="hero-check" class="size-3.5" />
      <span :if={!step_done?(@tab, @active_tab, @report)}>{@index + 1}</span>
    </span>
    """
  end

  attr :active_tab, :string, required: true
  attr :channels_form, :map, required: true
  attr :codex_auth, :map, required: true
  attr :codex_auth_running?, :boolean, required: true
  attr :codex_auth_url, :string, default: nil
  attr :xai_auth, :map, required: true
  attr :xai_auth_running?, :boolean, required: true
  attr :xai_auth_url, :string, default: nil
  attr :anthropic_auth, :map, required: true
  attr :anthropic_import_available?, :boolean, default: false
  attr :doctor_result, :any, required: true
  attr :doctor_probe_running?, :boolean, default: false
  attr :memory_form, :map, required: true
  attr :personalization_form, :map, required: true
  attr :provider_form, :map, required: true
  attr :provider_models, :list, required: true
  attr :live_models, :any, default: nil
  attr :plugin_auth_url, :map, default: nil
  attr :plugin_summary, :map, required: true
  attr :oauth_modal, :map, default: nil
  attr :installing_plugins, :list, default: []
  attr :realtime_form, :map, required: true
  attr :report, :map, required: true
  attr :restart_pending?, :boolean, default: false
  attr :sandbox_form, :map, required: true
  attr :search_form, :map, required: true
  attr :image_form, :map, required: true
  attr :skill_summary, :map, required: true
  attr :tabs, :list, required: true
  attr :tool_summary, :map, required: true
  attr :provider_statuses, :list, required: true

  defp active_pane(assigns), do: render_active_pane(assigns.active_tab, assigns)

  defp render_active_pane("provider", assigns), do: provider_pane(assigns)
  defp render_active_pane("realtime", assigns), do: realtime_pane(assigns)
  defp render_active_pane("channels", assigns), do: channels_pane(assigns)
  defp render_active_pane("plugins", assigns), do: plugins_pane(assigns)
  defp render_active_pane("search", assigns), do: search_pane(assigns)
  defp render_active_pane("media", assigns), do: media_pane(assigns)
  defp render_active_pane("sandbox", assigns), do: sandbox_pane(assigns)
  defp render_active_pane("memory", assigns), do: memory_pane(assigns)
  defp render_active_pane("personalization", assigns), do: personalization_pane(assigns)
  defp render_active_pane("doctor", assigns), do: doctor_pane(assigns)

  defp provider_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Provider &amp; Model"
        subtitle="Choose the reasoning backend and default model. Secrets stay out of the browser after save."
      />

      <form phx-submit="save_provider" phx-change="provider_changed" class="mt-6">
        <section class="space-y-3">
          <p class="text-xs text-base-content/60">
            Select a provider to set it up below. The one you save becomes primary (it serves
            every turn); other configured providers are fallbacks. Changing primary needs a
            daemon restart.
          </p>
          <.provider_cards provider_statuses={@provider_statuses} editing={@provider_form.provider} />
        </section>

        <h3 class="mb-4 mt-6 text-sm font-semibold">
          Configuring {provider_label(@provider_form.provider)}
        </h3>
        <div class={provider_grid_class(@provider_form.provider)}>
          <section class="min-w-0 space-y-5">
            <div class="grid gap-4 lg:grid-cols-2">
              <label class="form-control w-full">
                <span class="label pb-1 text-sm font-medium">Default model</span>
                <.default_model_input
                  provider_form={@provider_form}
                  provider_models={@provider_models}
                  live_models={@live_models}
                />
              </label>
              <%!-- Sub-agent model is a single GLOBAL setting (sub-agents run on the
                    primary provider), so it is shown only on the primary's pane to avoid
                    looking per-provider. Cross-provider sub-agents are a runtime/on-the-fly
                    choice, not a setup one. --%>
              <label
                :if={editing_primary?(@provider_statuses, @provider_form.provider)}
                class="form-control w-full"
              >
                <span class="label pb-1 text-sm font-medium">Sub-agent model</span>
                <select
                  name="provider_form[subagent_model]"
                  class="select select-bordered w-full bg-base-100"
                >
                  <option value="" selected={@provider_form.subagent_model in [nil, ""]}>
                    Same as main model (default)
                  </option>
                  <option
                    :for={entry <- @provider_models}
                    value={entry.id}
                    selected={entry.id == @provider_form.subagent_model}
                  >
                    {entry.label} ({entry.id} - {format_context(entry.context_window)})
                  </option>
                  <%!-- A stored value not in this provider's catalog (e.g. set while
                        another provider was primary) must still display + round-trip,
                        otherwise saving this pane would reset it to "Same as main". --%>
                  <option
                    :if={subagent_model_custom?(@provider_form.subagent_model, @provider_models)}
                    value={@provider_form.subagent_model}
                    selected
                  >
                    {@provider_form.subagent_model} (current)
                  </option>
                </select>
              </label>
            </div>

            <div :if={provider_connection?(@provider_form.provider)} class="space-y-3">
              <h3 class="text-sm font-semibold">Connection</h3>
              <.auth_mode_field
                :if={multi_auth_mode?(@provider_form.provider)}
                provider_form={@provider_form}
              />
              <.provider_secret_field
                :if={api_key_mode?(@provider_form)}
                provider_form={@provider_form}
                report={@report}
              />
              <.ollama_status_banner
                :if={@provider_form.provider == :ollama}
                live_models={@live_models}
              />
              <.provider_plain_fields provider_form={@provider_form} />
              <.codex_auth_field
                provider_form={@provider_form}
                codex_auth={@codex_auth}
                codex_auth_running?={@codex_auth_running?}
                codex_auth_url={@codex_auth_url}
              />
              <.xai_auth_field
                :if={@provider_form.provider == :xai and @provider_form.auth_mode == :oauth}
                xai_auth={@xai_auth}
                xai_auth_running?={@xai_auth_running?}
                xai_auth_url={@xai_auth_url}
              />
              <.anthropic_auth_field
                :if={@provider_form.provider == :anthropic and @provider_form.auth_mode == :oauth}
                anthropic_auth={@anthropic_auth}
                anthropic_import_available?={@anthropic_import_available?}
              />
              <p
                :if={
                  @provider_form.provider in [:anthropic, :xai] and @provider_form.auth_mode == :oauth
                }
                class="text-xs text-base-content/60"
              >
                A saved API key is kept while OAuth is selected; the route switches back if you
                pick API key again. Changing this needs a daemon restart.
              </p>
            </div>
          </section>

          <.provider_behavior_panel provider_form={@provider_form} />
        </div>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save provider" />
      </form>
    </div>
    """
  end

  attr :provider_statuses, :list, required: true
  attr :editing, :atom, required: true

  defp provider_cards(assigns) do
    ~H"""
    <div class="grid gap-2 sm:grid-cols-2">
      <div :for={status <- @provider_statuses} class={provider_card_class(status, @editing)}>
        <label class="flex min-w-0 flex-1 cursor-pointer items-start gap-3">
          <input
            type="radio"
            name="provider_form[provider]"
            class="radio radio-sm radio-primary mt-0.5"
            value={Atom.to_string(status.provider)}
            checked={status.provider == @editing}
          />
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-medium">{provider_label(status.provider)}</span>
              <span class={provider_badge_class(status)}>{provider_badge_label(status)}</span>
            </div>
            <p :if={status.configured?} class="truncate text-xs text-base-content/60">
              {status.model}
            </p>
            <p :if={not status.configured?} class="text-xs text-base-content/50">
              Select to set up credentials.
            </p>
          </div>
        </label>
        <button
          :if={status.configured? and not status.primary?}
          type="button"
          class="btn btn-ghost btn-xs self-center"
          phx-click="set_primary"
          phx-value-provider={Atom.to_string(status.provider)}
        >
          Set primary
        </button>
      </div>
    </div>
    """
  end

  defp provider_card_class(status, editing) do
    base =
      "flex items-start justify-between gap-2 rounded-field border p-3 text-sm transition-colors"

    if status.provider == editing do
      base <> " border-primary bg-primary/5"
    else
      base <> " border-base-300 bg-base-100"
    end
  end

  defp provider_badge_class(%{primary?: true}), do: "badge badge-sm badge-primary"
  defp provider_badge_class(%{configured?: true}), do: "badge badge-sm badge-ghost"
  defp provider_badge_class(_status), do: "badge badge-sm badge-ghost opacity-60"

  defp provider_badge_label(%{primary?: true}), do: "Primary"
  defp provider_badge_label(%{configured?: true}), do: "Fallback"
  defp provider_badge_label(_status), do: "Not configured"

  # Single-mode providers show the secret field iff their mode is api_key;
  # multi-mode providers follow the radio selection (M12 §6.2).
  defp api_key_mode?(%{provider: provider, auth_mode: mode}) do
    descriptor = Descriptor.fetch!(provider)

    if Descriptor.multi_auth_mode?(descriptor) do
      mode == :api_key
    else
      Descriptor.default_auth_mode(descriptor) == :api_key
    end
  end

  defp api_key_mode?(_form), do: false

  defp provider_label(provider), do: Descriptor.fetch!(provider).label

  defp multi_auth_mode?(provider),
    do: Descriptor.multi_auth_mode?(Descriptor.fetch!(provider))

  defp provider_grid_class(provider) do
    [
      "grid gap-5",
      provider_behavior?(provider) && "xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start"
    ]
  end

  defp provider_connection?(provider), do: provider in Descriptor.ids()

  # Hide the "Model behavior" panel when the provider has no behavior
  # knobs (no reasoning effort; the codex fast toggle rides effort? too).
  defp provider_behavior?(provider), do: Descriptor.fetch!(provider).effort?

  attr :provider_form, :map, required: true
  attr :provider_models, :list, required: true
  attr :live_models, :any, default: nil

  # Which options the default-model picker shows: the static catalog for
  # most providers; the LIVE source for providers that have one (installed
  # Ollama models, the upstream OpenRouter catalog). A failed live fetch
  # renders a free-form input plus a loud warning — never a silent
  # fall-back to catalog guesses the server may not serve.
  defp default_model_input(%{live_models: nil} = assigns) do
    ~H"""
    <select name="provider_form[default_model]" class="select select-bordered w-full bg-base-100">
      <option
        :for={entry <- @provider_models}
        value={entry.id}
        selected={entry.id == @provider_form.default_model}
      >
        {entry.label} ({entry.id} - {format_context(entry.context_window)})
      </option>
    </select>
    """
  end

  # Live list (e.g. the upstream OpenRouter catalog) can run to hundreds of
  # entries, so a plain <select> is unnavigable. A free-text <input> backed by
  # a <datalist> lets the user type to filter (matching id or label) and still
  # enter any custom slug. phx-debounce="blur" keeps keystrokes client-side —
  # the form's phx-change only fires once the field loses focus, not per letter.
  defp default_model_input(%{live_models: {:ok, [_ | _] = models}} = assigns) do
    assigns =
      assigns
      |> assign(:models, models)
      |> assign(:list_id, "model-options-#{assigns.provider_form.provider}")

    ~H"""
    <div class="space-y-1">
      <input
        type="text"
        name="provider_form[default_model]"
        value={@provider_form.default_model}
        list={@list_id}
        phx-debounce="blur"
        placeholder="Search or type a model id…"
        class="input input-bordered w-full bg-base-100 font-mono"
      />
      <datalist id={@list_id}>
        <option :for={model <- @models} value={model.id} label={live_model_option(model)} />
      </datalist>
      <p class="text-xs text-base-content/55">
        Type to filter {length(@models)} models, or enter any model id.
      </p>
    </div>
    """
  end

  defp default_model_input(%{live_models: {:ok, []}} = assigns) do
    ~H"""
    <div class="space-y-1">
      <input
        type="text"
        name="provider_form[default_model]"
        value={@provider_form.default_model}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
      <p class="text-xs text-warning">
        No models installed on this server — run <code>ollama pull &lt;model&gt;</code>.
      </p>
    </div>
    """
  end

  defp default_model_input(%{live_models: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <div class="space-y-1">
      <input
        type="text"
        name="provider_form[default_model]"
        value={@provider_form.default_model}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
      <p class="text-xs text-warning">
        Couldn't fetch the live model list ({@reason}) — enter a model id manually.
      </p>
    </div>
    """
  end

  defp live_model_option(%{label: label, id: id, context_window: nil}) when label == id, do: id

  defp live_model_option(%{label: label, id: id, context_window: nil}), do: "#{label} (#{id})"

  defp live_model_option(%{label: label, id: id, context_window: ctx}) when label == id do
    "#{id} - #{format_context(ctx)}"
  end

  defp live_model_option(%{label: label, id: id, context_window: ctx}) do
    "#{label} (#{id} - #{format_context(ctx)})"
  end

  attr :live_models, :any, default: nil

  # Server detection for the Ollama pane — one signal: the configured URL
  # either serves a model list or it doesn't. No host binary sniffing.
  defp ollama_status_banner(%{live_models: {:ok, models}} = assigns) do
    assigns = assign(assigns, :count, length(models))

    ~H"""
    <p class="rounded-field border border-success/40 bg-success/10 p-3 text-xs">
      Ollama server detected — {@count} installed model(s) listed below.
    </p>
    """
  end

  defp ollama_status_banner(%{live_models: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="rounded-field border border-warning/40 bg-warning/10 p-3 text-xs">
      No Ollama server responded ({@reason}). Start one with <code>ollama serve</code>
      (install from <a href="https://ollama.com" target="_blank" class="link">ollama.com</a>
      if needed), or point the base URL at a remote server.
    </p>
    """
  end

  defp ollama_status_banner(assigns), do: ~H""

  attr :provider_form, :map, required: true

  # Non-secret descriptor setup fields (e.g. Ollama's base_url) render as
  # plain text inputs prefilled with the saved value or descriptor default.
  defp provider_plain_fields(assigns) do
    assigns = assign(assigns, :plain_fields, plain_field_specs(assigns.provider_form.provider))

    ~H"""
    <label :for={field <- @plain_fields} class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{field.label}</span>
      <input
        type="text"
        name={"provider_form[#{field.key}]"}
        value={Map.get(@provider_form.field_values || %{}, field.key)}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
    </label>
    """
  end

  defp plain_field_specs(provider) do
    Enum.reject(Descriptor.fetch!(provider).setup_fields, & &1.secret?)
  end

  attr :provider_form, :map, required: true
  attr :report, :map, required: true

  defp provider_secret_field(assigns) do
    assigns =
      assigns
      |> assign(:secret_label, provider_secret_label(assigns.provider_form.provider))
      |> assign(:secret_name, provider_secret_name(assigns.provider_form.provider))

    ~H"""
    <label
      :if={@secret_name}
      class="form-control w-full"
    >
      <span class="label pb-1 text-sm font-medium">{@secret_label}</span>
      <input
        type="password"
        name={@secret_name}
        placeholder={secret_placeholder(api_key_set?(@report, @provider_form.provider))}
        class="input input-bordered w-full bg-base-100 font-mono"
        value=""
      />
      <span class="label pt-1 text-xs text-base-content/60">
        Leave blank to keep the existing key.
      </span>
    </label>
    """
  end

  # The web label stays short ("<Provider> API key") — the descriptor's
  # field label carries CLI-only hints (e.g. the xAI OAuth pointer) that
  # the web pane expresses through the auth-mode picker instead.
  defp provider_secret_field_spec(provider) do
    Descriptor.fetch!(provider).setup_fields |> Enum.find(& &1.secret?)
  end

  defp provider_secret_label(provider) do
    case provider_secret_field_spec(provider) do
      nil -> nil
      _field -> "#{provider_label(provider)} API key"
    end
  end

  defp provider_secret_name(provider) do
    case provider_secret_field_spec(provider) do
      nil -> nil
      field -> "provider_form[#{field.key}]"
    end
  end

  attr :provider_form, :map, required: true
  attr :codex_auth, :map, required: true
  attr :codex_auth_running?, :boolean, required: true
  attr :codex_auth_url, :string, default: nil

  defp codex_auth_field(assigns) do
    ~H"""
    <section
      :if={@provider_form.provider == :openai_codex}
      data-codex-auth-panel="true"
      class="rounded-field border border-base-300 bg-base-200/40 p-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="text-sm font-medium">ChatGPT OAuth</p>
          <p class="mt-1 text-xs leading-5 text-base-content/60">
            Codex uses browser login and stores credentials in the Fermix auth store.
          </p>
        </div>
        <span class={codex_auth_badge_class(@codex_auth, @codex_auth_running?)}>
          {codex_auth_badge_label(@codex_auth, @codex_auth_running?)}
        </span>
      </div>

      <p :if={@codex_auth.account} class="mt-2 truncate text-xs text-base-content/55">
        Account: {@codex_auth.account}
      </p>

      <p :if={@codex_auth.error} class="mt-2 text-xs text-error">
        Auth store error: {@codex_auth.error}
      </p>

      <div class="mt-3 flex flex-wrap items-center gap-2">
        <button
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="codex_login"
          data-auth-trigger="true"
          disabled={@codex_auth_running?}
        >
          <.icon name="hero-key" class="size-4" />
          {codex_auth_button_label(@codex_auth, @codex_auth_running?)}
        </button>
      </div>

      <div
        :if={@codex_auth_url}
        class="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-field border border-base-300 bg-base-100/70 px-3 py-2 text-xs text-base-content/65"
      >
        <span>If the ChatGPT tab did not open, use the fallback link.</span>
        <a
          class="link link-primary font-medium"
          href={@codex_auth_url}
          target="_blank"
          rel="noreferrer"
        >
          Open sign-in
        </a>
      </div>
    </section>
    """
  end

  defp codex_auth_badge_class(_auth, true), do: "badge badge-warning badge-sm"
  defp codex_auth_badge_class(%{connected?: true}, false), do: "badge badge-success badge-sm"
  defp codex_auth_badge_class(_auth, false), do: "badge badge-warning badge-sm"

  defp codex_auth_badge_label(_auth, true), do: "Waiting"
  defp codex_auth_badge_label(%{connected?: true}, false), do: "Connected"
  defp codex_auth_badge_label(_auth, false), do: "Needs auth"

  defp codex_auth_button_label(_auth, true), do: "Waiting for login"
  defp codex_auth_button_label(%{connected?: true}, false), do: "Reconnect ChatGPT"
  defp codex_auth_button_label(_auth, false), do: "Sign in with ChatGPT"

  attr :provider_form, :map, required: true

  defp auth_mode_field(assigns) do
    ~H"""
    <fieldset class="form-control">
      <legend class="label pb-1 text-sm font-medium">Authentication</legend>
      <div class="flex flex-wrap gap-4">
        <label class="flex items-center gap-2 text-sm">
          <input
            type="radio"
            name="provider_form[auth_mode]"
            value="api_key"
            checked={@provider_form.auth_mode == :api_key}
            class="radio radio-sm"
          />
          <span>API key</span>
        </label>
        <label class="flex items-center gap-2 text-sm">
          <input
            type="radio"
            name="provider_form[auth_mode]"
            value="oauth"
            checked={@provider_form.auth_mode == :oauth}
            class="radio radio-sm"
          />
          <span>Subscription (OAuth)</span>
        </label>
      </div>
    </fieldset>
    """
  end

  attr :xai_auth, :map, required: true
  attr :xai_auth_running?, :boolean, required: true
  attr :xai_auth_url, :string, default: nil

  defp xai_auth_field(assigns) do
    ~H"""
    <section
      data-xai-auth-panel="true"
      class="rounded-field border border-base-300 bg-base-200/40 p-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="text-sm font-medium">Grok OAuth</p>
          <p class="mt-1 text-xs leading-5 text-base-content/60">
            Grok uses browser login and stores credentials in the Fermix auth store.
          </p>
        </div>
        <span class={codex_auth_badge_class(@xai_auth, @xai_auth_running?)}>
          {codex_auth_badge_label(@xai_auth, @xai_auth_running?)}
        </span>
      </div>

      <p :if={@xai_auth.error} class="mt-2 text-xs text-error">
        Auth store error: {@xai_auth.error}
      </p>

      <div class="mt-3 flex flex-wrap items-center gap-2">
        <button
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="xai_login"
          data-auth-trigger="true"
          disabled={@xai_auth_running?}
        >
          <.icon name="hero-key" class="size-4" />
          {xai_auth_button_label(@xai_auth, @xai_auth_running?)}
        </button>
      </div>

      <div
        :if={@xai_auth_url}
        class="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-field border border-base-300 bg-base-100/70 px-3 py-2 text-xs text-base-content/65"
      >
        <span>If the Grok tab did not open, use the fallback link.</span>
        <a class="link link-primary font-medium" href={@xai_auth_url} target="_blank" rel="noreferrer">
          Open sign-in
        </a>
      </div>
    </section>
    """
  end

  defp xai_auth_button_label(_auth, true), do: "Waiting for login"
  defp xai_auth_button_label(%{connected?: true}, false), do: "Reconnect Grok"
  defp xai_auth_button_label(_auth, false), do: "Sign in with Grok"

  attr :anthropic_auth, :map, required: true
  attr :anthropic_import_available?, :boolean, default: false

  defp anthropic_auth_field(assigns) do
    ~H"""
    <section
      data-anthropic-auth-panel="true"
      class="rounded-field border border-base-300 bg-base-200/40 p-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="text-sm font-medium">Anthropic subscription (OAuth)</p>
          <p class="mt-1 text-xs leading-5 text-base-content/60">
            No in-app browser login: paste a <code class="font-mono">claude setup-token</code>
            (run it in Claude Code) and click <em>Save provider</em>, or import an existing
            Claude Code login.
          </p>
        </div>
        <span class={codex_auth_badge_class(@anthropic_auth, false)}>
          {codex_auth_badge_label(@anthropic_auth, false)}
        </span>
      </div>

      <p :if={@anthropic_auth.error} class="mt-2 text-xs text-error">
        Auth store error: {@anthropic_auth.error}
      </p>

      <label class="form-control mt-3 w-full">
        <span class="label pb-1 text-xs font-medium">Setup token</span>
        <input
          type="password"
          name="provider_form[anthropic_setup_token]"
          placeholder="claude setup-token output (leave blank to keep)"
          class="input input-bordered input-sm w-full bg-base-100 font-mono"
        />
      </label>

      <div :if={@anthropic_import_available?} class="mt-2">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="anthropic_import">
          Import Claude Code login
        </button>
      </div>
    </section>
    """
  end

  attr :provider_form, :map, required: true

  defp provider_behavior_panel(assigns) do
    ~H"""
    <section
      :if={provider_behavior?(@provider_form.provider)}
      class="rounded-field border border-base-300 bg-base-200/40 p-4"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="text-sm font-semibold">Model behavior</h3>
        <span class="badge badge-ghost badge-sm">{provider_label(@provider_form.provider)}</span>
      </div>

      <div class="mt-4 space-y-4">
        <.reasoning_effort_field
          :if={effort_provider?(@provider_form.provider)}
          provider_form={@provider_form}
        />
        <.codex_fast_field provider_form={@provider_form} />
      </div>
    </section>
    """
  end

  attr :provider_form, :map, required: true

  defp reasoning_effort_field(assigns) do
    ~H"""
    <fieldset
      :if={@provider_form.provider in [:openai, :openai_codex, :anthropic, :xai]}
      class="form-control"
    >
      <legend class="label pb-1 text-sm font-medium">Reasoning effort</legend>
      <div class="mt-1 grid grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-2">
        <label
          :for={effort <- effort_levels(@provider_form.provider)}
          class="flex cursor-pointer items-center gap-2 rounded-field border border-base-300 bg-base-100 px-2.5 py-2 hover:border-primary/50"
        >
          <input
            type="radio"
            name="provider_form[reasoning_effort]"
            value={effort}
            checked={Atom.to_string(@provider_form.reasoning_effort) == effort}
            class="radio radio-sm radio-primary"
          />
          <span class="text-sm">{effort}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp effort_provider?(provider), do: Descriptor.fetch!(provider).effort?

  defp effort_levels(provider) do
    provider |> ReasoningEffort.levels_for() |> Enum.map(&Atom.to_string/1)
  end

  attr :provider_form, :map, required: true

  defp codex_fast_field(assigns) do
    ~H"""
    <label
      :if={@provider_form.provider == :openai_codex}
      class="flex items-start gap-3 rounded-field border border-base-300 bg-base-100 p-3"
    >
      <input type="hidden" name="provider_form[fast]" value="false" />
      <input
        type="checkbox"
        name="provider_form[fast]"
        value="true"
        checked={@provider_form.fast == true}
        class="toggle toggle-primary mt-1"
      />
      <span>
        <span class="block text-sm font-medium">Fast mode</span>
        <span class="block text-xs text-base-content/60">
          Use priority processing when Codex supports it. This may consume credits faster.
        </span>
      </span>
    </label>
    """
  end

  defp realtime_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Voice companion"
        subtitle="Enable the local Realtime voice path when this host should run FermixPet."
      />

      <form phx-submit="save_realtime" class="mt-6 space-y-5">
        <.realtime_primary_fields form={@realtime_form} />
        <.realtime_secret_field form={@realtime_form} />
        <.realtime_limit_fields form={@realtime_form} />
        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save realtime" />
      </form>
    </div>
    """
  end

  attr :form, :map, required: true

  defp realtime_primary_fields(assigns) do
    ~H"""
    <div class="grid items-start gap-4 lg:grid-cols-2">
      <label class="form-control w-full">
        <span class="label pb-1 text-sm font-medium">Realtime status</span>
        <select name="realtime_form[enabled]" class="select select-bordered w-full bg-base-100">
          <option value="false" selected={!@form.enabled}>Disabled</option>
          <option value="true" selected={@form.enabled}>Enabled</option>
        </select>
      </label>

      <label class="form-control w-full">
        <span class="label pb-1 text-sm font-medium">Voice</span>
        <input
          type="text"
          name="realtime_form[voice]"
          value={@form.voice}
          class="input input-bordered w-full bg-base-100"
        />
      </label>
    </div>
    """
  end

  attr :form, :map, required: true

  defp realtime_secret_field(assigns) do
    ~H"""
    <label class="form-control w-full max-w-xl">
      <span class="label pb-1 text-sm font-medium">OpenAI API key for Realtime</span>
      <input
        type="password"
        name="realtime_form[api_key]"
        placeholder={secret_placeholder(@form.api_key_set)}
        class="input input-bordered w-full bg-base-100 font-mono"
        value=""
      />
      <span class="label pt-1 text-xs text-base-content/60">
        Realtime V1 uses OpenAI. Leave blank to reuse the current OpenAI key.
      </span>
    </label>
    """
  end

  attr :form, :map, required: true

  defp realtime_limit_fields(assigns) do
    ~H"""
    <div class="grid items-start gap-4 lg:grid-cols-3">
      <.number_field
        label="Max session minutes"
        name="realtime_form[max_session_minutes]"
        value={@form.max_session_minutes}
      />
      <.number_field
        label="Max cost cents"
        name="realtime_form[max_cost_cents]"
        value={@form.max_cost_cents}
      />
      <label class="form-control w-full">
        <span class="label pb-1 text-sm font-medium">Save transcripts</span>
        <select
          name="realtime_form[persist_transcripts]"
          class="select select-bordered w-full bg-base-100"
        >
          <option value="false" selected={!@form.persist_transcripts}>No</option>
          <option value="true" selected={@form.persist_transcripts}>Yes</option>
        </select>
      </label>
    </div>
    """
  end

  defp channels_pane(assigns) do
    sections = channel_sections(assigns.channels_form, assigns.report)
    editing = assigns.channels_form.editing
    editing_section = Enum.find(sections, &(&1.channel == editing)) || hd(sections)

    assigns =
      assign(assigns,
        channel_sections: sections,
        editing_section: editing_section,
        editing: editing
      )

    ~H"""
    <div>
      <.pane_header
        title="Channel coverage"
        subtitle="Add the tokens and owner IDs for the message surfaces this host should accept."
      />

      <section class="mt-6 space-y-3">
        <p class="text-xs text-base-content/60">
          Pick a channel to add its tokens and owner ID. Each channel is independent — there is no
          primary; configure as many as you need.
        </p>
        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <button
            :for={section <- @channel_sections}
            type="button"
            phx-click="select_channel"
            phx-value-channel={Atom.to_string(section.channel)}
            class={channel_card_class(section.channel, @editing)}
          >
            <span class="font-medium">{section.title}</span>
            <.status_pill status={section.status} />
          </button>
        </div>
      </section>

      <form phx-submit="save_channels" class="mt-6 space-y-5">
        <.integration_panel title={@editing_section.title} status={@editing_section.status}>
          <.channel_field :for={field <- @editing_section.fields} field={field} />
        </.integration_panel>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save channel" />
      </form>
    </div>
    """
  end

  defp plugins_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Integrations"
        subtitle="Connect an integration to sign in and enable its tools. Provider setup (like a Google OAuth client) sits with each group below."
      />

      <.google_plugin_group
        :if={@plugin_summary.available}
        plugin_summary={@plugin_summary}
        plugin_auth_url={@plugin_auth_url}
      />

      <.provider_plugin_group
        :for={group <- oauth_provider_groups(@plugin_summary)}
        oauth={group.oauth}
        plugins={group.plugins}
        catalog={group.catalog}
        installing_plugins={@installing_plugins}
        plugin_auth_url={@plugin_auth_url}
      />

      <div
        :if={@plugin_summary.available && ungrouped_plugins(@plugin_summary) != []}
        class="mt-5 flex flex-col gap-2"
      >
        <.plugin_card :for={plugin <- ungrouped_plugins(@plugin_summary)} plugin={plugin} />
      </div>

      <section :if={@plugin_summary.available} class="mt-5">
        <p :if={@plugin_summary.index_error} class="text-xs text-warning">
          Catalog index unavailable: {@plugin_summary.index_error}. Installed plugins still work.
        </p>
        <div :if={ungrouped_catalog(@plugin_summary) != []} class="flex flex-col gap-2">
          <.catalog_card
            :for={entry <- ungrouped_catalog(@plugin_summary)}
            entry={entry}
            installing?={entry.name in @installing_plugins}
          />
        </div>
      </section>

      <.info_panel :if={!@plugin_summary.available} class="mt-5">
        <p>Plugin catalog unavailable: {@plugin_summary.error}</p>
      </.info_panel>

      <.oauth_client_modal oauth_modal={@oauth_modal} plugin_summary={@plugin_summary} />

      <.step_actions active_tab={@active_tab} tabs={@tabs} />
    </div>
    """
  end

  defp search_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Search backend"
        subtitle="Choose the public web search provider and save optional provider keys in the OS keyring."
      />

      <form phx-change="search_changed" phx-submit="save_search" class="mt-6 space-y-6">
        <fieldset>
          <legend class="text-sm font-medium text-base-content/80">Provider</legend>
          <div class="mt-2 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.search_backend_option
              value="duckduckgo"
              label="DuckDuckGo"
              description="Keyless HTML results"
              checked={@search_form.backend == :duckduckgo}
            />
            <.search_backend_option
              value="tavily"
              label="Tavily"
              description="API-backed search"
              checked={@search_form.backend == :tavily}
            />
            <.search_backend_option
              value="exa"
              label="Exa"
              description="Neural web search"
              checked={@search_form.backend == :exa}
            />
            <.search_backend_option
              value="parallel"
              label="Parallel"
              description="Research search API"
              checked={@search_form.backend == :parallel}
            />
            <.search_backend_option
              value="brave"
              label="Brave"
              description="Independent search API"
              checked={@search_form.backend == :brave}
            />
            <.search_backend_option
              value="perplexity"
              label="Perplexity"
              description="Structured search API"
              checked={@search_form.backend == :perplexity}
            />
            <.search_backend_option
              value="firecrawl"
              label="Firecrawl"
              description="Web search API"
              checked={@search_form.backend == :firecrawl}
            />
          </div>
        </fieldset>

        <div class="max-w-xl">
          <.secret_input
            :if={@search_form.backend == :tavily}
            label="Tavily API key"
            name="search_form[tavily_api_key]"
            set={@search_form.tavily_api_key_set}
          />
          <.secret_input
            :if={@search_form.backend == :exa}
            label="Exa API key"
            name="search_form[exa_api_key]"
            set={@search_form.exa_api_key_set}
          />
          <.secret_input
            :if={@search_form.backend == :parallel}
            label="Parallel API key"
            name="search_form[parallel_api_key]"
            set={@search_form.parallel_api_key_set}
          />
          <.secret_input
            :if={@search_form.backend == :brave}
            label="Brave API key"
            name="search_form[brave_api_key]"
            set={@search_form.brave_api_key_set}
          />
          <.secret_input
            :if={@search_form.backend == :perplexity}
            label="Perplexity API key"
            name="search_form[perplexity_api_key]"
            set={@search_form.perplexity_api_key_set}
          />
          <.secret_input
            :if={@search_form.backend == :firecrawl}
            label="Firecrawl API key"
            name="search_form[firecrawl_api_key]"
            set={@search_form.firecrawl_api_key_set}
          />
          <p :if={@search_form.backend == :duckduckgo} class="text-sm text-base-content/60">
            DuckDuckGo needs no API key — nothing else to configure here.
          </p>
        </div>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save search" />
      </form>
    </div>
    """
  end

  defp media_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Image generation"
        subtitle="Pick the backend for the generate_image tool and set its API key here. The OpenAI and xAI keys are the same keys those providers use for chat; Google uses its own Gemini key."
      />

      <form phx-change="image_changed" phx-submit="save_image" class="mt-6 space-y-6">
        <fieldset>
          <legend class="text-sm font-medium text-base-content/80">Backend</legend>
          <div class="mt-2 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <.image_backend_option
              value="openai"
              label="OpenAI"
              description="gpt-image — reuses your OpenAI key"
              checked={@image_form.backend == :openai}
            />
            <.image_backend_option
              value="xai"
              label="xAI"
              description="grok image — reuses your xAI key"
              checked={@image_form.backend == :xai}
            />
            <.image_backend_option
              value="google"
              label="Google"
              description="Gemini image — needs a Gemini key"
              checked={@image_form.backend == :google}
            />
          </div>
        </fieldset>

        <div class="max-w-xl space-y-4">
          <div :if={@image_form.backend == :openai} class="space-y-2">
            <.secret_input
              label="OpenAI API key"
              name="image_form[openai_api_key]"
              set={@image_form.openai_api_key_set}
            />
            <p :if={@image_form.openai_api_key_set} class="text-sm text-success">
              Already configured. Leave blank to keep it, or paste a new key to replace it.
            </p>
          </div>
          <div :if={@image_form.backend == :xai} class="space-y-2">
            <.secret_input
              label="xAI API key"
              name="image_form[xai_api_key]"
              set={@image_form.xai_api_key_set}
            />
            <p :if={@image_form.xai_api_key_set} class="text-sm text-success">
              Already configured. Leave blank to keep it, or paste a new key to replace it.
            </p>
          </div>
          <div :if={@image_form.backend == :google} class="space-y-2">
            <.secret_input
              label="Gemini API key"
              name="image_form[google_api_key]"
              set={@image_form.google_api_key_set}
            />
            <p :if={@image_form.google_api_key_set} class="text-sm text-success">
              Already configured. Leave blank to keep it, or paste a new key to replace it.
            </p>
          </div>

          <.select_field
            label="Model"
            name="image_form[model]"
            options={@image_form.model_options}
            value={@image_form.model}
          />
          <p class="text-sm text-base-content/60">
            Choose the image model for this backend.
          </p>
        </div>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save media" />
      </form>
    </div>
    """
  end

  defp sandbox_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Sandbox policy"
        subtitle="Set the local execution posture and the environment names commands may receive."
      />

      <form phx-submit="save_sandbox" class="mt-6 space-y-5">
        <div class="grid gap-4 lg:grid-cols-2">
          <.select_field
            label="Mode"
            name="sandbox_form[mode]"
            options={~w(strict standard open)}
            value={@sandbox_form.mode}
          />
          <.select_field
            label="Command profile"
            name="sandbox_form[profile]"
            options={~w(bare assistant extended)}
            value={@sandbox_form.profile}
          />
        </div>

        <label class="form-control w-full">
          <span class="label pb-1 text-sm font-medium">Allowed env names</span>
          <textarea
            name="sandbox_form[env_allow]"
            class="textarea textarea-bordered min-h-28 w-full bg-base-100 font-mono"
            placeholder="OPENAI_API_KEY, TELEGRAM_BOT_TOKEN"
          >{@sandbox_form.env_allow}</textarea>
          <span class="label pt-1 text-xs text-base-content/60">
            Comma or newline separated. Values are never exposed here.
          </span>
        </label>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save sandbox" />
      </form>
    </div>
    """
  end

  defp memory_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Memory tuning"
        subtitle="Tune compaction and background review limits for durable memory."
      />
      <form phx-submit="save_memory" class="mt-6 space-y-5">
        <div class="grid gap-4 lg:grid-cols-2">
          <.number_field
            label="Compaction threshold"
            name="memory_form[compaction_threshold]"
            value={@memory_form.compaction_threshold}
            min="0.1"
            max="1.0"
            step="0.01"
          />
          <.number_field
            label="Extraction timeout ms"
            name="memory_form[extraction_timeout_ms]"
            value={@memory_form.extraction_timeout_ms}
          />
        </div>
        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save memory" />
      </form>
    </div>
    """
  end

  defp personalization_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Personalization"
        subtitle="Seed the profile that guides how the agent addresses you and frames replies."
      />
      <form phx-submit="save_personalization" class="mt-6 space-y-5">
        <div class="grid gap-4 lg:grid-cols-3">
          <.text_input
            label="Your name"
            name="personalization_form[user_name]"
            value={@personalization_form.user_name}
          />
          <.text_input
            label="Timezone"
            name="personalization_form[timezone]"
            value={@personalization_form.timezone}
          />
          <.text_input
            label="Communication style"
            name="personalization_form[communication_style]"
            value={@personalization_form.communication_style}
          />
        </div>
        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save personalization" />
      </form>
    </div>
    """
  end

  defp doctor_pane(assigns) do
    ~H"""
    <div>
      <.pane_header
        title="Readiness doctor"
        subtitle="Review remaining setup gaps and run live provider and channel probes when you are ready."
      />
      <div class="mt-6 space-y-4">
        <.validation_list report={@report} />
        <.skill_summary_panel skill_summary={@skill_summary} />
        <.tool_summary_panel tool_summary={@tool_summary} />
        <.doctor_result result={@doctor_result} />
      </div>
      <div class="mt-6 flex flex-wrap items-center justify-between gap-3 border-t border-base-300 pt-5">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="previous_step">
          <.icon name="hero-arrow-left" class="size-4" /> Back
        </button>
        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="run_doctor"
            disabled={@doctor_probe_running?}
          >
            <span
              :if={@doctor_probe_running?}
              class="loading loading-spinner loading-xs"
              aria-hidden="true"
            />
            <.icon :if={!@doctor_probe_running?} name="hero-play" class="size-4" />
            {if @doctor_probe_running?, do: "Running...", else: "Run probe"}
          </button>
          <button
            :if={@report.restart_required? || @restart_pending?}
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="apply_restart"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Apply &amp; restart
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  defp pane_header(assigns) do
    ~H"""
    <div class="max-w-3xl">
      <h2 class="text-2xl font-semibold tracking-normal">{raw(@title)}</h2>
      <p class="mt-2 text-sm leading-6 text-base-content/70">{@subtitle}</p>
    </div>
    """
  end

  attr :active_tab, :string, required: true
  attr :tabs, :list, required: true
  attr :save_label, :string, required: true

  defp form_actions(assigns) do
    ~H"""
    <div class="mt-8 flex flex-wrap items-center justify-between gap-3 border-t border-base-300 pt-5">
      <button
        :if={!first_step?(@active_tab, @tabs)}
        type="button"
        class="btn btn-ghost btn-sm"
        phx-click="previous_step"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Back
      </button>
      <span :if={first_step?(@active_tab, @tabs)} />

      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={!last_step?(@active_tab, @tabs)}
          type="submit"
          name="__nav"
          value="stay"
          class="btn btn-ghost btn-sm"
        >
          {@save_label}
        </button>
        <button
          :if={!last_step?(@active_tab, @tabs)}
          type="submit"
          name="__nav"
          value="next"
          class="btn btn-primary btn-sm"
        >
          Save &amp; next <.icon name="hero-arrow-right" class="size-4" />
        </button>
        <button
          :if={last_step?(@active_tab, @tabs)}
          type="submit"
          name="__nav"
          value="stay"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-check" class="size-4" /> {@save_label}
        </button>
      </div>
    </div>
    """
  end

  attr :active_tab, :string, required: true
  attr :tabs, :list, required: true

  defp step_actions(assigns) do
    ~H"""
    <div class="mt-6 flex flex-wrap items-center justify-between gap-3 border-t border-base-300 pt-5">
      <button
        :if={!first_step?(@active_tab, @tabs)}
        type="button"
        class="btn btn-outline"
        phx-click="previous_step"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Back
      </button>
      <span :if={first_step?(@active_tab, @tabs)} />
      <button
        :if={!last_step?(@active_tab, @tabs)}
        type="button"
        class="btn btn-primary"
        phx-click="next_step"
      >
        Next step <.icon name="hero-arrow-right" class="size-4" />
      </button>
    </div>
    """
  end

  attr :plugin_summary, :map, required: true
  attr :plugin_auth_url, :map, default: nil

  defp google_plugin_group(assigns) do
    assigns =
      assigns
      |> assign(:oauth, Map.fetch!(assigns.plugin_summary.oauth_clients, "google"))
      |> assign(:plugins, google_plugins(assigns.plugin_summary.plugins))

    ~H"""
    <section
      data-plugin-group="google"
      class="mt-5 rounded-box border border-base-300 bg-base-100/80 p-3 shadow-sm"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="flex items-center gap-1.5">
            <h3 class="text-sm font-semibold">Google</h3>
            <.oauth_help provider="google" />
          </div>
          <p class="text-xs text-base-content/55">Calendar, Gmail, and Drive</p>
        </div>
        <span class="badge badge-ghost badge-sm">OAuth desktop client</span>
      </div>

      <.oauth_client_row oauth={@oauth} />

      <.auth_fallback_link plugin_auth_url={@plugin_auth_url} plugins={@plugins} />

      <div class="mt-3 flex flex-col gap-2">
        <.plugin_card
          :for={plugin <- @plugins}
          plugin={plugin}
          label={strip_google_prefix(plugin.display_name)}
          auth_preopen?={oauth_client_configured?(@oauth) && plugin.auth_type == :oauth2}
        />
      </div>
    </section>
    """
  end

  # A non-Google oauth2 provider group. A single-plugin provider (GitHub, Notion,
  # X) renders as one bare card — like an ungrouped plugin — with the OAuth
  # client Connect/Edit folded into that card, so there is no redundant client
  # row. Only a multi-plugin provider (or one with a client but no card yet) gets
  # the shared client row in a titled section, the way Google does.
  attr :oauth, :map, required: true
  attr :plugins, :list, required: true
  attr :catalog, :list, default: []
  attr :installing_plugins, :list, default: []
  attr :plugin_auth_url, :map, default: nil

  defp provider_plugin_group(assigns) do
    assigns = assign(assigns, :card_count, length(assigns.plugins) + length(assigns.catalog))

    ~H"""
    <div
      :if={@card_count == 1}
      data-plugin-group={@oauth.provider}
      class="mt-5 flex flex-col gap-2"
    >
      <.plugin_card
        :for={plugin <- @plugins}
        plugin={plugin}
        oauth={@oauth}
        auth_preopen?={oauth_client_configured?(@oauth) && plugin.auth_type == :oauth2}
      />
      <.catalog_card
        :for={entry <- @catalog}
        entry={entry}
        oauth={@oauth}
        installing?={entry.name in @installing_plugins}
      />
      <.auth_fallback_link plugin_auth_url={@plugin_auth_url} plugins={@plugins} />
    </div>

    <section
      :if={@card_count != 1}
      data-plugin-group={@oauth.provider}
      class="mt-5 rounded-box border border-base-300 bg-base-100/80 p-3 shadow-sm"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-1.5">
          <h3 class="text-sm font-semibold">{@oauth.display_name}</h3>
          <.oauth_help provider={@oauth.provider} />
        </div>
        <span class="badge badge-ghost badge-sm">OAuth client</span>
      </div>

      <.oauth_client_row oauth={@oauth} />

      <p :if={@plugins == [] and @catalog == []} class="mt-2 text-xs text-base-content/55">
        Used when connecting {@oauth.display_name} from the catalog.
      </p>

      <.auth_fallback_link plugin_auth_url={@plugin_auth_url} plugins={@plugins} />

      <div :if={@plugins != [] or @catalog != []} class="mt-3 flex flex-col gap-2">
        <.plugin_card
          :for={plugin <- @plugins}
          plugin={plugin}
          auth_preopen?={oauth_client_configured?(@oauth) && plugin.auth_type == :oauth2}
        />
        <.catalog_card
          :for={entry <- @catalog}
          entry={entry}
          installing?={entry.name in @installing_plugins}
        />
      </div>
    </section>
    """
  end

  # Info "i" next to a provider heading: hover shows where to create the OAuth
  # client; clicking opens that provider's credentials page in a new tab.
  attr :provider, :string, required: true

  defp oauth_help(assigns) do
    {desc, url} = oauth_help_content(assigns.provider)
    assigns = assign(assigns, desc: desc, url: url)

    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="tooltip tooltip-bottom z-10 text-base-content/45 hover:text-base-content"
      data-tip={@desc}
      aria-label={"How to get #{@provider} OAuth credentials"}
    >
      <.icon name="hero-information-circle" class="size-4" />
    </a>
    """
  end

  defp oauth_help_content("google") do
    {"Google Cloud Console → APIs & Services → Credentials → Create credentials → OAuth client ID → Desktop app. Paste the Client ID and secret.",
     "https://console.cloud.google.com/apis/credentials"}
  end

  defp oauth_help_content("github") do
    {"GitHub → Settings → Developer settings → OAuth Apps → New. Set the callback to http://127.0.0.1/auth/callback, then paste the Client ID and secret.",
     "https://github.com/settings/developers"}
  end

  defp oauth_help_content("notion") do
    {"Notion → my integrations → New integration → Public. Set the redirect URI to http://localhost:1458/auth/callback (Notion forces https for 127.0.0.1 — use localhost), then paste the OAuth Client ID and secret.",
     "https://www.notion.so/my-integrations"}
  end

  defp oauth_help_content("x") do
    {"X Developer Portal → your app → User authentication settings: type \"Web App, Automated App or Bot\", callback URI http://127.0.0.1:1459/auth/callback exactly. Paste the OAuth 2.0 Client ID and secret. Note: X API usage is paid (pay-per-use credits).",
     "https://developer.x.com/en/portal/dashboard"}
  end

  defp oauth_help_content("slack") do
    {"Slack api.slack.com/apps → Create New App (from scratch) → OAuth & Permissions: add redirect URL http://127.0.0.1:1460/auth/callback and the bot scopes, then paste the Client ID and secret from Basic Information.",
     "https://api.slack.com/apps"}
  end

  defp oauth_help_content(provider) do
    {"Create an OAuth client with #{provider}, then paste its Client ID and secret.", nil}
  end

  # Compact one-line replacement for the always-visible client form: it states
  # whether the provider's OAuth client is set up and opens the modal to enter
  # (Connect) or change (Edit) the credentials. The actual sign-in stays on the
  # plugin cards below, so the popup-blocker click chain is untouched.
  attr :oauth, :map, required: true

  defp oauth_client_row(assigns) do
    assigns = assign(assigns, :configured?, oauth_client_configured?(assigns.oauth))

    ~H"""
    <div class="mt-3 flex items-center justify-between gap-3 rounded-field border border-base-300 bg-base-200/40 px-3 py-2">
      <div class="min-w-0">
        <p class="text-xs font-medium">OAuth client</p>
        <p class="truncate text-xs text-base-content/55">
          {if @configured?,
            do: "Configured — credentials stored",
            else: "Not set up — required to connect"}
        </p>
      </div>
      <button
        type="button"
        class={["btn btn-xs", (@configured? && "btn-ghost") || "btn-primary"]}
        phx-click="open_oauth_modal"
        phx-value-provider={@oauth.provider}
      >
        <.icon name={if @configured?, do: "hero-pencil-square", else: "hero-key"} class="size-3.5" />
        {if @configured?, do: "Edit", else: "Connect"}
      </button>
    </div>
    """
  end

  # One shared modal (rendered once per pane, parameterized by the open
  # provider) holding the relocated client form. Server-owned open/close via the
  # :oauth_modal assign — same overlay pattern as the "Restarting…" scrim, so no
  # JS hook and no popup-chain involvement. Step :creds collects credentials;
  # save advances to :signin, a confirmation pointing at the cards below.
  attr :oauth_modal, :map, default: nil
  attr :plugin_summary, :map, required: true

  defp oauth_client_modal(%{oauth_modal: nil} = assigns), do: ~H""

  defp oauth_client_modal(assigns) do
    assigns =
      assign(
        assigns,
        :oauth,
        Map.fetch!(assigns.plugin_summary.oauth_clients, assigns.oauth_modal.provider)
      )

    ~H"""
    <div
      class="fixed inset-0 z-50 grid place-items-center bg-base-300/70 p-4 backdrop-blur-sm"
      phx-window-keydown="close_oauth_modal"
      phx-key="Escape"
    >
      <div
        class="w-full max-w-md rounded-box border border-base-300 bg-base-100 p-5 shadow-lg"
        role="dialog"
        aria-modal="true"
        aria-label={"#{@oauth.display_name} OAuth client"}
        phx-click-away="close_oauth_modal"
        phx-mounted={JS.focus_first()}
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-1.5">
            <h3 class="text-base font-semibold">Connect {@oauth.display_name}</h3>
            <.oauth_help provider={@oauth.provider} />
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-circle"
            phx-click="close_oauth_modal"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div :if={@oauth_modal.step == :creds}>
          <p class="mt-1 text-sm text-base-content/65">
            Paste the desktop OAuth client you created for {@oauth.display_name}. The secret is
            stored in your OS keychain, never shown here.
          </p>
          <.oauth_client_form oauth={@oauth} />
        </div>

        <div :if={@oauth_modal.step == :signin}>
          <div class="mt-3 flex items-start gap-2 rounded-field border border-success/30 bg-success/10 px-3 py-2 text-sm">
            <.icon name="hero-check-circle" class="size-5 shrink-0 text-success" />
            <span>
              {@oauth.display_name} OAuth client saved. Connect each {@oauth.display_name} integration
              from the list below — re-open this anytime with <span class="font-medium">Edit</span>.
            </span>
          </div>
          <div class="mt-4 flex justify-end gap-2">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="open_oauth_modal"
              phx-value-provider={@oauth.provider}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit
            </button>
            <button type="button" class="btn btn-primary btn-sm" phx-click="close_oauth_modal">
              <.icon name="hero-check" class="size-4" /> Done
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The relocated client form (now stacked for the modal): client id/secret +
  # redirect port, submitting to "save_oauth_client" with the provider hidden
  # field. The id and event name are unchanged so existing flows/tests hold.
  attr :oauth, :map, required: true

  defp oauth_client_form(assigns) do
    ~H"""
    <form id={"oauth-client-form-#{@oauth.provider}"} phx-submit="save_oauth_client" class="mt-4">
      <input type="hidden" name="provider" value={@oauth.provider} />
      <div class="space-y-3">
        <.text_input
          label="Client ID (required)"
          name="oauth_client_form[client_id]"
          value={@oauth.client_id}
        />
        <.secret_input
          label="Client secret (required)"
          name="oauth_client_form[client_secret]"
          set={@oauth.client_secret_set}
        />
        <.number_field
          label="Redirect port"
          name="oauth_client_form[redirect_port]"
          value={@oauth.redirect_port}
        />
      </div>
      <button type="submit" class="btn btn-primary btn-sm mt-4 w-full">
        <.icon name="hero-key" class="size-4" /> Save client
      </button>
    </form>
    """
  end

  attr :plugin_auth_url, :map, default: nil
  attr :plugins, :list, required: true

  defp auth_fallback_link(assigns) do
    assigns =
      assign(
        assigns,
        :show?,
        assigns.plugin_auth_url != nil &&
          Enum.any?(assigns.plugins, &(&1.name == assigns.plugin_auth_url.name))
      )

    ~H"""
    <div
      :if={@show?}
      class="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-field border border-base-300 bg-base-200/50 px-3 py-2 text-xs text-base-content/65"
    >
      <span>If the {@plugin_auth_url.display_name} tab did not open, use the fallback link.</span>
      <a
        class="link link-primary font-medium"
        href={@plugin_auth_url.url}
        target="_blank"
        rel="noreferrer"
      >
        Open sign-in
      </a>
    </div>
    """
  end

  attr :plugin, :map, required: true
  attr :label, :string, default: nil
  attr :auth_preopen?, :boolean, default: false
  # When set, this card is the sole card of an OAuth provider group: it folds the
  # client Connect/Edit in. Until the client is configured, configuring it is the
  # only action (the plugin can't sign in without it).
  attr :oauth, :map, default: nil

  defp plugin_card(assigns) do
    assigns =
      assign(
        assigns,
        :oauth_unset?,
        assigns.oauth != nil and not oauth_client_configured?(assigns.oauth)
      )

    ~H"""
    <section
      data-plugin-name={@plugin.name}
      class="flex w-full items-center gap-3 rounded-box border border-base-300 bg-base-100/80 p-3 shadow-sm"
    >
      <div class="grid size-9 shrink-0 place-items-center overflow-hidden rounded-field border border-base-300 bg-base-100">
        <img
          :if={@plugin.logo}
          src={@plugin.logo}
          alt=""
          class="size-7 object-contain"
          loading="lazy"
        />
        <span :if={!@plugin.logo} class="text-sm font-semibold">
          {String.first(@plugin.display_name)}
        </span>
      </div>

      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <h3 class="truncate text-sm font-semibold">{@label || @plugin.display_name}</h3>
          <.status_pill :if={@plugin.status != :not_configured} status={@plugin.status} />
        </div>
        <p :if={@plugin.account} class="truncate text-xs text-base-content/55">{@plugin.account}</p>
        <p :if={@plugin.yanked_version} class="text-xs text-error">
          Version {@plugin.yanked_version} was yanked — run `fermix plugins upgrade {@plugin.name}`.
        </p>
        <form
          :if={@plugin.status == :needs_config && @plugin.missing_config != []}
          id={"plugin-config-form-#{@plugin.name}"}
          phx-submit="save_plugin_config"
          class="mt-2 flex flex-wrap items-end gap-2"
        >
          <input type="hidden" name="name" value={@plugin.name} />
          <.text_input
            :for={entry <- @plugin.missing_config}
            label={entry.prompt}
            name={"plugin_config_form[#{entry.key}]"}
            value=""
          />
          <button type="submit" class="btn btn-outline btn-sm">Save</button>
        </form>
        <form
          :if={@plugin.auth_type == :api_key && @plugin.enabled? && @plugin.status == :needs_secret}
          id={"plugin-secret-form-#{@plugin.name}"}
          phx-submit="set_plugin_secret"
          class="mt-2 flex items-end gap-2"
        >
          <input type="hidden" name="name" value={@plugin.name} />
          <label class="form-control min-w-0 flex-1">
            <span class="label flex items-center justify-between gap-2 pb-1 text-xs font-medium">
              <span>{@plugin.secret_prompt || "API key"}</span>
            </span>
            <input
              type="password"
              name="plugin_secret_form[value]"
              autocomplete="off"
              placeholder="Paste the key"
              class="input input-bordered input-sm w-full bg-base-100"
            />
          </label>
          <button type="submit" class="btn btn-outline btn-sm shrink-0">Connect</button>
        </form>
      </div>

      <div class="flex shrink-0 flex-wrap items-center justify-end gap-1.5">
        <button
          :if={@oauth_unset?}
          type="button"
          class="btn btn-primary btn-xs"
          phx-click="open_oauth_modal"
          phx-value-provider={@oauth.provider}
        >
          <.icon name="hero-key" class="size-3.5" /> Connect
        </button>
        <button
          :if={!@oauth_unset? && !@plugin.enabled?}
          type="button"
          class="btn btn-primary btn-xs"
          phx-click="plugin_enable"
          phx-value-name={@plugin.name}
          data-plugin-auth-trigger={if @auth_preopen?, do: "true", else: nil}
        >
          <.icon name="hero-plus" class="size-3.5" /> {plugin_primary_action(@plugin)}
        </button>
        <button
          :if={
            !@oauth_unset? && @plugin.enabled? && @plugin.auth_type == :oauth2 &&
              @plugin.status != :ready
          }
          type="button"
          class="btn btn-outline btn-xs"
          phx-click="plugin_connect"
          phx-value-name={@plugin.name}
          data-plugin-auth-trigger={if @auth_preopen?, do: "true", else: nil}
        >
          {plugin_action_label(@plugin.status)}
        </button>
        <button
          :if={!@oauth_unset? && @plugin.enabled? && @plugin.status == :ready}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_check"
          phx-value-name={@plugin.name}
        >
          <.icon name="hero-check-circle" class="size-3.5" /> Check
        </button>
        <button
          :if={
            !@oauth_unset? && @plugin.enabled? &&
              (@plugin.account || (@plugin.auth_type == :api_key && @plugin.status == :ready))
          }
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_disconnect"
          phx-value-name={@plugin.name}
        >
          Disconnect
        </button>
        <button
          :if={!@oauth_unset? && @plugin.enabled?}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_disable"
          phx-value-name={@plugin.name}
        >
          Disable
        </button>
        <button
          :if={@oauth != nil && !@oauth_unset?}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="open_oauth_modal"
          phx-value-provider={@oauth.provider}
          title="Edit OAuth client"
        >
          <.icon name="hero-pencil-square" class="size-3.5" /> Edit
        </button>
      </div>
    </section>
    """
  end

  # A not-yet-installed catalog entry (§6): index branding, Available/Installing/
  # Incompatible pill, and an Enable/Connect action that triggers install-first.
  attr :entry, :map, required: true
  attr :installing?, :boolean, default: false
  # As in plugin_card: when this is the sole card of an OAuth provider group,
  # the client Connect/Edit folds in and gates install until it is configured.
  attr :oauth, :map, default: nil

  defp catalog_card(assigns) do
    assigns =
      assigns
      |> assign(:blocked_reason, catalog_blocked_reason(assigns.entry))
      |> assign(
        :oauth_unset?,
        assigns.oauth != nil and not oauth_client_configured?(assigns.oauth)
      )

    ~H"""
    <section
      data-catalog-name={@entry.name}
      class={[
        "flex w-full items-center gap-3 rounded-box border border-base-300 bg-base-100/80 p-3 shadow-sm",
        @blocked_reason && "opacity-60"
      ]}
    >
      <div class="grid size-9 shrink-0 place-items-center overflow-hidden rounded-field border border-base-300 bg-base-100">
        <img :if={@entry.logo} src={@entry.logo} alt="" class="size-7 object-contain" loading="lazy" />
        <span :if={!@entry.logo} class="text-sm font-semibold">
          {String.first(@entry.display_name)}
        </span>
      </div>

      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <h3 class="truncate text-sm font-semibold">{@entry.display_name}</h3>
          <.status_pill status={catalog_status(@entry, @installing?)} />
          <span :if={@entry.latest} class="text-xs text-base-content/45">v{@entry.latest}</span>
        </div>
        <p :if={@entry.description} class="truncate text-xs text-base-content/55">
          {@entry.description}
        </p>
        <p :if={@entry.mcp?} class="text-xs text-base-content/55">
          Runs a local process with direct access to the folders you configure.
        </p>
        <p :if={@blocked_reason} class="text-xs text-warning">{@blocked_reason}</p>
      </div>

      <div class="flex shrink-0 items-center gap-1.5">
        <span :if={@installing?} class="loading loading-spinner loading-xs text-primary" />
        <button
          :if={@oauth_unset? && !@blocked_reason && !@installing?}
          type="button"
          class="btn btn-primary btn-xs"
          phx-click="open_oauth_modal"
          phx-value-provider={@oauth.provider}
        >
          <.icon name="hero-key" class="size-3.5" /> Connect
        </button>
        <button
          :if={!@oauth_unset? && !@blocked_reason && !@installing? && !@entry.enabled?}
          type="button"
          class="btn btn-primary btn-xs"
          phx-click="plugin_enable"
          phx-value-name={@entry.name}
        >
          <.icon name="hero-arrow-down-tray" class="size-3.5" />
          {if @entry.auth_type == :oauth2, do: "Connect", else: "Enable"}
        </button>
        <button
          :if={@entry.enabled? && !@installing?}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_disable"
          phx-value-name={@entry.name}
        >
          Disable
        </button>
        <button
          :if={@oauth != nil && !@oauth_unset? && !@installing?}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="open_oauth_modal"
          phx-value-provider={@oauth.provider}
          title="Edit OAuth client"
        >
          <.icon name="hero-pencil-square" class="size-3.5" /> Edit
        </button>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :status, :atom, required: true
  slot :inner_block, required: true

  defp integration_panel(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100/80 p-4 shadow-sm">
      <div class="mb-4 flex items-center justify-between gap-3">
        <h3 class="font-semibold">{@title}</h3>
        <.status_pill status={@status} />
      </div>
      <div class="grid items-start gap-3 sm:grid-cols-2">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :checked, :boolean, required: true

  defp search_backend_option(assigns) do
    ~H"""
    <label class={search_backend_option_class(@checked)}>
      <input
        type="radio"
        name="search_form[backend]"
        value={@value}
        checked={@checked}
        class="radio radio-primary radio-sm mt-0.5"
      />
      <span class="min-w-0">
        <span class="block font-medium">{@label}</span>
        <span class="block text-xs leading-5 text-base-content/60">{@description}</span>
      </span>
    </label>
    """
  end

  defp image_backend_option(assigns) do
    ~H"""
    <label class={search_backend_option_class(@checked)}>
      <input
        type="radio"
        name="image_form[backend]"
        value={@value}
        checked={@checked}
        class="radio radio-primary radio-sm mt-0.5"
      />
      <span class="min-w-0">
        <span class="block font-medium">{@label}</span>
        <span class="block text-xs leading-5 text-base-content/60">{@description}</span>
      </span>
    </label>
    """
  end

  # OpenAI/xAI image generation reuses the chat-provider key from the Provider
  # tab, so there is nothing to paste here — this just reports whether that key
  # is already configured.

  attr :field, :map, required: true

  defp channel_field(assigns) do
    ~H"""
    <.secret_input
      :if={@field.kind == :secret}
      label={@field.label}
      name={@field.name}
      set={@field.set}
    />
    <.text_input
      :if={@field.kind == :text}
      label={@field.label}
      name={@field.name}
      value={@field.value}
    />
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp info_panel(assigns) do
    ~H"""
    <div class={[
      "rounded-box border border-base-300 bg-base-200/60 p-4 text-sm leading-6 text-base-content/70",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :set, :boolean, required: true

  defp secret_input(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@label}</span>
      <input
        type="password"
        name={@name}
        value=""
        placeholder={secret_placeholder(@set)}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
    </label>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true

  defp text_input(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@label}</span>
      <input type="text" name={@name} value={@value} class="input input-bordered w-full bg-base-100" />
    </label>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :min, :string, default: "1"
  attr :max, :string, default: nil
  attr :step, :string, default: nil

  defp number_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@label}</span>
      <input
        type="number"
        name={@name}
        value={@value}
        min={@min}
        max={@max}
        step={@step}
        class="input input-bordered w-full bg-base-100"
      />
    </label>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :options, :list, required: true
  # Atom (sandbox mode/profile) or string (model ids) — compared via to_string/1.
  attr :value, :any, required: true

  defp select_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@label}</span>
      <select name={@name} class="select select-bordered w-full bg-base-100">
        <option :for={option <- @options} value={option} selected={option == to_string(@value)}>
          {option}
        </option>
      </select>
    </label>
    """
  end

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    ~H"""
    <span class={["shrink-0 whitespace-nowrap", status_pill_class(@status)]}>
      {status_pill_label(@status)}
    </span>
    """
  end

  attr :flash, :map, required: true

  defp flash_banner(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-2 rounded-box border px-4 py-2 text-sm",
        flash_banner_class(@flash.kind)
      ]}
      role={flash_role(@flash.kind)}
    >
      <.icon name={flash_icon(@flash.kind)} class="size-4 shrink-0" />
      <span>{@flash.message}</span>
      <button
        :if={Map.get(@flash, :restart_required?, false)}
        type="button"
        class="btn btn-primary btn-xs ml-auto"
        phx-click="apply_restart"
      >
        <.icon name="hero-arrow-path" class="size-3.5" /> Apply &amp; restart
      </button>
    </div>
    """
  end

  # Text uses the semantic token (not `*-content`, which is the on-solid color):
  # the banner background is a faint `/10` tint, so the text must read against
  # the base surface in both light and dark, which `text-error`/`text-success`
  # do (the token itself flips per theme).
  defp flash_banner_class(:error), do: "border-error/40 bg-error/10 text-error"
  defp flash_banner_class(:info), do: "border-success/40 bg-success/10 text-success"

  defp flash_icon(:error), do: "hero-x-circle"
  defp flash_icon(:info), do: "hero-check-circle"

  defp flash_role(:error), do: "alert"
  defp flash_role(:info), do: "status"

  attr :tool_summary, :map, required: true

  defp tool_summary_panel(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">Built-in tools</h3>
        <div class="badge badge-ghost badge-sm">
          {if @tool_summary.web_search, do: "web search registered", else: "web search unavailable"}
        </div>
      </div>

      <dl class="mt-4 grid gap-3 sm:grid-cols-3">
        <div class="rounded-field bg-base-200/60 p-3">
          <dt class="text-xs font-medium uppercase text-base-content/50">Registered</dt>
          <dd class="mt-1 text-xl font-semibold">{@tool_summary.count}</dd>
        </div>
        <div class="rounded-field bg-base-200/60 p-3">
          <dt class="text-xs font-medium uppercase text-base-content/50">Hidden</dt>
          <dd class="mt-1 text-xl font-semibold">{@tool_summary.hidden_count}</dd>
        </div>
        <div class="rounded-field bg-base-200/60 p-3">
          <dt class="text-xs font-medium uppercase text-base-content/50">Policy groups</dt>
          <dd class="mt-1 text-xl font-semibold">{map_size(@tool_summary.policy_counts)}</dd>
        </div>
      </dl>

      <p :if={@tool_summary.available} class="mt-3 text-sm text-base-content/70">
        Registered policies: {format_policy_counts(@tool_summary.policy_counts)}.
      </p>
      <p :if={!@tool_summary.available} class="mt-3 text-sm text-base-content/70">
        The capability registry is not running in this process yet. Start the daemon to see live tools.
      </p>
    </section>
    """
  end

  attr :skill_summary, :map, required: true

  defp skill_summary_panel(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">Skill summary</h3>
        <div class="badge badge-ghost badge-sm">read only</div>
      </div>

      <dl class="mt-4 grid gap-3 sm:grid-cols-3">
        <div class="rounded-field bg-base-200/60 p-3">
          <dt class="text-xs font-medium uppercase text-base-content/50">Skills</dt>
          <dd class="mt-1 text-xl font-semibold">{@skill_summary.count}</dd>
        </div>
        <div class="rounded-field bg-base-200/60 p-3">
          <dt class="text-xs font-medium uppercase text-base-content/50">Operator trusted</dt>
          <dd class="mt-1 text-xl font-semibold">{@skill_summary.operator_count}</dd>
        </div>
        <div class="rounded-field bg-base-200/60 p-3">
          <dt class="text-xs font-medium uppercase text-base-content/50">Guest scoped</dt>
          <dd class="mt-1 text-xl font-semibold">{@skill_summary.guest_count}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :report, :map, required: true

  defp validation_list(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">Current readiness</h3>
        <div class={status_badge_class(@report.status)}>{format_status(@report.status)}</div>
      </div>

      <ul :if={@report.failures != []} class="mt-4 space-y-3">
        <li :for={failure <- @report.failures} class="rounded-field bg-warning/10 p-3 text-sm">
          <p class="font-medium">{failure.component}</p>
          <p class="mt-1 text-base-content/70">{failure.action}</p>
        </li>
      </ul>

      <p :if={@report.failures == []} class="mt-4 text-sm text-base-content/70">
        Required setup is complete.
      </p>
    </section>
    """
  end

  attr :result, :any, required: true

  defp doctor_result(assigns) do
    assigns =
      assigns
      |> assign(:provider_result, provider_probe_result(assigns.result))
      |> assign(:channel_results, channel_probe_results(assigns.result))

    ~H"""
    <section class="rounded-box border border-base-300 p-4">
      <h3 class="font-semibold">Provider probe</h3>
      <p :if={is_nil(@provider_result)} class="mt-2 text-sm text-base-content/70">
        The probe has not run in this session.
      </p>
      <p
        :if={@provider_result == :running}
        class="mt-2 flex items-center gap-2 text-sm text-base-content/70"
      >
        <span class="loading loading-spinner loading-xs" aria-hidden="true" />
        Provider probe is running.
      </p>
      <p :if={match?({:ok, _}, @provider_result)} class="mt-2 text-sm text-success">
        {doctor_success(@provider_result)}
      </p>
      <p :if={match?({:error, _}, @provider_result)} class="mt-2 text-sm text-error">
        {doctor_error(@provider_result)}
      </p>

      <div class="mt-4 border-t border-base-300 pt-4">
        <h3 class="font-semibold">Channel probes</h3>
        <p :if={is_nil(@channel_results)} class="mt-2 text-sm text-base-content/70">
          Channel probes run with the provider probe.
        </p>
        <p :if={@channel_results == []} class="mt-2 text-sm text-base-content/70">
          No enabled channels are configured.
        </p>
        <ul :if={is_list(@channel_results) && @channel_results != []} class="mt-3 space-y-2">
          <li
            :for={probe <- @channel_results}
            class="flex items-start justify-between gap-3 text-sm"
          >
            <div class="min-w-0">
              <p class="font-medium">{probe.name}</p>
              <p class={["mt-0.5", channel_probe_text_class(probe.status)]}>{probe.detail}</p>
            </div>
            <span class={channel_probe_badge_class(probe.status)}>
              {channel_probe_label(probe.status)}
            </span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp channel_sections(channels_form, report) do
    Enum.map(@channels, fn {key, title} ->
      form = Map.fetch!(channels_form, key)

      %{
        channel: key,
        title: title,
        status: channel_status(report, key, form.enabled),
        fields: channel_fields(key, form)
      }
    end)
  end

  defp channel_card_class(channel, editing) do
    base =
      "flex items-center justify-between gap-2 rounded-field border p-3 text-sm transition-colors"

    if channel == editing do
      base <> " border-primary bg-primary/5"
    else
      base <> " border-base-300 bg-base-100 hover:border-primary/40"
    end
  end

  defp channel_fields(:telegram, form) do
    [
      secret_field("Bot token", "telegram_bot_token", form.bot_token_set),
      text_field("Owner user ID", "telegram_owner_user_id", form.owner_user_id)
    ]
  end

  defp channel_fields(:whatsapp, form) do
    [
      secret_field("Access token", "whatsapp_access_token", form.access_token_set),
      text_field("Phone number ID", "whatsapp_phone_number_id", form.phone_number_id),
      secret_field("Verify token", "whatsapp_verify_token", form.verify_token_set),
      secret_field("App secret", "whatsapp_app_secret", form.app_secret_set),
      text_field("Owner user ID", "whatsapp_owner_user_id", form.owner_user_id)
    ]
  end

  defp channel_fields(:discord, form) do
    [
      secret_field("Bot token", "discord_bot_token", form.bot_token_set),
      text_field("Bot user ID", "discord_bot_user_id", form.bot_user_id),
      text_field("Owner user ID", "discord_owner_user_id", form.owner_user_id)
    ]
  end

  defp channel_fields(:slack, form) do
    [
      secret_field("Bot token", "slack_bot_token", form.bot_token_set),
      secret_field("Signing secret", "slack_signing_secret", form.signing_secret_set),
      text_field("Owner user ID", "slack_owner_user_id", form.owner_user_id)
    ]
  end

  defp channel_fields(:signal, form) do
    [
      text_field("Account", "signal_account", form.account),
      text_field("Owner user ID", "signal_owner_user_id", form.owner_user_id)
    ]
  end

  defp secret_field(label, key, set) do
    %{kind: :secret, label: label, name: "channels_form[#{key}]", set: set}
  end

  defp text_field(label, key, value) do
    %{kind: :text, label: label, name: "channels_form[#{key}]", value: value}
  end

  defp current_step_number(tab_id, tabs) do
    case Enum.find_index(tabs, &(&1.id == tab_id)) do
      nil -> 1
      index -> index + 1
    end
  end

  defp setup_progress(tab_id, tabs), do: current_step_number(tab_id, tabs) / length(tabs) * 100
  defp first_step?(tab_id, tabs), do: current_step_number(tab_id, tabs) == 1
  defp last_step?(tab_id, tabs), do: current_step_number(tab_id, tabs) == length(tabs)

  # Panes that persist via a single "Save" button — these get the unsaved-edits
  # hint. Plugins and Doctor act per item/probe, so a pane-level hint doesn't fit.
  defp form_pane?(tab_id),
    do: tab_id in ~w(provider realtime channels search sandbox memory personalization)

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

  defp channel_status(_report, _channel, false), do: :not_configured
  defp channel_status(report, channel, true), do: status_by_prefix(report, "channel:#{channel}")

  defp status_by_prefix(report, prefix) do
    if Enum.any?(report.wizard.validation_errors, &String.starts_with?(&1.component, prefix)) do
      :partial
    else
      :ready
    end
  end

  defp sidebar_step_class(tab_id, active_tab) do
    base = "flex w-full items-center gap-3 rounded-field px-2.5 py-2 text-left transition"

    if tab_id == active_tab do
      base <> " bg-primary/10 ring-1 ring-primary/30"
    else
      base <> " hover:bg-base-200"
    end
  end

  defp step_done?(tab, active_tab, report) do
    tab.id != active_tab and tab_status(tab, report) == :ready
  end

  defp search_backend_option_class(true) do
    "flex min-w-0 cursor-pointer gap-3 rounded-field border border-primary bg-primary/10 p-3 text-sm shadow-sm"
  end

  defp search_backend_option_class(false) do
    "flex min-w-0 cursor-pointer gap-3 rounded-field border border-base-300 bg-base-100 p-3 text-sm hover:border-base-content/30"
  end

  defp step_marker_class(tab, active_tab, report) do
    base = "grid size-6 shrink-0 place-items-center rounded-full text-xs font-semibold"

    cond do
      tab.id == active_tab -> base <> " bg-primary text-primary-content"
      step_done?(tab, active_tab, report) -> base <> " bg-success/15 text-success"
      tab_status(tab, report) == :partial -> base <> " bg-warning/15 text-warning"
      true -> base <> " bg-base-200 text-base-content/50"
    end
  end

  defp status_pill_class(:ready), do: "badge badge-success badge-sm"
  defp status_pill_class(:partial), do: "badge badge-warning badge-sm"
  defp status_pill_class(:needs_auth), do: "badge badge-warning badge-sm"
  defp status_pill_class(:needs_client_config), do: "badge badge-warning badge-sm"
  defp status_pill_class(:needs_config), do: "badge badge-warning badge-sm"
  defp status_pill_class(:needs_secret), do: "badge badge-warning badge-sm"
  defp status_pill_class(:reauthorization_required), do: "badge badge-error badge-sm"
  defp status_pill_class(:error), do: "badge badge-error badge-sm"
  defp status_pill_class(:not_configured), do: "badge badge-ghost badge-sm"
  defp status_pill_class(:available), do: "badge badge-ghost badge-sm"
  defp status_pill_class(:installing), do: "badge badge-info badge-sm"
  defp status_pill_class(:incompatible), do: "badge badge-ghost badge-sm"
  defp status_pill_class(_), do: "badge badge-ghost badge-sm"

  defp status_pill_label(:ready), do: "Ready"
  defp status_pill_label(:partial), do: "Needs setup"
  defp status_pill_label(:needs_auth), do: "Needs auth"
  defp status_pill_label(:needs_client_config), do: "needs client config"
  defp status_pill_label(:needs_config), do: "Needs config"
  defp status_pill_label(:needs_secret), do: "Needs key"
  defp status_pill_label(:reauthorization_required), do: "Reauthorize"
  defp status_pill_label(:error), do: "Error"
  defp status_pill_label(:not_configured), do: "Not configured"
  defp status_pill_label(:available), do: "Available"
  defp status_pill_label(:installing), do: "Installing"
  defp status_pill_label(:incompatible), do: "Incompatible"
  defp status_pill_label(_), do: "Unknown"

  defp plugin_primary_action(%{auth_type: :oauth2}), do: "Connect"
  defp plugin_primary_action(_plugin), do: "Enable"

  defp plugin_action_label(:needs_client_config), do: "Configure"
  defp plugin_action_label(:needs_auth), do: "Connect"
  defp plugin_action_label(:reauthorization_required), do: "Reauthorize"
  defp plugin_action_label(:ready), do: "Check"
  defp plugin_action_label(_status), do: "Enable"

  defp catalog_status(_entry, true), do: :installing
  # Computer use stays a catalog entry even when on; reflect its real state instead
  # of a perpetual "Available" (enabled + sidecar/permissions ready, vs enabled but
  # not yet runnable). Every other catalog entry carries `enabled?: false`.
  defp catalog_status(%{enabled?: true, ready?: true}, _installing?), do: :ready
  defp catalog_status(%{enabled?: true, ready?: false}, _installing?), do: :partial
  defp catalog_status(%{compat: {:error, _reason}}, _installing?), do: :incompatible
  defp catalog_status(_entry, _installing?), do: :available

  # Pre-fetch blockers (§13): an incompatible/yanked/absent latest greys the
  # card before any artifact download.
  defp catalog_blocked_reason(%{compat: {:error, reason}}), do: compat_message(reason)
  defp catalog_blocked_reason(_entry), do: nil

  defp compat_message({:needs_newer_core, :min_core_version, floor}),
    do: "needs Fermix ≥ #{floor} — run `fermix upgrade`."

  defp compat_message({:needs_newer_core, :plugin_api, api}),
    do: "needs a newer Fermix (plugin API #{api}) — run `fermix upgrade`."

  defp compat_message({:plugin_too_old, :plugin_api, _api}),
    do: "built for an older Fermix — awaiting a plugin update."

  defp compat_message({:yanked, _name, version}), do: "version #{version} was yanked."
  defp compat_message({:version_not_found, _name, _version}), do: "no installable version yet."
  defp compat_message(other), do: Redaction.format(other)

  defp strip_google_prefix("Google " <> rest), do: rest
  defp strip_google_prefix(name), do: name

  defp google_plugins(plugins), do: Enum.filter(plugins, &(&1.provider == "google"))

  # Every non-Google provider with a client form gets one group; the form set
  # (summary.oauth_clients) is the single source of which providers qualify.
  # The group carries both the installed cards and the not-yet-installed catalog
  # cards for that provider, so the client form and its Connect card stay
  # together instead of being split across the bottom catalog list.
  defp oauth_provider_groups(%{plugins: plugins, catalog: catalog, oauth_clients: oauth_clients}) do
    by_provider = Enum.group_by(plugins, & &1.provider)
    catalog_by_provider = Enum.group_by(catalog, & &1.provider)

    oauth_clients
    |> Map.delete("google")
    |> Enum.sort()
    |> Enum.map(fn {provider, oauth} ->
      %{
        oauth: oauth,
        plugins: Map.get(by_provider, provider, []),
        catalog: Map.get(catalog_by_provider, provider, [])
      }
    end)
  end

  # Installed plugins outside every provider group (no oauth2 client form).
  defp ungrouped_plugins(%{plugins: plugins, oauth_clients: oauth_clients}) do
    Enum.reject(plugins, &Map.has_key?(oauth_clients, &1.provider))
  end

  # Catalog entries outside every provider group — e.g. an MCP plugin like
  # Obsidian (no oauth2 client form). The grouped ones render inside their
  # provider group beside the client form, not here.
  defp ungrouped_catalog(%{catalog: catalog, oauth_clients: oauth_clients}) do
    Enum.reject(catalog, &Map.has_key?(oauth_clients, &1.provider))
  end

  defp oauth_client_configured?(%{client_id: client_id, client_secret_set: true}) do
    present?(client_id)
  end

  defp oauth_client_configured?(_oauth), do: false

  defp status_badge_class(:ready), do: "badge badge-success badge-sm font-medium"
  defp status_badge_class(:setup_required), do: "badge badge-warning badge-sm font-medium"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm font-medium"

  defp format_status(:ready), do: "Ready"
  defp format_status(:setup_required), do: "Setup required"
  defp format_status(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp format_context(ctx) when is_integer(ctx) and ctx >= 1000, do: "#{div(ctx, 1000)}k ctx"
  defp format_context(ctx) when is_integer(ctx), do: "#{ctx} ctx"
  defp format_context(_), do: ""

  # Is the pane currently being edited the primary provider? Used to scope the
  # global sub-agent-model selector to a single pane.
  defp editing_primary?(statuses, provider),
    do: Enum.any?(statuses, fn s -> s.provider == provider and s.primary? end)

  # A set sub-agent model that the shown catalog doesn't list (e.g. configured
  # while a different provider was primary) — render it as a selectable option so
  # saving the pane preserves it instead of resetting to "Same as main".
  defp subagent_model_custom?(value, _models) when value in [nil, ""], do: false

  defp subagent_model_custom?(value, models) when is_binary(value),
    do: not Enum.any?(models, &(&1.id == value))

  defp format_policy_counts(policy_counts) when map_size(policy_counts) == 0, do: "none"

  defp format_policy_counts(policy_counts) do
    policy_counts
    |> Enum.sort_by(fn {policy, _count} -> Atom.to_string(policy) end)
    |> Enum.map_join(", ", fn {policy, count} -> "#{format_policy(policy)} #{count}" end)
  end

  defp format_policy(policy), do: policy |> Atom.to_string() |> String.replace("_", " ")
  defp secret_placeholder(true), do: "stored - leave blank to keep or paste to replace"
  defp secret_placeholder(false), do: "paste secret"

  defp api_key_set?(report, provider) do
    report.wizard.config_snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(:api_key)
    |> present?()
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(_), do: true

  defp provider_probe_result(nil), do: nil
  defp provider_probe_result(%{provider: result}), do: result
  defp provider_probe_result(result), do: result

  defp channel_probe_results(nil), do: nil
  defp channel_probe_results(%{channels: channels}) when is_list(channels), do: channels
  defp channel_probe_results(_result), do: nil

  defp channel_probe_text_class(:ok), do: "text-success"
  defp channel_probe_text_class(:warn), do: "text-warning"
  defp channel_probe_text_class(:error), do: "text-error"
  defp channel_probe_text_class(:running), do: "text-base-content/70"
  defp channel_probe_text_class(_status), do: "text-base-content/70"

  defp channel_probe_badge_class(:ok), do: "badge badge-success badge-sm"
  defp channel_probe_badge_class(:warn), do: "badge badge-warning badge-sm"
  defp channel_probe_badge_class(:error), do: "badge badge-error badge-sm"
  defp channel_probe_badge_class(:running), do: "badge badge-info badge-sm"
  defp channel_probe_badge_class(_status), do: "badge badge-ghost badge-sm"

  defp channel_probe_label(:ok), do: "OK"
  defp channel_probe_label(:warn), do: "Warn"
  defp channel_probe_label(:error), do: "Error"
  defp channel_probe_label(:running), do: "Running"
  defp channel_probe_label(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp doctor_success({:ok, result}) do
    "#{result.provider} #{result.model} responded in #{result.latency_ms} ms."
  end

  defp doctor_error({:error, {:misconfigured, reason}}), do: reason

  defp doctor_error({:error, {:auth_scope_mismatch, surface, hint}}) do
    "#{surface} rejected the credentials. #{hint}"
  end

  defp doctor_error({:error, {:server_error, status, _body}}),
    do: "Provider returned HTTP #{status}."

  defp doctor_error({:error, {:network, reason}}),
    do: "Network error: #{Redaction.format(reason)}"

  defp doctor_error({:error, reason}), do: Redaction.format(reason)
end
