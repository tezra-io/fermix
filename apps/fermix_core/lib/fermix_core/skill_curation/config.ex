defmodule FermixCore.SkillCuration.Config do
  @moduledoc """
  `[fermix_core.skill_curation]` config (MILESTONE_26_SKILL_CURATION §6.1).

  One key: `enabled` (default true). Cadence, window, budgets, caps, and TTLs
  are internal constants on the curation modules — tuning is not config. There
  is no compile-time baseline: the persisted TOML section is the complete
  intended state and the config store applies it replace-style, so `normalize/1`
  emits only keys that are actually present.
  """

  @default_enabled true

  @config_keys [:enabled]

  @doc """
  Canonical list of allowed `[fermix_core.skill_curation]` keys, used by the
  config store to reject typo'd keys at the parse boundary.
  """
  @spec config_keys() :: [atom()]
  def config_keys, do: @config_keys

  @type t :: keyword()

  @spec normalize(nil | map() | keyword()) :: t()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    Enum.reduce(@config_keys, [], fn key, acc ->
      put_if_present(acc, key, normalize_value(key, lookup(config, Atom.to_string(key), key)))
    end)
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(config \\ Application.get_env(:fermix_core, :skill_curation, [])) do
    Keyword.get(config, :enabled, @default_enabled)
  end

  defp normalize_value(_key, nil), do: nil
  defp normalize_value(:enabled, value), do: normalize_enabled(value)

  defp normalize_enabled(value) when is_boolean(value), do: value

  defp normalize_enabled(value) do
    raise ArgumentError,
          "invalid skill_curation.enabled #{inspect(value)}; expected boolean true or false"
  end

  defp lookup(config, string_key, atom_key) when is_map(config) do
    Map.get(config, string_key, Map.get(config, atom_key))
  end

  defp lookup(config, _string_key, atom_key) when is_list(config) do
    Keyword.get(config, atom_key)
  end

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)
end
