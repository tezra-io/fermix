defmodule FermixCore.Memory.CompactionConfig do
  @moduledoc """
  Typed accessors and validation for conversation compaction settings.

  `reasoning_effort` governs the effort the *summarization* call uses, separate
  from the agent's own turn effort. Summaries are mechanical, so this defaults to
  `:medium` rather than inheriting a high agent effort (e.g. `:xhigh`) — keeping
  compaction cost off the agent's effort budget.
  """

  alias FermixCore.Providers.ReasoningEffort

  @type t :: keyword()

  @default_enabled true
  @default_threshold 0.85
  @default_reasoning_effort :medium

  @spec normalize(nil | map() | keyword()) :: t()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    []
    |> put_if_present(:threshold, normalize_threshold(lookup(config, "threshold", :threshold)))
    |> put_if_present(:enabled, normalize_enabled(lookup(config, "enabled", :enabled)))
    |> put_if_present(
      :reasoning_effort,
      normalize_reasoning_effort(lookup(config, "reasoning_effort", :reasoning_effort))
    )
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(config \\ Application.get_env(:fermix_core, :compaction, [])) do
    Keyword.get(config, :enabled, @default_enabled)
  end

  @spec threshold(t()) :: float()
  def threshold(config \\ Application.get_env(:fermix_core, :compaction, [])) do
    Keyword.get(config, :threshold, @default_threshold)
  end

  @doc """
  Canonical reasoning-effort level for the summarization call (default
  `:medium`). The per-provider wire mapping (clamp/omit/reject) is the adapter's
  job via `FermixCore.Providers.ReasoningEffort`; this only resolves the level.
  """
  @spec reasoning_effort(t()) :: ReasoningEffort.level()
  def reasoning_effort(config \\ Application.get_env(:fermix_core, :compaction, [])) do
    Keyword.get(config, :reasoning_effort, @default_reasoning_effort)
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

  defp normalize_reasoning_effort(nil), do: nil

  defp normalize_reasoning_effort(value) do
    case ReasoningEffort.parse(value) do
      {:ok, level} ->
        level

      :error ->
        raise ArgumentError,
              "invalid compaction.reasoning_effort #{inspect(value)}; " <>
                "expected one of #{inspect(ReasoningEffort.levels())}"
    end
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
