defmodule FermixCore.Plugins.PromptCatalog do
  @moduledoc """
  Per-plugin runtime index, derived from the profile's already-filtered
  capability snapshot so it can never advertise a tool the worker cannot call.

  Tool names come from the plugin-owned capabilities in the profile snapshot, so
  the index is by construction a subset of the callable tools (it inherits the
  profile's trust/allowed-tools/excluded-category/registry filtering). Skill
  names are the plugin's manifest skills that are actually loaded in the skill
  registry, so the index never points at a skill `skill_view` cannot open. The
  agent opens a listed skill with `skill_view` and calls the listed tools.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry

  @type entry :: %{name: String.t(), tools: [String.t()], skills: [String.t()]}

  @doc """
  Build the index from a profile's filtered `capabilities` and the names of the
  currently loaded skills. Grouping the plugin-owned capabilities guarantees the
  listed tools match what the worker can call; skills are intersected with the
  loaded set. The registry is consulted only to map a plugin to its declared
  skill names.
  """
  @spec entries([Capability.t()], [String.t()]) :: [entry()]
  def entries(capabilities, loaded_skill_names)
      when is_list(capabilities) and is_list(loaded_skill_names) do
    loaded = MapSet.new(loaded_skill_names)

    capabilities
    |> Enum.filter(&plugin_owned?/1)
    |> Enum.group_by(&plugin_name/1)
    |> Enum.reject(fn {plugin, _caps} -> is_nil(plugin) end)
    |> Enum.map(fn {plugin, caps} -> entry(plugin, caps, loaded) end)
    |> Enum.sort_by(& &1.name)
  end

  defp entry(plugin_name, caps, loaded) do
    %{
      name: plugin_name,
      tools: caps |> Enum.map(& &1.name) |> Enum.sort(),
      skills: plugin_name |> manifest_skill_names() |> Enum.filter(&MapSet.member?(loaded, &1))
    }
  end

  defp plugin_owned?(%Capability{metadata: metadata}),
    do: Map.get(metadata, :plugin_owned?) == true

  defp plugin_owned?(_capability), do: false

  defp plugin_name(%Capability{metadata: metadata}), do: Map.get(metadata, :plugin)

  defp manifest_skill_names(plugin_name) do
    case Registry.find(plugin_name) do
      {:ok, %Plugin{skills: skills}} ->
        skills |> Enum.map(&Map.get(&1, "name")) |> Enum.filter(&is_binary/1)

      _other ->
        []
    end
  end
end
