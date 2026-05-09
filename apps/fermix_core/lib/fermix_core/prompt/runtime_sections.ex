defmodule FermixCore.Prompt.RuntimeSections do
  @moduledoc """
  Builds generated runtime prompt sections.

  These sections describe live tool and skill state. They stay generated so
  bootstrap files do not need to duplicate runtime-derived capabilities.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  @type skill :: AgentDefinition.t()

  @category_order [
    :file,
    :web,
    :git,
    :scheduling,
    :memory,
    :delegation,
    :skill_admin,
    :config,
    :system
  ]
  @category_labels %{
    file: "File & Code",
    web: "Web",
    git: "Git",
    scheduling: "Scheduling",
    memory: "Memory",
    delegation: "Delegation",
    skill_admin: "Skill Admin",
    config: "Configuration",
    system: "System"
  }

  @spec build([skill()]) :: String.t()
  def build(available_skills) when is_list(available_skills) do
    [
      runtime_contract(),
      capability_summary(),
      skill_catalog(available_skills)
    ]
    |> Enum.join("\n\n")
  end

  @spec capability_summary(GenServer.server()) :: String.t()
  def capability_summary(registry \\ CapabilityRegistry) do
    registry
    |> list_builtins()
    |> case do
      [] -> "## Built-in Capability Catalog\n- none registered"
      capabilities -> format_capability_summary(capabilities)
    end
  end

  defp runtime_contract do
    """
    ## Runtime Contract
    - Capabilities are available through the capability registry for built-in tools, skills, and MCP tools.
    - Prefer direct Fermix built-ins over shell, curl, grep, browser, computer-use, or external automation when a built-in owns the verb.
    - For reminders, recurring work, cron-style requests, periodic checks, digests, watchers, and "run this later" tasks, use `schedule_job`.
    - For channel-originated jobs that should report back to the same chat, set `delivery_mode` to `origin`; use `none` only for silent/local jobs.
    - Use `expires_at` for temporary scheduled jobs like "for 2 hours" or "until tomorrow"; keep lifecycle timing out of the job task text.
    - Pick a skill capability by name when a specialized skill is a better fit than handling the work directly.
    - Runtime capability snapshots change only after explicit reloads or process restart.
    """
    |> String.trim()
  end

  defp list_builtins(registry) do
    CapabilityRegistry.list(registry, kind: :builtin)
  rescue
    ArgumentError -> []
  end

  defp format_capability_summary(capabilities) do
    body =
      capabilities
      |> Enum.group_by(&(&1.metadata[:category] || :system))
      |> Enum.sort_by(fn {category, _caps} -> category_index(category) end)
      |> Enum.map_join("\n\n", &format_category/1)

    "## Built-in Capability Catalog\n#{body}"
  end

  defp format_category({category, capabilities}) do
    lines =
      capabilities
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", fn capability ->
        "- `#{capability.name}` — #{capability.metadata[:when_to_use] || capability.description}"
      end)

    "### #{Map.get(@category_labels, category, titleize(category))}\n#{lines}"
  end

  defp category_index(category) do
    case Enum.find_index(@category_order, &(&1 == category)) do
      nil -> length(@category_order)
      index -> index
    end
  end

  defp titleize(category) do
    category
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp skill_catalog([]), do: "## Skill Catalog\n- none loaded"

  defp skill_catalog(skills) do
    body =
      skills
      |> Enum.map(&format_skill/1)
      |> Enum.join("\n")

    "## Skill Catalog\n#{body}"
  end

  defp format_skill(%AgentDefinition{} = skill) do
    "- #{skill.name}: capabilities=#{join_values(skill.capabilities)}; tools=#{join_values(skill.allowed_tools)}"
  end

  defp join_values(nil), do: "default"
  defp join_values([]), do: "none"
  defp join_values(values), do: Enum.join(values, ", ")
end
