defmodule FermixCore.Agents.AgentDefinitionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentDefinition

  describe "new/1 — defaults and basic shape" do
    test "builds a valid sub-agent definition with defaults" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "coding-skill",
                 "description" => "Use for coding.",
                 "system_prompt" => "You are helpful."
               })

      assert definition.name == "coding-skill"
      assert definition.role == :sub
      assert definition.persistent == false
      assert definition.allowed_tools == nil
      assert definition.policy == nil
      assert definition.trust == nil
      assert definition.capabilities == []
      assert definition.max_iterations == 25
      assert definition.timeout_seconds == 300
    end

    test "accepts string roles and normalizes list-like fields" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "review-skill",
                 "description" => "Use for review.",
                 "system_prompt" => "Review code.",
                 "role" => "sub",
                 "capabilities" => "review",
                 "delegates_to" => ["coding-skill"]
               })

      assert definition.role == :sub
      assert definition.capabilities == ["review"]
      assert definition.delegates_to == ["coding-skill"]
    end
  end

  describe "allowed_tools — three states" do
    test "absent → nil (trust default sentinel)" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "skill-a",
                 "description" => "Use skill a.",
                 "system_prompt" => "Do things."
               })

      assert definition.allowed_tools == nil
    end

    test "explicit nil → nil (trust default sentinel)" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "skill-b",
                 "description" => "Use skill b.",
                 "system_prompt" => "Do things.",
                 "allowed_tools" => nil
               })

      assert definition.allowed_tools == nil
    end

    test "explicit [] → [] (no capabilities)" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "skill-c",
                 "description" => "Use skill c.",
                 "system_prompt" => "Do things.",
                 "allowed_tools" => []
               })

      assert definition.allowed_tools == []
    end

    test "name list → exact allowlist" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "skill-d",
                 "description" => "Use skill d.",
                 "system_prompt" => "Do things.",
                 "allowed_tools" => ["shell", "file_read"]
               })

      assert definition.allowed_tools == ["shell", "file_read"]
    end

    test "non-list, non-nil value rejected loud" do
      assert {:error, {:invalid_allowed_tools, "shell"}} =
               AgentDefinition.new(%{
                 "name" => "skill-e",
                 "description" => "Use skill e.",
                 "system_prompt" => "Do things.",
                 "allowed_tools" => "shell"
               })
    end
  end

  describe "policy field" do
    test "absent → nil" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => "."
               })

      assert definition.policy == nil
    end

    test "single-class shorthand → 1-element list of atoms" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "policy" => "exec"
               })

      assert definition.policy == [:exec]
    end

    test "list of strings → list of atoms in order" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "policy" => ["read_only", "read_write", "exec", "network"]
               })

      assert definition.policy == [:read_only, :read_write, :exec, :network]
    end

    test "unknown policy class raises an error tuple" do
      assert {:error, {:invalid_policy_class, "destroy"}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "policy" => ["read_only", "destroy"]
               })
    end

    test "non-string, non-list value rejected" do
      assert {:error, {:invalid_policy, 42}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "policy" => 42
               })
    end
  end

  describe "trust field" do
    test "frontmatter trust is rejected if outside the closed set" do
      assert {:error, {:invalid_trust, "operator"}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "trust" => "operator"
               })
    end

    test "with_trust/2 stamps a definition with its source classification" do
      {:ok, definition} =
        AgentDefinition.new(%{"name" => "p", "description" => "Use p.", "system_prompt" => "."})

      tagged = AgentDefinition.with_trust(definition, :guest)
      assert tagged.trust == :guest
    end
  end

  describe "provider field" do
    test "absent → nil" do
      assert {:ok, definition} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => "."
               })

      assert definition.provider == nil
    end

    test "string and atom forms parse to a known provider atom" do
      assert {:ok, %{provider: :anthropic}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "provider" => "anthropic"
               })

      assert {:ok, %{provider: :openai_codex}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "provider" => :openai_codex
               })

      assert {:ok, %{provider: :xai}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "provider" => "xai"
               })
    end

    test "unknown provider rejected loud" do
      assert {:error, {:invalid_provider, "claude"}} =
               AgentDefinition.new(%{
                 "name" => "p",
                 "description" => "Use p.",
                 "system_prompt" => ".",
                 "provider" => "claude"
               })
    end
  end

  describe "validation errors" do
    test "rejects invalid positive integer fields" do
      assert {:error, {:invalid_positive_integer, "0"}} =
               AgentDefinition.new(%{
                 "name" => "bad-skill",
                 "description" => "Bad.",
                 "system_prompt" => "Nope.",
                 "timeout_seconds" => "0"
               })

      assert {:error, {:invalid_positive_integer, -1}} =
               AgentDefinition.new(%{
                 "name" => "bad-skill",
                 "description" => "Bad.",
                 "system_prompt" => "Nope.",
                 "max_iterations" => -1
               })
    end

    test "rejects invalid role and persistent invariants" do
      assert {:error, {:invalid_role, "worker"}} =
               AgentDefinition.new(%{
                 "name" => "bad-skill",
                 "description" => "Bad.",
                 "system_prompt" => "Nope.",
                 "role" => "worker"
               })

      assert {:error, {:invalid_persistent, :main, false}} =
               AgentDefinition.new(%{
                 "name" => "main",
                 "description" => "Main.",
                 "system_prompt" => "Main agent.",
                 "role" => :main,
                 "persistent" => false
               })
    end
  end
end
