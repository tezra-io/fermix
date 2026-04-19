defmodule FermixWebWeb.SetupLive do
  use FermixWebWeb, :live_view

  alias FermixCore.Setup.BootReport

  @impl true
  def mount(_params, _session, socket) do
    report = BootReport.current()

    {:ok,
     assign(socket,
       page_title: "Fermix setup",
       report: report,
       wizard: report.wizard
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-10 sm:px-6 lg:px-8">
      <div class="space-y-6">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Fermix onboarding
          </p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight">{status_heading(@report.status)}</h1>
          <p class="mt-3 text-base-content/70">
            Shared setup state is coming from the same core report used by readiness checks and the CLI wizard.
          </p>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
          <dl class="grid gap-4 sm:grid-cols-2">
            <div>
              <dt class="text-sm text-base-content/60">Status</dt>
              <dd class="mt-1 text-lg font-medium">{format_status(@report.status)}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Next step</dt>
              <dd class="mt-1 text-lg font-medium">{format_step(@wizard.step)}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">OpenAI</dt>
              <dd class="mt-1">{configured_label(openai_config(@wizard.config_snapshot))}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Telegram</dt>
              <dd class="mt-1">
                {configured_label(channel_config(@wizard.config_snapshot, :telegram))}
              </dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">WhatsApp</dt>
              <dd class="mt-1">
                {configured_label(channel_config(@wizard.config_snapshot, :whatsapp))}
              </dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Discord</dt>
              <dd class="mt-1">
                {configured_label(channel_config(@wizard.config_snapshot, :discord))}
              </dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Slack</dt>
              <dd class="mt-1">
                {configured_label(channel_config(@wizard.config_snapshot, :slack))}
              </dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Signal</dt>
              <dd class="mt-1">
                {configured_label(channel_config(@wizard.config_snapshot, :signal))}
              </dd>
            </div>
            <div class="sm:col-span-2">
              <dt class="text-sm text-base-content/60">Persisted config path</dt>
              <dd class="mt-1 font-mono text-sm">{@report.config_path}</dd>
            </div>
          </dl>
        </div>

        <div
          :if={@wizard.validation_errors != []}
          class="rounded-box border border-warning/30 bg-warning/10 p-6"
        >
          <h2 class="text-lg font-semibold">Action needed</h2>
          <ul class="mt-4 space-y-2 text-sm">
            <li :for={failure <- @wizard.validation_errors}>
              <span class="font-medium">{failure.component}</span>
              <span class="text-base-content/70">, {failure.action}</span>
            </li>
          </ul>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
          <h2 class="text-lg font-semibold">CLI setup</h2>
          <p class="mt-2 text-sm text-base-content/70">
            Run <code>mix fermix.setup</code> to reuse the same onboarding model from the terminal.
          </p>
          <pre class="mt-4 overflow-x-auto rounded-lg bg-base-200 p-4 text-sm"><code>mix fermix.setup --openai-api-key sk-... --telegram-bot-token 123:abc</code></pre>
        </div>
      </div>
    </div>
    """
  end

  defp status_heading(:ready), do: "Fermix is ready"
  defp status_heading(_status), do: "Setup required"

  defp format_status(status), do: status |> Atom.to_string() |> String.replace("_", " ")
  defp format_step(step), do: step |> Atom.to_string() |> String.replace("_", " ")

  defp configured_label(config) do
    if configured?(config), do: "configured", else: "missing"
  end

  defp configured?(config) do
    Enum.any?(config, fn
      {:api_key, value} -> present?(value)
      {:bot_token, value} -> present?(value)
      {:signing_secret, value} -> present?(value)
      {:access_token, value} -> present?(value)
      {:account, value} -> present?(value)
      _ -> false
    end)
  end

  defp openai_config(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(:openai, [])
  end

  defp channel_config(snapshot, channel) do
    snapshot |> Map.get(:fermix_channels, []) |> Keyword.get(channel, [])
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
