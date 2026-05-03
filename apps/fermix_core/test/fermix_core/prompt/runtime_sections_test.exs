defmodule FermixCore.Prompt.RuntimeSectionsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Prompt.RuntimeSections

  test "build/1 renders runtime guidance and an empty skill snapshot" do
    content = RuntimeSections.build([])

    assert content =~ "## Runtime Contract"
    assert content =~ "Capabilities are available through the capability registry"
    assert content =~ "## Skill Catalog"
    assert content =~ "- none loaded"
    assert content =~ "Pick a skill capability by name"
    assert content =~ "cron-style requests"
    assert content =~ "use `schedule_job`"
    assert content =~ "Use `expires_at` for temporary"
    assert content =~ "Do not use shell, browser, computer-use, or MCP automation"
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
