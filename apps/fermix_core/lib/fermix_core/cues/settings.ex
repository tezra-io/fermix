defmodule FermixCore.Cues.Settings do
  @moduledoc """
  The owner's changes to the cue settings (M60 §6.2, §8.2, §10.1, §15), made
  from the setup page and from the management socket (`cues.*`, M60 app
  surface §3.1): the switches and the door's port, the default filter model,
  sources with their secrets, and mandates. Both doors call these functions,
  so every refusal and side effect is the same from either. At most
  `Cues.Config.max_sources/0` sources and `max_mandates/0` mandates are added.

  Every change is one save through the wizard's shared write tail
  (`Setup.Wizard.commit_snapshot/2`), as `Meetings.Config.save/1` makes its
  own: that tail refuses a save over an outside edit, records the new
  baseline, and applies the snapshot, and the config store's apply matches the
  source workers to the new sources (`Cues.SourceManager.reconcile/0`). The
  changed section is checked with `Cues.Config.normalize/1` before anything is
  written, and its sentence comes back as `{:error, {:invalid, sentence}}`.

  A secret is written through `SecretWriter` under `cue_source:<ref>:<field>`
  before the config that names it, so a refused save leaves the old config
  whole; a secret this call created is taken back out when its config is not
  saved. The config holds only the sentinel. No secret value is ever returned,
  except a local-push token this call made, which the caller shows once.

  Sections arrive in the persisted shape (enumerations as strings, durations
  as written), the shape `ConfigStore.current_snapshot/0` holds.
  """

  require Logger

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Presets
  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.Wizard

  @switch_keys [:enabled, :mandates_enabled, :door_port]
  # Fields the owner types. A local-push token and a webhook URL's random part
  # are made by Fermix (`new_token/1`, `Cues.Webhook.ensure_path_secret/2`).
  @typed_secret_fields [:key, :secret]
  @token_bytes 32

  @type refusal :: {:invalid, String.t()}
  @type secret_failure :: {:secret_store_failed, String.t(), String.t()}

  @doc """
  Saves `[fermix_core.cues] enabled`, `mandates_enabled` and `door_port`. A
  switch left at its default is not written when the section does not name it.
  `restart?` is true when cues were turned on or off or the door moved: the
  cue tree starts only at boot.
  """
  @spec save_switches(keyword()) :: {:ok, %{restart?: boolean()}} | {:error, refusal() | term()}
  def save_switches(changes) when is_list(changes) do
    unknown = Keyword.keys(changes) -- @switch_keys

    if unknown != [] do
      raise ArgumentError, "unknown cue switch(es): #{inspect(unknown)}"
    end

    with {:ok, plan} <- plan(fn cues -> {:ok, put_switches(cues, changes), nil} end),
         {:ok, _report} <- commit(plan) do
      {:ok, %{restart?: restart?(plan.old, plan.new)}}
    end
  end

  @doc """
  Saves the default filter model (`[fermix_core.routing] filter_provider` and
  `filter_model`, design §8.2): both, or neither to clear them. Read at every
  filter call, so it applies at once.
  """
  @spec save_filter_model(String.t() | nil, String.t() | nil) ::
          {:ok, %{cleared?: boolean()}} | {:error, refusal() | term()}
  def save_filter_model(provider, model)
      when (is_binary(provider) or is_nil(provider)) and (is_binary(model) or is_nil(model)) do
    provider = blank_to_nil(provider)
    model = blank_to_nil(model)
    snapshot = ConfigStore.current_snapshot()

    routing =
      snapshot.fermix_core
      |> Keyword.get(:routing, [])
      |> put_or_delete(:filter_provider, provider)
      |> put_or_delete(:filter_model, model)

    with :ok <- both_or_neither(provider, model),
         :ok <- validate_routing(routing),
         {:ok, _report} <- Wizard.commit_snapshot(put_core(snapshot, :routing, routing)) do
      {:ok, %{cleared?: is_nil(provider)}}
    end
  end

  @doc """
  Adds (`:create`) or replaces (`:update`) source `ref`'s section. `section`
  holds no secret field; `secrets` holds the values the owner typed (`:key`,
  `:secret`), and a field it leaves out keeps its stored value. A new
  local-push source gets a token, returned once as `token`; an update never
  makes one, so a hand-edited local push source with none keeps waiting for
  `new_token/1`, the one call that shows it.
  """
  @spec save_source(String.t(), keyword(), %{optional(atom()) => String.t()}, :create | :update) ::
          {:ok, %{token: String.t() | nil}} | {:error, refusal() | secret_failure() | term()}
  def save_source(ref, section, secrets, mode)
      when is_binary(ref) and is_list(section) and is_map(secrets) and mode in [:create, :update] do
    check_typed_secrets!(section, secrets)
    store_source(ref, section, secrets, mode, mode == :create)
  end

  # `mint?` makes a local push source's first token where it has none: a new
  # source, or `new_token/1` on one that waits for it.
  defp store_source(ref, section, secrets, mode, mint?) do
    with :ok <- check_name(ref, "source"),
         {:ok, plan} <- plan(&put_source(&1, ref, section, secrets, mode, mint?)),
         {:ok, created} <- write_secrets(ref, plan.extra.writes),
         {:ok, _report} <- commit_or_take_back(plan, ref, created) do
      {:ok, %{token: plan.extra.token}}
    end
  end

  @doc """
  Removes source `ref`'s section, then deletes its secrets from the stores
  their sentinels name. `left` lists, as sentences, any secret that could not
  be deleted (the source is gone either way).
  """
  @spec remove_source(String.t()) :: {:ok, %{left: [String.t()]}} | {:error, refusal() | term()}
  def remove_source(ref) when is_binary(ref) do
    with {:ok, plan} <- plan(&drop_section(&1, :sources, ref, "source")),
         {:ok, _report} <- commit(plan) do
      {:ok, %{left: delete_secrets(ref, plan.extra)}}
    end
  end

  @doc """
  Stores the value the owner typed for source `ref`'s `field` (`:key` or
  `:secret`, one its kind declares) and points the section at it, in one save
  through `save_source/4`. Storing the last secret a source waited for starts
  it: the save's apply runs `Cues.SourceManager.reconcile/0`, and the door
  reads the section at every request.
  """
  @spec set_secret(String.t(), :key | :secret, String.t()) ::
          {:ok, map()} | {:error, refusal() | secret_failure() | term()}
  def set_secret(ref, field, value)
      when is_binary(ref) and field in @typed_secret_fields and is_binary(value) do
    with {:ok, section} <- section(:sources, ref),
         :ok <- declared(ref, field) do
      kept = Keyword.drop(section, SecretWriter.cue_secret_fields())

      case save_source(ref, kept, %{field => value}, :update) do
        {:ok, _token} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Forgets source `ref`'s typed `field`: the settings file's write guard and
  the plan first, then the stored item, then the sentinel that names it, so
  neither an outside edit nor a refused delete leaves a sentinel naming
  nothing or an item no section names. A source whose kind needs that secret then waits for it again.
  Forgetting a field nothing stores succeeds: the postcondition holds.
  """
  @spec clear_secret(String.t(), :key | :secret) ::
          {:ok, map()} | {:error, refusal() | secret_failure() | term()}
  def clear_secret(ref, field) when is_binary(ref) and field in @typed_secret_fields do
    with {:ok, section} <- section(:sources, ref),
         :ok <- declared(ref, field) do
      forget_secret(ref, field, section)
    end
  end

  @doc """
  Turns source (`:sources`) or mandate (`:mandates`) `name` on or off. On is
  the default, so turning one on writes the key only where the section
  already has it. A mandate's switch stops its calls without being a new
  grant, so it leaves its approval as it was (`Cues.Pins`).
  """
  @spec set_enabled(:sources | :mandates, String.t(), boolean()) ::
          {:ok, map()} | {:error, refusal() | term()}
  def set_enabled(table, name, enabled?)
      when table in [:sources, :mandates] and is_binary(name) and is_boolean(enabled?) do
    with {:ok, plan} <- plan(&put_enabled(&1, table, name, enabled?)),
         {:ok, _report} <- commit(plan) do
      {:ok, %{}}
    end
  end

  @doc """
  Source (`:sources`) or mandate (`:mandates`) `name`'s section as the
  settings file holds it now (the persisted shape), or the sentence for a
  name no section has.
  """
  @spec section(:sources | :mandates, String.t()) :: {:ok, keyword()} | {:error, refusal()}
  def section(table, name) when table in [:sources, :mandates] and is_binary(name) do
    ConfigStore.current_snapshot().fermix_core
    |> Keyword.get(:cues, [])
    |> Keyword.get(table, %{})
    |> fetch_for(name, :update, what(table))
  end

  @doc """
  Writes a fresh token for local-push source `ref` in the store its sentinel
  names and returns it, for the caller to show once. The door reads a changed
  token within a minute (`Cues.Buckets` caches its fingerprint).
  """
  @spec new_token(String.t()) :: {:ok, String.t()} | {:error, refusal() | secret_failure()}
  def new_token(ref) when is_binary(ref) do
    with {:ok, store} <- token_store(ref) do
      replace_token(ref, store)
    end
  end

  # A source waiting for its first token (a hand-edited section with none) gets
  # it the way a new one does: the save mints it and writes its sentinel.
  defp replace_token(ref, :none) do
    with {:ok, section} <- section(:sources, ref) do
      kept = Keyword.drop(section, SecretWriter.cue_secret_fields())

      case store_source(ref, kept, %{}, :update, true) do
        {:ok, %{token: token}} when is_binary(token) -> {:ok, token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp replace_token(ref, store) do
    token = generate_token()

    with :ok <- put_secret(ref, :token, token, store), do: {:ok, token}
  end

  @doc "Adds (`:create`) or replaces (`:update`) mandate `name`'s section."
  @spec save_mandate(String.t(), keyword(), :create | :update) ::
          {:ok, map()} | {:error, refusal() | term()}
  def save_mandate(name, section, mode)
      when is_binary(name) and is_list(section) and mode in [:create, :update] do
    with :ok <- check_name(name, "mandate"),
         {:ok, plan} <- plan(&put_mandate(&1, name, section, mode)),
         {:ok, _report} <- commit(plan) do
      {:ok, %{}}
    end
  end

  @doc "Removes mandate `name`'s section."
  @spec remove_mandate(String.t()) :: {:ok, map()} | {:error, refusal() | term()}
  def remove_mandate(name) when is_binary(name) do
    with {:ok, plan} <- plan(&drop_section(&1, :mandates, name, "mandate")),
         {:ok, _report} <- commit(plan) do
      {:ok, %{}}
    end
  end

  @doc """
  The owner's approval of mandate `name` from the setup page (design §10.4):
  `Cues.Pins.approve/4` records the digest of what the mandate trusts as it is
  now and turns it back on. `opts` are the `Cues.Pins` options.
  """
  @spec approve_mandate(String.t(), DateTime.t(), keyword()) ::
          {:ok, Pins.status()} | {:error, refusal()}
  def approve_mandate(name, %DateTime{} = now, opts) when is_binary(name) and is_list(opts),
    do: approve_mandate(name, "setup page", now, opts)

  @doc """
  The owner's approval of mandate `name` from the surface `approved_from`
  names (the setup page, or "Fermix app" for the management socket).
  """
  @spec approve_mandate(String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, Pins.status()} | {:error, refusal()}
  def approve_mandate(name, approved_from, %DateTime{} = now, opts)
      when is_binary(name) and is_binary(approved_from) and is_list(opts) do
    case Pins.approve(name, approved_from, now, opts) do
      {:ok, status} -> {:ok, status}
      {:error, sentence} -> {:error, {:invalid, sentence}}
    end
  end

  # --- the save --------------------------------------------------------------

  # The live snapshot with the changed `[fermix_core.cues]`, checked before
  # anything is written. `change` returns the new section and what the caller
  # needs after the save.
  defp plan(change) do
    snapshot = ConfigStore.current_snapshot()
    old = Keyword.get(snapshot.fermix_core, :cues, [])

    with {:ok, new, extra} <- change.(old),
         :ok <- validate(new) do
      {:ok, %{snapshot: put_core(snapshot, :cues, new), old: old, new: new, extra: extra}}
    end
  end

  defp commit(plan), do: Wizard.commit_snapshot(plan.snapshot)

  defp commit_or_take_back(plan, ref, created) do
    case commit(plan) do
      {:ok, report} ->
        {:ok, report}

      {:error, reason} ->
        take_back(ref, created)
        {:error, reason}
    end
  end

  # The normalizer is the one place a cue section's values are checked; it
  # raises with the key named, which is the sentence the owner sees.
  defp validate(cues) do
    _normalized = CuesConfig.normalize(cues)
    :ok
  rescue
    error in ArgumentError -> {:error, {:invalid, Exception.message(error)}}
  end

  defp validate_routing(routing) do
    _filter = RoutingOverrides.parse(routing, :filter)
    :ok
  rescue
    error in ArgumentError -> {:error, {:invalid, Exception.message(error)}}
  end

  defp put_core(snapshot, key, value),
    do: %{snapshot | fermix_core: Keyword.put(snapshot.fermix_core, key, value)}

  # --- switches --------------------------------------------------------------

  defp put_switches(cues, changes) do
    Enum.reduce(changes, cues, fn {key, value}, acc ->
      if Keyword.has_key?(acc, key) or value != switch_default(key),
        do: put_key(acc, key, value),
        else: acc
    end)
  end

  defp switch_default(:enabled), do: CuesConfig.enabled?([])
  defp switch_default(:mandates_enabled), do: CuesConfig.mandates_enabled?([])
  defp switch_default(:door_port), do: CuesConfig.door_port([])

  defp restart?(old, new) do
    CuesConfig.enabled?(old) != CuesConfig.enabled?(new) or
      CuesConfig.door_port(old) != CuesConfig.door_port(new)
  end

  # --- sources ---------------------------------------------------------------

  defp put_source(cues, ref, section, secrets, mode, mint?) do
    sources = Keyword.get(cues, :sources, %{})

    with {:ok, existing} <- fetch_for(sources, ref, mode, "source"),
         :ok <- room(sources, mode, CuesConfig.max_sources(), "sources") do
      kept = Keyword.take(existing, SecretWriter.cue_secret_fields())
      typed = Enum.map(secrets, fn {field, value} -> {field, value, store_for(kept, field)} end)
      {token, writes} = maybe_token(section, kept, typed, mint?)
      sentinels = Enum.map(writes, fn {field, _value, store} -> {field, sentinel(store)} end)
      new_section = section ++ Keyword.drop(kept, Keyword.keys(sentinels)) ++ sentinels

      writes =
        Enum.map(writes, fn {field, value, store} ->
          {field, value, store, not Keyword.has_key?(kept, field)}
        end)

      {:ok, put_key(cues, :sources, Map.put(sources, ref, new_section)),
       %{token: token, writes: writes}}
    end
  end

  # A new local-push source gets its first token here, and so does one that
  # waits for it when `new_token/1` asks; one that has a token keeps it
  # (`new_token/1` replaces it), and an update makes none.
  defp maybe_token(section, kept, typed, mint?) do
    if mint? and local_push?(section) and not Keyword.has_key?(kept, :token) do
      token = generate_token()
      {token, [{:token, token, SecretWriter.store()} | typed]}
    else
      {nil, typed}
    end
  end

  defp local_push?(section) do
    case Keyword.fetch(section, :preset) do
      {:ok, preset} -> match?({:ok, %{kind: :local_push}}, Presets.defaults(preset))
      :error -> to_string(Keyword.get(section, :kind)) == "local_push"
    end
  end

  defp store_for(kept, field) do
    with {:ok, sentinel} <- Keyword.fetch(kept, field),
         {:ok, store} <- SecretWriter.store_of_sentinel(sentinel) do
      store
    else
      _none -> SecretWriter.store()
    end
  end

  defp sentinel(store), do: SecretWriter.sentinel_for(store)

  # Returns the fields this call created (no sentinel before), which are the
  # ones taken back if the config is not saved.
  defp write_secrets(ref, writes) do
    Enum.reduce_while(writes, {:ok, []}, fn {field, value, store, new?}, {:ok, created} ->
      case put_secret(ref, field, value, store) do
        :ok ->
          {:cont, {:ok, if(new?, do: [{field, store} | created], else: created)}}

        {:error, reason} ->
          take_back(ref, created)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp take_back(ref, created) do
    Enum.each(created, fn {field, store} ->
      case SecretWriter.delete({:cue_source, ref, field}, store: store) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "cue source #{ref}: the #{field} of an unsaved source stays in the #{store} " <>
              "store (#{inspect(reason)})"
          )
      end
    end)
  end

  defp put_secret(ref, field, value, store) do
    case SecretWriter.put({:cue_source, ref, field}, value, store: store) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("cue source #{ref}: its #{field} was not stored (#{inspect(reason)})")

        {:error,
         {:secret_store_failed, "cue_source:#{ref}:#{field}",
          "The #{field} for #{ref} could not be stored. See the daemon log."}}
    end
  end

  defp delete_secrets(ref, section) do
    section
    |> Keyword.take(SecretWriter.cue_secret_fields())
    |> Enum.flat_map(fn {field, sentinel} ->
      {:ok, store} = SecretWriter.store_of_sentinel(sentinel)

      case SecretWriter.delete({:cue_source, ref, field}, store: store) do
        :ok ->
          []

        {:error, reason} ->
          Logger.error(
            "cue source #{ref}: its #{field} stays in the #{store} store: " <>
              inspect(reason)
          )

          ["Its #{field} could not be deleted from the #{store} store. See the daemon log."]
      end
    end)
  end

  defp token_store(ref) do
    case CuesConfig.source(ref) do
      {:ok, %{kind: :local_push, secrets: %{token: store}}} ->
        {:ok, store}

      {:ok, %{kind: :local_push}} ->
        {:ok, :none}

      {:ok, %{kind: kind}} ->
        {:error,
         {:invalid, "Source #{ref} is a #{kind} source; only a local-push source has a token."}}

      :error ->
        {:error, {:invalid, "There is no source named #{ref}."}}
    end
  end

  defp generate_token,
    do: Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  defp check_typed_secrets!(section, secrets) do
    if Keyword.take(section, SecretWriter.cue_secret_fields()) != [] do
      raise ArgumentError, "a source section carries no secret field; pass secrets apart"
    end

    unknown = Map.keys(secrets) -- @typed_secret_fields

    if unknown != [] or Enum.any?(secrets, fn {_field, value} -> blank_to_nil(value) == nil end) do
      raise ArgumentError, "typed cue secrets are :key and :secret with a value"
    end
  end

  # --- mandates --------------------------------------------------------------

  defp put_mandate(cues, name, section, mode) do
    mandates = Keyword.get(cues, :mandates, %{})

    with {:ok, _existing} <- fetch_for(mandates, name, mode, "mandate"),
         :ok <- room(mandates, mode, CuesConfig.max_mandates(), "mandates") do
      {:ok, put_key(cues, :mandates, Map.put(mandates, name, section)), nil}
    end
  end

  # --- switches and secrets of one section -------------------------------------

  defp put_enabled(cues, table, name, enabled?) do
    sections = Keyword.get(cues, table, %{})

    with {:ok, section} <- fetch_for(sections, name, :update, what(table)) do
      section =
        if Keyword.has_key?(section, :enabled) or not enabled?,
          do: put_key(section, :enabled, enabled?),
          else: section

      {:ok, put_key(cues, table, Map.put(sections, name, section)), nil}
    end
  end

  # The fields a source's kind declares (`Cues.Config.secret_fields/1`); a
  # local push's token and a webhook's address are Fermix's to make.
  defp declared(ref, field) do
    with {:ok, kind} <- saved_kind(ref) do
      if field in CuesConfig.secret_fields(kind),
        do: :ok,
        else: {:error, {:invalid, "A #{kind_name(kind)} source keeps no #{field}."}}
    end
  end

  defp saved_kind(ref) do
    cues =
      CuesConfig.normalize(Keyword.get(ConfigStore.current_snapshot().fermix_core, :cues, []))

    case CuesConfig.source(ref, cues) do
      {:ok, %{kind: kind}} -> {:ok, kind}
      :error -> {:error, {:invalid, "There is no source named #{ref}."}}
    end
  end

  defp kind_name(:local_push), do: "local push"
  defp kind_name(kind), do: Atom.to_string(kind)

  defp forget_secret(ref, field, section) do
    case Keyword.fetch(section, field) do
      :error ->
        {:ok, %{}}

      {:ok, sentinel} ->
        {:ok, store} = SecretWriter.store_of_sentinel(sentinel)

        # The settings file's write guard and the plan come first, so an
        # outside edit refuses before the item goes.
        with :ok <- RestartState.writable(),
             {:ok, plan} <- plan(&put_section(&1, ref, Keyword.delete(section, field))),
             :ok <- delete_secret(ref, field, store),
             {:ok, _report} <- commit(plan) do
          {:ok, %{}}
        end
    end
  end

  defp put_section(cues, ref, section) do
    sources = Keyword.get(cues, :sources, %{})
    {:ok, put_key(cues, :sources, Map.put(sources, ref, section)), nil}
  end

  defp delete_secret(ref, field, store) do
    case SecretWriter.delete({:cue_source, ref, field}, store: store) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("cue source #{ref}: its #{field} was not deleted (#{inspect(reason)})")

        {:error,
         {:secret_store_failed, "cue_source:#{ref}:#{field}",
          "The #{field} for #{ref} could not be deleted from the #{store} store."}}
    end
  end

  # --- shared ----------------------------------------------------------------

  defp room(sections, :create, max, what) do
    if map_size(sections) < max,
      do: :ok,
      else: {:error, {:invalid, "Fermix holds at most #{max} #{what}. Remove one first."}}
  end

  defp room(_sections, :update, _max, _what), do: :ok

  defp what(:sources), do: "source"
  defp what(:mandates), do: "mandate"

  defp fetch_for(sections, name, :create, what) do
    if Map.has_key?(sections, name),
      do: {:error, {:invalid, "There is already a #{what} named #{name}."}},
      else: {:ok, []}
  end

  defp fetch_for(sections, name, :update, what) do
    case Map.fetch(sections, name) do
      {:ok, section} -> {:ok, section}
      :error -> {:error, {:invalid, "There is no #{what} named #{name}."}}
    end
  end

  defp drop_section(cues, table, name, what) do
    sections = Keyword.get(cues, table, %{})

    case Map.pop(sections, name) do
      {nil, _sections} ->
        {:error, {:invalid, "There is no #{what} named #{name}."}}

      {section, rest} when rest == %{} ->
        {:ok, Keyword.delete(cues, table), section}

      {section, rest} ->
        {:ok, put_key(cues, table, rest), section}
    end
  end

  defp check_name(name, what) do
    if CuesConfig.valid_name?(name) do
      :ok
    else
      {:error,
       {:invalid,
        "A #{what}'s name is lowercase letters, digits and hyphens, starts with a letter or " <>
          "digit, and is at most 64 characters."}}
    end
  end

  defp both_or_neither(nil, nil), do: :ok
  defp both_or_neither(provider, model) when is_binary(provider) and is_binary(model), do: :ok

  defp both_or_neither(_provider, _model),
    do: {:error, {:invalid, "Pick a provider and a model, or clear both."}}

  # Replaces a key where it stands, so a save keeps the file's order.
  defp put_key(keyword, key, value) do
    if Keyword.has_key?(keyword, key),
      do: Enum.map(keyword, &replace_entry(&1, key, value)),
      else: keyword ++ [{key, value}]
  end

  defp replace_entry({key, _old}, key, value), do: {key, value}
  defp replace_entry(entry, _key, _value), do: entry

  defp put_or_delete(keyword, key, nil), do: Keyword.delete(keyword, key)
  defp put_or_delete(keyword, key, value), do: put_key(keyword, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
