defmodule FermixCore.ComputerHistory.Config do
  @moduledoc """
  Reader + normalizer for the `[fermix_core.computer_history]` config block
  (MILESTONE_32 §9.4). Each key is a distinct consent question, so they are
  allowed under the minimal-knobs rule (consent-class settings, not tuning).

  ```toml
  [fermix_core.computer_history]
  enabled          = false   # the enable/consent act
  apps             = []      # capture allowlist, default-deny (bundle ids)
  sites            = []      # per-site allowlist inside allowlisted browsers (hosts)
  remote_summaries = []      # Tier 2: providers that may receive DERIVED summaries
  summarizer       = "default" # where summarization runs: "default" (the daemon's
                             #   default provider), "local" (on-device), or one
                             #   provider id (Tier 3: RAW events to that provider — S9)
  ```

  `normalize/1` is the parse-boundary validator (the `HarnessConfig.normalize`
  shape): present keys only, each value validated fail-loud, strings coerced to
  the atom forms the accessors return. The unknown-key refusal that keys off
  `config_keys/0` lives in the config store (the harness precedent), wired in
  the consent-surfaces stage. There is no `config.exs` baseline for this block —
  the persisted TOML is the sole source, applied replace-style — so every
  accessor reads `Application.get_env(:fermix_core, :computer_history, [])` and
  falls back to its own default when the key is absent.
  """

  require Logger

  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.RoutingOverrides

  @app :fermix_core
  @section :computer_history

  @config_keys [:enabled, :apps, :sites, :remote_summaries, :summarizer]

  @default_enabled false
  @default_apps []
  @default_sites []
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

  @doc "The current config block from app env."
  @spec current() :: keyword()
  def current, do: Application.get_env(@app, @section, [])

  @spec enabled?(keyword()) :: boolean()
  def enabled?(config \\ current()), do: Keyword.get(config, :enabled, @default_enabled)

  @doc "App-capture allowlist (bundle ids), default-deny (empty = nothing captured)."
  @spec apps(keyword()) :: [String.t()]
  def apps(config \\ current()), do: Keyword.get(config, :apps, @default_apps)

  @doc "Per-site allowlist (hosts) inside allowlisted browsers, default-deny."
  @spec sites(keyword()) :: [String.t()]
  def sites(config \\ current()), do: Keyword.get(config, :sites, @default_sites)

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
  Where summarization runs: `:default_provider` (default — the daemon's primary
  provider, §22.1), `:local` (on-device opt-in), or `{:provider, id}` (Tier 3, a
  specific pinned provider). Fails **closed** on a malformed value — an unexpected
  shape keeps summarization on-device (`:local`, no egress) rather than crashing
  the per-turn Gate snapshot (§9.4).
  """
  @spec summarizer(keyword()) :: summarizer()
  def summarizer(config \\ current()) do
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
  The operator's timezone (`[fermix_core.personalization] timezone`), `"Etc/UTC"`
  when unset **or unusable**. Read-only — this block owns no timezone key. The
  single resolver for the subsystem: the summarizer stamps event times with it
  and recall renders memory windows with it, so an event and the note about it
  never disagree, and neither surface can name a zone it did not actually use.
  """
  @spec timezone() :: String.t()
  def timezone do
    Application.get_env(@app, :personalization, [])
    |> Keyword.get(:timezone)
    |> configured_or_utc()
  end

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

  defp configured_or_utc(tz) when is_binary(tz) and tz != "", do: usable_timezone(tz)
  defp configured_or_utc(_unset), do: "Etc/UTC"

  @doc """
  Normalize a parsed config block: present keys only, values validated
  fail-loud, provider strings coerced to atoms. Raises `ArgumentError` on any
  invalid value so the daemon refuses to boot rather than run a malformed
  consent posture.
  """
  @spec normalize(nil | map() | keyword()) :: keyword()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    Enum.reduce(@config_keys, [], fn key, acc ->
      case lookup(config, key) do
        @absent -> acc
        value -> Keyword.put(acc, key, normalize_value(key, value))
      end
    end)
  end

  # --- per-key validators -------------------------------------------------

  defp normalize_value(:enabled, value) when is_boolean(value), do: value

  defp normalize_value(:enabled, value),
    do:
      raise(
        ArgumentError,
        "invalid computer_history.enabled #{inspect(value)}; expected a boolean"
      )

  defp normalize_value(key, value) when key in [:apps, :sites],
    do: normalize_string_list(key, value)

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
