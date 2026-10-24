defmodule FermixWebWeb.SetupLive.CuesState do
  @moduledoc """
  The setup page's Cues tab (M60 §15): what the pane shows and what its
  events change.

  `build/2` reads the saved `[fermix_core.cues]` section and
  `[fermix_core.routing] filter_*` from the wizard's snapshot, and what the
  daemon reports through `FermixCore.Cues.Overview` (the door, each source's
  status row, the watchers' counts, each mandate's load status and approval).
  `handle/4` turns one tab event into a change through
  `FermixCore.Cues.Settings` (or `Cues.Webhook.ensure_path_secret/2` for a
  webhook's URL, on request and right after a new webhook source is saved)
  and tells the LiveView what to do next.

  The filter model offers what `FermixCore.Cues.FilterChoices` offers: the
  main model (the empty choice) and the providers that are set up. `clock`
  carries `now` and the owner's zone (`[fermix_core.personalization]
  timezone`, through `ComputerHistory.Config.timezone/1`), so the pane can
  write a row's time short and local.

  The tab exists only in a build that admits cues (`visible_tabs/2`). Nothing
  here shows cue text: watchers are counts and ids, sources are Fermix's own
  status columns, and a secret is shown as set or not set. The two values a
  page shows once (a new local-push token, a webhook URL) live in `reveal`,
  which every following event clears. The presets are
  `Management.Cues.SourceForm`'s, with the labels the Mac app shows.

  Seams (the LiveView's `:cues_pane_opts`): `:repo`, `:door`, `:now`
  (zero-arity, a `DateTime`), `:mandate_opts` and `:webhook_opts` (the options
  of `Cues.Webhook.ensure_path_secret/2`).
  """

  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.FilterChoices
  alias FermixCore.Cues.Overview
  alias FermixCore.Cues.Presets
  alias FermixCore.Cues.Settings
  alias FermixCore.Cues.Webhook
  alias FermixCore.Management.Cues.SourceForm
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @tab %{id: "cues", label: "Cues", component: nil, description: "Outside input"}
  @url_note "Keep it private: it is half of what a request needs."
  @door FermixCore.Cues.Door

  # The kinds and webhook methods the page offers, in the Mac sheet's order; a
  # new source opens on a feed, the common case. `Cues.Config` is still the one
  # that accepts or refuses a section.
  @kinds ~w(feed stream webhook local_push)
  @default_kind "feed"
  @verify_methods ~w(hmac shared_secret standard_webhooks)
  # The method a webhook with no preset starts on: the menu's first, so the
  # form draws the fields of the method it shows and a save stores it.
  @default_verify "hmac"

  # Every source field the form knows, in the order a saved section lists them.
  # A field the form shows for the source's kind comes from the form; one it
  # knows but does not show for that kind is dropped; any other field (JSON
  # paths, symbols) stays as the section had it.
  @form_fields ~w(preset kind enabled url interval dids collections daily_budget verify header
                  algorithm prefix id_header id type_header)a
  @list_fields ~w(dids collections)a
  @integer_fields ~w(interval daily_budget)a

  @mandate_list_fields ~w(tools read_tools validator_env unpinned)a
  @mandate_text_fields ~w(approve_within max_cue_age validator interpreter idempotency_arg)a

  # `{:saved, message, opts}`: `:restart?`, `:reveal` (a value shown once) and
  # `:tone` (`:error` when the save went through and a step after it did not).
  @type result ::
          {:edit, map()}
          | :refresh
          | {:saved, String.t(), keyword()}
          | {:error, term(), map()}

  @doc "The setup tabs with Cues before Doctor when `available?` (the build admits cues)."
  @spec visible_tabs([map()], boolean()) :: [map()]
  def visible_tabs(tabs, false) when is_list(tabs), do: tabs

  def visible_tabs(tabs, true) when is_list(tabs) do
    {before, rest} = Enum.split_while(tabs, &(&1.id != "doctor"))
    before ++ [@tab | rest]
  end

  @doc "The tab's state from the wizard's config snapshot and the daemon's reports."
  @spec build(map(), keyword()) :: map()
  def build(%{fermix_core: core} = snapshot, opts) when is_list(opts) do
    raw = Keyword.get(core, :cues, [])
    cues = CuesConfig.normalize(raw)
    now = now(opts)
    rows = Overview.sources(opts)

    %{
      switches: %{
        enabled: CuesConfig.enabled?(cues),
        mandates_enabled: CuesConfig.mandates_enabled?(cues),
        door_port: CuesConfig.door_port(cues),
        memory_on?: MemoryConfig.enabled?()
      },
      door: Overview.door(Keyword.get(opts, :door, @door)),
      filter: filter_view(Keyword.get(core, :routing, []), snapshot),
      sources: Enum.map(CuesConfig.sources(cues), &source_view(&1, rows, now)),
      sources_error: rows_error(rows),
      watchers: Overview.watchers(now, opts),
      mandates: Enum.map(Overview.mandates(cues, opts), &mandate_view/1),
      cue_jobs: cue_jobs(opts),
      raw: %{sources: Keyword.get(raw, :sources, %{}), mandates: Keyword.get(raw, :mandates, %{})},
      presets: SourceForm.presets(),
      kinds: @kinds,
      verify_methods: @verify_methods,
      source_editor: nil,
      mandate_editor: nil,
      reveal: nil,
      clock: %{now: now, zone: owner_zone(core)}
    }
  end

  @doc "One tab event (`action` is the event name after `cues_`)."
  @spec handle(String.t(), map(), map(), keyword()) :: result()
  def handle(action, params, state, opts)
      when is_binary(action) and is_map(params) and is_map(state) do
    event(action, params, %{state | reveal: nil}, opts)
  end

  # --- events ----------------------------------------------------------------

  defp event("refresh", _params, _state, _opts), do: :refresh

  defp event("dismiss_reveal", _params, state, _opts), do: {:edit, state}

  defp event("save_switches", %{"cues_switches" => params}, state, _opts) do
    changes = [
      enabled: checked?(params["enabled"]),
      mandates_enabled: checked?(params["mandates_enabled"]),
      door_port: integer_or_text(params["door_port"])
    ]

    case Settings.save_switches(changes) do
      {:ok, %{restart?: true}} -> {:saved, "Cues saved. Restart to apply.", restart?: true}
      {:ok, %{restart?: false}} -> {:saved, "Cues saved.", []}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp event("filter_changed", %{"cues_filter" => params}, state, _opts),
    do: {:edit, put_filter(state, params)}

  defp event("save_filter", %{"cues_filter" => params}, state, _opts) do
    case Settings.save_filter_model(params["provider"], params["model"]) do
      {:ok, %{cleared?: true}} -> {:saved, "Filter model set to the main model.", []}
      {:ok, %{cleared?: false}} -> {:saved, "Filter model saved.", []}
      {:error, reason} -> {:error, reason, put_filter(state, params)}
    end
  end

  defp event("new_source", _params, state, _opts),
    do: {:edit, %{state | source_editor: new_source_editor(), mandate_editor: nil}}

  defp event("edit_source", %{"ref" => ref}, state, _opts),
    do: {:edit, %{state | source_editor: edit_source_editor(state, ref), mandate_editor: nil}}

  defp event("close_source", _params, state, _opts), do: {:edit, %{state | source_editor: nil}}

  defp event("source_changed", %{"cue_source" => params}, state, _opts),
    do: {:edit, update_source_editor(state, params)}

  defp event("save_source", %{"cue_source" => params}, state, opts) do
    state = update_source_editor(state, params)
    save_source(state.source_editor, Map.get(params, "secret"), state, opts)
  end

  defp event("remove_source", %{"ref" => ref}, state, _opts) do
    case Settings.remove_source(ref) do
      {:ok, %{left: left}} ->
        message = ["Source #{ref} removed." | left] ++ funnel_note(state, ref)
        {:saved, Enum.join(message, " "), []}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp event("new_token", %{"ref" => ref}, state, _opts) do
    case Settings.new_token(ref) do
      {:ok, token} ->
        {:saved, "New token for #{ref}. The old one stops working within a minute.",
         reveal: %{kind: :token, ref: ref, value: token}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # The URL's random part is made and its sentinel saved by `ensure_path_secret`
  # itself, so the LiveView re-reads the snapshot after it (never a stale form).
  defp event("webhook_url", %{"ref" => ref}, state, opts) do
    case Webhook.ensure_path_secret(ref, webhook_opts(opts)) do
      {:ok, path} ->
        {:saved, "The URL for #{ref} is below. #{@url_note}",
         reveal: %{kind: :url, ref: ref, value: path}}

      {:error, reason} ->
        {:error, url_refusal(reason), state}
    end
  end

  defp event("new_mandate", _params, state, _opts),
    do: {:edit, %{state | mandate_editor: new_mandate_editor(), source_editor: nil}}

  defp event("edit_mandate", %{"name" => name}, state, _opts),
    do: {:edit, %{state | mandate_editor: edit_mandate_editor(state, name), source_editor: nil}}

  defp event("close_mandate", _params, state, _opts), do: {:edit, %{state | mandate_editor: nil}}

  defp event("save_mandate", %{"cue_mandate" => params}, state, _opts) do
    editor = %{state.mandate_editor | values: merge_values(state.mandate_editor.values, params)}
    state = %{state | mandate_editor: editor}
    save_mandate(editor, state)
  end

  defp event("remove_mandate", %{"name" => name}, state, _opts) do
    case Settings.remove_mandate(name) do
      {:ok, _} -> {:saved, "Mandate #{name} removed.", []}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The approval digests the mandate as the daemon reads it at every call: the
  # live settings, read here, never the page's snapshot, which may be older.
  defp event("approve_mandate", %{"name" => name}, state, opts) do
    cues =
      CuesConfig.normalize(Keyword.get(ConfigStore.current_snapshot().fermix_core, :cues, []))

    case Settings.approve_mandate(name, now(opts), Overview.mandate_opts(cues, opts)) do
      {:ok, _status} -> {:saved, "Mandate #{name} approved. It can act from now on.", []}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Removing a webhook source leaves a Tailscale Funnel mount of it in place;
  # the funnel task takes it down, even once the source has left the config.
  defp funnel_note(state, ref) do
    if Enum.any?(state.sources, &(&1.ref == ref and &1.kind == "webhook")),
      do: [
        "If you put it on Tailscale Funnel, mix fermix.cues.funnel #{ref} --remove --apply takes the mount down."
      ],
      else: []
  end

  # --- default filter model ----------------------------------------------------

  # The empty provider is the main model; only providers that are set up are
  # offered, each with its catalog models as suggestions.
  defp filter_view(routing, snapshot) do
    provider = routing |> Keyword.get(:filter_provider) |> text()

    %{
      provider: provider,
      model: routing |> Keyword.get(:filter_model) |> text(),
      main_label: FilterChoices.main_model_label(snapshot),
      providers: FilterChoices.providers(snapshot),
      models: FilterChoices.models(provider)
    }
  end

  defp put_filter(state, params) do
    provider = text(params["provider"])
    filter = %{state.filter | provider: provider, model: text(params["model"])}
    %{state | filter: %{filter | models: FilterChoices.models(provider)}}
  end

  # --- sources -------------------------------------------------------------------

  defp source_view(source, rows, now) do
    %{
      ref: source.ref,
      kind: Atom.to_string(source.kind),
      preset: source.preset,
      enabled?: source.enabled?,
      url: source.url,
      interval: source.interval,
      dids: source.dids,
      daily_budget: source.daily_budget,
      verify: source.verify && Atom.to_string(source.verify),
      secrets: source.secrets,
      has_url?: Map.has_key?(source.secrets, :path_secret),
      status: status_view(row(rows, source.ref), now)
    }
  end

  defp row({:ok, rows}, ref), do: Map.get(rows, ref)
  defp row({:error, _reason}, _ref), do: nil

  defp rows_error({:ok, _rows}), do: nil
  defp rows_error({:error, reason}), do: reason

  defp status_view(nil, _now), do: nil

  defp status_view(row, now) do
    today = now |> DateTime.to_date() |> Date.to_iso8601()

    %{
      status: row.status,
      last_good_at: row.last_good_at,
      last_accepted_at: row.last_accepted_at,
      items_today: if(row.items_day == today, do: row.items_today, else: 0),
      refused:
        row.reject_counts |> Enum.sort() |> Enum.map(fn {reason, n} -> "#{reason} #{n}" end)
    }
  end

  # A new source opens on its kind's first preset, as the Mac sheet does.
  # `missing` lists the fields a refused save found empty; `refusal` is the
  # page's sentence for the last refused save, said inside the editor.
  defp new_source_editor do
    values = %{
      "ref" => "",
      "preset" => first_preset(@default_kind),
      "kind" => @default_kind,
      "enabled" => "true"
    }

    %{
      mode: :create,
      ref: nil,
      values: default_verify(values),
      secrets: %{},
      missing: [],
      refusal: nil
    }
  end

  defp edit_source_editor(state, ref) do
    section = Map.fetch!(state.raw.sources, ref)

    values = Map.new(@form_fields, fn field -> {to_key(field), form_text(section, field)} end)

    %{
      mode: :update,
      ref: ref,
      values: Map.put(values, "enabled", to_string(Keyword.get(section, :enabled, true))),
      secrets: Map.new(Keyword.take(section, SecretWriter.cue_secret_fields())),
      missing: [],
      refusal: nil
    }
  end

  defp form_text(section, :id), do: to_string(Keyword.get(section, :id) == "content_hash")

  defp form_text(section, field) when field in @list_fields,
    do: section |> Keyword.get(field, []) |> Enum.join(", ")

  defp form_text(section, field), do: section |> Keyword.get(field) |> text()

  # A typed secret is read from the submit alone and never kept in the editor.
  defp update_source_editor(%{source_editor: editor} = state, params) do
    values =
      editor.values
      |> merge_values(Map.delete(params, "secret"))
      |> preset_of_kind(editor.values, editor.mode)
      |> verify_of_choice(editor.values)

    missing = still_missing(editor.missing, values)
    %{state | source_editor: %{editor | values: values, refusal: nil, missing: missing}}
  end

  # A field marked missing stays marked only while the form still needs it:
  # a required field, or the delivery id header while no identity is given.
  defp still_missing(missing, values) do
    form = source_form(values)

    Enum.filter(missing, fn field ->
      field in form.required or
        (field == :id_header and identity_missing?(form, values, identity_of(values)))
    end)
  end

  # A new kind or preset brings its own method, as the Mac sheet does: the
  # preset's where it names one, else the menu's first.
  defp verify_of_choice(values, before) do
    chosen? =
      source_kind(values) != source_kind(before) or
        text(Map.get(values, "preset")) != text(Map.get(before, "preset"))

    values = if chosen?, do: Map.put(values, "verify", ""), else: values
    default_verify(values)
  end

  defp default_verify(values) do
    preset_method = values |> Map.get("preset") |> preset_defaults() |> Map.get(:verify)
    blank? = text(Map.get(values, "verify")) == ""

    if source_kind(values) == "webhook" and blank? and is_nil(preset_method),
      do: Map.put(values, "verify", @default_verify),
      else: values
  end

  # On a new source a kind chosen brings its first preset, as the Mac sheet
  # opens on one; No preset stays in the menu. An edit cannot change either.
  defp preset_of_kind(values, before, :create) do
    chosen = text(Map.get(values, "kind"))

    if chosen != "" and chosen != source_kind(before),
      do: Map.put(values, "preset", first_preset(chosen)),
      else: values
  end

  defp preset_of_kind(values, _before, :update), do: values

  defp first_preset(kind),
    do: Enum.find_value(SourceForm.presets(), "", &(&1["kind"] == kind && &1["id"]))

  defp merge_values(values, params) do
    Enum.reduce(params, values, fn
      {"_" <> _unused, _value}, acc -> acc
      {key, value}, acc when is_binary(value) -> Map.put(acc, key, value)
      {_key, _value}, acc -> acc
    end)
  end

  defp save_source(editor, typed_secret, state, opts) do
    ref = editor.ref || String.trim(Map.get(editor.values, "ref", ""))
    existing = Map.get(state.raw.sources, ref, [])
    section = source_section(editor.values, existing)
    secrets = typed_secrets(typed_secret, source_kind(editor.values))

    with :ok <- same_choice(editor.mode, editor.values, existing),
         :ok <- needed_fields(editor.values, section),
         {:ok, %{token: token}} <- Settings.save_source(ref, section, secrets, editor.mode) do
      saved_source(ref, token, source_kind(editor.values), editor.mode, opts)
    else
      {:error, {:missing, fields}} ->
        editor = %{editor | missing: fields}

        {:error, {:invalid, "Fill in the fields marked as needed."},
         %{state | source_editor: editor}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # A field the kind needs and no preset fills, left empty, is refused here,
  # under its own field, before anything is written; so is a missing identity
  # (`Cues.Config.missing_identity?/4`, read on the section the save would
  # write), under the delivery id header.
  defp needed_fields(values, section) do
    form = source_form(values)
    empty = Enum.filter(form.required, &(form_value(values, &1) == nil))
    identity = if identity_missing?(form, values, section), do: [:id_header], else: []

    case empty ++ identity do
      [] -> :ok
      missing -> {:error, {:missing, missing}}
    end
  end

  defp identity_missing?(form, values, fields) do
    form.kind
    |> String.to_existing_atom()
    |> CuesConfig.missing_identity?(blank(text(Map.get(values, "preset"))), form.verify, fields)
  end

  defp identity_of(values) do
    [
      id_header: form_value(values, :id_header),
      id: if(checked?(values["id"]), do: "content_hash")
    ]
  end

  # The name, kind and preset cannot change on an edit, as in the management
  # form; the page shows them as text, and a submit that names others anyway
  # is refused before anything is written.
  defp same_choice(:create, _values, _existing), do: :ok

  defp same_choice(:update, values, existing) do
    saved = %{"preset" => Keyword.get(existing, :preset), "kind" => Keyword.get(existing, :kind)}

    if choice(values) == choice(saved),
      do: :ok,
      else: {:error, {:invalid, "A source's kind cannot change. Remove it and add a new one."}}
  end

  # The preset and kind as written, and the kind they make.
  defp choice(values) do
    {blank(text(Map.get(values, "preset"))), blank(text(Map.get(values, "kind"))),
     source_kind(values)}
  end

  # A new local push source's first token is shown once. A new webhook
  # source's URL is made with its save and shown at once, as Generate URL shows
  # it; the source is saved either way, and a URL that could not be made carries
  # its refusal where the URL would be, for the page to say in its own words.
  defp saved_source(ref, token, _kind, _mode, _opts) when is_binary(token),
    do: {:saved, "Source #{ref} saved.", reveal: %{kind: :token, ref: ref, value: token}}

  defp saved_source(ref, nil, "webhook", :create, opts) do
    case Webhook.ensure_path_secret(ref, webhook_opts(opts)) do
      {:ok, path} ->
        {:saved, "Source #{ref} saved. Its URL is below. #{@url_note}",
         reveal: %{kind: :url, ref: ref, value: path}}

      {:error, reason} ->
        {:saved, "Source #{ref} saved, but its URL could not be made.",
         reveal: %{kind: :url_failed, ref: ref, reason: url_refusal(reason)}, tone: :error}
    end
  end

  defp saved_source(ref, nil, _kind, _mode, _opts), do: {:saved, "Source #{ref} saved.", []}

  # `ensure_path_secret`'s own sentence, or the write guard's refusal as is.
  defp url_refusal(sentence) when is_binary(sentence), do: {:invalid, sentence}
  defp url_refusal(refusal), do: refusal

  defp webhook_opts(opts), do: Keyword.get(opts, :webhook_opts, [])

  @doc """
  What the source form shows for its values: the effective kind (the
  preset's, else the chosen one), the webhook method, the fields drawn, and
  the ones it must fill itself (`Cues.Config.required_fields/2`).
  """
  @spec source_form(map()) :: %{
          kind: String.t(),
          verify: String.t() | nil,
          fields: [atom()],
          required: [atom()]
        }
  def source_form(values) when is_map(values) do
    kind = source_kind(values)
    verify = webhook_method(values, kind)

    %{
      kind: kind,
      verify: verify,
      fields: shown_fields(kind, verify),
      required: required_fields(kind, blank(text(Map.get(values, "preset"))), verify)
    }
  end

  # The page offers only its own kinds; another one is a forged form and fails loud.
  defp required_fields(kind, preset, verify) when kind in @kinds,
    do: kind |> String.to_existing_atom() |> CuesConfig.required_fields(preset, verify)

  defp required_fields(kind, _preset, _verify),
    do: raise(ArgumentError, "the source form offers no kind #{inspect(kind)}")

  @doc "What preset `name` fills, as the placeholders the form shows (`%{}` for none)."
  @spec preset_defaults(String.t() | nil) :: map()
  def preset_defaults(name) when name in [nil, ""], do: %{}

  def preset_defaults(name) when is_binary(name) do
    case Presets.defaults(name) do
      {:ok, defaults} -> defaults
      :error -> %{}
    end
  end

  defp source_kind(values) do
    case {preset_defaults(Map.get(values, "preset")), text(Map.get(values, "kind"))} do
      {%{kind: kind}, _chosen} -> Atom.to_string(kind)
      {_none, ""} -> @default_kind
      {_none, chosen} -> chosen
    end
  end

  defp webhook_method(values, "webhook") do
    case text(Map.get(values, "verify")) do
      "" -> preset_defaults(Map.get(values, "preset")) |> Map.get(:verify) |> text() |> blank()
      method -> method
    end
  end

  defp webhook_method(_values, _kind), do: nil

  defp shown_fields(kind, verify) do
    base = [:preset, :kind, :enabled, :daily_budget]
    base ++ kind_fields(kind, verify)
  end

  defp kind_fields("feed", _verify), do: [:url, :interval]
  defp kind_fields("stream", _verify), do: [:url, :dids, :collections]
  defp kind_fields("webhook", verify), do: [:verify | method_fields(verify)] ++ [:type_header]
  defp kind_fields(_local_push, _verify), do: []

  defp method_fields("hmac"), do: [:header, :algorithm, :prefix, :id_header, :id]
  defp method_fields("shared_secret"), do: [:header, :id_header, :id]
  defp method_fields(_standard_or_none), do: []

  defp source_section(values, existing) do
    %{kind: kind, fields: fields} = source_form(values)
    preset = blank(text(values["preset"]))

    shown =
      @form_fields
      |> Enum.filter(&(&1 in fields))
      |> Enum.flat_map(&source_entry(&1, values, existing, preset, kind))

    kept = Keyword.drop(existing, @form_fields ++ SecretWriter.cue_secret_fields())
    shown ++ kept
  end

  defp source_entry(:preset, _values, _existing, preset, _kind), do: entry(:preset, preset)

  # A preset names the kind, so the section does not repeat it.
  defp source_entry(:kind, _values, _existing, nil, kind), do: [kind: kind]
  defp source_entry(:kind, _values, _existing, _preset, _kind), do: []

  # On is the default, so it is written only when off or already written.
  defp source_entry(:enabled, values, existing, _preset, _kind),
    do: unless_default(:enabled, checked?(values["enabled"]), true, existing)

  defp source_entry(:id, values, _existing, _preset, _kind),
    do: if(checked?(values["id"]), do: [id: "content_hash"], else: [])

  defp source_entry(field, values, _existing, _preset, _kind) when field in @list_fields,
    do: entry(field, split_list(values[to_key(field)]))

  defp source_entry(field, values, _existing, _preset, _kind) when field in @integer_fields,
    do: entry(field, integer_or_text(values[to_key(field)]))

  defp source_entry(field, values, _existing, _preset, _kind),
    do: entry(field, form_value(values, field))

  defp typed_secrets(typed, "webhook") do
    case blank(text(typed)) do
      nil -> %{}
      secret -> %{secret: secret}
    end
  end

  defp typed_secrets(_typed, _kind), do: %{}

  # --- mandates ------------------------------------------------------------------

  defp mandate_view(%{mandate: mandate, approval: approval}) do
    %{
      name: mandate.name,
      job: mandate.job,
      job_name: mandate.job_name,
      enabled?: mandate.enabled?,
      mode: Atom.to_string(mandate.mode),
      tools: mandate.tools,
      read_tools: mandate.read_tools,
      max_cue_age_s: mandate.max_cue_age_s,
      approve_within_s: mandate.approve_within_s,
      validator: mandate.validator,
      pin_args: mandate.pin_args,
      status: mandate.status,
      approval: approval
    }
  end

  defp new_mandate_editor do
    %{mode: :create, name: nil, values: %{"name" => "", "enabled" => "true", "mode" => "approve"}}
  end

  defp edit_mandate_editor(state, name) do
    section = Map.fetch!(state.raw.mandates, name)

    values =
      Map.new([:job | @mandate_text_fields] ++ @mandate_list_fields, fn field ->
        value = Keyword.get(section, field)
        {Atom.to_string(field), if(is_list(value), do: Enum.join(value, ", "), else: text(value))}
      end)

    values =
      Map.merge(values, %{
        "enabled" => to_string(Keyword.get(section, :enabled, true)),
        "mode" => section |> Keyword.get(:mode, "approve") |> text(),
        "pin_args" => section |> Keyword.get(:pin_args, %{}) |> pin_args_text()
      })

    %{mode: :update, name: name, values: values}
  end

  defp save_mandate(editor, state) do
    name = editor.name || String.trim(Map.get(editor.values, "name", ""))
    existing = Map.get(state.raw.mandates, name, [])

    with {:ok, section} <- mandate_section(editor.values, existing),
         {:ok, _} <- Settings.save_mandate(name, section, editor.mode) do
      {:saved, "Mandate #{name} saved. Approve it before it acts.", []}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Every mandate key is on the form, so the section is the form's.
  defp mandate_section(values, existing) do
    with {:ok, pins} <- parse_pin_args(Map.get(values, "pin_args", "")) do
      texts = Enum.flat_map(@mandate_text_fields, &entry(&1, form_value(values, &1)))
      lists = Enum.flat_map(@mandate_list_fields, &entry(&1, split_list(values[to_key(&1)])))

      {:ok,
       entry(:job, form_value(values, :job)) ++
         unless_default(:enabled, checked?(values["enabled"]), true, existing) ++
         unless_default(:mode, text(values["mode"]), "approve", existing) ++
         texts ++ lists ++ entry(:pin_args, pins)}
    end
  end

  # A value equal to its default is written only when the section already has it.
  defp unless_default(key, default, default, existing) do
    if Keyword.has_key?(existing, key), do: [{key, default}], else: []
  end

  defp unless_default(key, value, _default, _existing), do: [{key, value}]

  defp form_value(values, field), do: blank(text(values[to_key(field)]))

  defp to_key(field), do: Atom.to_string(field)

  @doc """
  Parses the pinned arguments box: one `name = value` per line, the value
  written as in `config.toml` (a quoted string, `true`/`false`, a number), or
  bare text for a string. Blank lines are skipped.
  """
  @spec parse_pin_args(String.t()) :: {:ok, map() | nil} | {:error, {:invalid, String.t()}}
  def parse_pin_args(text) when is_binary(text) do
    lines =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    lines
    |> Enum.reduce_while({:ok, %{}}, &pin_line/2)
    |> no_pins_as_nil()
  end

  defp pin_line(line, {:ok, acc}) do
    case String.split(line, "=", parts: 2) do
      [name, value] ->
        {:cont, {:ok, Map.put(acc, String.trim(name), pin_value(String.trim(value)))}}

      [_no_equals] ->
        {:halt, {:error, {:invalid, "Each pinned argument is one line: name = value."}}}
    end
  end

  defp no_pins_as_nil({:ok, pins}) when pins == %{}, do: {:ok, nil}
  defp no_pins_as_nil(result), do: result

  defp pin_value("true"), do: true
  defp pin_value("false"), do: false

  defp pin_value(text) do
    cond do
      String.match?(text, ~r/\A"(?:[^"\\]|\\.)*"\z/) -> Jason.decode!(text)
      String.match?(text, ~r/\A\d+\z/) -> String.to_integer(text)
      String.match?(text, ~r/\A\d+\.\d+\z/) -> String.to_float(text)
      true -> text
    end
  end

  defp pin_args_text(pins) when is_map(pins) do
    pins
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, value} -> "#{name} = #{pin_text(value)}" end)
  end

  defp pin_text(value) when is_binary(value), do: Jason.encode!(value)
  defp pin_text(value), do: to_string(value)

  # --- shared ----------------------------------------------------------------------

  defp cue_jobs(opts) do
    case Overview.cue_jobs(opts) do
      {:ok, jobs} -> jobs
      {:error, _reason} -> []
    end
  end

  defp entry(_key, nil), do: []
  defp entry(_key, []), do: []
  defp entry(key, value), do: [{key, value}]

  defp split_list(nil), do: []

  defp split_list(value) when is_binary(value),
    do: value |> String.split([",", " ", "\n", "\r", "\t"], trim: true)

  # A number the owner typed is written as one; anything else goes to the
  # config's own check, which names the key in its refusal.
  defp integer_or_text(value) do
    case blank(text(value)) do
      nil ->
        nil

      typed ->
        case Integer.parse(typed) do
          {number, ""} -> number
          _not_a_number -> typed
        end
    end
  end

  # A toggle posts a hidden "false" ahead of its checked "true"; the last value
  # wins, so anything other than the literal "true" is off.
  defp checked?("true"), do: true
  defp checked?(_value), do: false

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: to_string(value)

  defp blank(""), do: nil
  defp blank(value), do: value

  defp now(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()

  defp owner_zone(core) do
    zone = core |> Keyword.get(:personalization, []) |> Keyword.get(:timezone)
    ComputerHistoryConfig.timezone(timezone: zone)
  end
end
