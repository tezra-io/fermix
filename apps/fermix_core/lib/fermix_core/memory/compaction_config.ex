defmodule FermixCore.Memory.CompactionConfig do
  @moduledoc """
  Typed accessors and validation for conversation compaction settings.
  """

  @type t :: keyword()

  @default_enabled true
  @default_threshold 0.85

  @spec normalize(nil | map() | keyword()) :: t()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    []
    |> put_if_present(:threshold, normalize_threshold(lookup(config, "threshold", :threshold)))
    |> put_if_present(:enabled, normalize_enabled(lookup(config, "enabled", :enabled)))
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(config \\ Application.get_env(:fermix_core, :compaction, [])) do
    Keyword.get(config, :enabled, @default_enabled)
  end

  @spec threshold(t()) :: float()
  def threshold(config \\ Application.get_env(:fermix_core, :compaction, [])) do
    Keyword.get(config, :threshold, @default_threshold)
  end

  defp normalize_enabled(nil), do: nil
  defp normalize_enabled(value) when is_boolean(value), do: value

  defp normalize_enabled(value) do
    raise ArgumentError,
          "invalid compaction.enabled #{inspect(value)}; expected boolean true or false"
  end

  defp normalize_threshold(nil), do: nil

  defp normalize_threshold(value) when is_float(value) and value >= 0.1 and value <= 1.0 do
    value
  end

  defp normalize_threshold(value) do
    raise ArgumentError,
          "invalid compaction.threshold #{inspect(value)}; expected float between 0.1 and 1.0"
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
