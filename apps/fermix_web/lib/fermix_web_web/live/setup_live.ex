defmodule FermixWebWeb.SetupLive do
  use FermixWebWeb, :live_view

  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Setup.Wizard

  @tabs [
    %{id: "provider", label: "Provider", component: "provider:*"},
    %{id: "realtime", label: "Realtime", component: "realtime"},
    %{id: "channels", label: "Channels", component: "channel:*"},
    %{id: "tools", label: "Tools", component: nil},
    %{id: "skills", label: "Skills", component: nil},
    %{id: "search", label: "Search", component: nil},
    %{id: "sandbox", label: "Sandbox", component: nil},
    %{id: "memory", label: "Memory", component: nil},
    %{id: "personalization", label: "Personalization", component: "personalization"},
    %{id: "doctor", label: "Doctor", component: nil}
  ]

  # ANSI Shadow font, rendered ahead of time so render/1 stays cheap.
  @ascii_fermix """
  ███████╗███████╗██████╗ ███╗   ███╗██╗██╗  ██╗
  ██╔════╝██╔════╝██╔══██╗████╗ ████║██║╚██╗██╔╝
  █████╗  █████╗  ██████╔╝██╔████╔██║██║ ╚███╔╝
  ██╔══╝  ██╔══╝  ██╔══██╗██║╚██╔╝██║██║ ██╔██╗
  ██║     ███████╗██║  ██║██║ ╚═╝ ██║██║██╔╝ ██╗
  ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═╝
  """

  @impl true
  def mount(_params, _session, socket) do
    # Compute a fresh report on mount so the LV reflects the persisted TOML
    # without mutating BootReport's cached state (which other routes rely on).
    report = Wizard.report()

    socket =
      socket
      |> assign(:page_title, "Fermix setup")
      |> assign(:active_tab, "provider")
      |> assign(:saved_flash, nil)
      |> assign_report(report)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab_id}, socket) do
    {:noreply, assign(socket, :active_tab, tab_id) |> assign(:saved_flash, nil)}
  end

  def handle_event("provider_changed", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)
    form = Map.merge(socket.assigns.provider_form, %{provider: provider})

    {:noreply,
     socket
     |> assign(:provider_form, form)
     |> assign(:provider_models, models_for_safe(provider))}
  end

  def handle_event("save_provider", %{"provider_form" => params}, socket) do
    answers =
      []
      |> maybe_put_string(:provider, params["provider"])
      |> maybe_put_string(:default_model, params["default_model"])
      |> maybe_put_string(:reasoning_effort, params["reasoning_effort"])
      |> maybe_put_string(:openai_api_key, params["openai_api_key"])

    case Wizard.save_answers(socket.assigns.report.wizard, answers) do
      {:ok, report} ->
        {:noreply, socket |> assign_report(report) |> assign(:saved_flash, "Provider saved.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:saved_flash, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save_personalization", %{"personalization_form" => params}, socket) do
    answers =
      []
      |> maybe_put_string(:user_name, params["user_name"])
      |> maybe_put_string(:timezone, params["timezone"])
      |> maybe_put_string(:communication_style, params["communication_style"])

    case Wizard.save_answers(socket.assigns.report.wizard, answers) do
      {:ok, report} ->
        {:noreply,
         socket |> assign_report(report) |> assign(:saved_flash, "Personalization saved.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:saved_flash, "Save failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-8">
        <.ascii_header report={@report} />

        <div class="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-[14rem_1fr]">
          <.tab_rail tabs={@tabs} active_tab={@active_tab} report={@report} />

          <section class="rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
            <.flash_banner :if={@saved_flash} message={@saved_flash} />
            <.restart_banner :if={@report.restart_required?} />
            <.active_pane
              active_tab={@active_tab}
              report={@report}
              provider_form={@provider_form}
              provider_models={@provider_models}
              personalization_form={@personalization_form}
            />
          </section>
        </div>
      </div>
    </div>
    """
  end

  # --- Components ---

  attr :report, :map, required: true

  defp ascii_header(assigns) do
    assigns = assign(assigns, :ascii, @ascii_fermix)

    ~H"""
    <header class="rounded-box border border-base-300 bg-base-100 px-6 py-5 shadow-sm">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
        <pre class="text-[10px] leading-[1.1] font-mono text-primary sm:text-xs"><%= @ascii %></pre>

        <div class="flex flex-col items-start gap-2 lg:items-end">
          <div class={status_badge_class(@report.status)}>{format_status(@report.status)}</div>
          <code class="rounded bg-base-200 px-2 py-1 font-mono text-xs text-base-content/70">
            {@report.config_path}
          </code>
        </div>
      </div>
    </header>
    """
  end

  attr :tabs, :list, required: true
  attr :active_tab, :string, required: true
  attr :report, :map, required: true

  defp tab_rail(assigns) do
    ~H"""
    <nav
      class="rounded-box border border-base-300 bg-base-100 p-2 shadow-sm"
      aria-label="Setup categories"
    >
      <ul class="space-y-1">
        <li :for={tab <- @tabs}>
          <button
            type="button"
            phx-click="select_tab"
            phx-value-tab={tab.id}
            class={tab_button_class(tab.id, @active_tab)}
            aria-current={if tab.id == @active_tab, do: "page", else: "false"}
          >
            <span class={status_icon_class(tab_status(tab, @report))}>
              {status_icon(tab_status(tab, @report))}
            </span>
            <span class="ml-2 flex-1 text-left">{tab.label}</span>
          </button>
        </li>
      </ul>
    </nav>
    """
  end

  attr :active_tab, :string, required: true
  attr :report, :map, required: true
  attr :provider_form, :map, required: true
  attr :provider_models, :list, required: true
  attr :personalization_form, :map, required: true

  defp active_pane(assigns) do
    case assigns.active_tab do
      "provider" -> provider_pane(assigns)
      "personalization" -> personalization_pane(assigns)
      _ -> coming_soon_pane(assigns)
    end
  end

  defp provider_pane(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold tracking-tight">Provider &amp; Model</h2>
      <p class="mt-1 text-sm text-base-content/70">
        Pick a provider and the model that handles each turn. The API key is stored
        in your OS keychain via the configured secret writer.
      </p>

      <form phx-submit="save_provider" phx-change="provider_changed" class="mt-6 space-y-5">
        <label class="form-control w-full max-w-md">
          <span class="label pb-1 text-sm font-medium">Provider</span>
          <select name="provider_form[provider]" class="select select-bordered">
            <option
              :for={provider <- ModelCatalog.providers()}
              value={Atom.to_string(provider)}
              selected={provider == @provider_form.provider}
            >
              {Atom.to_string(provider)}
            </option>
          </select>
        </label>

        <label class="form-control w-full max-w-md">
          <span class="label pb-1 text-sm font-medium">Default model</span>
          <select name="provider_form[default_model]" class="select select-bordered">
            <option
              :for={{id, label, ctx} <- @provider_models}
              value={id}
              selected={id == @provider_form.default_model}
            >
              {label} ({id} · {format_context(ctx)})
            </option>
          </select>
        </label>

        <label :if={@provider_form.provider == :openai} class="form-control w-full max-w-md">
          <span class="label pb-1 text-sm font-medium">OpenAI API key</span>
          <input
            type="password"
            name="provider_form[openai_api_key]"
            placeholder={if api_key_set?(@report), do: "(configured — leave blank to keep)", else: "sk-..."}
            class="input input-bordered font-mono"
            value=""
          />
          <span class="label pt-1 text-xs text-base-content/60">
            Stored in the OS keychain. Leave blank to keep the existing value.
          </span>
        </label>

        <fieldset
          :if={@provider_form.provider in [:openai, :openai_codex]}
          class="form-control"
        >
          <legend class="label pb-1 text-sm font-medium">Reasoning effort</legend>
          <div class="flex flex-wrap gap-3">
            <label :for={effort <- ~w(none minimal low medium high)} class="label cursor-pointer gap-2">
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

        <div class="pt-2">
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    </div>
    """
  end

  defp personalization_pane(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold tracking-tight">Personalization</h2>
      <p class="mt-1 text-sm text-base-content/70">
        How the agent should address you and frame replies. These values seed
        <code class="font-mono text-xs">USER.md</code> in your prompt memory directory.
      </p>

      <form phx-submit="save_personalization" class="mt-6 space-y-5">
        <label class="form-control w-full max-w-md">
          <span class="label pb-1 text-sm font-medium">Your name</span>
          <input
            type="text"
            name="personalization_form[user_name]"
            value={@personalization_form.user_name}
            placeholder="e.g. Sujeeth"
            class="input input-bordered"
          />
        </label>

        <label class="form-control w-full max-w-md">
          <span class="label pb-1 text-sm font-medium">Timezone</span>
          <input
            type="text"
            name="personalization_form[timezone]"
            value={@personalization_form.timezone}
            placeholder="e.g. America/Los_Angeles"
            class="input input-bordered font-mono"
          />
          <span class="label pt-1 text-xs text-base-content/60">
            IANA timezone string. Free-text in M10; validation lands later.
          </span>
        </label>

        <label class="form-control w-full max-w-md">
          <span class="label pb-1 text-sm font-medium">Communication style</span>
          <input
            type="text"
            name="personalization_form[communication_style]"
            value={@personalization_form.communication_style}
            placeholder="e.g. concise and direct"
            class="input input-bordered"
          />
        </label>

        <div class="pt-2">
          <button type="submit" class="btn btn-primary">Save</button>
        </div>
      </form>
    </div>
    """
  end

  defp coming_soon_pane(assigns) do
    ~H"""
    <div class="flex flex-col items-start gap-2 py-4">
      <h2 class="text-xl font-semibold tracking-tight">{tab_label(@active_tab)}</h2>
      <p class="text-sm text-base-content/70">
        This tab lands in a later M10 stage. The
        <code class="rounded bg-base-200 px-1 font-mono text-xs">Provider</code>
        and
        <code class="rounded bg-base-200 px-1 font-mono text-xs">Personalization</code>
        tabs are functional today.
      </p>
    </div>
    """
  end

  attr :message, :string, required: true

  defp flash_banner(assigns) do
    ~H"""
    <div
      class="mb-4 rounded-box border border-success/40 bg-success/10 px-4 py-2 text-sm text-success-content"
      role="status"
    >
      {@message}
    </div>
    """
  end

  defp restart_banner(assigns) do
    ~H"""
    <div
      class="mb-4 rounded-box border border-warning/40 bg-warning/10 px-4 py-2 text-sm"
      role="status"
    >
      Restart required — provider change takes effect after
      <code class="font-mono">fermix restart</code>.
    </div>
    """
  end

  # --- Assigns helpers ---

  defp assign_report(socket, report) do
    snapshot = report.wizard.config_snapshot

    socket
    |> assign(:report, report)
    |> assign(:tabs, @tabs)
    |> assign(:provider_form, build_provider_form(snapshot))
    |> assign(:provider_models, models_for_safe(current_provider(snapshot)))
    |> assign(:personalization_form, build_personalization_form(snapshot))
  end

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

  defp build_personalization_form(snapshot) do
    personalization =
      snapshot |> Map.get(:fermix_core, []) |> Keyword.get(:personalization, [])

    %{
      user_name: Keyword.get(personalization, :user_name, ""),
      timezone: Keyword.get(personalization, :timezone, ""),
      communication_style: Keyword.get(personalization, :communication_style, "")
    }
  end

  defp current_provider(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:agent, [])
    |> Keyword.get(:provider)
    |> normalize_provider()
  end

  defp normalize_provider(nil), do: :openai
  defp normalize_provider(provider) when provider in [:openai, :openai_codex, :anthropic], do: provider
  defp normalize_provider("openai"), do: :openai
  defp normalize_provider("openai_codex"), do: :openai_codex
  defp normalize_provider("anthropic"), do: :anthropic

  defp provider_block(snapshot, provider) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
  end

  defp models_for_safe(provider) when provider in [:openai, :openai_codex, :anthropic] do
    ModelCatalog.models_for(provider)
  end

  defp models_for_safe(_), do: ModelCatalog.models_for(:openai)

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
  defp present?(_), do: false

  defp maybe_put_string(answers, _key, nil), do: answers
  defp maybe_put_string(answers, _key, ""), do: answers

  defp maybe_put_string(answers, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      answers
    else
      [{key, value} | answers]
    end
  end

  # --- View helpers ---

  defp tab_button_class(tab_id, active_tab) do
    base = "flex w-full items-center rounded-field px-3 py-2 text-sm transition"

    if tab_id == active_tab do
      base <> " bg-primary text-primary-content shadow-sm"
    else
      base <> " hover:bg-base-200 text-base-content/80"
    end
  end

  defp tab_label(tab_id) do
    Enum.find_value(@tabs, "Setup", fn tab ->
      if tab.id == tab_id, do: tab.label
    end)
  end

  defp tab_status(%{component: nil}, _report), do: :ready
  defp tab_status(%{component: "provider:*"}, report), do: status_by_prefix(report, "provider:")
  defp tab_status(%{component: "channel:*"}, report), do: status_by_prefix(report, "channel:")

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

  defp status_icon(:ready), do: "✓"
  defp status_icon(:partial), do: "!"

  defp status_icon_class(:ready), do: "inline-block w-4 text-success"
  defp status_icon_class(:partial), do: "inline-block w-4 text-warning"

  defp status_badge_class(:ready), do: "badge badge-success badge-sm font-medium"
  defp status_badge_class(:setup_required), do: "badge badge-warning badge-sm font-medium"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm font-medium"

  defp format_status(:ready), do: "Ready"
  defp format_status(:setup_required), do: "Setup required"
  defp format_status(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp format_context(ctx) when is_integer(ctx) and ctx >= 1000 do
    "#{div(ctx, 1000)}k ctx"
  end

  defp format_context(ctx) when is_integer(ctx), do: "#{ctx} ctx"
  defp format_context(_), do: ""
end
