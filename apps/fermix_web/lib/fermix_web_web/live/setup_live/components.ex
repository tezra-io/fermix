defmodule FermixWebWeb.SetupLive.Components do
  use FermixWebWeb, :html

  alias FermixCore.Auth.Redaction
  alias FermixCore.Providers.ModelCatalog
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
  attr :doctor_result, :any, required: true
  attr :memory_form, :map, required: true
  attr :personalization_form, :map, required: true
  attr :provider_form, :map, required: true
  attr :provider_models, :list, required: true
  attr :plugin_auth_url, :map, default: nil
  attr :plugin_summary, :map, required: true
  attr :realtime_form, :map, required: true
  attr :report, :map, required: true
  attr :sandbox_form, :map, required: true
  attr :search_form, :map, required: true
  attr :restarting, :boolean, default: false
  attr :saved_flash, :map, default: nil
  attr :skill_summary, :map, required: true
  attr :tabs, :list, required: true
  attr :tool_summary, :map, required: true

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

          <div class="rounded-box border border-base-300 bg-base-100 p-6 shadow-sm sm:p-8">
            <.active_pane
              active_tab={@active_tab}
              channels_form={@channels_form}
              doctor_result={@doctor_result}
              memory_form={@memory_form}
              personalization_form={@personalization_form}
              provider_form={@provider_form}
              provider_models={@provider_models}
              plugin_auth_url={@plugin_auth_url}
              plugin_summary={@plugin_summary}
              realtime_form={@realtime_form}
              report={@report}
              sandbox_form={@sandbox_form}
              search_form={@search_form}
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
        <div class="flex items-center gap-3 px-1">
          <div class="grid size-9 shrink-0 place-items-center rounded-field bg-primary font-bold text-primary-content">
            F
          </div>
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold leading-tight">Fermix setup</p>
            <p class="truncate text-xs text-base-content/55">Guided onboarding</p>
          </div>
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
            {Atom.to_string(@provider_form.provider)} · {@provider_form.default_model}
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
  attr :doctor_result, :any, required: true
  attr :memory_form, :map, required: true
  attr :personalization_form, :map, required: true
  attr :provider_form, :map, required: true
  attr :provider_models, :list, required: true
  attr :plugin_auth_url, :map, default: nil
  attr :plugin_summary, :map, required: true
  attr :realtime_form, :map, required: true
  attr :report, :map, required: true
  attr :sandbox_form, :map, required: true
  attr :search_form, :map, required: true
  attr :skill_summary, :map, required: true
  attr :tabs, :list, required: true
  attr :tool_summary, :map, required: true

  defp active_pane(assigns), do: render_active_pane(assigns.active_tab, assigns)

  defp render_active_pane("provider", assigns), do: provider_pane(assigns)
  defp render_active_pane("realtime", assigns), do: realtime_pane(assigns)
  defp render_active_pane("channels", assigns), do: channels_pane(assigns)
  defp render_active_pane("plugins", assigns), do: plugins_pane(assigns)
  defp render_active_pane("search", assigns), do: search_pane(assigns)
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

      <form phx-submit="save_provider" phx-change="provider_changed" class="mt-6 space-y-5">
        <div class="grid gap-4 lg:grid-cols-2">
          <label class="form-control w-full">
            <span class="label pb-1 text-sm font-medium">Provider</span>
            <select name="provider_form[provider]" class="select select-bordered w-full bg-base-100">
              <option
                :for={provider <- ModelCatalog.providers()}
                value={Atom.to_string(provider)}
                selected={provider == @provider_form.provider}
              >
                {Atom.to_string(provider)}
              </option>
            </select>
          </label>

          <label class="form-control w-full">
            <span class="label pb-1 text-sm font-medium">Default model</span>
            <select
              name="provider_form[default_model]"
              class="select select-bordered w-full bg-base-100"
            >
              <option
                :for={{id, label, ctx} <- @provider_models}
                value={id}
                selected={id == @provider_form.default_model}
              >
                {label} ({id} - {format_context(ctx)})
              </option>
            </select>
          </label>
        </div>

        <.provider_secret_field provider_form={@provider_form} report={@report} />
        <.reasoning_effort_field provider_form={@provider_form} />
        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save provider" />
      </form>
    </div>
    """
  end

  attr :provider_form, :map, required: true
  attr :report, :map, required: true

  defp provider_secret_field(assigns) do
    ~H"""
    <label
      :if={@provider_form.provider == :openai}
      class="form-control w-full max-w-xl"
    >
      <span class="label pb-1 text-sm font-medium">OpenAI API key</span>
      <input
        type="password"
        name="provider_form[openai_api_key]"
        placeholder={secret_placeholder(api_key_set?(@report))}
        class="input input-bordered w-full bg-base-100 font-mono"
        value=""
      />
      <span class="label pt-1 text-xs text-base-content/60">
        Leave blank to keep the existing key.
      </span>
    </label>
    """
  end

  attr :provider_form, :map, required: true

  defp reasoning_effort_field(assigns) do
    ~H"""
    <fieldset
      :if={@provider_form.provider in [:openai, :openai_codex]}
      class="form-control rounded-field border border-base-300 bg-base-200/40 p-3"
    >
      <legend class="label pb-1 text-sm font-medium">Reasoning effort</legend>
      <div class="flex flex-wrap gap-3">
        <label
          :for={effort <- effort_levels(@provider_form.provider)}
          class="label cursor-pointer gap-2 rounded-field px-2 py-1 hover:bg-base-100"
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

  defp effort_levels(provider) do
    provider |> ReasoningEffort.levels_for() |> Enum.map(&Atom.to_string/1)
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
    assigns =
      assign(assigns, :channel_sections, channel_sections(assigns.channels_form, assigns.report))

    ~H"""
    <div>
      <.pane_header
        title="Channel coverage"
        subtitle="Add the tokens and owner IDs for the message surfaces this host should accept."
      />

      <form phx-submit="save_channels" class="mt-6 space-y-5">
        <div class="grid gap-4 xl:grid-cols-2">
          <.integration_panel
            :for={section <- @channel_sections}
            title={section.title}
            status={section.status}
          >
            <.channel_field :for={field <- section.fields} field={field} />
          </.integration_panel>
        </div>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save channels" />
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

      <div
        :if={@plugin_summary.available && non_google_plugins(@plugin_summary.plugins) != []}
        class="mt-5 flex flex-col gap-2"
      >
        <.plugin_card :for={plugin <- non_google_plugins(@plugin_summary.plugins)} plugin={plugin} />
      </div>

      <.info_panel class="mt-5">
        <p :if={@plugin_summary.available}>
          coming later: {Enum.join(@plugin_summary.later, ", ")}.
        </p>
        <p :if={!@plugin_summary.available}>
          Plugin catalog unavailable: {@plugin_summary.error}
        </p>
      </.info_panel>

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
          <p :if={@search_form.backend == :duckduckgo} class="text-sm text-base-content/60">
            DuckDuckGo needs no API key — nothing else to configure here.
          </p>
        </div>

        <.form_actions active_tab={@active_tab} tabs={@tabs} save_label="Save search" />
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
        subtitle="Review remaining setup gaps and run a live provider probe when you are ready."
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
          <button type="button" class="btn btn-ghost btn-sm" phx-click="run_doctor">
            <.icon name="hero-play" class="size-4" /> Run probe
          </button>
          <button
            :if={@report.restart_required?}
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
      assign(
        assigns,
        :google_oauth_configured?,
        google_oauth_configured?(assigns.plugin_summary.google_oauth)
      )

    ~H"""
    <section
      data-plugin-group="google"
      class="mt-5 rounded-box border border-base-300 bg-base-100/80 p-3 shadow-sm"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 class="text-sm font-semibold">Google</h3>
          <p class="text-xs text-base-content/55">Calendar, Gmail, and Drive</p>
        </div>
        <span class="badge badge-ghost badge-sm">OAuth desktop client</span>
      </div>

      <form phx-submit="save_google_oauth" class="mt-3 rounded-field bg-base-200/50 p-3">
        <div class="grid items-end gap-2 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_8rem_auto]">
          <.text_input
            label="Client ID (required)"
            name="google_oauth_form[client_id]"
            value={@plugin_summary.google_oauth.client_id}
          />
          <.secret_input
            label="Client secret (required)"
            name="google_oauth_form[client_secret]"
            set={@plugin_summary.google_oauth.client_secret_set}
          />
          <.number_field
            label="Port"
            name="google_oauth_form[redirect_port]"
            value={@plugin_summary.google_oauth.redirect_port}
          />
          <button type="submit" class="btn btn-outline btn-sm">
            <.icon name="hero-key" class="size-4" /> Save
          </button>
        </div>
      </form>

      <p
        :if={
          @plugin_summary.google_oauth.client_id in [nil, ""] ||
            !@plugin_summary.google_oauth.client_secret_set
        }
        class="mt-3 rounded-field border border-warning/30 bg-warning/10 px-3 py-2 text-xs text-base-content/80"
      >
        Add your Client ID and Client secret above, then Save before connecting these integrations.
      </p>

      <div
        :if={@plugin_auth_url}
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

      <div class="mt-3 flex flex-col gap-2">
        <.plugin_card
          :for={plugin <- google_plugins(@plugin_summary.plugins)}
          plugin={plugin}
          label={strip_google_prefix(plugin.display_name)}
          auth_preopen?={@google_oauth_configured? && plugin.auth_type == :oauth2}
        />
      </div>
    </section>
    """
  end

  attr :plugin, :map, required: true
  attr :label, :string, default: nil
  attr :auth_preopen?, :boolean, default: false

  defp plugin_card(assigns) do
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
      </div>

      <div class="flex shrink-0 flex-wrap items-center justify-end gap-1.5">
        <button
          :if={!@plugin.enabled?}
          type="button"
          class="btn btn-primary btn-xs"
          phx-click="plugin_enable"
          phx-value-name={@plugin.name}
          data-plugin-auth-trigger={if @auth_preopen?, do: "true", else: nil}
        >
          <.icon name="hero-plus" class="size-3.5" /> {plugin_primary_action(@plugin)}
        </button>
        <button
          :if={@plugin.enabled? && @plugin.auth_type == :oauth2 && @plugin.status != :ready}
          type="button"
          class="btn btn-outline btn-xs"
          phx-click="plugin_connect"
          phx-value-name={@plugin.name}
          data-plugin-auth-trigger={if @auth_preopen?, do: "true", else: nil}
        >
          {plugin_action_label(@plugin.status)}
        </button>
        <button
          :if={@plugin.enabled? && @plugin.status == :ready}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_check"
          phx-value-name={@plugin.name}
        >
          <.icon name="hero-check-circle" class="size-3.5" /> Check
        </button>
        <button
          :if={@plugin.enabled? && @plugin.account}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_disconnect"
          phx-value-name={@plugin.name}
        >
          Disconnect
        </button>
        <button
          :if={@plugin.enabled?}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="plugin_disable"
          phx-value-name={@plugin.name}
        >
          Disable
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
  attr :value, :atom, required: true

  defp select_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@label}</span>
      <select name={@name} class="select select-bordered w-full bg-base-100">
        <option :for={option <- @options} value={option} selected={option == Atom.to_string(@value)}>
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
    </div>
    """
  end

  defp flash_banner_class(:error), do: "border-error/40 bg-error/10 text-error-content"
  defp flash_banner_class(:info), do: "border-success/40 bg-success/10 text-success-content"

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
    ~H"""
    <section class="rounded-box border border-base-300 p-4">
      <h3 class="font-semibold">Provider probe</h3>
      <p :if={is_nil(@result)} class="mt-2 text-sm text-base-content/70">
        The probe has not run in this session.
      </p>
      <p :if={match?({:ok, _}, @result)} class="mt-2 text-sm text-success">
        {doctor_success(@result)}
      </p>
      <p :if={match?({:error, _}, @result)} class="mt-2 text-sm text-error">
        {doctor_error(@result)}
      </p>
    </section>
    """
  end

  defp channel_sections(channels_form, report) do
    Enum.map(@channels, fn {key, title} ->
      form = Map.fetch!(channels_form, key)

      %{
        title: title,
        status: channel_status(report, key, form.enabled),
        fields: channel_fields(key, form)
      }
    end)
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
  defp status_pill_class(:reauthorization_required), do: "badge badge-error badge-sm"
  defp status_pill_class(:error), do: "badge badge-error badge-sm"
  defp status_pill_class(:not_configured), do: "badge badge-ghost badge-sm"
  defp status_pill_class(_), do: "badge badge-ghost badge-sm"

  defp status_pill_label(:ready), do: "Ready"
  defp status_pill_label(:partial), do: "Needs setup"
  defp status_pill_label(:needs_auth), do: "Needs auth"
  defp status_pill_label(:needs_client_config), do: "needs client config"
  defp status_pill_label(:reauthorization_required), do: "Reauthorize"
  defp status_pill_label(:error), do: "Error"
  defp status_pill_label(:not_configured), do: "Not configured"
  defp status_pill_label(_), do: "Unknown"

  defp plugin_primary_action(%{auth_type: :oauth2}), do: "Connect"
  defp plugin_primary_action(_plugin), do: "Enable"

  defp plugin_action_label(:needs_client_config), do: "Configure"
  defp plugin_action_label(:needs_auth), do: "Connect"
  defp plugin_action_label(:reauthorization_required), do: "Reauthorize"
  defp plugin_action_label(:ready), do: "Check"
  defp plugin_action_label(_status), do: "Enable"

  defp strip_google_prefix("Google " <> rest), do: rest
  defp strip_google_prefix(name), do: name

  defp google_plugins(plugins), do: Enum.filter(plugins, &(&1.provider == "google"))
  defp non_google_plugins(plugins), do: Enum.reject(plugins, &(&1.provider == "google"))

  defp google_oauth_configured?(%{client_id: client_id, client_secret_set: true}) do
    present?(client_id)
  end

  defp google_oauth_configured?(_oauth), do: false

  defp status_badge_class(:ready), do: "badge badge-success badge-sm font-medium"
  defp status_badge_class(:setup_required), do: "badge badge-warning badge-sm font-medium"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm font-medium"

  defp format_status(:ready), do: "Ready"
  defp format_status(:setup_required), do: "Setup required"
  defp format_status(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp format_context(ctx) when is_integer(ctx) and ctx >= 1000, do: "#{div(ctx, 1000)}k ctx"
  defp format_context(ctx) when is_integer(ctx), do: "#{ctx} ctx"
  defp format_context(_), do: ""

  defp format_policy_counts(policy_counts) when map_size(policy_counts) == 0, do: "none"

  defp format_policy_counts(policy_counts) do
    policy_counts
    |> Enum.sort_by(fn {policy, _count} -> Atom.to_string(policy) end)
    |> Enum.map_join(", ", fn {policy, count} -> "#{format_policy(policy)} #{count}" end)
  end

  defp format_policy(policy), do: policy |> Atom.to_string() |> String.replace("_", " ")
  defp secret_placeholder(true), do: "configured - leave blank to keep"
  defp secret_placeholder(false), do: "paste secret"

  defp api_key_set?(report) do
    report.wizard.config_snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(:openai, [])
    |> Keyword.get(:api_key)
    |> present?()
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(_), do: true

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
