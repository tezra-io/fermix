defmodule FermixWebWeb.SetupLive.CuesPane do
  @moduledoc """
  The Cues tab's markup (M60 §15), drawn from `SetupLive.CuesState`: the
  switches and the door, the default filter model, sources with their editor,
  the watchers made in chat (counts and ids only), and mandates with their
  approval. Every control posts a `cues_*` event the LiveView hands to
  `CuesState.handle/4`.
  """

  use FermixWebWeb, :html

  alias FermixWebWeb.SetupLive.CuesState

  @status_labels %{
    "connected" => "Connected",
    "reconnecting" => "Reconnecting",
    "auth_failed" => "Credential refused",
    "polling" => "Polling",
    "over_budget" => "Over its daily budget",
    "idle" => "Idle",
    "stopped" => "Stopped",
    "unavailable" => "Unavailable"
  }

  @kind_labels %{
    "local_push" => "Local push: a program posts events to the door",
    "feed" => "Feed: Fermix polls a URL",
    "stream" => "Stream: Fermix keeps a connection open",
    "webhook" => "Webhook: a service posts to a URL"
  }

  attr :cues, :map, required: true

  def pane(assigns) do
    ~H"""
    <div id="cues-pane" class="space-y-8">
      <div class="max-w-3xl">
        <h2 class="text-2xl font-semibold tracking-normal">Cues</h2>
        <p class="mt-2 text-sm leading-6 text-base-content/70">
          Outside input that wakes a task: feeds, streams, webhooks and your own scripts. A
          watcher decides which items matter; its task acts on them. This section exists only in a
          development build.
        </p>
      </div>
      <.reveal :if={@cues.reveal} reveal={@cues.reveal} port={@cues.switches.door_port} />
      <.switches switches={@cues.switches} door={@cues.door} />
      <.filter_model filter={@cues.filter} />
      <.sources cues={@cues} />
      <.watchers watchers={@cues.watchers} />
      <.mandates cues={@cues} />
    </div>
    """
  end

  # --- shown once ------------------------------------------------------------

  attr :reveal, :map, required: true
  attr :port, :integer, required: true

  defp reveal(%{reveal: %{kind: :token}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="rounded-box border border-primary/40 bg-primary/5 p-4 text-sm">
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">Token for {@reveal.ref}</h3>
        <button type="button" class="btn btn-ghost btn-xs" phx-click="cues_dismiss_reveal">
          Done
        </button>
      </div>
      <p class="mt-1 text-base-content/70">
        Shown only now. Put it in the program that posts; one token per machine.
      </p>
      <code class="mt-2 block break-all rounded bg-base-200 px-2 py-1 font-mono">
        {@reveal.value}
      </code>
      <p class="mt-3 text-base-content/70">Try it from this machine:</p>
      <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 font-mono text-xs">{curl(@reveal, @port)}</pre>
    </section>
    """
  end

  defp reveal(%{reveal: %{kind: :url}} = assigns) do
    ~H"""
    <section id="cues-reveal" class="rounded-box border border-primary/40 bg-primary/5 p-4 text-sm">
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">URL for {@reveal.ref}</h3>
        <button type="button" class="btn btn-ghost btn-xs" phx-click="cues_dismiss_reveal">
          Done
        </button>
      </div>
      <code class="mt-2 block break-all rounded bg-base-200 px-2 py-1 font-mono">
        http://127.0.0.1:{@port}{@reveal.value}
      </code>
      <p class="mt-2 text-base-content/70">
        The door listens on this machine only. Point a tunnel at port {@port} and give the service
        your tunnel's address followed by {@reveal.value}. For Tailscale Funnel,
        <code class="font-mono">mix fermix.cues.funnel {@reveal.ref}</code>
        prints the command and the public address. In the service, choose application/json as
        the content type.
      </p>
    </section>
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
    ~H"""
    <section class="space-y-4">
      <h3 class="text-sm font-semibold">Switches and door</h3>
      <form id="cues-switches-form" phx-submit="cues_save_switches" class="space-y-4">
        <.toggle
          name="cues_switches[enabled]"
          checked={@switches.enabled}
          label="Run cues"
          hint="Starts sources, the door, filters and watchers' tasks. Applies after restart."
        />
        <.toggle
          name="cues_switches[mandates_enabled]"
          checked={@switches.mandates_enabled}
          label="Let mandates act"
          hint="Off stops every mandate call at once, a run already going included. No restart needed."
        />
        <label class="form-control w-full max-w-xs">
          <span class="label pb-1 text-sm font-medium">Door port</span>
          <input
            type="number"
            name="cues_switches[door_port]"
            value={@switches.door_port}
            min="1024"
            max="65535"
            class="input input-bordered w-full bg-base-100"
          />
          <span class="label pt-1 text-xs text-base-content/60">
            The door listens on 127.0.0.1 only. Applies after restart.
          </span>
        </label>
        <p class="text-sm text-base-content/70">
          {door_line(@door, @switches)}
        </p>
        <p :if={!@switches.memory_on?} class="text-sm text-warning">
          Memory is off, so cues cannot run: every cue is a row in memory.
        </p>
        <button type="submit" class="btn btn-primary btn-sm">Save switches</button>
      </form>
    </section>
    """
  end

  defp door_line({:listening, ip, port}, %{door_port: port}),
    do: "Door: listening on #{ip}:#{port}."

  defp door_line({:listening, ip, port}, %{door_port: configured}),
    do: "Door: listening on #{ip}:#{port}. Restart to move it to port #{configured}."

  defp door_line({:unavailable, failure}, %{door_port: port}),
    do: "Door: unavailable; #{door_failure(failure, port)}"

  defp door_line(:not_running, %{enabled: true}),
    do: "Door: not running; it starts after a restart."

  defp door_line(:not_running, _switches), do: "Door: not running; cues are off."

  defp door_failure(:address_in_use, port), do: "another program is using port #{port}."
  defp door_failure(:permission_denied, port), do: "this user may not listen on port #{port}."
  defp door_failure(:address_unavailable, _port), do: "the loopback address is not available."
  defp door_failure(_listen_failed, port), do: "it could not listen on port #{port}."

  # --- default filter model --------------------------------------------------

  attr :filter, :map, required: true

  defp filter_model(assigns) do
    ~H"""
    <section class="space-y-4">
      <h3 class="text-sm font-semibold">Default filter model</h3>
      <p class="max-w-prose text-sm leading-6 text-base-content/70">
        A watcher that names no model of its own filters with this one. The filter answers pass or
        drop for one item at a time, so pick a small, inexpensive model. With no default here, a
        watcher must name its own model: Fermix never falls back to your main model.
      </p>
      <form
        id="cues-filter-form"
        phx-change="cues_filter_changed"
        phx-submit="cues_save_filter"
        class="space-y-4"
      >
        <div class="grid gap-4 lg:grid-cols-2">
          <label class="form-control w-full">
            <span class="label pb-1 text-sm font-medium">Provider</span>
            <select name="cues_filter[provider]" class="select select-bordered w-full bg-base-100">
              <option value="" selected={@filter.provider == ""}>None</option>
              <option
                :for={provider <- @filter.providers}
                value={provider.id}
                selected={provider.id == @filter.provider}
              >
                {provider.label}{if provider.configured?, do: "", else: " (not set up)"}
              </option>
            </select>
          </label>
          <label class="form-control w-full">
            <span class="label pb-1 text-sm font-medium">Model</span>
            <input
              type="text"
              name="cues_filter[model]"
              value={@filter.model}
              list="cues-filter-models"
              class="input input-bordered w-full bg-base-100 font-mono"
            />
            <datalist id="cues-filter-models">
              <option :for={model <- @filter.models} value={model.id}>{model.label}</option>
            </datalist>
          </label>
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Save filter model</button>
      </form>
    </section>
    """
  end

  # --- sources ---------------------------------------------------------------

  attr :cues, :map, required: true

  defp sources(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h3 class="text-sm font-semibold">Sources</h3>
        <div class="flex gap-2">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="cues_refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh status
          </button>
          <button type="button" class="btn btn-outline btn-sm" phx-click="cues_new_source">
            <.icon name="hero-plus" class="size-4" /> Add source
          </button>
        </div>
      </div>
      <p class="max-w-prose text-sm leading-6 text-base-content/70">
        Where cues come from. While cues run, a save starts, changes or stops the source at once.
      </p>
      <p :if={@cues.sources_error} class="text-sm text-warning">
        {rows_note(@cues.sources_error)}
      </p>
      <p :if={@cues.sources == []} class="text-sm text-base-content/60">No sources yet.</p>
      <ul :if={@cues.sources != []} class="space-y-3">
        <li
          :for={source <- @cues.sources}
          id={"cue-source-#{source.ref}"}
          class="rounded-box border border-base-300 bg-base-100 p-4 text-sm"
        >
          <.source_row source={source} />
        </li>
      </ul>
      <.source_editor :if={@cues.source_editor} editor={@cues.source_editor} cues={@cues} />
    </section>
    """
  end

  attr :source, :map, required: true

  defp source_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0 space-y-1">
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-mono font-semibold">{@source.ref}</span>
          <span class="badge badge-ghost badge-sm">{@source.preset || @source.kind}</span>
          <span class={[
            "badge badge-sm",
            if(@source.enabled?, do: "badge-success", else: "badge-ghost")
          ]}>
            {if @source.enabled?, do: "On", else: "Off"}
          </span>
        </div>
        <p :if={@source.url} class="break-all text-base-content/70">{@source.url}</p>
        <p :if={@source.dids != []} class="break-all text-base-content/70">
          Following {Enum.join(@source.dids, ", ")}
        </p>
        <p class="text-base-content/70">{status_line(@source)}</p>
        <p class="text-base-content/70">{secrets_line(@source)}</p>
      </div>
      <div class="flex flex-wrap gap-2">
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
        <button
          type="button"
          class="btn btn-ghost btn-xs text-error"
          phx-click="cues_remove_source"
          phx-value-ref={@source.ref}
          data-confirm={"Remove source #{@source.ref} and its stored secrets?"}
        >
          Remove
        </button>
      </div>
    </div>
    """
  end

  defp status_line(%{enabled?: false}), do: "Off: nothing is read from it."
  defp status_line(%{status: nil}), do: "No activity yet."

  defp status_line(%{status: status}) do
    [
      Map.get(@status_labels, status.status, status.status),
      status.last_good_at && "last good #{time(status.last_good_at)}",
      "#{status.items_today} today",
      status.last_accepted_at && "last accepted #{time(status.last_accepted_at)}",
      status.refused != [] && "refused: #{Enum.join(status.refused, ", ")}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp secrets_line(%{kind: "local_push", secrets: secrets}),
    do: "Token: #{set(secrets, :token)}"

  defp secrets_line(%{kind: "webhook", secrets: secrets, has_url?: has_url?, verify: verify}),
    do:
      "#{secret_label(verify)}: #{set(secrets, :secret)} · " <>
        if(has_url?, do: "URL: made", else: "URL: not made yet")

  defp secrets_line(%{secrets: secrets}) when map_size(secrets) == 0, do: nil

  defp secrets_line(%{secrets: secrets}),
    do: Enum.map_join(secrets, " · ", fn {field, _store} -> "#{field}: set" end)

  defp set(secrets, field), do: if(Map.has_key?(secrets, field), do: "set", else: "not set")

  defp secret_label("shared_secret"), do: "Shared secret"
  defp secret_label(_method), do: "Signing secret"

  defp rows_note(:memory_off), do: "Memory is off, so a source's live status is not shown."
  defp rows_note(reason), do: "Live status could not be read: #{inspect(reason)}"

  attr :editor, :map, required: true
  attr :cues, :map, required: true

  defp source_editor(assigns) do
    form = CuesState.source_form(assigns.editor.values)
    defaults = CuesState.preset_defaults(assigns.editor.values["preset"])
    assigns = assign(assigns, form: form, defaults: defaults, values: assigns.editor.values)

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
        <.field
          :if={@editor.mode == :create}
          name="cue_source[ref]"
          label="Name"
          value={@values["ref"]}
          hint="Lowercase letters, digits and hyphens, such as home-alerts."
        />
        <label class="form-control w-full">
          <span class="label pb-1 text-sm font-medium">Preset</span>
          <select name="cue_source[preset]" class="select select-bordered w-full bg-base-100">
            <option value="" selected={@values["preset"] in [nil, ""]}>No preset</option>
            <option :for={name <- @cues.presets} value={name} selected={name == @values["preset"]}>
              {name}
            </option>
          </select>
        </label>
        <label
          :if={:kind in @form.fields and @values["preset"] in [nil, ""]}
          class="form-control w-full"
        >
          <span class="label pb-1 text-sm font-medium">Kind</span>
          <select name="cue_source[kind]" class="select select-bordered w-full bg-base-100">
            <option :for={kind <- @cues.kinds} value={kind} selected={kind == @form.kind}>
              {kind_label(kind)}
            </option>
          </select>
        </label>
      </div>
      <.toggle name="cue_source[enabled]" checked={@values["enabled"] != "false"} label="On" />
      <div class="grid gap-4 lg:grid-cols-2">
        <.field
          :if={:url in @form.fields}
          name="cue_source[url]"
          label="URL"
          value={@values["url"]}
          placeholder={text(@defaults[:url])}
        />
        <.field
          :if={:interval in @form.fields}
          name="cue_source[interval]"
          label="Poll every (seconds, at least 60)"
          value={@values["interval"]}
          placeholder={text(@defaults[:interval])}
        />
        <.field
          :if={:dids in @form.fields}
          name="cue_source[dids]"
          label="Accounts to follow (DIDs, comma-separated)"
          value={@values["dids"]}
        />
        <.field
          :if={:collections in @form.fields}
          name="cue_source[collections]"
          label="Collections (comma-separated)"
          value={@values["collections"]}
          placeholder={Enum.join(@defaults[:collections] || [], ", ")}
        />
        <label :if={:verify in @form.fields} class="form-control w-full">
          <span class="label pb-1 text-sm font-medium">How requests are verified</span>
          <select name="cue_source[verify]" class="select select-bordered w-full bg-base-100">
            <option :if={@defaults[:verify]} value="" selected={@values["verify"] in [nil, ""]}>
              From the preset ({@defaults[:verify]})
            </option>
            <option
              :for={method <- @cues.verify_methods}
              value={method}
              selected={method == @values["verify"]}
            >
              {method}
            </option>
          </select>
        </label>
        <.field
          :if={:header in @form.fields}
          name="cue_source[header]"
          label="Signature header"
          value={@values["header"]}
          placeholder={text(@defaults[:header])}
        />
        <.field
          :if={:algorithm in @form.fields}
          name="cue_source[algorithm]"
          label="Algorithm (sha1, sha256 or sha512)"
          value={@values["algorithm"]}
          placeholder={text(@defaults[:algorithm]) |> default_to("sha256")}
        />
        <.field
          :if={:prefix in @form.fields}
          name="cue_source[prefix]"
          label="Signature prefix"
          value={@values["prefix"]}
          placeholder={text(@defaults[:prefix])}
        />
        <.field
          :if={:id_header in @form.fields}
          name="cue_source[id_header]"
          label="Delivery id header"
          value={@values["id_header"]}
          placeholder={text(@defaults[:id_header])}
        />
        <.field
          :if={:type_header in @form.fields}
          name="cue_source[type_header]"
          label="Event type header"
          value={@values["type_header"]}
          placeholder={text(@defaults[:type_header])}
        />
        <.field
          :if={:daily_budget in @form.fields}
          name="cue_source[daily_budget]"
          label="Items a day (0 or blank for no limit)"
          value={@values["daily_budget"]}
        />
      </div>
      <.toggle
        :if={:id in @form.fields}
        name="cue_source[id]"
        checked={@values["id"] == "true"}
        label="The service sends no delivery id: treat exact repeats as duplicates"
      />
      <.source_secret_fields form={@form} editor={@editor} />
      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save source</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cues_close_source">
          Cancel
        </button>
      </div>
    </form>
    """
  end

  attr :form, :map, required: true
  attr :editor, :map, required: true

  defp source_secret_fields(%{form: %{kind: "webhook"}} = assigns) do
    ~H"""
    <label class="form-control w-full max-w-xl">
      <span class="label pb-1 text-sm font-medium">{secret_label(@form.verify)}</span>
      <input
        type="password"
        name="cue_source[secret]"
        value=""
        autocomplete="off"
        placeholder={
          if Map.has_key?(@editor.secrets, :secret),
            do: "set; leave blank to keep it",
            else: "paste the secret the service signs with"
        }
        class="input input-bordered w-full bg-base-100 font-mono"
      />
      <span class="label pt-1 text-xs text-base-content/60">
        {if @form.verify == "standard_webhooks",
          do: "Starts with whsec_. ",
          else: ""}Kept in Fermix's secret store, never shown here. In the service, choose application/json as the content type.
      </span>
    </label>
    """
  end

  defp source_secret_fields(%{form: %{kind: "local_push"}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/70">
      {if @editor.mode == :create,
        do: "A token is made when you save and shown once.",
        else:
          "Token: #{if Map.has_key?(@editor.secrets, :token), do: "set", else: "not set"}. New token replaces it."}
    </p>
    """
  end

  defp source_secret_fields(assigns), do: ~H""

  defp kind_label(kind), do: Map.get(@kind_labels, kind, kind)

  # --- watchers --------------------------------------------------------------

  attr :watchers, :any, required: true

  defp watchers(assigns) do
    ~H"""
    <section class="space-y-4">
      <h3 class="text-sm font-semibold">Watchers</h3>
      <p class="max-w-prose text-sm leading-6 text-base-content/70">
        Watchers are made and changed in chat with Fermix; this list only shows them. Counts cover
        the last 24 hours.
      </p>
      <.watcher_list watchers={@watchers} />
    </section>
    """
  end

  attr :watchers, :any, required: true

  defp watcher_list(%{watchers: {:error, :memory_off}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">Memory is off, so there are no watchers to show.</p>
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
    <p class="text-sm text-base-content/60">
      No watchers yet. Ask Fermix in chat to watch a source for you.
    </p>
    """
  end

  defp watcher_list(%{watchers: {:ok, watchers}} = assigns) do
    assigns = assign(assigns, :list, watchers)

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Name</th>
            <th>Filter</th>
            <th>Sources</th>
            <th>Task</th>
            <th>State</th>
            <th class="text-right">Waiting</th>
            <th class="text-right">Passed</th>
            <th class="text-right">Dropped</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={watcher <- @list}
            id={"cue-watcher-#{watcher.id}"}
            data-watcher-waiting={watcher.waiting}
            data-watcher-passed={watcher.passed}
            data-watcher-dropped={watcher.dropped}
          >
            <td class="font-mono">{watcher.name}</td>
            <td>{watcher.filter}</td>
            <td class="font-mono">{Enum.join(watcher.sources, ", ")}</td>
            <td>
              <span :if={watcher.task_name}>{watcher.task_name}</span>
              <span class="font-mono text-xs text-base-content/60">{watcher.task_job_id}</span>
            </td>
            <td>
              {if watcher.enabled?, do: "On", else: "Paused"}
              <span :if={watcher.held?} class="badge badge-warning badge-sm ml-1">Held</span>
            </td>
            <td class="text-right">{watcher.waiting}</td>
            <td class="text-right">{watcher.passed}</td>
            <td class="text-right">{watcher.dropped}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p :if={Enum.any?(@list, & &1.held?)} class="text-xs text-base-content/60">
      Held: the filter's provider failed three times in a row; Fermix retries every 10 minutes.
    </p>
    """
  end

  # --- mandates --------------------------------------------------------------

  attr :cues, :map, required: true

  defp mandates(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h3 class="text-sm font-semibold">Mandates</h3>
        <button type="button" class="btn btn-outline btn-sm" phx-click="cues_new_mandate">
          <.icon name="hero-plus" class="size-4" /> Add mandate
        </button>
      </div>
      <p class="max-w-prose text-sm leading-6 text-base-content/70">
        A mandate lets one task call named action tools in its cue runs. In approve mode each call
        waits for you to confirm it in chat; in auto mode the checks decide. A mandate acts only
        after you approve it here, and a change to it, its task or its validator needs approving
        again.
      </p>
      <p :if={@cues.mandates == []} class="text-sm text-base-content/60">No mandates.</p>
      <ul :if={@cues.mandates != []} class="space-y-3">
        <li
          :for={mandate <- @cues.mandates}
          id={"cue-mandate-#{mandate.name}"}
          class="rounded-box border border-base-300 bg-base-100 p-4 text-sm"
        >
          <.mandate_row mandate={mandate} />
        </li>
      </ul>
      <.mandate_editor :if={@cues.mandate_editor} editor={@cues.mandate_editor} cues={@cues} />
    </section>
    """
  end

  attr :mandate, :map, required: true

  defp mandate_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0 space-y-1">
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-mono font-semibold">{@mandate.name}</span>
          <span class="badge badge-ghost badge-sm">{@mandate.mode}</span>
          <span class={[
            "badge badge-sm",
            if(@mandate.enabled?, do: "badge-success", else: "badge-ghost")
          ]}>
            {if @mandate.enabled?, do: "On", else: "Off"}
          </span>
        </div>
        <p class="text-base-content/70">
          Task {@mandate.job_name || @mandate.job}
          <span class="font-mono text-xs">({@mandate.job})</span>
        </p>
        <p class="text-base-content/70">
          Tools: {Enum.join(@mandate.tools, ", ")}{read_tools(@mandate.read_tools)} · acts on cues {freshness(
            @mandate.max_cue_age_s
          )}
        </p>
        <p :if={@mandate.validator} class="break-all text-base-content/70">
          Validator: <span class="font-mono">{@mandate.validator}</span>
        </p>
        <p :if={@mandate.pin_args != %{}} class="text-base-content/70">
          Pinned arguments: <span class="font-mono">{pins(@mandate.pin_args)}</span>
        </p>
        <p class={status_class(@mandate.status)}>{status_text(@mandate.status)}</p>
        <p class="text-base-content/70" data-mandate-approval>{approval_text(@mandate.approval)}</p>
      </div>
      <div class="flex flex-wrap gap-2">
        <button
          :if={@mandate.status == :active}
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
        <button
          type="button"
          class="btn btn-ghost btn-xs text-error"
          phx-click="cues_remove_mandate"
          phx-value-name={@mandate.name}
          data-confirm={"Remove mandate #{@mandate.name}?"}
        >
          Remove
        </button>
      </div>
    </div>
    """
  end

  defp read_tools([]), do: ""
  defp read_tools(tools), do: "; reads with #{Enum.join(tools, ", ")}"

  defp freshness(0), do: "of any age"
  defp freshness(seconds), do: "at most #{duration(seconds)} old"

  defp pins(pin_args),
    do: Enum.map_join(Enum.sort(pin_args), ", ", fn {k, v} -> "#{k} = #{v}" end)

  defp status_class(:active), do: "text-success"
  defp status_class(_inactive), do: "text-warning"

  defp status_text(:active), do: "Active."
  defp status_text({:inactive, reason}), do: "Inactive: #{reason}"

  defp approval_text({:ok, %{state: :unapproved}}), do: "Not approved yet."

  defp approval_text({:ok, %{state: :approved} = status}),
    do: "Approved #{time(status.approved_at)}#{from(status.approved_from)}."

  defp approval_text({:ok, %{state: :changed} = status}),
    do:
      "Changed since it was approved #{time(status.approved_at)}#{detail(status.detail)}; " <>
        "approve it again before it acts."

  defp approval_text({:ok, %{state: :disabled} = status}),
    do:
      "Disabled #{time(status.disabled_at)}: #{status.disabled_reason}. Approve it again to turn it on."

  defp approval_text({:error, :memory_off}), do: "Approval unknown: memory is off."
  defp approval_text({:error, reason}), do: "Approval could not be read: #{inspect(reason)}"

  defp from(nil), do: ""
  defp from(where), do: " from the #{where}"

  defp detail(nil), do: ""
  defp detail(sentence), do: " (#{sentence})"

  attr :editor, :map, required: true
  attr :cues, :map, required: true

  defp mandate_editor(assigns) do
    assigns = assign(assigns, :values, assigns.editor.values)

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
        <label class="form-control w-full">
          <span class="label pb-1 text-sm font-medium">Task (a job that runs on cues)</span>
          <input
            type="text"
            name="cue_mandate[job]"
            value={@values["job"]}
            list="cue-jobs"
            class="input input-bordered w-full bg-base-100 font-mono"
          />
          <datalist id="cue-jobs">
            <option :for={job <- @cues.cue_jobs} value={job.id}>{job.name}</option>
          </datalist>
        </label>
        <label class="form-control w-full">
          <span class="label pb-1 text-sm font-medium">Mode</span>
          <select name="cue_mandate[mode]" class="select select-bordered w-full bg-base-100">
            <option value="approve" selected={@values["mode"] != "auto"}>
              approve: each call waits for your confirmation
            </option>
            <option value="auto" selected={@values["mode"] == "auto"}>
              auto: the checks decide
            </option>
          </select>
        </label>
        <.field
          name="cue_mandate[approve_within]"
          label="A proposal waits (at most 24h)"
          value={@values["approve_within"]}
          placeholder="30m"
        />
        <.field
          name="cue_mandate[tools]"
          label="Action tools (comma-separated)"
          value={@values["tools"]}
        />
        <.field
          name="cue_mandate[read_tools]"
          label="Read tools (comma-separated)"
          value={@values["read_tools"]}
        />
        <.field
          name="cue_mandate[max_cue_age]"
          label="Act on cues at most this old (0 for any age)"
          value={@values["max_cue_age"]}
          placeholder="15m"
        />
        <.field
          name="cue_mandate[validator]"
          label="Validator (absolute path)"
          value={@values["validator"]}
        />
        <.field name="cue_mandate[interpreter]" label="Interpreter" value={@values["interpreter"]} />
        <.field
          name="cue_mandate[validator_env]"
          label="Validator environment names"
          value={@values["validator_env"]}
        />
        <.field
          name="cue_mandate[idempotency_arg]"
          label="Argument Fermix sets as the call's id"
          value={@values["idempotency_arg"]}
        />
        <.field
          name="cue_mandate[unpinned]"
          label="Skill paths the job writes (unpinned)"
          value={@values["unpinned"]}
        />
      </div>
      <label class="form-control w-full max-w-xl">
        <span class="label pb-1 text-sm font-medium">Pinned arguments</span>
        <textarea
          name="cue_mandate[pin_args]"
          rows="3"
          class="textarea textarea-bordered w-full bg-base-100 font-mono"
        >{@values["pin_args"]}</textarea>
        <span class="label pt-1 text-xs text-base-content/60">
          One per line, as in config.toml: repo = "ops". Every call must carry these exact values.
        </span>
      </label>
      <.toggle name="cue_mandate[enabled]" checked={@values["enabled"] != "false"} label="On" />
      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save mandate</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cues_close_mandate">
          Cancel
        </button>
      </div>
    </form>
    """
  end

  # --- small parts -----------------------------------------------------------

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :hint, :string, default: nil

  defp field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@label}</span>
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class="input input-bordered w-full bg-base-100"
      />
      <span :if={@hint} class="label pt-1 text-xs text-base-content/60">{@hint}</span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  defp toggle(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label cursor-pointer justify-start gap-3">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          name={@name}
          value="true"
          checked={@checked}
          class="toggle toggle-sm toggle-primary"
        />
        <span class="label-text text-sm font-medium">{@label}</span>
      </label>
      <p :if={@hint} class="max-w-prose pt-1 text-xs leading-relaxed text-base-content/60">{@hint}</p>
    </div>
    """
  end

  defp time(nil), do: "never"
  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp duration(seconds) when rem(seconds, 3_600) == 0, do: "#{div(seconds, 3_600)}h"
  defp duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp duration(seconds), do: "#{seconds}s"

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: to_string(value)

  defp default_to(nil, default), do: default
  defp default_to(value, _default), do: value
end
