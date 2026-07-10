defmodule FermixCore.Providers.ReasoningEffort do
  @moduledoc """
  Fermix-canonical reasoning effort levels and per-provider mapping.

  One vocabulary of effort levels; each provider's API supports a subset.
  The level name *is* the provider's wire value. Transforms, treating the
  levels as an ordered scale: `:none` -> omit the field (providers that
  support it); a level *above* a provider's ceiling clamps to that ceiling
  (so `:max` on xAI -> `"high"`, its highest); a level *below* a
  provider's floor (e.g. `:none` on Anthropic) is rejected as unsupported.

  This module stays provider-level. Per-*model* effort ceilings (e.g. `max`
  is a gpt-5.6-family capability, so the older OpenAI models top out at
  `xhigh`) live in `ModelCatalog` as an `Entry` field and are applied via
  `cap/2` before the wire — see `ModelCatalog.clamp_effort/3`. Anthropic's
  per-model nuance (`xhigh` is Opus-only) is still left to the provider
  API's 400, matching the prior OpenAI design.

  Replaces the OpenAI-owned list in `OpenAI.ResponsesShared`: the canonical
  set lives here (provider-neutral) and each provider maps through
  `to_provider/2`, so we keep one vocabulary rather than a copy per provider.
  """

  @type level :: :none | :low | :medium | :high | :xhigh | :max
  @type provider :: :openai | :openai_codex | :anthropic | :xai
  @type mapping :: :omit | {:ok, String.t()} | {:error, {:unsupported, atom(), atom()}}

  @levels [:none, :low, :medium, :high, :xhigh, :max]

  # Per-provider API vocabularies (not per-model). The wizard (normal +
  # reconfigure) and web UI offer effort selection for OpenAI/Codex/xAI and gate
  # it out for `anthropic` until its adapter sends `output_config.effort` — the
  # `anthropic` subset below is encoded for that upcoming adapter slice and is
  # consumed by `to_provider/2`, but no setup surface offers it yet. `xai` is
  # consumed by `XAI.Responses` (per-model rejection stays in that adapter —
  # §6.2 of the provider design).
  @provider_levels %{
    openai: [:none, :low, :medium, :high, :xhigh, :max],
    openai_codex: [:none, :low, :medium, :high, :xhigh, :max],
    anthropic: [:low, :medium, :high, :xhigh, :max],
    xai: [:none, :low, :medium, :high]
  }

  @spec levels() :: [level()]
  def levels, do: @levels

  @spec valid?(term()) :: boolean()
  def valid?(level) when is_atom(level), do: level in @levels
  def valid?(_level), do: false

  @doc """
  Casts an atom or case-insensitive string to a canonical level. Returns
  `:error` for removed (`minimal`), CLI-only (`auto`), or unknown values.
  """
  @spec parse(term()) :: {:ok, level()} | :error
  def parse(level) when level in @levels, do: {:ok, level}

  def parse(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Enum.find_value(@levels, :error, fn level ->
      if Atom.to_string(level) == normalized, do: {:ok, level}
    end)
  end

  def parse(_value), do: :error

  @spec levels_for(atom()) :: [level()]
  def levels_for(provider) when is_atom(provider), do: Map.get(@provider_levels, provider, [])

  @doc """
  Provider levels narrowed to those at or below `ceiling` (a per-model effort
  cap from `ModelCatalog`). A `nil` ceiling returns the full provider list.
  """
  @spec levels_for(atom(), level() | nil) :: [level()]
  def levels_for(provider, nil) when is_atom(provider), do: levels_for(provider)

  def levels_for(provider, ceiling) when is_atom(provider) and ceiling in @levels do
    provider |> levels_for() |> Enum.filter(&(rank(&1) <= rank(ceiling)))
  end

  @doc """
  Caps `level` DOWN to `ceiling` on the ordered scale: returns `ceiling` when
  `level` ranks above it, otherwise `level` unchanged. Never raises a level and
  never rejects — a `nil` ceiling means "no cap". Used to narrow a
  provider-legal effort to a specific model's ceiling (`ModelCatalog`).
  """
  @spec cap(level(), level() | nil) :: level()
  def cap(level, nil) when level in @levels, do: level

  def cap(level, ceiling) when level in @levels and ceiling in @levels do
    if rank(level) > rank(ceiling), do: ceiling, else: level
  end

  @spec supported?(atom(), atom()) :: boolean()
  def supported?(level, provider) when is_atom(level) and is_atom(provider) do
    level in levels_for(provider)
  end

  @doc """
  Clamps a canonical level into a provider's supported range: above the ceiling
  clamps down to the ceiling, below the floor clamps up to the floor, a
  supported level passes through unchanged. A range fit (never an error), used
  to overlay one routing-level effort onto each route of a possibly
  multi-provider chain without rejecting it. A provider with no known levels
  returns the level unchanged.
  """
  @spec clamp(level(), provider()) :: level()
  def clamp(level, provider) when level in @levels and is_atom(provider) do
    case levels_for(provider) do
      [] -> level
      supported -> clamp_into(level, supported)
    end
  end

  defp clamp_into(level, supported) do
    cond do
      level in supported -> level
      rank(level) < rank(List.first(supported)) -> List.first(supported)
      true -> List.last(supported)
    end
  end

  @doc """
  Maps a canonical level to a provider's wire value.

    * `:omit` — send no reasoning/effort field (`:none` on a provider that supports it).
    * `{:ok, "xhigh"}` — send this effort string. A level above the provider's
      ceiling clamps to the ceiling (e.g. `:max` on xAI -> `"high"`).
    * `{:error, {:unsupported, level, provider}}` — the level is below the
      provider's floor (e.g. `:none` on Anthropic) or is not a canonical level.
  """
  @spec to_provider(atom(), atom()) :: mapping()
  def to_provider(level, provider) when is_atom(level) and is_atom(provider) do
    supported = levels_for(provider)

    cond do
      not valid?(level) -> unsupported(level, provider)
      supported == [] -> unsupported(level, provider)
      level == :none and :none in supported -> :omit
      level in supported -> {:ok, Atom.to_string(level)}
      above_ceiling?(level, supported) -> {:ok, Atom.to_string(List.last(supported))}
      true -> unsupported(level, provider)
    end
  end

  defp above_ceiling?(level, supported), do: rank(level) > rank(List.last(supported))

  defp rank(level), do: Enum.find_index(@levels, &(&1 == level))

  defp unsupported(level, provider), do: {:error, {:unsupported, level, provider}}
end
