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
    assert content =~ "Capabilities are available through the capability registry"
    assert content =~ "## Built-in Capability Catalog"
    assert content =~ "## Skill Catalog"
    assert content =~ "- none loaded"
    assert content =~ "Pick a skill capability by name"
    assert content =~ "cron-style requests"
    assert content =~ "use `schedule_job`"
    assert content =~ "For channel-originated jobs that should report back to the same chat"
    assert content =~ "Use `expires_at` for temporary"
    assert content =~ "Prefer direct Fermix built-ins over shell"
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

    assert content =~ "- coding-skill: capabilities=code, tests; tools=file_read, shell"
    refute content =~ "You write code."
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

  test "build/2 hides skills whose capabilities were filtered out" do
    # Operator's skill list (the GenServer-side snapshot from SkillRegistry).
    operator_skill = %AgentDefinition{
      name: "operator-only-skill",
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

    # Filtered capability snapshot for the current turn — does NOT include
    # the operator-only skill (it was removed by trust/policy filtering).
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

    content = RuntimeSections.build([operator_skill], capabilities: snapshot)

    refute content =~ "operator-only-skill"
    assert content =~ "## Skill Catalog"
    assert content =~ "- none loaded"
  end

  test "build/2 keeps skills whose capabilities are still visible" do
    skill = %AgentDefinition{
      name: "shared-skill",
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

    snapshot = [
      Capability.new(%{
        name: "shared-skill",
        description: "Shared skill capability.",
        parameters: %{"type" => "object"},
        kind: :skill,
        executor: {__MODULE__, :unused, []},
        policy_class: :exec,
        metadata: %{}
      })
    ]

    content = RuntimeSections.build([skill], capabilities: snapshot)

    assert content =~ "- shared-skill: capabilities=analyze; tools=file_read"
  end

  test "build/1 renders 'default' for a skill with absent allowed_tools (nil)" do
    skill = %AgentDefinition{
      name: "loose-skill",
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

    assert content =~ "- loose-skill: capabilities=none; tools=default"
  end
end
