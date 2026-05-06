defmodule FermixCore.Prompt.RuntimeSections do
  @moduledoc """
  Builds generated runtime prompt sections.

  These sections describe live tool and skill state. They stay generated so
  bootstrap files do not need to duplicate runtime-derived capabilities.
  """

  alias FermixCore.Agents.AgentDefinition

  @type skill :: AgentDefinition.t()

  @spec build([skill()]) :: String.t()
  def build(available_skills) when is_list(available_skills) do
    [
      runtime_contract(),
      skill_catalog(available_skills)
    ]
    |> Enum.join("\n\n")
  end

  defp runtime_contract do
    """
    ## Runtime Contract
    - Capabilities are available through the capability registry for shell commands, file access, memory, browser actions, scheduled jobs, and skills.
    - Use direct built-in capabilities when the task is narrow and the required capability is obvious.
    - For reminders, recurring work, cron-style requests, periodic checks, digests, watchers, and "run this later" tasks, use `schedule_job`.
    - For channel-originated jobs that should report back to the same chat, set `delivery_mode` to `origin`; use `none` only for silent/local jobs.
    - Use `expires_at` for temporary scheduled jobs like "for 2 hours" or "until tomorrow"; keep lifecycle timing out of the job task text.
    - Do not use shell, browser, computer-use, or MCP automation to create a Fermix scheduled job unless the user explicitly asks to modify an external scheduler.
    - Pick a skill capability by name when a specialized skill is a better fit than handling the work directly.
    - Runtime capability snapshots change only after explicit reloads or process restart.
    """
    |> String.trim()
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
