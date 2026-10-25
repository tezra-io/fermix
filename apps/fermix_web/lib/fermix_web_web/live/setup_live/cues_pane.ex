defmodule FermixWebWeb.SetupLive.CuesPane do
  @moduledoc """
  The Cues tab's markup (M60 §15), drawn from `SetupLive.CuesState`: the
  switches and the door, the filter model, sources with their editor, the
  watchers made in chat (counts and ids only), and mandates with their
  approval. Every control posts a `cues_*` event the LiveView hands to
  `CuesState.handle/4`.

  Rows stay compact: a kind symbol, the name, a status pill and one quiet
  line, actions at the trailing edge. Longer explanations sit behind an info
  control or on the docs page; rarely used fields fold under "Advanced" or
  "More options". A row's time is short and in the owner's zone, the full
  time in its title.
  """

  use FermixWebWeb, :html

  alias FermixCore.Management.Cues.SourceForm
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

  @kind_icons %{
    "feed" => "hero-rss",
    "stream" => "hero-signal",
    "webhook" => "hero-globe-alt",
    "local_push" => "hero-command-line"
  }

  @kind_labels %{
    "local_push" => "Local push",
    "feed" => "Feed",
    "stream" => "Stream",
    "webhook" => "Webhook"
  }

  # Under the kind: where its items come from and, on a new source, what saving
  # makes. A kind's extra detail sits behind the info beside the line.
  @kind_lines %{
    "feed" => {"Fermix checks the feed's URL for new items on a schedule.", nil},
    "stream" =>
      {"Fermix keeps a connection open to a WebSocket (wss://) address and takes items as they arrive.",
       nil},
    "webhook" =>
      {"A service sends items to Fermix.",
       "Saving makes its URL. Give the service that URL and the secret you enter here."},
    "local_push" =>
      {"Your own scripts on this machine send items to Fermix.",
       "Saving makes a token, shown once."}
  }

  @kind_notes %{
    "webhook" =>
      "The door listens on this machine only. A service outside reaches it through a tunnel you run.",
    "local_push" => "Each item is a CloudEvent, sent with the token as a bearer token."
  }

  @verify_labels %{
    "hmac" => "HMAC signature",
    "shared_secret" => "Shared secret",
    "standard_webhooks" => "Standard Webhooks"
  }

  @info %{
    run:
      "Starts the sources, the door, the filters and the tasks watchers wake. Applies after a restart.",
    mandates:
      "Off stops the next call of every mandate at once, even in a run already going. No restart needed.",
    door_port: "The door listens on this machine only. Applies after a restart.",
    filter:
      "Decides which items reach a watcher's task, one item at a time. The main model works; a small, inexpensive one costs less. A watcher with a model of its own uses that one.",
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
      <section class="space-y-2">
        <.switches switches={@cues.switches} door={@cues.door} />
        <.filter_model filter={@cues.filter} />
      </section>
      <.sources cues={@cues} />
      <.watchers watchers={@cues.watchers} />
      <.mandates cues={@cues} />
    </div>
    """
  end

  defp pane_title(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <h2 class="text-2xl font-semibold tracking-normal">Cues</h2>
          <span class="badge badge-ghost badge-sm">Development build</span>
        </div>
        <p class="mt-1 text-sm text-base-content/70">
          Feeds, webhooks and your own scripts that wake a task.
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

  defp reveal(%{reveal: %{kind: :url_failed}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="space-y-2 rounded-box border border-warning/40 bg-warning/5 p-4">
      <.reveal_head title={"No URL for #{@reveal.ref} yet"} note={@reveal.sentence} reveal={@reveal} />
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
      <.copy_block
        id="cues-reveal-value"
        text={"http://127.0.0.1:#{@port}#{@reveal.value}"}
        label="Copy URL"
      />
      <p class="text-xs leading-5 text-base-content/60">
        Give the service your tunnel's address followed by the path, with content type
        application/json. For Tailscale Funnel, run <code class="font-mono">mix fermix.cues.funnel {@reveal.ref}</code>.
      </p>
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

  # --- switches and door -----------------------------------------------------

  attr :switches, :map, required: true
  attr :door, :any, required: true

  defp switches(assigns) do
    assigns = assign(assigns, info: @info, card: @card)

    ~H"""
    <form id="cues-switches-form" phx-submit="cues_save_switches" class={@card}>
      <div class="divide-y divide-base-300">
        <.switch_row
          name="cues_switches[enabled]"
          checked={@switches.enabled}
          label="Run cues"
          info={@info.run}
        />
        <.switch_row
          name="cues_switches[mandates_enabled]"
          checked={@switches.mandates_enabled}
          label="Let mandates act"
          info={@info.mandates}
        />
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
        <div class="flex items-start gap-3 px-4 py-3">
          <.disclosure id="cues-switches-advanced" label="Advanced" class="min-w-0 flex-1">
            <label class="mt-2 flex flex-wrap items-center gap-3">
              <span class="flex items-center gap-1.5 text-sm">
                Door port <.info text={@info.door_port} />
              </span>
              <input
                type="number"
                name="cues_switches[door_port]"
                value={@switches.door_port}
                min="1024"
                max="65535"
                class="input input-bordered input-sm w-28 bg-base-100"
              />
            </label>
          </.disclosure>
          <button type="submit" class="btn btn-primary btn-sm shrink-0">Save</button>
        </div>
      </div>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :info, :string, required: true

  defp switch_row(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center justify-between gap-3 px-4 py-3">
      <span class="flex items-center gap-1.5 text-sm font-medium">
        {@label} <.info text={@info} />
      </span>
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        name={@name}
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

  # --- filter model ----------------------------------------------------------

  attr :filter, :map, required: true

  defp filter_model(assigns) do
    ids = Enum.map(assigns.filter.providers, & &1.id)
    chosen? = assigns.filter.provider in ids
    stale? = assigns.filter.provider != "" and not chosen?
    assigns = assign(assigns, chosen?: chosen?, stale?: stale?, info: @info.filter, card: @card)

    ~H"""
    <form
      id="cues-filter-form"
      phx-change="cues_filter_changed"
      phx-submit="cues_save_filter"
      class={[@card, "flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3"]}
    >
      <span class="flex items-center gap-1.5 text-sm font-medium">
        Filter model <.info text={@info} />
      </span>
      <div class="flex w-full flex-wrap items-center gap-2 sm:ml-auto sm:w-auto">
        <select
          name="cues_filter[provider]"
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
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
      </div>
      <p :if={@stale?} class="w-full text-sm text-warning">
        The saved filter provider, {@filter.provider}, is not set up.
      </p>
    </form>
    """
  end

  attr :filter, :map, required: true

  defp filter_model_input(assigns) do
    ~H"""
    <input
      type="text"
      name="cues_filter[model]"
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
      <p :if={@cues.sources == []} class="text-sm text-base-content/50">No sources yet.</p>
      <ul :if={@cues.sources != []} class="flex flex-col gap-2">
        <li :for={source <- @cues.sources} id={"cue-source-#{source.ref}"} class={[@card, "p-3"]}>
          <.source_row source={source} clock={@cues.clock} />
        </li>
      </ul>
      <.source_editor :if={@cues.source_editor} editor={@cues.source_editor} cues={@cues} />
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
    {label, tone} = Map.get(@status_pills, status.status, {status.status, "badge-ghost"})
    title = status.last_good_at && "Last good #{full_time(status.last_good_at, assigns.clock)}"
    assigns = assign(assigns, label: label, tone: tone, title: title)

    ~H"""
    <span class={["badge badge-sm", @tone]} title={@title}>{@label}</span>
    """
  end

  defp source_type(%{preset: preset}) when is_binary(preset), do: SourceForm.preset_label(preset)
  defp source_type(%{kind: kind}), do: kind_label(kind)

  defp kind_label(kind), do: Map.get(@kind_labels, kind, kind)
  defp kind_icon_name(kind), do: Map.get(@kind_icons, kind, "hero-bolt")

  # The row's one quiet line: what came in today and when, any refusals, then
  # where it reads from (last, so it is what truncates).
  defp source_line(source, clock) do
    [activity(source, clock), refused(source.status), following(source.dids), address(source.url)]
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

  defp following([]), do: []
  defp following(dids), do: [part("following #{length(dids)}", Enum.join(dids, ", "))]

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

  defp secret_label("shared_secret"), do: "Shared secret"
  defp secret_label(_method), do: "Signing secret"

  defp secret_noun(method), do: method |> secret_label() |> String.downcase()

  defp rows_note(:memory_off), do: "Memory is off, so a source's live status is not shown."
  defp rows_note(reason), do: "Live status could not be read: #{inspect(reason)}"

  # --- source editor ---------------------------------------------------------

  attr :editor, :map, required: true
  attr :cues, :map, required: true

  defp source_editor(assigns) do
    values = assigns.editor.values
    form = CuesState.source_form(values)
    defaults = CuesState.preset_defaults(values["preset"])
    open = open_fields(form.fields, defaults)

    assigns =
      assign(assigns,
        form: form,
        defaults: defaults,
        values: values,
        open: open,
        folded: form.fields -- open,
        more?: source_more?(values, form.fields -- open)
      )

    ~H"""
    <form
      id="cue-source-form"
      phx-change="cues_source_changed"
      phx-submit="cues_save_source"
      class="space-y-4 rounded-box border border-base-300 bg-base-200/40 p-4"
    >
      <h4 class="text-sm font-semibold">
        {if @editor.mode == :create, do: "New source", else: "Edit #{@editor.ref}"}
      </h4>
      <div class="grid gap-4 lg:grid-cols-2">
        <.source_kind_fields editor={@editor} cues={@cues} form={@form} values={@values} />
        <.source_main_fields
          form={@form}
          values={@values}
          defaults={@defaults}
          cues={@cues}
          missing={@editor.missing}
        />
        <.source_field
          :for={field <- @open}
          field={field}
          values={@values}
          defaults={@defaults}
          required_fields={@form.required}
          missing={@editor.missing}
        />
        <.source_secret_fields form={@form} editor={@editor} />
      </div>
      <.toggle name="cue_source[enabled]" checked={@values["enabled"] != "false"} label="On" />
      <.disclosure id="cue-source-more" label="More options" open={@more?}>
        <.source_more_fields fields={@folded} values={@values} defaults={@defaults} />
      </.disclosure>
      <p :if={@editor.refusal} id="cue-source-refusal" class="text-sm text-error">
        {@editor.refusal}
      </p>
      <.editor_actions save="Save source" close="cues_close_source" />
    </form>
    """
  end

  attr :editor, :map, required: true
  attr :cues, :map, required: true
  attr :form, :map, required: true
  attr :values, :map, required: true

  # The kind first, then that kind's presets by label, then the line that says
  # where the kind's items come from, and the name. An edit cannot change the
  # kind or the preset, so it shows them as text, as the Mac sheet does.
  defp source_kind_fields(assigns) do
    assigns =
      assign(assigns,
        line: kind_line(assigns.form.kind, assigns.editor.mode),
        note: Map.get(@kind_notes, assigns.form.kind)
      )

    ~H"""
    <.source_choice_fields :if={@editor.mode == :create} form={@form} values={@values} cues={@cues} />
    <p
      :if={@editor.mode == :update}
      id="cue-source-choice"
      class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm lg:col-span-2"
    >
      <span>
        <span class="text-base-content/60">Kind</span>
        <span class="font-medium">{kind_label(@form.kind)}</span>
      </span>
      <span :if={@values["preset"] not in [nil, ""]}>
        <span class="text-base-content/60">Preset</span>
        <span class="font-medium">{SourceForm.preset_label(@values["preset"])}</span>
      </span>
    </p>
    <p
      :if={@line}
      id="cue-source-kind-line"
      class="flex items-center gap-1.5 text-xs text-base-content/60 lg:col-span-2"
    >
      {@line} <.info :if={@note} text={@note} />
    </p>
    <.field
      :if={@editor.mode == :create}
      name="cue_source[ref]"
      label="Name"
      value={@values["ref"]}
      placeholder="home-alerts"
      info="Lowercase letters, digits and hyphens."
    />
    """
  end

  attr :form, :map, required: true
  attr :values, :map, required: true
  attr :cues, :map, required: true

  defp source_choice_fields(assigns) do
    assigns =
      assign(
        assigns,
        :presets,
        Enum.filter(assigns.cues.presets, &(&1["kind"] == assigns.form.kind))
      )

    ~H"""
    <.select_field name="cue_source[kind]" label="Kind" describedby="cue-source-kind-line">
      <option :for={kind <- @cues.kinds} value={kind} selected={kind == @form.kind}>
        {kind_label(kind)}
      </option>
    </.select_field>
    <.select_field :if={@presets != []} name="cue_source[preset]" label="Preset">
      <option value="" selected={@values["preset"] in [nil, ""]}>No preset</option>
      <option
        :for={preset <- @presets}
        value={preset["id"]}
        selected={preset["id"] == @values["preset"]}
      >
        {preset["label"]}
      </option>
    </.select_field>
    """
  end

  defp kind_line(kind, mode) do
    case {Map.get(@kind_lines, kind), mode} do
      {nil, _mode} -> nil
      {{flow, made}, :create} when is_binary(made) -> "#{flow} #{made}"
      {{flow, _made}, _mode} -> flow
    end
  end

  attr :form, :map, required: true
  attr :values, :map, required: true
  attr :defaults, :map, required: true
  attr :cues, :map, required: true
  attr :missing, :list, required: true

  # A field the source must fill itself is marked required; one a refused save
  # found empty says so under it until it has a value.
  defp source_main_fields(assigns) do
    ~H"""
    <.field
      :if={:url in @form.fields}
      name="cue_source[url]"
      label="URL"
      value={@values["url"]}
      placeholder={text(@defaults[:url])}
      required={:url in @form.required}
      refusal={missing_refusal(:url, @missing, @values)}
      refusal_id="cue-source-url-refusal"
    />
    <.field
      :if={:interval in @form.fields}
      name="cue_source[interval]"
      label="Poll every (seconds)"
      value={@values["interval"]}
      placeholder={text(@defaults[:interval])}
      info="At least 60."
      required={:interval in @form.required}
      refusal={missing_refusal(:interval, @missing, @values)}
      refusal_id="cue-source-interval-refusal"
    />
    <.field
      :if={:dids in @form.fields}
      name="cue_source[dids]"
      label="Accounts (DIDs)"
      value={@values["dids"]}
      info="The accounts to follow, comma-separated."
      required={:dids in @form.required}
      refusal={missing_refusal(:dids, @missing, @values)}
      refusal_id="cue-source-dids-refusal"
    />
    <.field
      :if={:collections in @form.fields}
      name="cue_source[collections]"
      label="Collections"
      value={@values["collections"]}
      placeholder={Enum.join(@defaults[:collections] || [], ", ")}
      info="Comma-separated."
    />
    <.general_field
      :for={{field, {label, info}} <- general_fields()}
      :if={field in @form.fields}
      field={field}
      label={label}
      info={info}
      values={@values}
      required={field in @form.required}
      missing={@missing}
    />
    <.select_field
      :if={:verify in @form.fields}
      name="cue_source[verify]"
      label="Verification"
      info="How the door checks that a request comes from the service."
    >
      <option :if={@defaults[:verify]} value="" selected={@values["verify"] in [nil, ""]}>
        From the preset ({verify_label(text(@defaults[:verify]))})
      </option>
      <option
        :for={method <- @cues.verify_methods}
        value={method}
        selected={method == @values["verify"]}
      >
        {verify_label(method)}
      </option>
    </.select_field>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :info, :string, required: true
  attr :values, :map, required: true
  attr :required, :boolean, default: false
  attr :missing, :list, default: []

  # One field of a stream with no preset, its name the config key's.
  defp general_field(assigns) do
    assigns = assign(assigns, :key, Atom.to_string(assigns.field))

    ~H"""
    <.field
      name={"cue_source[#{@key}]"}
      label={@label}
      value={@values[@key]}
      info={@info}
      required={@required}
      refusal={missing_refusal(@field, @missing, @values)}
      refusal_id={"cue-source-#{@key}-refusal"}
    />
    """
  end

  # A stream with no preset: the management form's rows after its address, in
  # its words (`SourceForm.general_stream_rows/0`), the info text with its
  # literals' backticks dropped.
  defp general_fields, do: general_rows(false)
  defp general_more_fields, do: general_rows(true)

  defp general_rows(advanced?) do
    for row <- SourceForm.general_stream_rows(),
        row.field != :url and row.advanced == advanced?,
        do: {row.field, {row.label, String.replace(row.info, "`", "")}}
  end

  defp missing_refusal(field, missing, values) do
    if field in missing and not present?(values[Atom.to_string(field)]),
      do: missing_words(field)
  end

  defp missing_words(:id_header), do: "Give a delivery id header, or turn on No delivery id."
  defp missing_words(_field), do: "Needed when no preset fills it."

  # The fields a webhook's method needs that no preset fills (the signature
  # header, the delivery identity) are drawn open; a preset's own fold.
  defp open_fields(fields, defaults) do
    header = if Map.has_key?(defaults, :header), do: [], else: [:header]

    identity =
      if Enum.any?(~w(id_header id id_path)a, &Map.has_key?(defaults, &1)),
        do: [],
        else: [:id_header, :id]

    Enum.filter(header ++ identity, &(&1 in fields))
  end

  attr :field, :atom, required: true
  attr :values, :map, required: true
  attr :defaults, :map, required: true
  attr :required_fields, :list, default: []
  attr :missing, :list, default: []

  # A webhook method's field, drawn open or under More options.
  defp source_field(%{field: :header} = assigns) do
    ~H"""
    <.field
      name="cue_source[header]"
      label="Signature header"
      value={@values["header"]}
      placeholder={text(@defaults[:header])}
      required={:header in @required_fields}
      refusal={missing_refusal(:header, @missing, @values)}
      refusal_id="cue-source-header-refusal"
    />
    """
  end

  defp source_field(%{field: :id_header} = assigns) do
    ~H"""
    <.field
      name="cue_source[id_header]"
      label="Delivery id header"
      value={@values["id_header"]}
      placeholder={text(@defaults[:id_header])}
      refusal={missing_refusal(:id_header, @missing, @values)}
      refusal_id="cue-source-id_header-refusal"
    />
    """
  end

  defp source_field(%{field: :id} = assigns) do
    ~H"""
    <div class="flex items-center">
      <.toggle
        name="cue_source[id]"
        checked={@values["id"] == "true"}
        label="No delivery id"
        info="The service sends no delivery id: treat exact repeats as duplicates."
      />
    </div>
    """
  end

  attr :fields, :list, required: true
  attr :values, :map, required: true
  attr :defaults, :map, required: true

  defp source_more_fields(assigns) do
    ~H"""
    <div class="mt-3 grid gap-4 lg:grid-cols-2">
      <.source_field :if={:header in @fields} field={:header} values={@values} defaults={@defaults} />
      <.field
        :if={:algorithm in @fields}
        name="cue_source[algorithm]"
        label="Algorithm"
        value={@values["algorithm"]}
        placeholder={text(@defaults[:algorithm]) |> default_to("sha256")}
        info="sha1, sha256 or sha512."
      />
      <.field
        :if={:prefix in @fields}
        name="cue_source[prefix]"
        label="Signature prefix"
        value={@values["prefix"]}
        placeholder={text(@defaults[:prefix])}
      />
      <.source_field
        :if={:id_header in @fields}
        field={:id_header}
        values={@values}
        defaults={@defaults}
      />
      <.field
        :if={:type_header in @fields}
        name="cue_source[type_header]"
        label="Event type header"
        value={@values["type_header"]}
        placeholder={text(@defaults[:type_header])}
      />
      <.general_field
        :for={{field, {label, info}} <- general_more_fields()}
        :if={field in @fields}
        field={field}
        label={label}
        info={info}
        values={@values}
      />
      <.field
        :if={:daily_budget in @fields}
        name="cue_source[daily_budget]"
        label="Daily budget"
        value={@values["daily_budget"]}
        info="Items a day; 0 or blank for no limit."
      />
    </div>
    <div :if={:id in @fields} class="mt-4">
      <.source_field field={:id} values={@values} defaults={@defaults} />
    </div>
    """
  end

  # A field folded under More options opens it when it already holds a value:
  # a webhook's, and the general stream's as `SourceForm` folds them.
  @source_more_fields Enum.uniq(
                        ~w(header algorithm prefix id_header type_header daily_budget)a ++
                          for(
                            row <- SourceForm.general_stream_rows(),
                            row.advanced,
                            do: row.field
                          )
                      )

  defp source_more?(values, folded) do
    (values["id"] == "true" and :id in folded) or
      Enum.any?(@source_more_fields, &(&1 in folded and present?(values[Atom.to_string(&1)])))
  end

  attr :form, :map, required: true
  attr :editor, :map, required: true

  defp source_secret_fields(%{form: %{kind: "webhook"}} = assigns) do
    assigns = assign(assigns, :set?, Map.has_key?(assigns.editor.secrets, :secret))

    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        {secret_label(@form.verify)} <.info text={secret_info(@form.verify)} />
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

  # A stream with no preset signs in with a key and a secret, each typed once.
  defp source_secret_fields(%{form: %{kind: "stream", preset: nil}} = assigns) do
    ~H"""
    <.secret_input :for={field <- [:key, :secret]} field={field} editor={@editor} />
    """
  end

  defp source_secret_fields(assigns), do: ~H""

  attr :field, :atom, required: true
  attr :editor, :map, required: true

  defp secret_input(assigns) do
    assigns = assign(assigns, :set?, Map.has_key?(assigns.editor.secrets, assigns.field))

    ~H"""
    <label class="form-control w-full">
      <span class="label flex items-center gap-1.5 pb-1 text-sm font-medium">
        {if @field == :key, do: "Key", else: "Secret"}
        <.info text="Kept in Fermix's secret store, never shown here." />
      </span>
      <input
        type="password"
        name={"cue_source[#{@field}]"}
        value=""
        autocomplete="off"
        placeholder={if @set?, do: "Set; leave blank to keep it", else: "Paste the #{@field}"}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
    </label>
    """
  end

  defp secret_info("standard_webhooks"),
    do: "Starts with whsec_. " <> secret_info(nil)

  defp secret_info(_method),
    do:
      "Kept in Fermix's secret store, never shown here. In the service, choose application/json as the content type."

  defp verify_label(method), do: Map.get(@verify_labels, method, method)

  # --- watchers --------------------------------------------------------------

  attr :watchers, :any, required: true

  defp watchers(assigns) do
    assigns = assign(assigns, info: @info.watchers, count: watcher_count(assigns.watchers))

    ~H"""
    <section class="space-y-3">
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
    <p class="text-sm text-base-content/50">No watchers yet. Ask Fermix in chat to watch a source.</p>
    """
  end

  defp watcher_list(%{watchers: {:ok, watchers}} = assigns) do
    assigns = assign(assigns, list: watchers, card: @card)

    ~H"""
    <ul class="flex flex-col gap-2">
      <li
        :for={watcher <- @list}
        id={"cue-watcher-#{watcher.id}"}
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
    assigns = assign(assigns, :held_info, @info.held)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
      <.kind_icon icon="hero-eye" />
      <div class="min-w-0 flex-1 basis-56">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class="truncate font-mono text-sm font-semibold">{@watcher.name}</span>
          <.pill :if={@watcher.enabled?} label="On" tone="badge-success" />
          <.pill :if={!@watcher.enabled?} label="Paused" tone="badge-ghost" />
          <.pill :if={@watcher.held?} label="Held" tone="badge-warning" tip={@held_info} />
        </div>
        <p class="mt-0.5 truncate text-xs text-base-content/50">
          {filter_word(@watcher.filter)} ·
          <span class="font-mono">{Enum.join(@watcher.sources, ", ")}</span>
          · task
          <span title={@watcher.task_job_id}>{@watcher.task_name || @watcher.task_job_id}</span>
        </p>
      </div>
      <div
        class="ml-auto flex shrink-0 items-center gap-3 text-xs text-base-content/50 tabular-nums"
        title="Last 24 hours"
      >
        <.count n={@watcher.waiting} label="waiting" />
        <.count n={@watcher.passed} label="passed" />
        <.count n={@watcher.dropped} label="dropped" />
      </div>
    </div>
    """
  end

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
    <section class="space-y-3">
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
  attr :info, :string, required: true
  slot :inner_block

  defp section_head(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2">
      <div class="flex items-center gap-2">
        <h3 class="text-sm font-semibold">{@title}</h3>
        <span :if={@count} class="text-xs text-base-content/45 tabular-nums">{@count}</span>
        <.info text={@info} />
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

  defp editor_actions(assigns) do
    ~H"""
    <div class="flex gap-2">
      <button type="submit" class="btn btn-primary btn-sm">{@save}</button>
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

  defp default_to(nil, default), do: default
  defp default_to(value, _default), do: value
end
