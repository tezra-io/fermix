defmodule FermixCore.Prompt.RuntimeSections do
  @moduledoc """
  Builds generated runtime prompt sections.

  These sections describe live tool and skill state. They stay generated so
  bootstrap files do not need to duplicate runtime-derived capabilities.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Harness.Config, as: HarnessConfig

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
    :harness,
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
    harness: "Coding Harness",
    skill_admin: "Skill Admin",
    config: "Configuration",
    channel: "Channel",
    system: "System"
  }

  @spec build([skill()], keyword()) :: String.t()
  def build(available_skills, opts \\ []) when is_list(available_skills) and is_list(opts) do
    [
      runtime_contract(),
      sub_agent_orchestration(opts),
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
    #{deferred_tools_contract()}- Prefer direct Fermix built-ins over shell, curl, grep, computer-use, or external automation when a built-in owns the verb — but `computer_use` is the ONLY tool that acts on the user's OWN live screen; use it when the task is about a page/app/session they already have open (`browser`/`shell` run in their own context and won't touch their screen).
    - Even on the user's own screen, an intent the OS can NAME is a script, not a pixel hunt: launch apps from `shell` (`open -a` on macOS), drive app menus/settings/Finder through the OS scripting surface where it names the object (AppleScript via `osascript` on macOS), and spend `computer_use` clicks only on state that exists solely as pixels.
    - Web routing — pick ONE and commit; switch only on a new reason, never rotate through tools for the same goal:
      - If a connected plugin owns the surface (e.g. `github_*` for GitHub, `notion_*` for Notion, `obsidian_*` for the vault, `x_*` for X/Twitter, the Google tools for mail/calendar/drive) use its tools — they hit the real API directly; do NOT open the browser or `web_search` for that surface. Any such plugin is listed under Plugins below.
      - `web_search` for static facts with no known URL (hours, prices, schedules, addresses, lookups).
      - `web_fetch` for the readable text of ONE known URL whose content is in the server HTML.
      - `browser` for JavaScript/dynamic/interactive pages or live data (flight prices, seat maps, dashboards, login, forms) — in its OWN browser instance, not the page/app the user has open on screen (for that, `computer_use`).
      - Never shell-scrape a JS-rendered site (`curl`/`urllib`/`requests` return empty or partial markup — a dead end, not a retry). An empty `web_search`/`web_fetch` result on dynamic content is the signal to switch to `browser`, not to rerun the same tool.
    - Drive ONE surface per task: don't restart the same work in the other tool's separate session — wait for a change with the session you're already in (the browser's `act` wait for a page you drive, `computer_use`'s `wait_for_change` for the host screen). On a single shared page, structure goes through `browser` and pixels through `computer_use`: that split is one context, not a switch.
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

  # Rendered only when `subagents` is actually callable on this surface: a whole
  # section instructing delegation on a session that excludes the delegation
  # category (voice does) is dead weight in every prompt and an instruction the
  # model cannot follow. No explicit capability list (text mode) keeps the
  # section — the registry advertises subagents there.
  defp sub_agent_orchestration(opts) do
    case Keyword.fetch(opts, :capabilities) do
      {:ok, capabilities} ->
        if Enum.any?(capabilities, &(&1.name == "subagents")),
          do: sub_agent_orchestration_text(),
          else: ""

      :error ->
        sub_agent_orchestration_text()
    end
  end

  defp sub_agent_orchestration_text do
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
      |> Enum.reject(&harness_when_unusable?/1)
      |> Enum.group_by(&(&1.metadata[:category] || :system))
      |> Enum.sort_by(fn {category, _caps} -> category_index(category) end)
      |> Enum.map_join("\n\n", &format_category/1)

    "## Built-in Capability Catalog\n#{body}"
  end

  # Design §23.4 collapses the harness into two states, and the prompt must follow
  # the wire: the run tools are seeded on CLI detection alone but advertise only
  # when the harness is USABLE (`enabled` + `approved`). Rendering the section
  # while they are unadvertised is the dead end §23.4 removed — steering that
  # names tools the model cannot call. Unusable ⇒ the whole category drops and
  # Fermix silently codes with its own file/shell tools.
  defp harness_when_unusable?(capability) do
    capability.metadata[:category] == :harness and not harness_usable?()
  end

  defp harness_usable?, do: HarnessConfig.enabled?() and HarnessConfig.approved?()

  # The coding-harness category carries a section-level PREAMBLE line (design
  # §7.4) before its tool list — a new touchpoint, rendered only when the bucket
  # is non-empty (i.e. harness tools are registered this boot). The preamble
  # steers repo coding work through a harness run and, when configured, names the
  # preferred vendor.
  defp format_category({:harness, capabilities}) do
    "### #{@category_labels.harness}\n#{harness_preamble(capabilities)}#{capability_lines(capabilities)}"
  end

  defp format_category({category, capabilities}) do
    "### #{Map.get(@category_labels, category, titleize(category))}\n#{capability_lines(capabilities)}"
  end

  defp capability_lines(capabilities) do
    capabilities
    |> Enum.sort_by(& &1.name)
    |> Enum.map_join("\n", fn capability ->
      "- `#{capability.name}` — #{capability.metadata[:when_to_use] || capability.description}"
    end)
  end

  # The owner-authored delegation-steering principle (design §7.4). Names the
  # failure class (repository work → harness run; incidental → your own hands)
  # rather than example-specific patterns.
  defp harness_preamble(capabilities) do
    base =
      "Delegating repository work. When a coding harness is available, route work " <>
        "that means understanding or changing a codebase — reviewing a PR or recent " <>
        "changes, diagnosing and fixing a bug (a real fix needs root-cause analysis, " <>
        "which is the harness's job, not a patch guessed from the symptom), " <>
        "implementing or refactoring a feature, working through a GitHub or local " <>
        "repository — to a harness run rather than doing it yourself with file edits. " <>
        "Reserve your own direct tools for the genuinely incidental: running a quick " <>
        "calculation or one-off script via the shell, reading a file to answer a " <>
        "question, scratch work outside any project. For repository work the harness " <>
        "is the default; your own hands are for the small, non-repo touches."

    "#{base}#{vendor_preference(capabilities)}\n"
  end

  # The vendor steer renders only when a default_vendor is configured AND both
  # vendor CLIs are registered this boot (both run tools present in the bucket).
  # It names both tools and states that the non-default vendor stays reachable on
  # explicit request — because `default_vendor` now filters the non-default tool
  # off the advertised wire (advertisement gate), so the model must learn the
  # alternate name here to override.
  defp vendor_preference(capabilities) do
    vendor = HarnessConfig.default_vendor()

    if is_binary(vendor) and both_run_tools?(capabilities) do
      " When the request does not name a vendor, prefer `#{vendor}`; both " <>
        "`codex_run` and `claude_code_run` remain available, so run the other on an " <>
        "explicit request even if only one is listed above."
    else
      ""
    end
  end

  defp both_run_tools?(capabilities) do
    names = MapSet.new(capabilities, & &1.name)
    MapSet.member?(names, "codex_run") and MapSet.member?(names, "claude_code_run")
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
