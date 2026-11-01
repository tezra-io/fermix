defmodule FermixWebWeb.SetupLive.CuesState do
  @moduledoc """
  The setup page's Cues tab (M60 §15): what the pane shows and what its
  events change.

  `build/2` reads the saved `[fermix_core.cues]` section and
  `[fermix_core.routing] filter_*` from the wizard's snapshot, and what the
  daemon reports through `FermixCore.Cues.Overview` (the door, each source's
  status row, the watchers' counts, each mandate's load status and approval).
  `handle/4` turns one tab event into a change and tells the LiveView what
  to do next. The settings at the top (Run cues, the watchers' switch, the
  door's port, the Screen and the filter model) are one form with one Save,
  which writes the keys the owner changed through
  `Management.Settings.Cues.save/1`, the `cues` section's writer that
  `settings.apply` uses. Sources and mandates change through
  `FermixCore.Cues.Settings` (a new source through `add_source/3`, which
  names one left unnamed; `Cues.Webhook.ensure_path_secret/2` for a webhook's
  URL, on request and right after a new webhook source is saved).

  A new source starts from what to watch (`SourceForm.choices/0`): the
  editor opens on that list, and the choice fixes the kind and preset.

  Watchers are made and changed in chat, so the tab changes one thing about
  them: a follow-up's Always allow, which it only takes back
  (`Cues.Watchers.ask_first/3`, from `"setup_page"`). Each follow-up is the
  management row's (`WatcherRow.follow_up/1`), in the engine's words.

  The filter model offers what `FermixCore.Cues.FilterChoices` offers: the
  main model (the empty choice) and the providers that are set up. `clock`
  carries `now` and the owner's zone (`[fermix_core.personalization]
  timezone`, through `ComputerHistory.Config.timezone/1`), so the pane can
  write a row's time short and local.

  Nothing here shows cue text: watchers are counts and ids, sources are Fermix's own
  status columns, and a secret is shown as set or not set. The values a page
  shows once (a new local-push token, a webhook URL, the secret Fermix makes
  for a new GitHub source) live in `reveal`, which every following event
  clears. The choices are `Management.Cues.SourceForm`'s, with the words the
  Mac app shows.

  Seams (the LiveView's `:cues_pane_opts`): `:repo`, `:door`, `:now`
  (zero-arity, a `DateTime`), `:mandate_opts`, `:follow_up_opts` (the
  readiness seams a follow-up reads, `Cues.Overview`), `:webhook_opts` (the
  options of `Cues.Webhook.ensure_path_secret/2`) and `:x_sign_in`
  (zero-arity, the X sign-in the X accounts form reads,
  `SourceForm.requirement/2`).
  """

  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.FilterChoices
  alias FermixCore.Cues.Overview
  alias FermixCore.Cues.Presets
  alias FermixCore.Cues.Settings
  alias FermixCore.Cues.Watchers
  alias FermixCore.Cues.Webhook
  alias FermixCore.Cues.XAccounts
  alias FermixCore.Management.Cues.SourceForm
  alias FermixCore.Management.Cues.WatcherRow
  alias FermixCore.Management.Settings.Cues, as: SettingsCues
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @url_note "Keep it private: it is half of what a request needs."
  @door FermixCore.Cues.Door

  # The kinds the page draws a form for; a source with neither kind nor
  # preset reads as a feed. `Cues.Config` is still the one that accepts or
  # refuses a section.
  @kinds ~w(feed stream webhook local_push)
  @default_kind "feed"
  # The method a webhook with no preset starts on: the menu's first, so the
  # form draws the fields of the method it shows and a save stores it.
  @default_verify "hmac"

  # Every source field the form knows, in the order a saved section lists them.
  # A field the form shows for the source's kind comes from the form; one it
  # knows but does not show for that kind is dropped, except the JSON paths,
  # which only a stream with no preset shows and a feed or webhook keeps as
  # the section had them; any other field stays as the section had it.
  # A stream with no preset shows the management form's own rows after its
  # address (`SourceForm.general_stream_rows/0`).
  @general_stream_rows SourceForm.general_stream_rows() |> Enum.reject(&(&1.field == :url))
  @general_stream_fields Enum.map(@general_stream_rows, & &1.field)
  @path_fields ~w(items_path id_path revision_path type_path subject_path time_path)a
  @form_fields ~w(preset kind enabled url handles interval)a ++
                 @general_stream_fields ++
                 ~w(daily_budget verify header algorithm prefix id_header id type_header)a
  @list_fields [:handles | for(row <- @general_stream_rows, row.kind == :list, do: row.field)]
  # The secrets the form takes, each read from the submit alone.
  @typed_secret_keys ~w(key secret)
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
      words: section_words(snapshot),
      screen: screen_view(cues, snapshot),
      filter: filter_view(Keyword.get(core, :routing, []), snapshot),
      sources: Enum.map(CuesConfig.sources(cues), &source_view(&1, rows, now)),
      sources_error: rows_error(rows),
      watchers: watchers(now, Keyword.put(opts, :cues_config, cues)),
      mandates: Enum.map(Overview.mandates(cues, opts), &mandate_view/1),
      cue_jobs: cue_jobs(opts),
      raw: %{sources: Keyword.get(raw, :sources, %{}), mandates: Keyword.get(raw, :mandates, %{})},
      choices: SourceForm.choices(),
      source_editor: nil,
      mandate_editor: nil,
      reveal: nil,
      settings_refusal: nil,
      clock: %{now: now, zone: owner_zone(core)}
    }
  end

  # The `cues` section's rows in their own words (label and info), by key, so
  # a new label or explanation there reaches this page unchanged.
  defp section_words(snapshot) do
    "cues"
    |> SettingsCues.rows(snapshot)
    |> Map.new(&{&1["key"], %{label: &1["label"], info: &1["info"]}})
  end

  @doc "One tab event (`action` is the event name after `cues_`)."
  @spec handle(String.t(), map(), map(), keyword()) :: result()
  def handle(action, params, state, opts)
      when is_binary(action) and is_map(params) and is_map(state) do
    event(action, params, %{state | reveal: nil, settings_refusal: nil}, opts)
  end

  # --- events ----------------------------------------------------------------

  defp event("refresh", _params, _state, _opts), do: :refresh

  defp event("dismiss_reveal", _params, state, _opts), do: {:edit, state}

  # Choosing a filter provider brings its models; nothing is saved before Save.
  defp event("settings_changed", %{"cues_settings" => params}, state, _opts),
    do: {:edit, put_filter(state, params)}

  # One Save writes what the owner changed above through the `cues` section's
  # writer, the one `settings.apply` uses, so this page and the Mac app write
  # alike; with nothing changed it writes nothing.
  defp event("save_settings", %{"cues_settings" => params}, state, _opts) do
    case changed_settings(params, state) do
      [] -> {:saved, "Nothing changed.", []}
      changes -> save_settings(changes, put_filter(state, params))
    end
  end

  defp event("new_source", _params, state, _opts),
    do: {:edit, %{state | source_editor: new_source_editor(), mandate_editor: nil}}

  defp event("pick_source", %{"choice" => id}, state, opts),
    do: {:edit, %{state | source_editor: picked_source_editor(state.choices, id, opts)}}

  defp event("back_to_choices", _params, %{source_editor: %{mode: :create}} = state, _opts),
    do: {:edit, %{state | source_editor: new_source_editor()}}

  defp event("edit_source", %{"ref" => ref}, state, opts),
    do:
      {:edit, %{state | source_editor: edit_source_editor(state, ref, opts), mandate_editor: nil}}

  defp event("close_source", _params, state, _opts), do: {:edit, %{state | source_editor: nil}}

  defp event("source_changed", %{"cue_source" => params}, state, _opts),
    do: {:edit, update_source_editor(state, params)}

  defp event("save_source", %{"cue_source" => params}, state, opts) do
    state = update_source_editor(state, params)
    save_source(state.source_editor, Map.take(params, @typed_secret_keys), state, opts)
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

  # The one change the tab makes to a watcher: taking back its follow-up's
  # Always allow, so its next item asks first. Only a card's tap grants it.
  defp event("ask_first", %{"name" => name}, state, opts) do
    case Watchers.ask_first(name, "setup_page", Keyword.take(opts, [:repo])) do
      {:ok, %{echo: echo}} -> {:saved, echo, []}
      {:error, sentence} -> {:error, {:invalid, sentence}, state}
    end
  end

  # Removing a webhook source leaves a Tailscale Funnel mount of it in place.
  defp funnel_note(state, ref) do
    if Enum.any?(state.sources, &(&1.ref == ref and &1.kind == "webhook")),
      do: [
        "If you put it on Tailscale Funnel, its mount stays: tailscale funnel status lists it " <>
          "under /cues/hooks/#{ref}/, and tailscale funnel --https=443 --set-path=<that path> off " <>
          "takes it down."
      ],
      else: []
  end

  # --- settings ----------------------------------------------------------------

  # What the owner changed on the form, as `cues` section answers. The filter
  # pair is written whole, so a change to either half sends both.
  defp changed_settings(params, state) do
    form = [
      enabled: checked?(params["enabled"]),
      mandates_enabled: checked?(params["mandates_enabled"]),
      door_port: integer_or_text(params["door_port"]),
      screen: text(params["screen"])
    ]

    saved = [
      enabled: state.switches.enabled,
      mandates_enabled: state.switches.mandates_enabled,
      door_port: state.switches.door_port,
      screen: state.screen.value
    ]

    pair = [
      filter_provider: text(params["filter_provider"]),
      filter_model: text(params["filter_model"])
    ]

    saved_pair = [
      filter_provider: state.filter.saved.provider,
      filter_model: state.filter.saved.model
    ]

    (form -- saved) ++ if(pair == saved_pair, do: [], else: pair)
  end

  # A refusal names its row, and the page says it under that field as well as
  # in the banner. Turning cues on or off or moving the door needs a restart.
  defp save_settings(changes, state) do
    restart? = Keyword.has_key?(changes, :enabled) or Keyword.has_key?(changes, :door_port)

    case SettingsCues.save(changes) do
      {:ok, _saved} when restart? ->
        {:saved, "Cues saved. Restart to apply.", restart?: true}

      {:ok, _saved} ->
        {:saved, "Cues saved.", []}

      {:error, {:invalid_value, row, sentence}} ->
        {:error, {:invalid, sentence}, refused(state, row, sentence)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp refused(state, row, sentence),
    do: %{state | settings_refusal: %{row: row, sentence: sentence}}

  # --- the screen ----------------------------------------------------------------

  # Keyword match is the form's empty option, as it is saved as no key. The
  # decision model is always offered, so a saved one stays the form's value;
  # `Settings.save_screen/1` refuses it while none is set up, and its hint says
  # which one Fermix uses or what to set up.
  defp screen_view(cues, snapshot) do
    [keyword, decision_model] = FilterChoices.screen_choices(snapshot)

    %{
      value: if(CuesConfig.screen(cues) == :keyword, do: "", else: "decision_model"),
      keyword: keyword,
      decision_model: decision_model,
      info: FilterChoices.screen_info()
    }
  end

  # --- default filter model ----------------------------------------------------

  # The empty provider is the main model; only providers that are set up are
  # offered, each with its catalog models as suggestions. `provider` and
  # `model` follow the form; `saved` is what Save compares them with.
  defp filter_view(routing, snapshot) do
    provider = routing |> Keyword.get(:filter_provider) |> text()
    model = routing |> Keyword.get(:filter_model) |> text()

    %{
      provider: provider,
      model: model,
      saved: %{provider: provider, model: model},
      main_label: FilterChoices.main_model_label(snapshot),
      providers: FilterChoices.providers(snapshot),
      models: FilterChoices.models(provider)
    }
  end

  defp put_filter(state, params) do
    provider = text(params["filter_provider"])
    filter = %{state.filter | provider: provider, model: text(params["filter_model"])}
    %{state | filter: %{filter | models: FilterChoices.models(provider)}}
  end

  # --- watchers ------------------------------------------------------------------

  # Each watcher as `Overview` reads it, with its follow-up as the management
  # row publishes it (`WatcherRow.follow_up/1`), so the page says it in the
  # engine's words.
  defp watchers(now, opts) do
    with {:ok, watchers} <- Overview.watchers(now, opts) do
      {:ok, Enum.map(watchers, &%{&1 | follow_up: WatcherRow.follow_up(&1.follow_up)})}
    end
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
      daily_budget: source.daily_budget,
      verify: source.verify && Atom.to_string(source.verify),
      secrets: source.secrets,
      missing_secret: source.missing_secret,
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
      stop_reason: row.stop_reason,
      last_good_at: row.last_good_at,
      last_accepted_at: row.last_accepted_at,
      items_today: if(row.items_day == today, do: row.items_today, else: 0),
      refused:
        row.reject_counts |> Enum.sort() |> Enum.map(fn {reason, n} -> "#{reason} #{n}" end)
    }
  end

  # A new source opens on what to watch (`SourceForm.choices/0`), with no
  # choice yet. `missing` lists the fields a refused save found empty;
  # `refusal` is the page's sentence for the last refused save, said inside
  # the editor; `requirement` is what the choice needs set up first, and
  # `notes` how its items come in.
  defp new_source_editor do
    %{
      mode: :create,
      choice: nil,
      ref: nil,
      values: %{},
      secrets: %{},
      missing: [],
      refusal: nil,
      requirement: nil,
      notes: []
    }
  end

  # A choice brings its kind, its preset, the method a webhook starts on, and
  # the form answer's notes and requirement: X accounts says whether the X
  # sign-in is there, which never stops the add.
  defp picked_source_editor(choices, id, opts) do
    choice = Enum.find(choices, &(&1["id"] == id))

    if is_nil(choice), do: raise(ArgumentError, "the source form offers no choice #{inspect(id)}")

    values = %{
      "ref" => "",
      "preset" => text(choice["preset"]),
      "kind" => choice["kind"],
      "enabled" => "true"
    }

    form = form_answer(choice["kind"], choice["preset"], opts)

    %{
      new_source_editor()
      | choice: id,
        values: default_verify(values),
        requirement: form["requirement"],
        notes: form["notes"]
    }
  end

  # An edit carries its kind's and preset's notes too, and no requirement.
  defp edit_source_editor(state, ref, opts) do
    section = Map.fetch!(state.raw.sources, ref)

    values = Map.new(@form_fields, fn field -> {to_key(field), form_text(section, field)} end)
    preset = blank(text(Map.get(values, "preset")))

    %{
      mode: :update,
      choice: choice_of(state.choices, values),
      ref: ref,
      values: Map.put(values, "enabled", to_string(Keyword.get(section, :enabled, true))),
      secrets: Map.new(Keyword.take(section, SecretWriter.cue_secret_fields())),
      missing: [],
      refusal: nil,
      requirement: nil,
      notes: form_answer(source_kind(values), preset, opts)["notes"]
    }
  end

  # The engine's add form for a kind and preset (`SourceForm.form/4`), read
  # for its notes and requirement. Both come from the page's own choices and
  # saved sections, so a refusal is a bug and fails loud.
  defp form_answer(kind, preset, opts) do
    {:ok, form} = SourceForm.form(kind, preset, nil, Keyword.take(opts, [:x_sign_in]))
    form
  end

  # The choice a saved source's kind and preset make.
  defp choice_of(choices, values) do
    preset = blank(text(Map.get(values, "preset")))
    kind = source_kind(values)
    Enum.find_value(choices, &(&1["kind"] == kind and &1["preset"] == preset and &1["id"]))
  end

  defp form_text(section, :id), do: to_string(Keyword.get(section, :id) == "content_hash")

  defp form_text(section, field) when field in @list_fields,
    do: section |> Keyword.get(field, []) |> Enum.join(", ")

  defp form_text(section, field), do: section |> Keyword.get(field) |> text()

  # A typed secret is read from the submit alone and never kept in the editor.
  defp update_source_editor(%{source_editor: editor} = state, params) do
    values = merge_values(editor.values, Map.drop(params, @typed_secret_keys))
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

  defp default_verify(values) do
    preset_method = values |> Map.get("preset") |> preset_defaults() |> Map.get(:verify)
    blank? = text(Map.get(values, "verify")) == ""

    if source_kind(values) == "webhook" and blank? and is_nil(preset_method),
      do: Map.put(values, "verify", @default_verify),
      else: values
  end

  defp merge_values(values, params) do
    Enum.reduce(params, values, fn
      {"_" <> _unused, _value}, acc -> acc
      {key, value}, acc when is_binary(value) -> Map.put(acc, key, value)
      {_key, _value}, acc -> acc
    end)
  end

  defp save_source(editor, typed, state, opts) do
    existing = Map.get(state.raw.sources, editor.ref, [])
    section = source_section(editor.values, existing)
    secrets = typed_secrets(typed, source_form(editor.values))

    with :ok <- same_choice(editor.values, fixed_choice(editor, state.choices, existing)),
         :ok <- needed_fields(editor.values, section),
         {:ok, section} <- x_handles(section),
         {:ok, saved} <- store_source(editor, section, secrets) do
      saved_source(saved, source_kind(editor.values), editor.mode, opts)
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

  # X accounts keeps its handles as X spells them in a search, as the
  # management form does (`Cues.XAccounts.handles/1`); one X would not take is
  # refused in its words before anything is written.
  defp x_handles(section) do
    with {:ok, typed} <- Keyword.fetch(section, :handles),
         {:ok, handles} <- XAccounts.handles(typed) do
      {:ok, List.keyreplace(section, :handles, 0, {:handles, handles})}
    else
      :error -> {:ok, section}
      {:error, words} -> {:error, {:invalid, "Handles: " <> words}}
    end
  end

  # A new source is added under the name typed or, left empty, the one Fermix
  # makes (`Settings.add_source/3`); an edit replaces its own section.
  defp store_source(%{mode: :create, values: values}, section, secrets),
    do: Settings.add_source(form_value(values, :ref), section, secrets)

  defp store_source(%{mode: :update, ref: ref}, section, secrets),
    do: Settings.save_source(ref, section, secrets, :update)

  # The kind and preset are the choice's on a new source and the section's on
  # an edit, as in the management form; the page draws neither as a field, and
  # a submit that names others anyway is refused before anything is written.
  defp fixed_choice(%{mode: :create, choice: id}, choices, _existing) when is_binary(id) do
    choice = Enum.find(choices, &(&1["id"] == id))
    %{"preset" => choice["preset"], "kind" => choice["kind"]}
  end

  defp fixed_choice(%{mode: :update}, _choices, existing),
    do: %{"preset" => Keyword.get(existing, :preset), "kind" => Keyword.get(existing, :kind)}

  defp same_choice(values, fixed) do
    if choice(values) == choice(fixed),
      do: :ok,
      else: {:error, {:invalid, "A source's kind cannot change. Remove it and add a new one."}}
  end

  # The preset and kind as written, and the kind they make.
  defp choice(values) do
    {blank(text(Map.get(values, "preset"))), blank(text(Map.get(values, "kind"))),
     source_kind(values)}
  end

  # Every name is the one the save answered, which Fermix made when none was
  # typed. A new local push source's first token is shown once. A new webhook
  # source's URL is made with its save and shown at once, as Generate URL shows
  # it, beside the secret Fermix made for a GitHub source; the source is saved
  # either way, and a URL that could not be made carries its refusal where the
  # URL would be, for the page to say in its own words, and the secret still.
  defp saved_source(%{ref: ref, token: token}, _kind, :create, _opts) when is_binary(token),
    do: {:saved, "Source #{ref} saved.", reveal: %{kind: :token, ref: ref, value: token}}

  defp saved_source(%{ref: ref, secret: secret}, "webhook", :create, opts) do
    case Webhook.ensure_path_secret(ref, webhook_opts(opts)) do
      {:ok, path} ->
        url_saved(ref, path, secret)

      {:error, reason} ->
        {:saved, "Source #{ref} saved, but its URL could not be made.",
         reveal: %{kind: :url_failed, ref: ref, reason: url_refusal(reason), secret: secret},
         tone: :error}
    end
  end

  defp saved_source(%{ref: ref}, _kind, _mode, _opts), do: {:saved, "Source #{ref} saved.", []}

  defp url_saved(ref, path, nil),
    do:
      {:saved, "Source #{ref} saved. Its URL is below. #{@url_note}",
       reveal: %{kind: :url, ref: ref, value: path}}

  defp url_saved(ref, path, secret),
    do:
      {:saved, "Source #{ref} saved. Its secret and URL are below, shown once.",
       reveal: %{kind: :github, ref: ref, value: path, secret: secret}}

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
          preset: String.t() | nil,
          verify: String.t() | nil,
          fields: [atom()],
          required: [atom()]
        }
  def source_form(values) when is_map(values) do
    kind = source_kind(values)
    preset = blank(text(Map.get(values, "preset")))
    verify = webhook_method(values, kind)

    %{
      kind: kind,
      preset: preset,
      verify: verify,
      fields: shown_fields(kind, preset, verify),
      required: required_fields(kind, preset, verify)
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

  defp shown_fields(kind, preset, verify) do
    base = [:preset, :kind, :enabled, :daily_budget]
    base ++ kind_fields(kind, preset, verify)
  end

  # A stream shows the general WebSocket source's fields; X accounts shows its
  # handles where a feed shows its URL.
  defp kind_fields("feed", "x_accounts", _verify), do: [:handles, :interval]
  defp kind_fields("feed", _preset, _verify), do: [:url, :interval]
  defp kind_fields("stream", nil, _verify), do: [:url | @general_stream_fields]

  defp kind_fields("webhook", _preset, verify),
    do: [:verify | method_fields(verify)] ++ [:type_header]

  defp kind_fields(_local_push, _preset, _verify), do: []

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

    known = (@form_fields -- @path_fields) ++ Enum.filter(@path_fields, &(&1 in fields))
    kept = Keyword.drop(existing, known ++ SecretWriter.cue_secret_fields())
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

  # A webhook's one secret, or the key and secret a stream with no preset signs
  # in with; a field left blank keeps what is stored.
  defp typed_secrets(typed, %{kind: "webhook"}), do: typed_values(typed, [:secret])

  defp typed_secrets(typed, %{kind: "stream", preset: nil}),
    do: typed_values(typed, [:key, :secret])

  defp typed_secrets(_typed, _form), do: %{}

  defp typed_values(typed, fields) do
    for field <- fields,
        value = blank(text(Map.get(typed, Atom.to_string(field)))),
        into: %{},
        do: {field, value}
  end

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
