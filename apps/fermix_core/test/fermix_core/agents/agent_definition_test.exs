defmodule FermixCore.Agents.AgentDefinitionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentDefinition

  test "builds a valid sub-agent definition with defaults" do
    assert {:ok, definition} =
             AgentDefinition.new(%{
               "name" => "coding-skill",
               "system_prompt" => "You are helpful."
             })

    assert definition.name == "coding-skill"
    assert definition.role == :sub
    assert definition.persistent == false
    assert definition.allowed_tools == []
    assert definition.capabilities == []
    assert definition.max_iterations == 25
    assert definition.timeout_seconds == 300
  end

  test "accepts string roles and normalizes list-like fields" do
    assert {:ok, definition} =
             AgentDefinition.new(%{
               "name" => "review-skill",
               "system_prompt" => "Review code.",
               "role" => "sub",
               "capabilities" => "review",
               "allowed_tools" => nil,
               "delegates_to" => ["coding-skill"]
             })

    assert definition.role == :sub
    assert definition.capabilities == ["review"]
    assert definition.allowed_tools == []
    assert definition.delegates_to == ["coding-skill"]
  end

  test "rejects invalid positive integer fields" do
    assert {:error, {:invalid_positive_integer, "0"}} =
             AgentDefinition.new(%{
               "name" => "bad-skill",
               "system_prompt" => "Nope.",
               "timeout_seconds" => "0"
             })

    assert {:error, {:invalid_positive_integer, -1}} =
             AgentDefinition.new(%{
               "name" => "bad-skill",
               "system_prompt" => "Nope.",
               "max_iterations" => -1
             })
  end

  test "rejects invalid role and persistent invariants" do
    assert {:error, {:invalid_role, "worker"}} =
             AgentDefinition.new(%{
               "name" => "bad-skill",
               "system_prompt" => "Nope.",
               "role" => "worker"
             })

    assert {:error, {:invalid_persistent, :main, false}} =
             AgentDefinition.new(%{
               "name" => "main",
               "system_prompt" => "Main agent.",
               "role" => :main,
               "persistent" => false
             })
  end
end
