defmodule FermixCore.Prompt.RuntimeSections do
  @moduledoc """
  Builds generated runtime prompt sections.

  These sections describe live tool and skill state. They stay generated so
  bootstrap files do not need to duplicate runtime-derived capabilities.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  @type skill :: AgentDefinition.t()

  @catalog_max_bytes 16_384

  @category_order [
    :file,
    :web,
    :git,
    :scheduling,
    :memory,
    :delegation,
    :skill_admin,
    :config,
    :channel,
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
    channel: "Channel",
    system: "System"
  }

  @spec build([skill()], keyword()) :: String.t()
  def build(available_skills, opts \\ []) when is_list(available_skills) and is_list(opts) do
    [
      runtime_contract(),
      capability_summary_from_opts(opts),
      skill_catalog(available_skills, Keyword.get(opts, :trust, :operator))
    ]
    |> Enum.join("\n\n")
  end

  defp capability_summary_from_opts(opts) do
    case Keyword.fetch(opts, :capabilities) do
      {:ok, capabilities} -> format_capability_summary_or_empty(capabilities)
      :error -> capability_summary()
    end
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

  defp format_capability_summary_or_empty([]),
    do: "## Built-in Capability Catalog\n- none registered"

  defp format_capability_summary_or_empty(capabilities),
    do: format_capability_summary(capabilities)

  defp runtime_contract do
    """
    ## Runtime Contract
    - Capabilities are available through the capability registry for built-in tools and MCP tools.
    - Prefer direct Fermix built-ins over shell, curl, grep, browser, computer-use, or external automation when a built-in owns the verb.
    - For reminders, recurring work, cron-style requests, periodic checks, digests, watchers, and "run this later" tasks, use `schedule_job`.
    - For channel-originated jobs that should report back to the same chat, set `delivery_mode` to `origin`; use `none` only for silent/local jobs.
    - Use `expires_at` for temporary scheduled jobs like "for 2 hours" or "until tomorrow"; keep lifecycle timing out of the job task text.
    - Use the Skill Catalog only to decide whether a skill is relevant.
    - Before following a skill, call `skill_view` with the skill name.
    - Do not infer detailed behavior from the description alone.
    - Use supporting files only if the loaded `SKILL.md` asks for them.
    - Use `skill_run` when a specialized skill should execute as a delegated sub-agent.
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

  defp skill_catalog(_skills, :guest), do: "## Skill Catalog\n- none loaded"
  defp skill_catalog([], _trust), do: "## Skill Catalog\n- none loaded"

  defp skill_catalog(skills, _trust) do
    entries =
      skills
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&format_skill/1)

    {visible, omitted} = fit_catalog_entries(entries)
    omitted_entry = if omitted > 0, do: ["  <omitted count=\"#{omitted}\" />"], else: []
    body = Enum.join(["<skills>"] ++ visible ++ omitted_entry ++ ["</skills>"], "\n")

    "## Skill Catalog\n#{body}"
  end

  defp format_skill(%AgentDefinition{} = skill) do
    description = xml_escape(skill.description || "")
    trust = skill.trust || :operator
    path = xml_escape(skill.source_path || "")

    [
      "  <skill name=\"#{xml_escape(skill.name)}\" trust=\"#{trust}\" path=\"#{path}\">",
      "    #{description}",
      "  </skill>"
    ]
    |> Enum.join("\n")
  end

  defp fit_catalog_entries(entries) do
    Enum.reduce_while(entries, {[], 0, length(entries)}, fn entry, {acc, bytes, remaining} ->
      projected = bytes + byte_size(entry) + 1

      if projected <= @catalog_max_bytes do
        {:cont, {[entry | acc], projected, remaining - 1}}
      else
        {:halt, {acc, bytes, remaining}}
      end
    end)
    |> then(fn {acc, _bytes, omitted} -> {Enum.reverse(acc), omitted} end)
  end

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
