defmodule FermixCore.Prompt.RuntimeSectionsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Prompt.RuntimeSections

  # Two executor doubles for the credential-gate tests: readiness is the whole
  # difference, and neither reads config, so the assertions carry no global state.
  defmodule ReadyGatedTool do
    def execute(_args, _context), do: {:ok, %{}}
    def advertise?(_context), do: true
  end

  defmodule UnreadyGatedTool do
    def execute(_args, _context), do: {:ok, %{}}
    def advertise?(_context), do: false
  end

  test "build/1 renders runtime guidance and an empty skill snapshot" do
    content = RuntimeSections.build([])

    assert content =~ "## Runtime Contract"
    # M10 §7.6 audit cuts: non-actionable opener and rhetorical browser line.
    refute content =~ "Capabilities are available through the capability registry"
    refute content =~ "first-class built-in, not a fallback"
    assert content =~ "## Built-in Capability Catalog"
    assert content =~ "## Skill Catalog"
    assert content =~ "- none loaded"
    refute content =~ "Pick a skill capability by name"
    refute content =~ "snapshots change only after process restart"
    assert content =~ "Use the Skill Catalog only to decide whether a skill is relevant"
    assert content =~ "call `skill_view`"
    assert content =~ "Do not infer detailed behavior from the description alone"
    assert content =~ "Use supporting files only if the loaded `SKILL.md` asks for them"
    assert content =~ "Use `skill_run`"
    assert content =~ "cron-style requests"
    # MILESTONE_30 §12.3: the job line no longer claims reminders, and the
    # event/job boundary is stated beside it.
    assert content =~ "Use `schedule_job` when the future run must reason"
    assert content =~ "Use `event_store` for deterministic personal reminders"
    assert content =~ "Defer a delivered reminder with `reminder_snooze`"
    assert content =~ "consults every available calendar surface"
    assert content =~ "ask whether the owner wants Fermix reminders for it too"
    assert content =~ "For channel-originated jobs that should report back to the same chat"
    assert content =~ "Use `expires_at` for temporary"
    assert content =~ "Prefer direct Fermix built-ins over shell"
    assert content =~ "## Delegate Wide, Think at the Center"
    # Effort calibration leads the section: scale is decided before the split
    # (live eval catch: "a quick rundown" answered with a 6-subagent,
    # 6.1M-token research fan-out that blew the duration budget).
    assert content =~ "Match the machinery to the ask"
    assert content =~ "not a research project"
    assert content =~ "offer to go deeper"
    assert content =~ "Prefer more narrow workers over fewer broad ones"
    assert content =~ "Use `subagents`"
  end

  # M31 §9 + §18 row "Runtime prompt": the evidence-preserving answer contract is
  # a model contract carried by the runtime prompt (no answer post-processor), so
  # every one of its semantics has to be stated there — and stated once.
  test "build/1 carries the research evidence rules once" do
    content = RuntimeSections.build([])

    assert count_matches(content, "Research evidence") == 1

    # §9.1 — an evidence tool's URL survives into the final answer.
    assert content =~ "keep that tool's exact URL in the answer"
    # §9.2 — link beside the claim; a compact Sources list is the readable escape.
    assert content =~ "right after the claim it supports"
    assert content =~ "compact `Sources` list"
    # §9.3 / §9.4 — a recommended place links to its returned page; a discovered
    # image links to both the image and its source page.
    assert content =~ "Link a place you recommend"
    assert content =~ "link a discovered image to the image AND its source page"
    # §9.5 — the exact returned URL, never invented or assembled. Names the
    # observed fabrication classes (live eval catches: an OpenSSL advisory URL
    # built from a date, an ESA press-release URL built from an article ID).
    assert content =~ "never assemble one from anything you read"
    assert content =~ "press-release ID, an advisory date, a version number"
    assert content =~ "fabrication even when it happens to resolve"
    # §9.5b — the fallback when the deep link never arrived: cite the page that
    # did, never the URL you never received.
    assert content =~ "link the page that was returned"
    assert content =~ "a URL you never received is not citable"

    # §9.6 — unused results are not citations.
    assert content =~ "Cite only results you actually used"
    # §9.7 — an unsourced lookup is said out loud, not papered over with a link.
    assert content =~ "say the lookup was unsourced"
  end

  # M31 §14.1 + §18 row "Advertisement": a credential-gated built-in is filtered
  # off the wire while its credential is missing, so the catalog has to drop it
  # too — a name in the prompt that the model cannot call is the dead end the
  # harness category already removed. Written over the whole family (any
  # `requires_setup` built-in), not one tool name, and driven by fixtures so it
  # needs no global config.
  test "capability_summary/1 drops a credential-gated built-in whose credential is missing" do
    name = :"runtime_gated_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    Registry.register(name, gated_capability("ready_tool", ReadyGatedTool))
    Registry.register(name, gated_capability("unready_tool", UnreadyGatedTool))

    summary = RuntimeSections.capability_summary(name)

    assert summary =~ "`ready_tool`"
    refute summary =~ "`unready_tool`"
  end

  test "capability_summary/1 keeps a keyless built-in that declares no setup" do
    name = :"runtime_keyless_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    Registry.register(name, keyless_capability("plain_tool", UnreadyGatedTool))

    # No `requires_setup`, so `advertise?/1` is not the catalog's business: only
    # the credential-gated family is filtered here.
    assert RuntimeSections.capability_summary(name) =~ "`plain_tool`"
  end

  test "build/1 does not mandate a Sources section on an answer that did no research" do
    [contract | _rest] = String.split(RuntimeSections.build([]), "\n\n## ")

    assert contract =~ "An answer you did not look up gets no `Sources` section"

    # The contract names `Sources` exactly twice: as the readable escape hatch
    # for inline links, and as the thing a non-research answer does not get. A
    # third mention is how a ceremonial mandate creeps back in — a stage that
    # adds one has to justify it here.
    assert count_matches(contract, "Sources") == 2
  end

  test "capability_summary/1 renders registered built-ins from metadata" do
    name = :"runtime_caps_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(FermixCore.Tools.ContentSearch))

    content = RuntimeSections.capability_summary(name)

    assert content =~ "### File & Code"
    assert content =~ "`content_search`"
    assert content =~ "Search file contents"
  end

  test "build/1 renders a compact skill catalog from available skills" do
    skill = %AgentDefinition{
      name: "coding-skill",
      description: "Use when code needs to be written.",
      role: :sub,
      persistent: false,
      system_prompt: "You write code.",
      capabilities: ["code", "tests"],
      allowed_tools: ["file_read", "shell"],
      max_iterations: 12,
      timeout_seconds: 120,
      parent: nil,
      delegates_to: []
    }

    content = RuntimeSections.build([skill])

    assert content =~ ~s(<skills>)
    assert content =~ ~s(<skill name="coding-skill" trust="operator")
    assert content =~ "Use when code needs to be written."
    assert content =~ "</skills>"
    refute content =~ "You write code."
    refute content =~ "capabilities=code"
  end

  test "build/2 renders the supplied capability snapshot instead of global registry built-ins" do
    snapshot = [
      Capability.new(%{
        name: "safe_realtime_tool",
        description: "Only realtime-safe tool.",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: {__MODULE__, :unused, []},
        policy_class: :read_only,
        metadata: %{category: :system, when_to_use: "Use only in realtime tests."}
      })
    ]

    content = RuntimeSections.build([], capabilities: snapshot)

    assert content =~ "`safe_realtime_tool`"
    assert content =~ "Use only in realtime tests."
    refute content =~ "`content_search`"
  end

  test "build/2 hides skills from guest profiles" do
    # Operator's skill list (the GenServer-side snapshot from SkillRegistry).
    operator_skill = %AgentDefinition{
      name: "operator-only-skill",
      description: "Operator only.",
      role: :sub,
      persistent: false,
      system_prompt: "Operator skill.",
      capabilities: [],
      allowed_tools: [],
      max_iterations: 4,
      timeout_seconds: 60,
      parent: nil,
      delegates_to: []
    }

    snapshot = [
      Capability.new(%{
        name: "read_only_tool",
        description: "Allowed under guest policy.",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: {__MODULE__, :unused, []},
        policy_class: :read_only,
        metadata: %{category: :system, when_to_use: "guest-safe."}
      })
    ]

    content = RuntimeSections.build([operator_skill], capabilities: snapshot, trust: :guest)

    refute content =~ "operator-only-skill"
    assert content =~ "## Skill Catalog"
    assert content =~ "- none loaded"
  end

  test "build/2 keeps skills for operator profiles without requiring skill capabilities" do
    skill = %AgentDefinition{
      name: "shared-skill",
      description: "Shared skill description.",
      role: :sub,
      persistent: false,
      system_prompt: "Shared skill.",
      capabilities: ["analyze"],
      allowed_tools: ["file_read"],
      max_iterations: 4,
      timeout_seconds: 60,
      parent: nil,
      delegates_to: []
    }

    content = RuntimeSections.build([skill], capabilities: [])

    assert content =~ ~s(<skill name="shared-skill")
    assert content =~ "Shared skill description."
  end

  test "build/1 omits allowed_tools from the compact skill catalog" do
    skill = %AgentDefinition{
      name: "loose-skill",
      description: "Trust-default skill description.",
      role: :sub,
      persistent: false,
      system_prompt: "Trust-default skill.",
      capabilities: [],
      allowed_tools: nil,
      max_iterations: 10,
      timeout_seconds: 60,
      parent: nil,
      delegates_to: []
    }

    content = RuntimeSections.build([skill])

    assert content =~ ~s(<skill name="loose-skill")
    assert content =~ "Trust-default skill description."
    refute content =~ "tools=default"
  end

  test "build/1 keeps the section assembly order stable" do
    content = RuntimeSections.build([])

    assert String.match?(
             content,
             ~r/## Runtime Contract.*## Built-in Capability Catalog.*## Skill Catalog/s
           )
  end

  test "build/2 renders a plugin index from supplied plugin entries" do
    plugins = [
      %{
        name: "google_calendar",
        tools: ["google_calendar_search_events"],
        skills: ["google-calendar"]
      }
    ]

    content = RuntimeSections.build([], capabilities: [], plugins: plugins)

    assert content =~ "## Plugins"

    assert content =~
             ~s(<plugin name="google_calendar" skill="google-calendar">google_calendar_search_events</plugin>)

    # Reconciled with the deferred-tools routing (M10): skill_view is purposeful
    # (load it for workflow/args), NOT mandated before every tool call.
    assert content =~ "Open a plugin's skill with `skill_view` when you need"
    refute content =~ "skill_view` first, then call its tools"
  end

  test "build/2 omits the plugin index when no plugins are supplied" do
    refute RuntimeSections.build([], capabilities: []) =~ "## Plugins"
  end

  test "build/2 omits the skill attribute for a plugin with no loaded skill" do
    plugins = [%{name: "weather", tools: ["weather.lookup"], skills: []}]

    content = RuntimeSections.build([], capabilities: [], plugins: plugins)

    assert content =~ ~s(<plugin name="weather">weather.lookup</plugin>)
  end

  test "build/2 keeps plugin-owned capabilities out of the built-in catalog" do
    snapshot = [
      Capability.new(%{
        name: "google_calendar_search_events",
        description: "Google Calendar",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: {__MODULE__, :unused, []},
        policy_class: :external_api,
        metadata: %{category: :plugin, plugin_owned?: true, plugin: "google_calendar"}
      })
    ]

    content = RuntimeSections.build([], capabilities: snapshot)

    refute content =~ "google_calendar_search_events"
  end

  defp count_matches(content, needle) do
    length(String.split(content, needle)) - 1
  end

  defp gated_capability(name, module) do
    name
    |> keyless_capability(module)
    |> put_in([Access.key!(:metadata), :requires_setup], %{credential: "some_api_key"})
  end

  defp keyless_capability(name, module) do
    Capability.new(%{
      name: name,
      description: "A tool that needs a credential.",
      parameters: %{type: "object", properties: %{}},
      kind: :builtin,
      executor: {module, :execute, []},
      policy_class: :network,
      metadata: %{
        category: :web,
        when_to_use: "when the credential is present",
        requires_setup: nil
      }
    })
  end
end
