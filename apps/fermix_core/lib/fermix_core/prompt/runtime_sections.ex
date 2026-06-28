defmodule FermixCore.Prompt.RuntimeSections do
  @moduledoc """
  Builds generated runtime prompt sections.

  These sections describe live tool and skill state. They stay generated so
  bootstrap files do not need to duplicate runtime-derived capabilities.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  @type skill :: AgentDefinition.t()

  @catalog_max_bytes 16_384

  @category_order [
    :file,
    :web,
    :media,
    :computer,
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
    media: "Media Generation",
    computer: "Computer Use",
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
      sub_agent_orchestration(),
      capability_summary_from_opts(opts),
      plugin_index_from_opts(opts),
      skill_catalog(available_skills, Keyword.get(opts, :trust, :operator))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
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
    #{deferred_tools_contract()}- Prefer direct Fermix built-ins over shell, curl, grep, computer-use, or external automation when a built-in owns the verb.
    - Web routing — pick ONE and commit; switch only on a new reason, never rotate through tools for the same goal:
      - If a connected plugin owns the surface (e.g. `github_*` for GitHub, `notion_*` for Notion, `obsidian_*` for the vault, `x_*` for X/Twitter, the Google tools for mail/calendar/drive) use its tools — they hit the real API directly; do NOT open the browser or `web_search` for that surface. Any such plugin is listed under Plugins below.
      - `web_search` for static facts with no known URL (hours, prices, schedules, addresses, lookups).
      - `web_fetch` for the readable text of ONE known URL whose content is in the server HTML.
      - `browser` for JavaScript/dynamic/interactive pages or live data (flight prices, seat maps, dashboards, login, forms).
      - Never shell-scrape a JS-rendered site (`curl`/`urllib`/`requests` return empty or partial markup — a dead end, not a retry). An empty `web_search`/`web_fetch` result on dynamic content is the signal to switch to `browser`, not to rerun the same tool.
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

  # M10 §3.4: rendered only when tool-schema deferral is on — the off-path
  # prompt stays byte-identical to the inline design.
  defp deferred_tools_contract do
    if Deferral.enabled?() do
      "- Plugin and MCP tool schemas load on demand: call the tool directly if its " <>
        "name is listed under Plugins (its skill documents the arguments), " <>
        "`tool_describe` when unsure of parameters, `tool_search` to discover by capability.\n"
    else
      ""
    end
  end

  defp sub_agent_orchestration do
    """
    ## Delegate Wide, Think at the Center
    - When a task splits into independent parts, delegate. Use `subagents` to spawn a separate worker for each narrow part and run them in parallel — never hand one worker a multi-part job. You may delegate even if the user did not ask for subagents.
    - Prefer more narrow workers over fewer broad ones: one worker = one question, one source, one angle. If a part is still broad, split it further before delegating. Width is cheap; a worker handed too much overshoots.
    - Describe each task as a goal. Do not name which tools a subagent should use — it selects its own from a controlled surface (read, web, MCP/plugins, skills, sandbox-bounded shell; no direct writes).
    - Never choose a sub-agent model yourself — omit the `subagents` `model` argument and the configured default applies. Pass a `model` (a known slug) only when the user explicitly asked the sub-agents to use a specific one; it applies to that one call and reverts to the default next time. You cannot change your own model this way.
    - Workers gather; you reason. Judgment, comparison, and synthesis stay with you — pull the workers' findings into one answer; don't push your thinking down into a worker. Don't delegate tightly-coupled reasoning or trivial work where coordination overhead exceeds the benefit.
    - Do not claim work ran in parallel unless `subagents` ran multiple workers concurrently. Synthesize the returned results yourself and state any important gaps or failures.
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
      |> Enum.reject(&(&1.metadata[:category] == :plugin))
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

  defp plugin_index_from_opts(opts) do
    opts |> Keyword.get(:plugins, []) |> plugin_index()
  end

  defp plugin_index([]), do: ""

  defp plugin_index(plugins) when is_list(plugins) do
    body =
      plugins
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", &format_plugin/1)

    "## Plugins\n" <>
      "These connected integrations own their surface — prefer their tools (listed by name below) over the browser, web, or shell. Open a plugin's skill with `skill_view` when you need its workflow or argument conventions — not as a step before every tool call. A plugin showing a status instead of tools is not connected; offer to connect it on the setup page rather than scraping.\n" <>
      "<plugins>\n#{body}\n</plugins>"
  end

  defp format_plugin(entry) do
    case Map.get(entry, :status, :ready) do
      :ready -> format_ready_plugin(entry)
      status -> format_status_plugin(entry, status)
    end
  end

  defp format_ready_plugin(entry) do
    name = xml_escape(entry.name)
    tools = entry.tools |> Enum.join(", ") |> xml_escape()

    case entry.skills do
      [] ->
        "  <plugin name=\"#{name}\">#{tools}</plugin>"

      skills ->
        "  <plugin name=\"#{name}\" skill=\"#{skills |> Enum.join(", ") |> xml_escape()}\">#{tools}</plugin>"
    end
  end

  # An enabled plugin that is not ready: no tools, one status line saying
  # why and what fixes it — so the model can explain the absence.
  defp format_status_plugin(entry, status) do
    name = xml_escape(entry.name)
    note = entry |> Map.get(:remediation) |> remediation_note()

    "  <plugin name=\"#{name}\" status=\"#{status}\">#{note}</plugin>"
  end

  defp remediation_note(nil), do: ""
  defp remediation_note(text) when is_binary(text), do: xml_escape(text)

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
