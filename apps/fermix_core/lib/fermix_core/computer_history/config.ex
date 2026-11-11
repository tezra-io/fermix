defmodule FermixCore.ComputerHistory.Config do
  @moduledoc """
  Reader + normalizer for the `[fermix_core.computer_history]` config block
  (MILESTONE_32 §9.4). Each key is a distinct consent question, so they are
  allowed under the minimal-knobs rule (consent-class settings, not tuning).

  **Split by key (M97 §4).** The table is in both settings files, with
  different keys in each:

  ```toml
  # machine.toml: this computer's own, never carried by a move or a backup
  [fermix_core.computer_history]
  enabled          = false   # the enable/consent act: this computer records
  apps             = []      # capture allowlist, default-deny (bundle ids)
  summarizer       = "local" # only "local", or absent: this computer makes
                             #   its own notes on its own model and sends
                             #   only the note

  # config.toml: the home's, which a move carries to its server
  [fermix_core.computer_history]
  remote_summaries = []      # Tier 2: providers that may receive DERIVED summaries
  summarizer       = "default" # the route the home summarizes on: "default"
                             #   (the daemon's default provider), "local" (the
                             #   home's own on-device model), or one provider id
                             #   (Tier 3: RAW sitting text to that provider — S9)
  ```

  Application environment holds both under one key, the machine file's
  `summarizer` as `machine_summarizer` (`machine_file/1`), so neither ever
  stands for the other, and `machine_keyword/1` and `home_keyword/1` split it
  back for the two files. One writer each: the machine's keys are written
  only on that machine, the home's only on the home.

  **Which summarizer is in force (`summarizer/1`).** A machine that chose
  local makes its own notes, and where that machine is the home, the
  roll-up and every sitting it summarizes stay on it too: no history leaves
  it for a provider. Otherwise the home's route is in force. A computer whose
  home is elsewhere (the `device` role) never reads the home's keys
  (`for_role/2`, applied when the settings are), so its own sittings are
  either made into notes here or sent to the home as text.

  `normalize/1` is the parse-boundary validator (the `HarnessConfig.normalize`
  shape): present keys only, each value validated fail-loud, strings coerced to
  the atom forms the accessors return. The unknown-key refusal that keys off
  `config_keys/0` lives in the config store (the harness precedent), wired in
  the consent-surfaces stage. There is no `config.exs` baseline for this block —
  the persisted TOML is the sole source, applied replace-style — so every
  accessor reads `Application.get_env(:fermix_core, :computer_history, [])` and
  falls back to its own default when the key is absent.

  `sites` is **retired** (v1.1 decision 1: every site visited in an allowlisted
  browser is recorded, so there is no per-site filter to configure). It stays in
  `@retired_keys` so a `config.toml` that still carries it is accepted, named once
  at warning, and dropped — a retired key must never refuse boot, and `to_keyword/1`
  never writes it back.
  """

  require Logger

  alias FermixCore.Clock
  alias FermixCore.Home.Role
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.RoutingOverrides

  @app :fermix_core
  @section :computer_history

  @config_keys [:enabled, :apps, :remote_summaries, :summarizer]
  # What application environment holds: the files' keys, and the machine
  # file's `summarizer` under a name of its own.
  @env_keys @config_keys ++ [:machine_summarizer]
  # This machine's keys, and the home's (§4).
  @machine_keys [:enabled, :apps, :machine_summarizer]
  @home_keys [:summarizer, :remote_summaries]
  # The keys the machine file's own table may hold, as it spells them.
  @machine_file_keys [:enabled, :apps, :summarizer]

  # Keys a persisted config may still carry: accepted at parse, dropped at
  # normalize, never written back.
  @retired_keys [:sites]

  @default_enabled false
  @default_apps []
  @default_remote_summaries []
  # The default summarizer runs on the daemon's configured default provider
  # (§22.1): on-device (`:local`) is DOA for the majority who can't run a local
  # model, so out of the box we summarize with the provider the operator already
  # configured — with the enable-time disclosure that raw activity is sent there.
  @default_summarizer :default_provider

  @absent :__absent__

  @type summarizer :: :local | :default_provider | {:provider, atom()}

  @doc "Canonical allowed keys, used by the config store to reject typos at parse."
  @spec config_keys() :: [atom(), ...]
  def config_keys, do: @config_keys

  @doc """
  Keys this section no longer honors but still accepts from an existing
  `config.toml`. `normalize/1` names each one at warning and drops it.
  """
  @spec retired_keys() :: [atom()]
  def retired_keys, do: @retired_keys

  @doc """
  Every key the parse boundary accepts: the live keys plus the retired ones. The
  one resolver the config store's unknown-key refusal consults, so a retired key
  is never mistaken for a typo (which would refuse boot on a config the operator
  already has).
  """
  @spec accepted_keys() :: [atom(), ...]
  def accepted_keys, do: @config_keys ++ @retired_keys

  @doc """
  Every key the block holds in application environment and in a settings
  snapshot: the files' keys and `machine_summarizer`, with the retired ones.
  The config store's key check for a snapshot.
  """
  @spec env_keys() :: [atom(), ...]
  def env_keys, do: @env_keys ++ @retired_keys

  @doc "The current config block from app env."
  @spec current() :: keyword()
  def current, do: Application.get_env(@app, @section, [])

  @doc """
  `config` as an engine in `role` holds it: a computer whose home is
  elsewhere (`:device`) without the home's keys, which it never acts on;
  every other role as it is.
  """
  @spec for_role(keyword(), Role.role() | nil) :: keyword()
  def for_role(config, :device) when is_list(config), do: Keyword.drop(config, @home_keys)

  def for_role(config, role) when is_list(config) and role in [nil, :primary, :candidate],
    do: config

  @doc """
  The machine file's own `[fermix_core.computer_history]` (`table`, decoded,
  nil when absent): its local summarizer as application environment holds
  it (`[machine_summarizer: :local]`), or `[]`. Raises `ArgumentError`
  naming `machine.toml` for a key that is not this machine's (the home's
  `remote_summaries` included) or a summarizer other than `"local"`. Its
  `enabled` and `apps` are read with the rest of the settings
  (`Setup.MachineFile.join/2`).
  """
  @spec machine_file(nil | map() | keyword()) :: keyword()
  def machine_file(nil), do: []

  def machine_file(table) when is_map(table) or is_list(table) do
    warn_retired_keys(table)
    machine_file_keys!(table)

    case lookup(table, :summarizer) do
      @absent -> []
      value -> [machine_summarizer: machine_summarizer!(value, "machine.toml ")]
    end
  end

  defp machine_file_keys!(table) do
    allowed = Enum.map(@machine_file_keys ++ @retired_keys, &Atom.to_string/1)
    keys = if is_map(table), do: Map.keys(table), else: Keyword.keys(table)

    case keys |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "machine.toml [fermix_core.computer_history] has unknown key(s): " <>
                "#{Enum.join(unknown, ", ")}. It takes this computer's enabled, apps and " <>
                ~s(summarizer = "local"; the home's summarizer and remote_summaries are in ) <>
                "config.toml."
    end
  end

  @doc """
  This machine's keys of a persisted block (`to_keyword/1`'s shape), as the
  machine file spells them: `enabled`, `apps`, and `summarizer = "local"`
  where it makes its own notes.
  """
  @spec machine_keyword(keyword()) :: keyword()
  def machine_keyword(block) when is_list(block) do
    for {key, value} <- block, key in @machine_keys, do: machine_entry(key, value)
  end

  defp machine_entry(:machine_summarizer, value), do: {:summarizer, value}
  defp machine_entry(key, value), do: {key, value}

  @doc "The home's keys of a persisted block, as config.toml spells them."
  @spec home_keyword(keyword()) :: keyword()
  def home_keyword(block) when is_list(block),
    do: for({key, value} <- block, key in @home_keys, do: {key, value})

  @spec enabled?(keyword()) :: boolean()
  def enabled?(config \\ current()), do: Keyword.get(config, :enabled, @default_enabled)

  @doc "App-capture allowlist (bundle ids), default-deny (empty = nothing captured)."
  @spec apps(keyword()) :: [String.t()]
  def apps(config \\ current()), do: Keyword.get(config, :apps, @default_apps)

  @doc "Tier-2 grant: providers that may receive derived summaries, as atoms."
  @spec remote_summaries(keyword()) :: [atom()]
  def remote_summaries(config \\ current()),
    do: Keyword.get(config, :remote_summaries, @default_remote_summaries)

  @doc """
  The Tier-2 grant set as a MapSet, for the Gate's per-hop chain check. Runs on
  the per-turn Gate hot path, so it fails **closed** — a malformed
  (non-list) app-env value yields an empty grant set (no remote egress) rather
  than crashing the turn. `normalize/1` rejects such values loudly at the write
  boundary; this defends the read.
  """
  @spec granted_providers(keyword()) :: MapSet.t(atom())
  def granted_providers(config \\ current()) do
    case remote_summaries(config) do
      list when is_list(list) -> MapSet.new(list)
      _malformed -> MapSet.new()
    end
  end

  @doc """
  Where summarization runs on this engine (the moduledoc's rule): `:local`
  where this machine chose to make its own notes (`machine_summarizer`),
  else the home's route: `:default_provider` (default — the daemon's primary
  provider, §22.1), `:local` (the home's on-device model), or
  `{:provider, id}` (Tier 3, a specific pinned provider). A computer holds
  no route (`for_role/2`), so there it is `:local` or `:default_provider`,
  its sittings sent to the home as text. Fails **closed** on a malformed
  value — an unexpected shape keeps summarization on-device (`:local`, no
  egress) rather than crashing the per-turn Gate snapshot (§9.4).
  """
  @spec summarizer(keyword()) :: summarizer()
  def summarizer(config \\ current()) do
    case Keyword.get(config, :machine_summarizer) do
      nil -> route(config)
      _local_or_malformed -> :local
    end
  end

  @doc """
  The home's route this machine's own local summarizer decides over (M97 §4):
  where `machine.toml` says `summarizer = "local"` and the home's
  `config.toml` names another, that one, as `summarizer/1` would answer it
  without the machine's; nil where nothing is overridden. A computer holds no
  home route (`for_role/2`), so there it is always nil. Deleting the line
  from `machine.toml` hands the choice back to `config.toml`.
  """
  @spec shadowed_route(keyword()) :: summarizer() | nil
  def shadowed_route(config \\ current()) when is_list(config) do
    machine? = Keyword.get(config, :machine_summarizer) != nil

    if machine? and Keyword.has_key?(config, :summarizer) and route(config) != :local,
      do: route(config),
      else: nil
  end

  @doc """
  Say once, where it is true, that this machine's local summarizer decides
  over the home's route in `config.toml` (`shadowed_route/1`). Called as the
  history rail starts, so a route edited in `config.toml` that does not take
  is never silent.
  """
  @spec warn_if_shadowed(keyword()) :: :ok
  def warn_if_shadowed(config \\ current()) when is_list(config) do
    case shadowed_route(config) do
      nil ->
        :ok

      route ->
        Logger.warning(
          ~s(computer_history: summarizer = "local" in this machine's machine.toml decides ) <>
            "over config.toml's summarizer (#{route_word(route)}), which is not used while " <>
            "that line is there; delete it from machine.toml to use config.toml's"
        )
    end
  end

  @doc "What a settings row says while `shadowed_route/1` names a route."
  @spec shadowed_footer() :: String.t()
  def shadowed_footer,
    do:
      ~s(This Mac's `machine.toml` says `summarizer = "local"`, so its notes are made here ) <>
        "and the summarizer in `config.toml` is not used while that line is there."

  @doc "A route as `config.toml` spells it: `default`, `local` or a provider's id."
  @spec route_word(summarizer()) :: String.t()
  def route_word(:default_provider), do: "default"
  def route_word(:local), do: "local"
  def route_word({:provider, provider}), do: Atom.to_string(provider)

  defp route(config) do
    case Keyword.get(config, :summarizer, @default_summarizer) do
      :local -> :local
      :default_provider -> :default_provider
      provider when is_atom(provider) -> {:provider, provider}
      _malformed -> :local
    end
  end

  @doc """
  The provider the default (`:default_provider`) summarizer runs on: the operator's
  **subagent** provider if set (`[fermix_core.routing] subagent_provider` — the
  model they already designated for lightweight delegated work, §22.1), else the
  primary provider. `{:error, _}` when neither resolves (fail-closed at the Gate).
  """
  @spec default_summarizer_provider() :: {:ok, atom()} | {:error, term()}
  def default_summarizer_provider do
    case RoutingOverrides.subagent() do
      %{provider: provider} when is_atom(provider) and not is_nil(provider) -> {:ok, provider}
      _no_subagent_provider -> PrimaryConfig.primary()
    end
  end

  @doc """
  The model/effort route options for the default summarizer — the subagent
  override's `model`/`reasoning_effort` if set, else `[]` (the provider's default
  model). Summarizing on the subagent model is deliberate: it is the tier the
  operator picked for cheap, high-volume delegated work.
  """
  @spec default_summarizer_route_opts() :: keyword()
  def default_summarizer_route_opts do
    override = RoutingOverrides.subagent()

    []
    |> put_if(:model, override.model)
    |> put_if(:reasoning_effort, override.reasoning_effort)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  The zone every time Fermix shows is stated in (`FermixCore.Clock.shown_zone/1`):
  the operator's `[fermix_core.personalization] timezone`, or `"Etc/UTC"` when it
  is unset or unknown. Read-only — this block owns no timezone key. The summarizer
  stamps event times with it and recall renders memory windows with it, so an
  event, the note about it and the current-date note all read one clock, and no
  surface can name a zone it did not actually use.
  """
  @spec timezone() :: String.t()
  def timezone, do: Clock.shown_zone()

  @doc """
  The timezone for a caller's `opts`: `:timezone` when given, else the configured
  one. Always a zone the runtime can actually shift into. A present-but-nil or
  non-string `:timezone` behaves as absent — an opts list built with
  `Keyword.put(:timezone, nil)` must not take a surface down.
  """
  @spec timezone(keyword()) :: String.t()
  def timezone(opts) when is_list(opts) do
    case Keyword.get(opts, :timezone) do
      tz when is_binary(tz) and tz != "" -> usable_timezone(tz)
      _absent_or_blank -> timezone()
    end
  end

  @doc """
  `tz` if the runtime can shift into it, else `"Etc/UTC"` with a warning. A
  mistyped zone must not stop a summary or a digest — but the surface has to
  render (and name) the zone it really used.
  """
  @spec usable_timezone(String.t()) :: String.t()
  def usable_timezone(tz) when is_binary(tz) do
    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, _local} ->
        tz

      {:error, reason} ->
        Logger.warning(
          "computer_history: unusable timezone #{inspect(tz)} (#{inspect(reason)}); using Etc/UTC"
        )

        "Etc/UTC"
    end
  end

  @doc """
  Normalize a parsed config block: present keys only, values validated
  fail-loud, provider strings coerced to atoms. Raises `ArgumentError` on any
  invalid value so the daemon refuses to boot rather than run a malformed
  consent posture.
  """
  @spec normalize(nil | map() | keyword()) :: keyword()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    warn_retired_keys(config)

    Enum.reduce(@env_keys, [], fn key, acc ->
      case lookup(config, key) do
        @absent -> acc
        value -> Keyword.put(acc, key, normalize_value(key, value))
      end
    end)
  end

  # One line per retired key actually present, never a refusal: the operator's
  # existing config.toml must keep booting. Because normalize DROPS the key, the
  # second pass over its own output is silent (idempotence, config_test).
  # Expect the line TWICE on the first setup save and never again: the save reads
  # the still-on-disk file (one line) and then re-parses the snapshot it is about
  # to write (a second). The saved file no longer has the key, so every later boot
  # is silent. That is the retirement working, not a double-warn bug.
  defp warn_retired_keys(config) do
    Enum.each(@retired_keys, fn key ->
      case lookup(config, key) do
        @absent -> :ok
        _present -> Logger.warning(retired_message(key))
      end
    end)
  end

  defp retired_message(:sites) do
    "computer_history.sites is retired: every site in an allowlisted browser is " <>
      "recorded; remove the key from the file that holds it"
  end

  # --- per-key validators -------------------------------------------------

  defp normalize_value(:enabled, value) when is_boolean(value), do: value

  defp normalize_value(:enabled, value),
    do:
      raise(
        ArgumentError,
        "invalid computer_history.enabled #{inspect(value)}; expected a boolean"
      )

  defp normalize_value(:apps, value), do: normalize_string_list(:apps, value)

  defp normalize_value(:remote_summaries, value) when is_list(value) do
    value
    |> Enum.map(&provider_entry_string(:remote_summaries, &1))
    |> Enum.map(&validate_remote_provider/1)
  end

  defp normalize_value(:remote_summaries, value),
    do:
      raise(
        ArgumentError,
        "invalid computer_history.remote_summaries #{inspect(value)}; expected a list of providers"
      )

  defp normalize_value(:summarizer, "local"), do: :local
  defp normalize_value(:summarizer, :local), do: :local
  defp normalize_value(:summarizer, "default"), do: :default_provider
  defp normalize_value(:summarizer, :default_provider), do: :default_provider

  defp normalize_value(:summarizer, value) when is_binary(value),
    do: validate_summarizer_provider(value)

  # Idempotence over normalize's own output (a provider atom): apply/2 re-normalizes
  # whichever shape reaches it — parsed atoms or persisted strings — so the app env
  # holds exactly one shape on every path.
  defp normalize_value(:summarizer, value)
       when is_atom(value) and value not in [nil, true, false],
       do: validate_summarizer_provider(Atom.to_string(value))

  defp normalize_value(:summarizer, value),
    do: raise(ArgumentError, summarizer_error(value))

  defp normalize_value(:machine_summarizer, value), do: machine_summarizer!(value, "")

  # The machine file's summarizer says one thing: this computer makes its own
  # notes. Any other value is the home's route, which lives in config.toml.
  defp machine_summarizer!(value, _file) when value in ["local", :local], do: :local

  defp machine_summarizer!(value, file) do
    raise ArgumentError,
          "invalid #{file}computer_history.summarizer #{inspect(value)}: this computer's " <>
            ~s(summarizer takes only "local"; the route the home summarizes on is ) <>
            "config.toml's summarizer"
  end

  # The summarizer's refusal names its FULL vocabulary — "default"/"local" ahead
  # of the provider ids — because this message is the repair instruction a user
  # with a typo'd config acts on; validate_provider/1's provider-only list
  # (correct for remote_summaries) omits the two most likely fixes here.
  defp validate_summarizer_provider(provider_string) do
    provider = safe_atom(provider_string)

    if provider in Descriptor.ids() do
      provider
    else
      raise ArgumentError, summarizer_error(provider_string)
    end
  end

  defp summarizer_error(value) do
    ~s(invalid computer_history.summarizer #{inspect(value)}; expected "default", "local", ) <>
      "or one of #{Enum.map_join(Descriptor.ids(), ", ", &Atom.to_string/1)}"
  end

  # remote_summaries entries arrive as strings (TOML) or already-validated atoms
  # (re-normalizing the app env); both funnel through validate_remote_provider.
  defp provider_entry_string(_key, entry) when is_binary(entry) and entry != "", do: entry

  defp provider_entry_string(_key, entry) when is_atom(entry) and entry not in [nil, true, false],
    do: Atom.to_string(entry)

  defp provider_entry_string(key, entry),
    do:
      raise(
        ArgumentError,
        "invalid computer_history.#{key} entry #{inspect(entry)}; expected a provider"
      )

  @doc """
  The inverse of `normalize/1` for the persist path: normalized app-env values
  back to their TOML spellings (`:default_provider` → `"default"`, provider
  atoms → strings). `ConfigStore.persistable_snapshot/1` uses it so the section
  survives save→load→apply — the raw atom spelling `"default_provider"` on disk
  is exactly the parse-refusal that crashed the daemon (2026-08-19). Present
  keys only, mirroring `normalize/1`.
  """
  @spec to_keyword(keyword()) :: keyword()
  def to_keyword(config) when is_list(config) do
    Enum.map(config, fn {key, value} -> {key, persist_value(key, value)} end)
  end

  defp persist_value(:summarizer, :default_provider), do: "default"
  defp persist_value(:summarizer, :local), do: "local"
  defp persist_value(:machine_summarizer, :local), do: "local"
  defp persist_value(:summarizer, provider) when is_atom(provider), do: Atom.to_string(provider)
  defp persist_value(:remote_summaries, providers), do: Enum.map(providers, &Atom.to_string/1)
  defp persist_value(_key, value), do: value

  defp normalize_string_list(key, value) when is_list(value) do
    Enum.map(value, fn
      item when is_binary(item) and item != "" ->
        item

      item ->
        raise ArgumentError,
              "invalid computer_history.#{key} entry #{inspect(item)}; expected a non-empty string"
    end)
  end

  defp normalize_string_list(key, value),
    do:
      raise(
        ArgumentError,
        "invalid computer_history.#{key} #{inspect(value)}; expected a list of strings"
      )

  # A Tier-2 or Tier-3 provider must be a known provider id. A Tier-2 grant
  # additionally must be a *remote* provider — granting summaries to a local
  # provider is a no-op that hides a config mistake, so reject it loudly.
  defp validate_remote_provider(provider_string) do
    provider = validate_provider(provider_string)

    if Descriptor.locality(provider) == :remote do
      provider
    else
      raise ArgumentError,
            "invalid computer_history.remote_summaries entry #{inspect(provider_string)}; " <>
              "expected a remote provider (a local provider needs no summaries grant)"
    end
  end

  defp validate_provider(provider_string) when is_binary(provider_string) do
    provider = safe_atom(provider_string)

    if provider in Descriptor.ids() do
      provider
    else
      raise ArgumentError,
            "unknown provider #{inspect(provider_string)} in computer_history config; " <>
              "expected one of #{Enum.map_join(Descriptor.ids(), ", ", &Atom.to_string/1)}"
    end
  end

  # Only ever called on strings we are about to check against a fixed id set;
  # an unknown string raises above rather than minting a stray atom that lingers.
  defp safe_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :__unknown_provider__
  end

  # TOML parsing yields string keys; a keyword/atom-keyed map is also accepted.
  defp lookup(config, key) do
    string_key = Atom.to_string(key)

    cond do
      is_map(config) and Map.has_key?(config, string_key) -> Map.fetch!(config, string_key)
      is_map(config) and Map.has_key?(config, key) -> Map.fetch!(config, key)
      is_list(config) and Keyword.has_key?(config, key) -> Keyword.fetch!(config, key)
      true -> @absent
    end
  end
end
