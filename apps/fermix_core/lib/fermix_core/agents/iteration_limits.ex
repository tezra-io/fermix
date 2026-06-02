defmodule FermixCore.Agents.IterationLimits do
  @moduledoc """
  Domain-level iteration caps for bounded agent-loop entry points.

  These are system-side knobs, not setup or user-facing configuration. Runtime
  callers read them from `Application.get_env(:fermix_core, :iteration_limits, [])`
  and fall back to conservative defaults.
  """

  @config_key :iteration_limits
  @defaults [
    interactive: 100,
    subagent: 100,
    scheduled_job_default: 100
  ]

  @spec interactive() :: pos_integer()
  def interactive, do: limit(:interactive)

  @spec subagent() :: pos_integer()
  def subagent, do: limit(:subagent)

  @spec scheduled_job_default() :: pos_integer()
  def scheduled_job_default, do: limit(:scheduled_job_default)

  defp limit(key) when is_atom(key) do
    :fermix_core
    |> Application.get_env(@config_key, [])
    |> lookup(key)
    |> positive_integer!(key)
  end

  defp lookup(config, key) when is_list(config), do: Keyword.get(config, key, default!(key))

  defp lookup(config, key) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default!(key)))
  end

  defp lookup(config, _key) do
    raise ArgumentError,
          "invalid iteration_limits #{inspect(config)}; expected keyword list or map"
  end

  defp default!(key), do: Keyword.fetch!(@defaults, key)

  defp positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, key) do
    raise ArgumentError,
          "invalid iteration_limits.#{key} #{inspect(value)}; expected a positive integer"
  end
end
