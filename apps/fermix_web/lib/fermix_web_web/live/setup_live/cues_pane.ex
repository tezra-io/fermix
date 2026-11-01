defmodule FermixWebWeb.SetupLive.CuesPane do
  @moduledoc """
  The Cues tab's markup (M60 §15, M60 simpler setup §8), drawn from
  `SetupLive.CuesState`: one settings form with one Save (Run cues, the
  watchers' switch, the door and its port, then how watchers judge items: the
  Screen, then the filter model); on a first run one card in place of the
  empty lists, else the sources with their editor; the watchers made in chat
  (counts and ids only, and each follow-up with Ask first again while it is
  always allowed) once a source or a watcher exists; and the mandates with
  their approval once a watcher or a mandate exists. Every control posts a
  `cues_*` event the LiveView hands to `CuesState.handle/4`.

  A new source starts from what to watch, then asks only what that choice
  needs. Every label, info, example, fold and line on the source form is
  `Management.Cues.SourceForm`'s, the words the Mac app shows; the page keeps
  its own markup, icons and status pills.

  Rows stay compact: a kind symbol, the name, a status pill and one quiet
  line, actions at the trailing edge. Longer explanations sit behind an info
  control or on the docs page; rarely used fields fold under "Advanced" or
  "More options". A row's time is short and in the owner's zone, the full
  time in its title.
  """

  use FermixWebWeb, :html

  alias FermixCore.Cues.Webhook
  alias FermixCore.Management.Cues.SourceForm
  alias FermixCore.Management.Cues.WatcherRow
  alias FermixWebWeb.SetupLive.CuesState

  @card "rounded-box border border-base-300 bg-base-100/80 shadow-sm"

  @status_pills %{
    "connected" => {"Connected", "badge-success"},
    "reconnecting" => {"Reconnecting", "badge-warning"},
    "auth_failed" => {"Credential refused", "badge-error"},
    "polling" => {"Polling", "badge-success"},
    "over_budget" => {"Over budget", "badge-warning"},
    "idle" => {"Idle", "badge-ghost"},
    "stopped" => {"Stopped", "badge-ghost"},
    "unavailable" => {"Unavailable", "badge-error"}
  }
  # A status whose reason changes what it means, by `{status, stop_reason}`.
  @reason_pills %{{"auth_failed", "x_sign_in"} => {"Needs X sign-in", "badge-error"}}

  @kind_icons %{
    "feed" => "hero-rss",
    "stream" => "hero-signal",
    "webhook" => "hero-globe-alt",
    "local_push" => "hero-command-line"
  }

  @choice_icons %{
    "rss" => "hero-rss",
    "x_accounts" => "hero-at-symbol",
    "github" => "hero-code-bracket",
    "local_push" => "hero-command-line",
    "feed" => "hero-arrow-path",
    "stream" => "hero-signal",
    "webhook" => "hero-globe-alt"
  }

  @first_run_steps [
    "Add something to watch: a blog, X accounts, GitHub or your scripts.",
    "In chat, tell Fermix what to look for. It makes a watcher.",
    "When something matches, your task runs, and asks you before it acts."
  ]

  # Every field a source form draws but its secrets, in form order; a form
  # draws those its kind shows (`CuesState.source_form/1`).
  @general_fields for row <- SourceForm.general_stream_rows(), row.field != :url, do: row.field
  @input_order [:url, :handles, :interval] ++
                 @general_fields ++
                 ~w(verify header algorithm prefix id_header id type_header daily_budget)a
  # An edit keeps its layout: these sit under More options, as do a webhook
  # method's header and identity where the preset fills them.
  @edit_folded ~w(algorithm prefix type_header daily_budget)a ++
                 for(row <- SourceForm.general_stream_rows(), row.advanced, do: row.field)
  # The row key `SourceForm` words a field under, where it is not the field's name.
  @row_keys %{interval: "interval_minutes", id: "content_hash"}

  @info %{
    sources: "While cues run, a save starts, changes or stops the source at once.",
    watchers:
      "Watchers are made and changed in chat with Fermix. Counts cover the last 24 hours.",
    held: "The filter's provider failed three times in a row; Fermix retries every 10 minutes.",
    mandates_list:
      "A mandate lets one task call named action tools in its cue runs. It acts only after you approve it here; a change to it, its task or its validator needs approving again.",
    mode:
      "Approve: each call waits for you to confirm it in chat. Auto: the checks decide, so it needs a validator or pinned arguments (under More options)."
  }

  attr :cues, :map, required: true

  def pane(assigns) do
    ~H"""
    <div id="cues-pane" class="space-y-8">
      <.pane_title />
      <.settings cues={@cues} />
      <.first_run :if={first_run?(@cues)} />
      <.sources :if={!first_run?(@cues)} cues={@cues} />
      <.watchers :if={watchers_shown?(@cues)} watchers={@cues.watchers} />
      <.mandates :if={mandates_shown?(@cues)} cues={@cues} />
    </div>
    """
  end

  # A first run (no source, nothing open) shows one card in place of the
  # empty lists. Watchers show once there is a source to watch or a watcher,
  # and a failure to read them is said where they would be; mandates once a
  # watcher or a mandate exists, since a mandate needs a task that runs on cues.
  defp first_run?(cues),
    do: cues.sources == [] and is_nil(cues.source_editor) and is_nil(cues.reveal)

  defp watchers_shown?(cues),
    do: cues.sources != [] or listed?(cues.watchers) or read_failed?(cues.watchers)

  defp mandates_shown?(cues), do: cues.mandates != [] or listed?(cues.watchers)

  defp listed?({:ok, watchers}), do: watchers != []
  defp listed?({:error, _reason}), do: false

  defp read_failed?({:error, reason}), do: reason != :memory_off
  defp read_failed?({:ok, _watchers}), do: false

  defp pane_title(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <h2 class="text-2xl font-semibold tracking-normal">Cues</h2>
        </div>
        <p class="mt-1 text-sm text-base-content/70">
          Fermix can watch blogs, X accounts, GitHub and your scripts, and wake a task when something matters.
        </p>
      </div>
      <a
        href="https://fermix.ai/docs/cues/"
        target="_blank"
        rel="noopener noreferrer"
        class="btn btn-ghost btn-sm gap-1.5 text-base-content/70"
      >
        <.icon name="hero-book-open" class="size-4" /> Docs
      </a>
    </div>
    """
  end

  # --- shown once ------------------------------------------------------------

  # A value shown once sits at the top of the Sources section, where the owner
  # just saved or pressed the row's button, and its heading takes focus as it
  # appears, which brings it into view on this long page. The heading's id
  # names the value, so a new one is a new element and is brought in again.

  attr :reveal, :map, required: true
  attr :port, :integer, required: true

  defp reveal(%{reveal: %{kind: :token}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="space-y-3 rounded-box border border-primary/30 bg-primary/5 p-4">
      <.reveal_head
        title={"Token for #{@reveal.ref}"}
        note="Shown once. One token per machine."
        reveal={@reveal}
      />
      <.copy_block id="cues-reveal-value" text={@reveal.value} label="Copy token" />
      <p class="text-xs font-medium text-base-content/60">Test from this machine</p>
      <.copy_block id="cues-reveal-curl" text={curl(@reveal, @port)} label="Copy" pre?={true} />
    </section>
    """
  end

  # A secret Fermix made is shown here even when the URL was not: it cannot
  # be shown again.
  defp reveal(%{reveal: %{kind: :url_failed}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="space-y-2 rounded-box border border-warning/40 bg-warning/5 p-4">
      <.reveal_head title={"No URL for #{@reveal.ref} yet"} note={@reveal.sentence} reveal={@reveal} />
      <div :if={@reveal[:secret]} class="space-y-1.5">
        <p class="text-xs font-medium text-base-content/60">Its secret, shown once</p>
        <.copy_block id="cues-reveal-secret" text={@reveal.secret} label="Copy secret" />
      </div>
      <p class="text-xs text-base-content/60">
        The source is saved. Generate URL on its row tries again.
      </p>
    </section>
    """
  end

  defp reveal(%{reveal: %{kind: :url}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="space-y-3 rounded-box border border-primary/30 bg-primary/5 p-4">
      <.reveal_head
        title={"URL for #{@reveal.ref}"}
        note="The door listens on this machine only."
        reveal={@reveal}
      />
      <.copy_block id="cues-reveal-value" text={door_url(@reveal.value, @port)} label="Copy URL" />
      <p class="text-xs leading-5 text-base-content/60">
        Give the service your tunnel's address followed by the path, with content type
        application/json.
      </p>
      <.funnel_help path={@reveal.value} port={@port} />
    </section>
    """
  end

  # A new GitHub source: the secret Fermix made, shown once, its URL, and
  # where each goes in GitHub's webhook form, in the engine's words
  # (`SourceForm.github_steps/0`).
  defp reveal(%{reveal: %{kind: :github}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="space-y-3 rounded-box border border-primary/30 bg-primary/5 p-4">
      <.reveal_head
        title={"Secret and URL for #{@reveal.ref}"}
        note="The secret is shown once. The door listens on this machine only."
        reveal={@reveal}
      />
      <.copy_block id="cues-reveal-secret" text={@reveal.secret} label="Copy secret" />
      <.copy_block id="cues-reveal-value" text={door_url(@reveal.value, @port)} label="Copy URL" />
      <ol
        id="cues-reveal-steps"
        class="list-decimal space-y-1 pl-5 text-xs leading-5 text-base-content/70"
      >
        <li :for={step <- SourceForm.github_steps()}>{step}</li>
      </ol>
      <.funnel_help path={@reveal.value} port={@port} />
    </section>
    """
  end

  attr :title, :string, required: true
  attr :note, :string, required: true
  attr :reveal, :map, required: true

  defp reveal_head(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div>
        <h3
          id={"cues-reveal-#{@reveal.kind}-#{@reveal.ref}"}
          tabindex="-1"
          phx-mounted={JS.focus()}
          class="text-sm font-semibold outline-none"
        >
          {@title}
        </h3>
        <p class="text-xs text-base-content/60">{@note}</p>
      </div>
      <button type="button" class="btn btn-ghost btn-xs" phx-click="cues_dismiss_reveal">
        Done
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true
  attr :pre?, :boolean, default: false

  defp copy_block(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <pre
        :if={@pre?}
        id={@id}
        class="min-w-0 flex-1 select-all overflow-x-auto rounded-field bg-base-200 p-2 font-mono text-xs"
      >{@text}</pre>
      <code
        :if={!@pre?}
        id={@id}
        class="min-w-0 flex-1 select-all break-all rounded-field bg-base-200 px-2 py-1.5 font-mono text-sm"
      >
        {@text}
      </code>
      <button
        id={"#{@id}-copy"}
        type="button"
        class="btn btn-ghost btn-xs shrink-0"
        phx-hook="CopyText"
        data-copy-from={@id}
      >
        {@label}
      </button>
    </div>
    """
  end

  defp curl(%{ref: ref, value: token}, port) do
    event =
      ~s({"specversion":"1.0","id":"note-1","source":"my-script","type":"com.example.note",) <>
        ~s("data":{"text":"Hello from my script"}})

    """
    curl -sS http://127.0.0.1:#{port}/cues/v1/#{ref} \\
      -H 'Authorization: Bearer #{token}' \\
      -H 'Content-Type: application/cloudevents+json' \\
      --data '#{event}'\
    """
  end

  attr :path, :string, required: true
  attr :port, :integer, required: true

  defp funnel_help(assigns) do
    ~H"""
    <p class="text-xs leading-5 text-base-content/60">
      With Tailscale Funnel, this command puts this one path on the internet, and the address
      is your machine's ts.net name followed by the path:
    </p>
    <.copy_block id="cues-reveal-funnel" text={funnel_command(@path, @port)} label="Copy command" />
    <p class="text-xs leading-5 text-base-content/60">
      Funnel opens port 443 as a whole: whatever else <code class="font-mono">tailscale serve</code>
      has on 443 becomes public too, so check <code class="font-mono">tailscale funnel status</code>
      first.
    </p>
    """
  end

  defp door_url(path, port), do: "http://127.0.0.1:#{port}#{path}"

  defp funnel_command(path, port),
    do: Enum.join(["tailscale" | Webhook.funnel_args(path, port)], " ")

  # --- settings ----------------------------------------------------------------

  attr :cues, :map, required: true

  # The settings above the lists: one form, saved by its one Save at the
  # bottom. Choosing a filter provider refreshes its models and saves nothing.
  defp settings(assigns) do
    ~H"""
    <form
      id="cues-settings-form"
      phx-change="cues_settings_changed"
      phx-submit="cues_save_settings"
      class="space-y-8"
    >
      <.switches
        switches={@cues.switches}
        words={@cues.words}
        door={@cues.door}
        refusal={@cues.settings_refusal}
      />
      <section id="cues-judging" class="space-y-2">
        <.section_head title="How watchers judge items" />
        <.screen screen={@cues.screen} words={@cues.words} refusal={@cues.settings_refusal} />
        <.filter_model filter={@cues.filter} words={@cues.words} refusal={@cues.settings_refusal} />
      </section>
      <div class="flex justify-end">
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
      </div>
    </form>
    """
  end

  attr :refusal, :map, default: nil
  attr :rows, :list, required: true

  # A refused Save, said under the field its row names; the page's banner
  # announces it.
  defp settings_refusal(assigns) do
    ~H"""
    <p
      :if={@refusal && @refusal.row in @rows}
      id={"cues-settings-#{@refusal.row}-refusal"}
      class="w-full text-sm text-error"
    >
      {@refusal.sentence}
    </p>
    """
  end

  # --- switches and door -----------------------------------------------------

  attr :switches, :map, required: true
  attr :words, :map, required: true
  attr :door, :any, required: true
  attr :refusal, :map, default: nil

  # Run cues, then the watchers' switch, the door, and its port under
  # Advanced, each in the `cues` section's own words (`Management.Settings.Cues`).
  defp switches(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <div class={@card}>
      <div class="divide-y divide-base-300">
        <.switch_row
          key="enabled"
          checked={@switches.enabled}
          label={@words["cues_enabled"].label}
          info={@words["cues_enabled"].info}
        />
        <.switch_row
          key="mandates_enabled"
          checked={@switches.mandates_enabled}
          label={@words["cues_mandates_enabled"].label}
          info={@words["cues_mandates_enabled"].info}
        />
        <.settings_refusal refusal={@refusal} rows={~w(cues_enabled cues_mandates_enabled)} />
        <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
          <span class="text-sm font-medium">Door</span>
          <.door_status door={@door} switches={@switches} />
        </div>
        <p
          :if={!@switches.memory_on?}
          class="flex items-center gap-1.5 px-4 py-3 text-sm text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          Memory is off, so cues cannot run: every cue is a row in memory.
        </p>
        <div class="px-4 py-3">
          <.disclosure id="cues-switches-advanced" label="Advanced">
            <label class="mt-2 flex flex-wrap items-center gap-3">
              <span class="flex items-center gap-1.5 text-sm">
                {@words["cues_door_port"].label} <.info text={@words["cues_door_port"].info} />
              </span>
              <input
                type="number"
                name="cues_settings[door_port]"
                value={@switches.door_port}
                min="1024"
                max="65535"
                class="input input-bordered input-sm w-28 bg-base-100"
              />
            </label>
            <.settings_refusal refusal={@refusal} rows={["cues_door_port"]} />
          </.disclosure>
        </div>
      </div>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :info, :string, required: true

  defp switch_row(assigns) do
    ~H"""
    <label
      id={"cues-settings-#{@key}"}
      class="flex cursor-pointer items-center justify-between gap-3 px-4 py-3"
    >
      <span class="flex items-center gap-1.5 text-sm font-medium">
        {@label} <.info text={@info} />
      </span>
      <input type="hidden" name={"cues_settings[#{@key}]"} value="false" />
      <input
        type="checkbox"
        name={"cues_settings[#{@key}]"}
        value="true"
        checked={@checked}
        class="toggle toggle-sm toggle-primary"
      />
    </label>
    """
  end

  attr :door, :any, required: true
  attr :switches, :map, required: true

  defp door_status(%{door: {:listening, ip, port}} = assigns) do
    assigns =
      assign(assigns, address: "#{ip}:#{port}", moved?: port != assigns.switches.door_port)

    ~H"""
    <span class="flex flex-wrap items-center justify-end gap-2">
      <.dot tone="bg-success" text={"Listening on #{@address}"} />
      <.pill
        :if={@moved?}
        label="Restart to apply"
        tone="badge-warning"
        tip={"Restart to move it to port #{@switches.door_port}."}
      />
    </span>
    """
  end

  defp door_status(%{door: {:unavailable, failure}} = assigns) do
    assigns = assign(assigns, :failure, door_failure(failure, assigns.switches.door_port))

    ~H"""
    <.dot tone="bg-error" text={"Unavailable: #{@failure}"} class="text-error" />
    """
  end

  defp door_status(%{door: :not_running, switches: %{enabled: true}} = assigns) do
    ~H"""
    <.pill label="Restart to apply" tone="badge-warning" tip="The door starts after a restart." />
    """
  end

  defp door_status(assigns) do
    ~H"""
    <.dot tone="bg-base-content/30" text="Not running" />
    """
  end

  defp door_failure(:address_in_use, port), do: "another program is using port #{port}"
  defp door_failure(:permission_denied, port), do: "this user may not listen on port #{port}"
  defp door_failure(:address_unavailable, _port), do: "the loopback address is not available"
  defp door_failure(_listen_failed, port), do: "it could not listen on port #{port}"

  # --- screen ----------------------------------------------------------------

  attr :screen, :map, required: true
  attr :words, :map, required: true
  attr :refusal, :map, default: nil

  defp screen(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <div id="cues-screen" class={[@card, "space-y-2 px-4 py-3"]}>
      <span class="flex items-center gap-1.5 text-sm font-medium">
        Screen <.info text={@screen.info} />
      </span>
      <div role="radiogroup" aria-label="Screen" class="grid gap-2 sm:grid-cols-2">
        <.screen_option value="" choice={@screen.keyword} checked={@screen.selected == ""} />
        <.screen_option
          value="decision_model"
          choice={@screen.decision_model}
          checked={@screen.selected == "decision_model"}
        />
      </div>
      <.decision_provider
        :if={@screen.selected == "decision_model"}
        screen={@screen}
        words={@words["cues_decision_provider"]}
      />
      <.settings_refusal refusal={@refusal} rows={["cues_screen", "cues_decision_provider"]} />
    </div>
    """
  end

  attr :screen, :map, required: true
  attr :words, :map, required: true

  # Which decision model the screen uses, under it while the decision model is
  # picked. A provider that is not set up cannot be picked, but the saved one
  # stays selectable, so the form keeps it as it is and its hint says why it
  # does not run.
  defp decision_provider(assigns) do
    saved =
      Enum.find(assigns.screen.decision_providers, &(&1.id == assigns.screen.decision_provider))

    assigns = assign(assigns, hint: saved && saved.disabled? && saved.hint)

    ~H"""
    <div
      id="cues-decision-provider"
      class="flex flex-wrap items-center gap-x-3 gap-y-2 border-t border-base-300 pt-3"
    >
      <span class="flex items-center gap-1.5 text-sm font-medium">
        {@words.label} <.info text={@words.info} />
      </span>
      <select
        name="cues_settings[decision_provider]"
        aria-label={@words.label}
        class="select select-bordered select-sm w-full bg-base-100 sm:ml-auto sm:w-auto"
      >
        <option
          :for={choice <- @screen.decision_providers}
          value={choice.id}
          selected={choice.id == @screen.decision_provider}
          disabled={choice.disabled? and choice.id != @screen.decision_provider}
        >
          {choice.label}
        </option>
      </select>
      <p :if={@hint} class="w-full text-sm text-warning">{@hint}</p>
    </div>
    """
  end

  attr :value, :string, required: true
  attr :choice, :map, required: true
  attr :checked, :boolean, required: true

  # One of the Screen's two options. Its hint shows while the option is in use,
  # and always while it cannot be used, saying what to set up. The input is
  # never disabled, so a saved choice still submits and the save refuses it.
  defp screen_option(assigns) do
    hint? = assigns.choice.hint != nil and (assigns.checked or assigns.choice.disabled?)
    assigns = assign(assigns, hint?: hint?)

    ~H"""
    <label class={screen_option_class(@checked)}>
      <input
        type="radio"
        name="cues_settings[screen]"
        value={@value}
        checked={@checked}
        class="radio radio-primary radio-sm mt-0.5"
      />
      <span class="min-w-0">
        <span class="cues-screen-label block font-medium">{@choice.label}</span>
        <span
          :if={@hint?}
          class={[
            "cues-screen-hint block text-xs leading-5",
            if(@choice.disabled?, do: "text-warning", else: "text-base-content/60")
          ]}
        >
          {@choice.hint}
        </span>
      </span>
    </label>
    """
  end

  defp screen_option_class(true),
    do:
      "flex min-w-0 cursor-pointer gap-3 rounded-field border border-primary bg-primary/10 p-3 text-sm"

  defp screen_option_class(false),
    do:
      "flex min-w-0 cursor-pointer gap-3 rounded-field border border-base-300 bg-base-100 p-3 text-sm hover:border-base-content/30"

  # --- filter model ----------------------------------------------------------

  attr :filter, :map, required: true
  attr :words, :map, required: true
  attr :refusal, :map, default: nil

  defp filter_model(assigns) do
    ids = Enum.map(assigns.filter.providers, & &1.id)
    chosen? = assigns.filter.provider in ids
    stale? = assigns.filter.saved.provider != "" and assigns.filter.saved.provider not in ids
    words = assigns.words["filter_provider"]

    assigns =
      assign(assigns,
        chosen?: chosen?,
        stale?: stale?,
        label: words.label,
        info: words.info,
        card: @card
      )

    ~H"""
    <div id="cues-filter" class={[@card, "flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3"]}>
      <span class="flex items-center gap-1.5 text-sm font-medium">
        {@label} <.info text={@info} />
      </span>
      <div class="flex w-full flex-wrap items-center gap-2 sm:ml-auto sm:w-auto">
        <select
          name="cues_settings[filter_provider]"
          aria-label="Filter model"
          class="select select-bordered select-sm w-full bg-base-100 sm:w-auto"
        >
          <option value="" selected={!@chosen?}>{@filter.main_label}</option>
          <option
            :for={provider <- @filter.providers}
            value={provider.id}
            selected={provider.id == @filter.provider}
          >
            {provider.label}
          </option>
        </select>
        <.filter_model_input :if={@chosen?} filter={@filter} />
      </div>
      <p :if={@stale?} class="w-full text-sm text-warning">
        The saved filter provider, {@filter.saved.provider}, is not set up.
      </p>
      <.settings_refusal refusal={@refusal} rows={~w(filter_provider filter_model)} />
    </div>
    """
  end

  attr :filter, :map, required: true

  defp filter_model_input(assigns) do
    ~H"""
    <input
      type="text"
      name="cues_settings[filter_model]"
      value={@filter.model}
      list="cues-filter-models"
      placeholder="Model"
      aria-label="Model"
      class="input input-bordered input-sm w-full bg-base-100 font-mono sm:w-56"
    />
    <datalist id="cues-filter-models">
      <option :for={model <- @filter.models} value={model.id}>{model.label}</option>
    </datalist>
    """
  end

  # --- sources ---------------------------------------------------------------

  attr :cues, :map, required: true

  defp sources(assigns) do
    assigns = assign(assigns, info: @info.sources, card: @card)

    ~H"""
    <section id="cues-sources" class="space-y-3">
      <.section_head title="Sources" count={length(@cues.sources)} info={@info}>
        <span class="tooltip tooltip-left" data-tip="Refresh status">
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="cues_refresh"
            aria-label="Refresh status"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </span>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cues_new_source">
          <.icon name="hero-plus" class="size-4" /> Add source
        </button>
      </.section_head>
      <.reveal :if={@cues.reveal} reveal={@cues.reveal} port={@cues.switches.door_port} />
      <p :if={@cues.sources_error} class="text-sm text-warning">
        {rows_note(@cues.sources_error)}
      </p>
      <ul :if={@cues.sources != []} class="flex flex-col gap-2">
        <li :for={source <- @cues.sources} id={"cue-source-#{source.ref}"} class={[@card, "p-3"]}>
          <.source_row source={source} clock={@cues.clock} />
        </li>
      </ul>
      <.source_editor :if={@cues.source_editor} editor={@cues.source_editor} cues={@cues} />
    </section>
    """
  end

  # A first run: one card in place of the three empty lists, saying how cues
  # work in three steps, with the one thing to do first.
  defp first_run(assigns) do
    assigns = assign(assigns, steps: @first_run_steps, card: @card)

    ~H"""
    <section id="cues-first-run" class={[@card, "space-y-4 p-5"]}>
      <div class="flex items-center gap-3">
        <.kind_icon icon="hero-eye" />
        <h3 class="text-base font-semibold">Nothing is watched yet</h3>
      </div>
      <ol class="list-decimal space-y-1.5 pl-5 text-sm text-base-content/80 marker:font-semibold marker:text-primary">
        <li :for={step <- @steps}>{step}</li>
      </ol>
      <button type="button" class="btn btn-primary btn-sm" phx-click="cues_new_source">
        <.icon name="hero-plus" class="size-4" /> Add a source
      </button>
    </section>
    """
  end

  attr :source, :map, required: true
  attr :clock, :map, required: true

  defp source_row(assigns) do
    assigns = assign(assigns, :missing, missing_secret(assigns.source))

    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
      <.kind_icon icon={kind_icon_name(@source.kind)} />
      <div class="min-w-0 flex-1 basis-56">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class="truncate font-mono text-sm font-semibold">{@source.ref}</span>
          <span class="text-xs text-base-content/50">{source_type(@source)}</span>
          <.source_pill source={@source} clock={@clock} />
          <.pill :if={@missing} label={@missing} tone="badge-warning" />
        </div>
        <p class="mt-0.5 truncate text-xs text-base-content/50">
          <span :for={part <- source_line(@source, @clock)} class={part.class} title={part.title}>
            {part.text}
          </span>
        </p>
      </div>
      <.source_actions source={@source} />
    </div>
    """
  end

  attr :source, :map, required: true

  defp source_actions(assigns) do
    ~H"""
    <div class="ml-auto flex shrink-0 flex-wrap items-center justify-end gap-1">
      <button
        :if={@source.kind == "local_push"}
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="cues_new_token"
        phx-value-ref={@source.ref}
        data-confirm={"Replace the token of #{@source.ref}? The old one stops working within a minute."}
      >
        New token
      </button>
      <button
        :if={@source.kind == "webhook"}
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="cues_webhook_url"
        phx-value-ref={@source.ref}
      >
        {if @source.has_url?, do: "Show URL", else: "Generate URL"}
      </button>
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="cues_edit_source"
        phx-value-ref={@source.ref}
      >
        Edit
      </button>
      <.remove_button
        event="cues_remove_source"
        value_name="ref"
        value={@source.ref}
        confirm={"Remove source #{@source.ref} and its stored secrets?"}
      />
    </div>
    """
  end

  attr :source, :map, required: true
  attr :clock, :map, required: true

  defp source_pill(%{source: %{enabled?: false}} = assigns) do
    ~H"""
    <.pill label="Off" tone="badge-ghost" />
    """
  end

  defp source_pill(%{source: %{status: nil}} = assigns), do: ~H""

  defp source_pill(assigns) do
    status = assigns.source.status
    {label, tone} = status_pill(status)
    title = status.last_good_at && "Last good #{full_time(status.last_good_at, assigns.clock)}"
    assigns = assign(assigns, label: label, tone: tone, title: title)

    ~H"""
    <span class={["badge badge-sm", @tone]} title={@title}>{@label}</span>
    """
  end

  defp status_pill(status) do
    Map.get(@reason_pills, {status.status, status.stop_reason}) ||
      Map.get(@status_pills, status.status, {status.status, "badge-ghost"})
  end

  defp source_type(%{preset: preset}) when is_binary(preset), do: SourceForm.preset_label(preset)
  defp source_type(%{kind: kind}), do: SourceForm.kind_label(kind)

  defp kind_icon_name(kind), do: Map.get(@kind_icons, kind, "hero-bolt")

  # The row's one quiet line: what came in today and when, any refusals, then
  # where it reads from (last, so it is what truncates).
  defp source_line(source, clock) do
    [activity(source, clock), refused(source.status), address(source.url)]
    |> List.flatten()
    |> Enum.with_index()
    |> Enum.map(fn {part, index} -> separated(part, index) end)
  end

  defp activity(%{enabled?: false}, _clock), do: []
  defp activity(%{status: nil}, _clock), do: [part("No activity yet")]

  defp activity(%{status: status}, clock) do
    last = status.last_accepted_at

    [
      part("#{status.items_today} today"),
      last && part("last item #{short_time(last, clock)}", full_time(last, clock))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp refused(%{refused: [_ | _] = refused}),
    do: [%{part("refused #{Enum.join(refused, ", ")}") | class: "text-warning"}]

  defp refused(_status), do: []

  defp address(nil), do: []
  defp address(url), do: [part(url, url)]

  defp part(text, title \\ nil), do: %{text: text, title: title, class: nil}

  defp separated(part, 0), do: part
  defp separated(part, _index), do: %{part | text: " · " <> part.text}

  defp missing_secret(%{kind: "local_push", secrets: secrets}),
    do: if(Map.has_key?(secrets, :token), do: nil, else: "Needs a token")

  defp missing_secret(%{kind: "webhook", secrets: secrets, verify: verify}),
    do: if(Map.has_key?(secrets, :secret), do: nil, else: "Needs a #{secret_noun(verify)}")

  defp missing_secret(%{kind: "stream", missing_secret: field}) when not is_nil(field),
    do: "Needs a #{field}"

  defp missing_secret(_source), do: nil

  defp secret_noun(method), do: method |> SourceForm.webhook_secret_label() |> String.downcase()

  defp rows_note(:memory_off), do: "Memory is off, so a source's live status is not shown."
  defp rows_note(reason), do: "Live status could not be read: #{inspect(reason)}"

  # --- source editor ---------------------------------------------------------

  attr :editor, :map, required: true
  attr :cues, :map, required: true

  # A new source asks what to watch first: every choice in one list, the
  # featured ones first, each in the engine's words (`SourceForm.choices/0`).
  defp source_editor(%{editor: %{mode: :create, choice: nil}} = assigns) do
    ~H"""
    <div
      id="cue-source-choices"
      class="space-y-3 rounded-box border border-base-300 bg-base-200/40 p-4"
    >
      <h4 class="text-sm font-semibold">What should Fermix watch?</h4>
      <ul id="cue-source-choice-list" class="grid gap-2 sm:grid-cols-2">
        <li :for={choice <- @cues.choices}><.choice_button choice={choice} /></li>
      </ul>
      <button type="button" class="btn btn-ghost btn-sm" phx-click="cues_close_source">
        Cancel
      </button>
    </div>
    """
  end

  # A chosen source's fields: a new one opens what its choice needs and folds
  # the name and the rest under More options; an edit keeps its layout.
  defp source_editor(assigns) do
    editor = assigns.editor
    form = CuesState.source_form(editor.values)
    defaults = CuesState.preset_defaults(editor.values["preset"])
    inputs = inputs(form, editor.mode)
    open = open_inputs(editor.mode, inputs, form, defaults)
    folded = folded_inputs(editor.mode, inputs -- open)

    assigns =
      assign(assigns,
        form: form,
        defaults: defaults,
        choice: Enum.find(assigns.cues.choices, &(&1["id"] == editor.choice)),
        open: open,
        folded: folded,
        more?: source_more?(editor.values, folded)
      )

    ~H"""
    <form
      id="cue-source-form"
      phx-change="cues_source_changed"
      phx-submit="cues_save_source"
      class="space-y-4 rounded-box border border-base-300 bg-base-200/40 p-4"
    >
      <.source_head editor={@editor} choice={@choice} form={@form} />
      <div :if={@open != []} class="grid gap-4 lg:grid-cols-2">
        <.source_input
          :for={field <- @open}
          field={field}
          editor={@editor}
          form={@form}
          defaults={@defaults}
          choice={@choice}
        />
      </div>
      <.toggle
        :if={@editor.mode == :update}
        name="cue_source[enabled]"
        checked={@editor.values["enabled"] != "false"}
        label="On"
      />
      <.disclosure id="cue-source-more" label="More options" open={@more?}>
        <div class="mt-3 grid gap-4 lg:grid-cols-2">
          <.source_input
            :for={field <- @folded}
            field={field}
            editor={@editor}
            form={@form}
            defaults={@defaults}
            choice={@choice}
          />
        </div>
      </.disclosure>
      <p :if={@editor.refusal} id="cue-source-refusal" class="text-sm text-error">
        {@editor.refusal}
      </p>
      <.editor_actions
        save={if @editor.mode == :create, do: "Add source", else: "Save source"}
        close="cues_close_source"
        back={if @editor.mode == :create, do: "cues_back_to_choices"}
      />
    </form>
    """
  end

  attr :choice, :map, required: true

  defp choice_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="cues_pick_source"
      phx-value-choice={@choice["id"]}
      class="flex h-full w-full items-start gap-3 rounded-box border border-base-300 bg-base-100 p-3 text-left transition-colors hover:border-primary/40 hover:bg-primary/5"
    >
      <.kind_icon icon={choice_icon(@choice["id"])} />
      <span class="min-w-0">
        <span class="block text-sm font-medium">{@choice["label"]}</span>
        <span class="mt-0.5 block text-xs leading-5 text-base-content/60">
          {@choice["sentence"]}
        </span>
      </span>
    </button>
    """
  end

  defp choice_icon(id), do: Map.get(@choice_icons, id, "hero-bolt")

  attr :editor, :map, required: true
  attr :choice, :map, default: nil
  attr :form, :map, required: true

  # What the source is: a new one's choice, or an edit's kind and preset as
  # text (neither can change, as in the Mac sheet), then the choice's line,
  # with the form answer's notes (how items come in) behind its info.
  defp source_head(assigns) do
    assigns = assign(assigns, :note, notes_text(assigns.editor.notes))

    ~H"""
    <div class="space-y-1">
      <h4 class="text-sm font-semibold">
        {if @editor.mode == :create, do: @choice["label"], else: "Edit #{@editor.ref}"}
      </h4>
      <p
        :if={@editor.mode == :update}
        id="cue-source-choice"
        class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm"
      >
        <span>
          <span class="text-base-content/60">Kind</span>
          <span class="font-medium">{SourceForm.kind_label(@form.kind)}</span>
        </span>
        <span :if={@form.preset}>
          <span class="text-base-content/60">Preset</span>
          <span class="font-medium">{SourceForm.preset_label(@form.preset)}</span>
        </span>
      </p>
      <p
        :if={@choice}
        id="cue-source-kind-line"
        class="flex items-center gap-1.5 text-xs text-base-content/60"
      >
        <span>{@choice["sentence"]}</span> <.info :if={@note} text={@note} />
      </p>
    </div>
    """
  end

  defp notes_text([]), do: nil
  defp notes_text(notes), do: Enum.join(notes, " ")

  # The fields a form draws, in form order: a stream with no preset asks for
  # its API key and secret straight after its address, as the app's form
  # does, and every other form ends with its secret.
  defp inputs(form, mode) do
    fields = Enum.filter(@input_order, &(&1 in form.fields))
    secrets = secret_inputs(form, mode)

    if general_stream?(form),
      do: [:url | secrets] ++ List.delete(fields, :url),
      else: fields ++ secrets
  end

  # Fermix makes a GitHub source's secret when it is added
  # (`Settings.add_source/3`), so its add form asks for none.
  defp secret_inputs(%{kind: "webhook", preset: "github"}, :create), do: []
  defp secret_inputs(%{kind: "webhook"}, _mode), do: [:secret]
  defp secret_inputs(%{kind: "stream", preset: nil}, _mode), do: [:key, :secret]
  defp secret_inputs(_form, _mode), do: []

  # A new source opens what its choice needs (`SourceForm.add_open_keys/3`);
  # an edit keeps its layout, folding what a preset fills.
  defp open_inputs(:create, inputs, form, _defaults) do
    open = SourceForm.add_open_keys(form.kind, form.preset, form.verify)
    Enum.filter(inputs, &(row_key(&1) in open))
  end

  defp open_inputs(:update, inputs, _form, defaults) do
    folded = @edit_folded ++ preset_filled(defaults)
    Enum.reject(inputs, &(&1 in folded))
  end

  # The name is a new source's first folded field: left empty, Fermix makes it.
  defp folded_inputs(:create, folded), do: [:ref | folded]
  defp folded_inputs(:update, folded), do: folded

  # A webhook method's header and identity, where the preset fills them.
  defp preset_filled(defaults) do
    header = if Map.has_key?(defaults, :header), do: [:header], else: []

    identity =
      if Enum.any?(~w(id_header id id_path)a, &Map.has_key?(defaults, &1)),
        do: [:id_header, :id],
        else: []

    header ++ identity
  end

  defp row_key(field), do: Map.get(@row_keys, field, Atom.to_string(field))

  # More options starts open when a field under it already holds a value.
  defp source_more?(values, folded) do
    Enum.any?(folded, fn
      :id -> values["id"] == "true"
      field -> present?(values[Atom.to_string(field)])
    end)
  end

  attr :field, :atom, required: true
  attr :editor, :map, required: true
  attr :form, :map, required: true
  attr :defaults, :map, required: true
  attr :choice, :map, default: nil

  # One field of the form, in `SourceForm`'s words.
  defp source_input(%{field: :verify} = assigns) do
    assigns = assign(assigns, :label, SourceForm.field_words("verify").label)

    ~H"""
    <.select_field name="cue_source[verify]" label={@label}>
      <option :if={@defaults[:verify]} value="" selected={@editor.values["verify"] in [nil, ""]}>
        From the preset ({verify_label(text(@defaults[:verify]))})
      </option>
      <option
        :for={{method, label} <- SourceForm.verify_options()}
        value={method}
        selected={method == @editor.values["verify"]}
      >
        {label}
      </option>
    </.select_field>
    """
  end

  defp source_input(%{field: :id} = assigns) do
    assigns = assign(assigns, :words, SourceForm.field_words("content_hash"))

    ~H"""
    <div class="flex items-center">
      <.toggle
        name="cue_source[id]"
        checked={@editor.values["id"] == "true"}
        label={@words.label}
        info={@words.info}
      />
    </div>
    """
  end

  defp source_input(%{field: :secret, form: %{kind: "webhook"}} = assigns) do
    assigns = assign(assigns, :set?, Map.has_key?(assigns.editor.secrets, :secret))

    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        {SourceForm.webhook_secret_label(@form.verify)} <.info text={secret_info(@form.verify)} />
      </span>
      <input
        type="password"
        name="cue_source[secret]"
        value=""
        autocomplete="off"
        placeholder={
          if @set?,
            do: "Set; leave blank to keep it",
            else: "Paste the secret"
        }
        class="input input-bordered w-full bg-base-100 font-mono"
      />
    </label>
    """
  end

  defp source_input(%{field: field} = assigns) when field in [:key, :secret] do
    assigns = assign(assigns, :set?, Map.has_key?(assigns.editor.secrets, field))

    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        {if @field == :key, do: "API key", else: "API secret"}
        <.info text="Kept in Fermix's secret store, never shown here." />
      </span>
      <input
        type="password"
        name={"cue_source[#{@field}]"}
        value=""
        autocomplete="off"
        placeholder={if @set?, do: "Set; leave blank to keep it", else: "Paste the API #{@field}"}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
    </label>
    """
  end

  # X accounts says under its accounts whether the X sign-in is there.
  defp source_input(%{field: :handles} = assigns) do
    ~H"""
    <div>
      <.text_input
        field={@field}
        editor={@editor}
        form={@form}
        defaults={@defaults}
        choice={@choice}
      />
      <.requirement :if={@editor.requirement} requirement={@editor.requirement} />
    </div>
    """
  end

  defp source_input(assigns), do: text_input(assigns)

  attr :field, :atom, required: true
  attr :editor, :map, required: true
  attr :form, :map, required: true
  attr :defaults, :map, required: true
  attr :choice, :map, default: nil

  # A field the source must fill itself is marked required; one a refused
  # save found empty says so under it until it has a value.
  defp text_input(assigns) do
    key = Atom.to_string(assigns.field)
    words = text_words(assigns.field, assigns.form, assigns.defaults, assigns.choice)
    assigns = assign(assigns, key: key, words: words)

    ~H"""
    <.field
      name={"cue_source[#{@key}]"}
      label={@words.label}
      value={@editor.values[@key]}
      placeholder={@words.placeholder}
      info={@words.info}
      required={@field in @form.required}
      refusal={missing_refusal(@field, @editor.missing, @editor.values)}
      refusal_id={"cue-source-#{@key}-refusal"}
    />
    """
  end

  # A text field's label, info and what its empty field shows (an example, or
  # the preset's value), all `SourceForm`'s but the interval's unit, which is
  # the page's: it takes seconds where the app takes minutes.
  defp text_words(:ref, _form, _defaults, choice),
    do: example_words(SourceForm.name_row(choice["id"]))

  defp text_words(:handles, _form, _defaults, _choice),
    do: example_words(SourceForm.handles_row())

  defp text_words(:url, form, defaults, _choice) do
    if general_stream?(form),
      do: general_words(:url),
      else: %{
        label: SourceForm.url_label(form.preset),
        info: nil,
        placeholder: text(defaults[:url])
      }
  end

  defp text_words(:interval, _form, defaults, _choice) do
    %{
      label: SourceForm.field_words("interval_minutes").label <> " (seconds)",
      info: "At least 60.",
      placeholder: text(defaults[:interval])
    }
  end

  defp text_words(field, _form, _defaults, _choice) when field in @general_fields,
    do: general_words(field)

  defp text_words(field, _form, defaults, _choice) do
    words = SourceForm.field_words(row_key(field))
    %{label: words.label, info: words.info, placeholder: placeholder(field, defaults)}
  end

  defp placeholder(:algorithm, defaults), do: text(defaults[:algorithm]) || "sha256"
  defp placeholder(field, defaults), do: text(defaults[field])

  defp example_words(words),
    do: %{label: words.label, info: words.info, placeholder: words.example}

  # A stream with no preset: the management form's row (its literals'
  # backticks dropped from the info) and its example.
  defp general_words(field) do
    row = Enum.find(SourceForm.general_stream_rows(), &(&1.field == field))
    %{label: row.label, info: String.replace(row.info, "`", ""), placeholder: row.example}
  end

  defp general_stream?(form), do: form.kind == "stream" and form.preset == nil

  attr :requirement, :map, required: true

  # What a choice needs set up first, read when it was picked; it never stops
  # the add. A sign-in still to make links to the Plugins tab.
  defp requirement(assigns) do
    assigns = assign(assigns, :ready?, assigns.requirement["state"] == "ready")

    ~H"""
    <p
      id="cue-source-requirement"
      class={[
        "mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs",
        if(@ready?, do: "text-success", else: "text-warning")
      ]}
    >
      <.icon
        name={if @ready?, do: "hero-check-circle", else: "hero-exclamation-triangle"}
        class="size-3.5 shrink-0"
      />
      <span>{@requirement["sentence"]}</span>
      <button
        :if={!@ready?}
        type="button"
        class="link link-hover font-medium"
        phx-click="select_tab"
        phx-value-tab="plugins"
      >
        Open Plugins
      </button>
    </p>
    """
  end

  defp missing_refusal(field, missing, values) do
    if field in missing and not present?(values[Atom.to_string(field)]),
      do: missing_words(field)
  end

  defp missing_words(:id_header),
    do: "Give a delivery id header, or have Fermix identify items by their content."

  defp missing_words(_field), do: "Needed when no preset fills it."

  defp secret_info("standard_webhooks"),
    do: "Starts with whsec_. " <> secret_info(nil)

  defp secret_info(_method), do: "Kept in Fermix's secret store, never shown here."

  defp verify_label(method),
    do:
      Enum.find_value(SourceForm.verify_options(), method, fn {id, label} ->
        id == method && label
      end)

  # --- watchers --------------------------------------------------------------

  attr :watchers, :any, required: true

  defp watchers(assigns) do
    assigns = assign(assigns, info: @info.watchers, count: watcher_count(assigns.watchers))

    ~H"""
    <section id="cues-watchers" class="space-y-3">
      <.section_head title="Watchers" count={@count} info={@info} />
      <.watcher_list watchers={@watchers} />
    </section>
    """
  end

  defp watcher_count({:ok, watchers}), do: length(watchers)
  defp watcher_count({:error, _reason}), do: nil

  attr :watchers, :any, required: true

  defp watcher_list(%{watchers: {:error, :memory_off}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/50">Memory is off, so there are no watchers to show.</p>
    """
  end

  defp watcher_list(%{watchers: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="text-sm text-warning">Watchers could not be read: {inspect(@reason)}</p>
    """
  end

  defp watcher_list(%{watchers: {:ok, []}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/50">
      No watchers yet. Ask Fermix in chat to watch for something.
    </p>
    """
  end

  defp watcher_list(%{watchers: {:ok, watchers}} = assigns) do
    assigns = assign(assigns, list: watchers, card: @card)

    ~H"""
    <ul class="flex flex-col gap-2">
      <li
        :for={watcher <- @list}
        id={"cue-watcher-#{watcher.id}"}
        data-watcher-offered={watcher.offered}
        data-watcher-waiting={watcher.waiting}
        data-watcher-passed={watcher.passed}
        data-watcher-dropped={watcher.dropped}
        class={[@card, "p-3"]}
      >
        <.watcher_row watcher={watcher} />
      </li>
    </ul>
    """
  end

  attr :watcher, :map, required: true

  defp watcher_row(assigns) do
    assigns =
      assign(assigns,
        held_info: @info.held,
        needs: assigns.watcher.enabled? && assigns.watcher.needs_update
      )

    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
      <.kind_icon icon="hero-eye" />
      <div class="min-w-0 flex-1 basis-56">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class="truncate font-mono text-sm font-semibold">{@watcher.name}</span>
          <.pill :if={@watcher.enabled? && !@needs} label="On" tone="badge-success" />
          <.pill :if={!@watcher.enabled?} label="Paused" tone="badge-ghost" />
          <.pill
            :if={@needs}
            label="Needs update"
            tone="badge-warning"
            tip={WatcherRow.needs_update_sentence(@needs)}
          />
          <.pill :if={@watcher.held?} label="Held" tone="badge-warning" tip={@held_info} />
        </div>
        <p class="mt-0.5 truncate text-xs text-base-content/50">
          {filter_word(@watcher.filter)} ·
          <span class="font-mono">{Enum.join(@watcher.sources, ", ")}</span>
          <span :if={@watcher.task_job_id}>
            · task
            <span title={@watcher.task_job_id}>{@watcher.task_name || @watcher.task_job_id}</span>
          </span>
        </p>
        <.follow_up_line
          :if={@watcher.follow_up}
          watcher_id={@watcher.id}
          watcher_name={@watcher.name}
          follow_up={@watcher.follow_up}
        />
      </div>
      <div
        class="ml-auto flex shrink-0 items-center gap-3 text-xs text-base-content/50 tabular-nums"
        title="Last 24 hours"
      >
        <.count n={@watcher.offered} label="offered" />
        <.count n={@watcher.waiting} label="waiting" />
        <.count n={@watcher.passed} label="passed" />
        <.count n={@watcher.dropped} label="dropped" />
      </div>
    </div>
    """
  end

  # A watcher's follow-up, one quiet line in the engine's words (the management
  # row's `follow_up`), in the warning colour while held. The tab only takes an
  # Always allow back; a card's tap alone grants one.
  attr :watcher_id, :string, required: true
  attr :watcher_name, :string, required: true
  attr :follow_up, :map, required: true

  defp follow_up_line(assigns) do
    ~H"""
    <div
      id={"cue-watcher-#{@watcher_id}-follow-up"}
      class={[
        "mt-0.5 flex flex-wrap items-center gap-x-2 text-xs",
        follow_up_tone(@follow_up["state"])
      ]}
    >
      <span>
        Follow-up
        <span title={@follow_up["job_id"]}>{@follow_up["name"] || @follow_up["job_id"]}</span>
        · {@follow_up["status_sentence"]}
      </span>
      <button
        :if={@follow_up["always_allowed"]}
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="cues_ask_first"
        phx-value-name={@watcher_name}
      >
        Ask first again
      </button>
    </div>
    """
  end

  defp follow_up_tone("held"), do: "text-warning"
  defp follow_up_tone("ready"), do: "text-base-content/50"

  attr :n, :integer, required: true
  attr :label, :string, required: true

  defp count(assigns) do
    ~H"""
    <span><span class="font-semibold text-base-content/80">{@n}</span> {@label}</span>
    """
  end

  defp filter_word("none"), do: "No filter"
  defp filter_word(_llm), do: "Model filter"

  # --- mandates --------------------------------------------------------------

  attr :cues, :map, required: true

  defp mandates(assigns) do
    assigns = assign(assigns, info: @info.mandates_list, card: @card)

    ~H"""
    <section id="cues-mandates" class="space-y-3">
      <.section_head title="Mandates" count={length(@cues.mandates)} info={@info}>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cues_new_mandate">
          <.icon name="hero-plus" class="size-4" /> Add mandate
        </button>
      </.section_head>
      <p :if={@cues.mandates == []} class="text-sm text-base-content/50">No mandates.</p>
      <ul :if={@cues.mandates != []} class="flex flex-col gap-2">
        <li :for={mandate <- @cues.mandates} id={"cue-mandate-#{mandate.name}"} class={[@card, "p-3"]}>
          <.mandate_row mandate={mandate} clock={@cues.clock} />
        </li>
      </ul>
      <.mandate_editor :if={@cues.mandate_editor} editor={@cues.mandate_editor} cues={@cues} />
    </section>
    """
  end

  attr :mandate, :map, required: true
  attr :clock, :map, required: true

  defp mandate_row(assigns) do
    {label, tone, tip} = approval_pill(assigns.mandate, assigns.clock)
    assigns = assign(assigns, label: label, tone: tone, tip: tip)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
      <.kind_icon icon="hero-shield-check" />
      <div class="min-w-0 flex-1 basis-56">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class="truncate font-mono text-sm font-semibold">{@mandate.name}</span>
          <span class="text-xs text-base-content/50">{mode_label(@mandate.mode)}</span>
          <.pill :if={!@mandate.enabled?} label="Off" tone="badge-ghost" />
          <span data-mandate-approval><.pill label={@label} tone={@tone} tip={@tip} /></span>
        </div>
        <p class="mt-0.5 flex items-center gap-1 text-xs text-base-content/50">
          <span class="truncate" title={@mandate.job}>{mandate_line(@mandate)}</span>
          <.info text={mandate_details(@mandate)} class="tooltip tooltip-left" />
        </p>
      </div>
      <.mandate_actions mandate={@mandate} />
    </div>
    """
  end

  attr :mandate, :map, required: true

  defp mandate_actions(assigns) do
    ~H"""
    <div class="ml-auto flex shrink-0 items-center gap-1">
      <button
        :if={approvable?(@mandate)}
        type="button"
        class="btn btn-primary btn-xs"
        phx-click="cues_approve_mandate"
        phx-value-name={@mandate.name}
        data-confirm={"Approve mandate #{@mandate.name} as it is now?"}
      >
        Approve
      </button>
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="cues_edit_mandate"
        phx-value-name={@mandate.name}
      >
        Edit
      </button>
      <.remove_button
        event="cues_remove_mandate"
        value_name="name"
        value={@mandate.name}
        confirm={"Remove mandate #{@mandate.name}?"}
      />
    </div>
    """
  end

  # Approve applies to an active mandate that is not approved as it is now.
  defp approvable?(%{status: :active, approval: {:ok, %{state: :approved}}}), do: false
  defp approvable?(%{status: :active}), do: true
  defp approvable?(_inactive), do: false

  defp mode_label("auto"), do: "Auto"
  defp mode_label(_approve), do: "Approve each call"

  defp mandate_line(mandate) do
    reads =
      if mandate.read_tools == [], do: "", else: " · reads #{Enum.join(mandate.read_tools, ", ")}"

    "#{mandate.job_name || mandate.job} · #{Enum.join(mandate.tools, ", ")}#{reads}"
  end

  defp mandate_details(mandate) do
    [
      "Task #{mandate.job}.",
      "Acts on cues #{freshness(mandate.max_cue_age_s)}.",
      mandate.mode == "approve" && mandate.approve_within_s &&
        "A proposal waits #{duration(mandate.approve_within_s)}.",
      mandate.validator && "Validator: #{mandate.validator}.",
      mandate.pin_args != %{} && "Pinned: #{pins(mandate.pin_args)}."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp approval_pill(%{status: {:inactive, reason}}, _clock),
    do: {"Inactive", "badge-error", "Inactive: #{reason}"}

  defp approval_pill(%{approval: approval}, clock), do: approval_view(approval, clock)

  defp approval_view({:ok, %{state: :unapproved}}, _clock),
    do:
      {"Needs approval", "badge-warning", "Not approved yet. It acts only after you approve it."}

  defp approval_view({:ok, %{state: :approved} = status}, clock),
    do:
      {"Approved", "badge-success",
       "Approved #{full_time(status.approved_at, clock)}#{from(status.approved_from)}."}

  defp approval_view({:ok, %{state: :changed} = status}, clock),
    do:
      {"Changed", "badge-warning",
       "Changed since it was approved #{full_time(status.approved_at, clock)}#{detail(status.detail)}; " <>
         "approve it again before it acts."}

  defp approval_view({:ok, %{state: :disabled} = status}, clock),
    do:
      {"Disabled", "badge-error",
       "Disabled #{full_time(status.disabled_at, clock)}: #{status.disabled_reason}. " <>
         "Approve it again to turn it on."}

  defp approval_view({:error, :memory_off}, _clock),
    do: {"Approval unknown", "badge-ghost", "Memory is off."}

  defp approval_view({:error, reason}, _clock),
    do: {"Approval unknown", "badge-ghost", "Approval could not be read: #{inspect(reason)}"}

  defp freshness(0), do: "of any age"
  defp freshness(seconds), do: "at most #{duration(seconds)} old"

  defp pins(pin_args),
    do: Enum.map_join(Enum.sort(pin_args), ", ", fn {k, v} -> "#{k} = #{v}" end)

  defp from(nil), do: ""
  defp from(where), do: " from the #{where}"

  defp detail(nil), do: ""
  defp detail(sentence), do: " (#{sentence})"

  # --- mandate editor --------------------------------------------------------

  attr :editor, :map, required: true
  attr :cues, :map, required: true

  defp mandate_editor(assigns) do
    values = assigns.editor.values
    assigns = assign(assigns, values: values, more?: mandate_more?(values), mode_info: @info.mode)

    ~H"""
    <form
      id="cue-mandate-form"
      phx-submit="cues_save_mandate"
      class="space-y-4 rounded-box border border-base-300 bg-base-200/40 p-4"
    >
      <h4 class="text-sm font-semibold">
        {if @editor.mode == :create, do: "New mandate", else: "Edit #{@editor.name}"}
      </h4>
      <div class="grid gap-4 lg:grid-cols-2">
        <.field
          :if={@editor.mode == :create}
          name="cue_mandate[name]"
          label="Name"
          value={@values["name"]}
        />
        <.mandate_job_field values={@values} jobs={@cues.cue_jobs} />
        <.select_field name="cue_mandate[mode]" label="Mode" info={@mode_info}>
          <option value="approve" selected={@values["mode"] != "auto"}>
            Approve each call
          </option>
          <option value="auto" selected={@values["mode"] == "auto"}>Auto</option>
        </.select_field>
        <.field
          name="cue_mandate[approve_within]"
          label="Proposal wait"
          value={@values["approve_within"]}
          placeholder="30m"
          info="How long a proposal waits for you; at most 24h."
        />
        <.field
          name="cue_mandate[tools]"
          label="Action tools"
          value={@values["tools"]}
          info="Comma-separated."
        />
        <.field
          name="cue_mandate[read_tools]"
          label="Read tools"
          value={@values["read_tools"]}
          info="Comma-separated."
        />
      </div>
      <.toggle name="cue_mandate[enabled]" checked={@values["enabled"] != "false"} label="On" />
      <.disclosure id="cue-mandate-more" label="More options" open={@more?}>
        <.mandate_more_fields values={@values} />
      </.disclosure>
      <.editor_actions save="Save mandate" close="cues_close_mandate" />
    </form>
    """
  end

  attr :values, :map, required: true
  attr :jobs, :list, required: true

  defp mandate_job_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        Task <.info text="A job that runs on cues." />
      </span>
      <input
        type="text"
        name="cue_mandate[job]"
        value={@values["job"]}
        list="cue-jobs"
        class="input input-bordered w-full bg-base-100 font-mono"
      />
      <datalist id="cue-jobs">
        <option :for={job <- @jobs} value={job.id}>{job.name}</option>
      </datalist>
    </label>
    """
  end

  attr :values, :map, required: true

  defp mandate_more_fields(assigns) do
    ~H"""
    <div class="mt-3 grid gap-4 lg:grid-cols-2">
      <.field
        name="cue_mandate[max_cue_age]"
        label="Max cue age"
        value={@values["max_cue_age"]}
        placeholder="15m"
        info="Acts on cues at most this old; 0 for any age."
      />
      <.field
        name="cue_mandate[validator]"
        label="Validator"
        value={@values["validator"]}
        info="Absolute path to a program that checks each call."
      />
      <.field
        name="cue_mandate[interpreter]"
        label="Interpreter"
        value={@values["interpreter"]}
        info="Runs the validator, such as python3. Blank runs it directly."
      />
      <.field
        name="cue_mandate[validator_env]"
        label="Validator environment"
        value={@values["validator_env"]}
        info="Names of the environment variables the validator gets, comma-separated."
      />
      <.field
        name="cue_mandate[idempotency_arg]"
        label="Idempotency argument"
        value={@values["idempotency_arg"]}
        info="The argument Fermix sets as the call's id."
      />
      <.field
        name="cue_mandate[unpinned]"
        label="Unpinned skill paths"
        value={@values["unpinned"]}
        info="Skill paths the job itself writes, left out of the approval. Comma-separated."
      />
    </div>
    <label class="form-control mt-4 block w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        Pinned arguments
        <.info text={
          ~s(One per line, as in config.toml: repo = "ops". Every call must carry these exact values.)
        } />
      </span>
      <textarea
        name="cue_mandate[pin_args]"
        rows="3"
        placeholder={~s(repo = "ops")}
        class="textarea textarea-bordered w-full bg-base-100 font-mono"
      >{@values["pin_args"]}</textarea>
    </label>
    """
  end

  @mandate_more_fields ~w(max_cue_age validator interpreter validator_env idempotency_arg unpinned
                          pin_args)

  defp mandate_more?(values), do: Enum.any?(@mandate_more_fields, &present?(values[&1]))

  # --- small parts -----------------------------------------------------------

  attr :title, :string, required: true
  attr :count, :any, default: nil
  attr :info, :string, default: nil
  slot :inner_block

  defp section_head(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2">
      <div class="flex items-center gap-2">
        <h3 class="text-sm font-semibold">{@title}</h3>
        <span :if={@count} class="text-xs text-base-content/45 tabular-nums">{@count}</span>
        <.info :if={@info} text={@info} />
      </div>
      <div :if={@inner_block != []} class="flex items-center gap-1">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :class, :string, default: "tooltip"

  # Info "i": an explanation kept behind the control, never inline.
  defp info(assigns) do
    ~H"""
    <span
      class={[@class, "z-10 inline-flex font-normal text-base-content/45 max-sm:before:max-w-48"]}
      data-tip={@text}
      tabindex="0"
    >
      <.icon name="hero-information-circle" class="size-4" />
      <span class="sr-only">{@text}</span>
    </span>
    """
  end

  attr :label, :string, required: true
  attr :tone, :string, required: true
  attr :tip, :string, default: nil

  defp pill(%{tip: nil} = assigns) do
    ~H"""
    <span class={["badge badge-sm shrink-0 whitespace-nowrap", @tone]}>{@label}</span>
    """
  end

  defp pill(assigns) do
    ~H"""
    <span class="tooltip z-10 inline-flex max-sm:before:max-w-48" data-tip={@tip} tabindex="0">
      <span class={["badge badge-sm shrink-0 whitespace-nowrap", @tone]}>{@label}</span>
      <span class="sr-only">{@tip}</span>
    </span>
    """
  end

  attr :tone, :string, required: true
  attr :text, :string, required: true
  attr :class, :string, default: "text-base-content/70"

  defp dot(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-xs", @class]}>
      <span class={["size-1.5 shrink-0 rounded-full", @tone]} />{@text}
    </span>
    """
  end

  attr :icon, :string, required: true

  defp kind_icon(assigns) do
    ~H"""
    <span class="grid size-8 shrink-0 place-items-center rounded-field border border-base-300 bg-base-200/60 text-base-content/70">
      <.icon name={@icon} class="size-4" />
    </span>
    """
  end

  attr :event, :string, required: true
  attr :value_name, :string, required: true
  attr :value, :string, required: true
  attr :confirm, :string, required: true

  defp remove_button(assigns) do
    assigns = assign(assigns, :value_attr, %{"phx-value-#{assigns.value_name}" => assigns.value})

    ~H"""
    <span class="tooltip tooltip-left" data-tip="Remove">
      <button
        type="button"
        class="btn btn-ghost btn-xs btn-square text-error/80"
        phx-click={@event}
        data-confirm={@confirm}
        aria-label={"Remove #{@value}"}
        {@value_attr}
      >
        <.icon name="hero-trash" class="size-4" />
      </button>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :open, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true

  # The browser owns `open` once mounted, so a re-render never folds it shut.
  defp disclosure(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      phx-mounted={JS.ignore_attributes("open")}
      class={["group", @class]}
    >
      <summary class="flex min-h-8 w-fit cursor-pointer list-none items-center gap-1.5 text-sm text-base-content/70 hover:text-base-content">
        <.icon name="hero-chevron-right" class="size-3.5 transition-transform group-open:rotate-90" />
        {@label}
      </summary>
      {render_slot(@inner_block)}
    </details>
    """
  end

  attr :save, :string, required: true
  attr :close, :string, required: true
  attr :back, :string, default: nil

  defp editor_actions(assigns) do
    ~H"""
    <div class="flex gap-2">
      <button type="submit" class="btn btn-primary btn-sm">{@save}</button>
      <button :if={@back} type="button" class="btn btn-ghost btn-sm" phx-click={@back}>Back</button>
      <button type="button" class="btn btn-ghost btn-sm" phx-click={@close}>Cancel</button>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :info, :string, default: nil
  attr :required, :boolean, default: false
  attr :refusal, :string, default: nil
  attr :refusal_id, :string, default: nil

  defp field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        {@label} <.info :if={@info} text={@info} />
      </span>
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        required={@required}
        aria-invalid={@refusal && "true"}
        aria-describedby={@refusal && @refusal_id}
        class={["input input-bordered w-full bg-base-100", @refusal && "input-error"]}
      />
      <span :if={@refusal} id={@refusal_id} class="mt-1 block text-xs text-error">{@refusal}</span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :info, :string, default: nil
  attr :describedby, :string, default: nil
  slot :inner_block, required: true

  defp select_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        {@label} <.info :if={@info} text={@info} />
      </span>
      <select
        name={@name}
        aria-describedby={@describedby}
        class="select select-bordered w-full bg-base-100"
      >
        {render_slot(@inner_block)}
      </select>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :info, :string, default: nil

  defp toggle(assigns) do
    ~H"""
    <label class="flex w-fit cursor-pointer items-center gap-3">
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        name={@name}
        value="true"
        checked={@checked}
        class="toggle toggle-sm toggle-primary"
      />
      <span class="flex items-center gap-1.5 text-sm font-medium">
        {@label} <.info :if={@info} text={@info} />
      </span>
    </label>
    """
  end

  # --- times -----------------------------------------------------------------

  # A row's time in the owner's zone: the clock time today, "yesterday", else
  # the date (with the year once it is not this year's).
  defp short_time(%DateTime{} = at, clock) do
    local = DateTime.shift_zone!(at, clock.zone)
    today = clock.now |> DateTime.shift_zone!(clock.zone) |> DateTime.to_date()
    short_date(local, Date.diff(today, DateTime.to_date(local)), today.year)
  end

  defp short_date(local, days, _year) when days <= 0, do: Calendar.strftime(local, "%H:%M")
  defp short_date(_local, 1, _year), do: "yesterday"
  defp short_date(%{year: year} = local, _days, year), do: Calendar.strftime(local, "%b %-d")
  defp short_date(local, _days, _year), do: Calendar.strftime(local, "%b %-d, %Y")

  defp full_time(nil, _clock), do: "never"

  defp full_time(%DateTime{} = at, clock),
    do: at |> DateTime.shift_zone!(clock.zone) |> Calendar.strftime("%Y-%m-%d %H:%M %Z")

  defp duration(seconds) when rem(seconds, 3_600) == 0, do: "#{div(seconds, 3_600)}h"
  defp duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp duration(seconds), do: "#{seconds}s"

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: to_string(value)
end
