defmodule FermixCore.Prompt.RuntimeSectionsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Prompt.RuntimeSections

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
    assert content =~ "Prefer more narrow workers over fewer broad ones"
    assert content =~ "Use `subagents`"
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
end
