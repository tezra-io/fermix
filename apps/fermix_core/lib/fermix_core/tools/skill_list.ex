defmodule FermixCore.Tools.SkillList do
  @moduledoc """
  List installed skills (name, description, trust) so an agent can discover
  which skills exist before delegating to one with `skill_run`.

  Read-only. This only enumerates the catalog; the per-skill trust and tool
  surface are resolved and enforced by `skill_run` when a skill actually runs.
  It exists so a subagent — whose lean prompt does not carry the skill catalog —
  can still discover skills on demand.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Tools.Support

  @impl true
  def name, do: "skill_list"

  @impl true
  def description,
    do: "List installed skills (name, description, trust) available to run via skill_run."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def when_to_use,
    do: "Discover which installed skills exist before delegating to one with skill_run."

  @impl true
  def examples, do: [%{args: %{}, note: "list all installed skills"}]

  @impl true
  def failure_modes,
    do: [%{tag: "registry_unavailable", description: "the skill registry could not be queried"}]

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(context) end)
  end

  defp do_execute(context) do
    registry = Map.get(context, :skill_registry, SkillRegistry)

    skills =
      registry
      |> SkillRegistry.list_detailed()
      |> Enum.map(&entry/1)
      |> Enum.sort_by(& &1.name)

    Support.success_json(%{skills: skills})
  end

  defp entry(skill) do
    %{name: skill.name, description: skill.description, trust: skill.trust}
  end
end
