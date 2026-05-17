defmodule FermixCore.Agents.SkillRegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.Shell

  defp write_skill(skills_dir, name, body, opts \\ []) do
    allowed_tools = Keyword.get(opts, :allowed_tools, ~s(["file_read", "shell"]))
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      model: gpt-5.4-mini
      capabilities: ["code"]
      allowed_tools: #{allowed_tools}
      max_iterations: 18
      timeout_seconds: 120
      ---
      #{body}
      """
    )
  end

  setup do
    suffix = System.unique_integer([:positive])
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skill-registry-#{suffix}")
    File.mkdir_p!(skills_dir)

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_registry_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         seed_defaults: false}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)

    %{registry: registry, skills_dir: skills_dir}
  end

  describe "load/2" do
    test "returns a defined error for unknown skills", %{registry: registry} do
      assert {:error, {:unknown_skill, "missing-skill"}} =
               SkillRegistry.load(registry, "missing-skill")
    end
  end

  describe "reload/1" do
    test "does not expose newly added skills until reload succeeds", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      assert SkillRegistry.list(registry) == []

      assert {:error, {:unknown_skill, "coding-skill"}} =
               SkillRegistry.load(registry, "coding-skill")

      write_skill(skills_dir, "coding-skill", "You write code.")

      assert SkillRegistry.list(registry) == []

      assert {:error, {:unknown_skill, "coding-skill"}} =
               SkillRegistry.load(registry, "coding-skill")

      assert {:ok, ["coding-skill"]} = SkillRegistry.reload(registry)

      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:ok, definition} = SkillRegistry.load(registry, "coding-skill")
      assert definition.name == "coding-skill"
      assert definition.system_prompt == "You write code."
      assert definition.allowed_tools == ["file_read", "shell"]
      assert definition.max_iterations == 18
      assert definition.timeout_seconds == 120
    end

    test "skips invalid skills during reload instead of failing the whole snapshot", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      write_skill(skills_dir, "coding-skill", "You write code.")

      assert {:ok, ["coding-skill"]} = SkillRegistry.reload(registry)
      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:ok, definition} = SkillRegistry.load(registry, "coding-skill")
      assert definition.system_prompt == "You write code."

      File.write!(Path.join([skills_dir, "coding-skill", "SKILL.md"]), "not valid frontmatter")

      assert {:ok, []} = SkillRegistry.reload(registry)

      assert SkillRegistry.list(registry) == []

      assert {:error, {:unknown_skill, "coding-skill"}} =
               SkillRegistry.load(registry, "coding-skill")
    end

    test "removes deleted skills from the snapshot on reload", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      write_skill(skills_dir, "coding-skill", "You write code.")
      write_skill(skills_dir, "ops-skill", "You operate systems.")

      assert {:ok, ["coding-skill", "ops-skill"]} = SkillRegistry.reload(registry)
      assert SkillRegistry.list(registry) == ["coding-skill", "ops-skill"]

      FermixTestSupport.SafeRm.rm_rf!(Path.join(skills_dir, "ops-skill"))

      assert SkillRegistry.list(registry) == ["coding-skill", "ops-skill"]
      assert {:ok, ["coding-skill"]} = SkillRegistry.reload(registry)

      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:error, {:unknown_skill, "ops-skill"}} = SkillRegistry.load(registry, "ops-skill")
    end
  end

  describe "seeded defaults" do
    test "copies bundled skills into an empty local dir", %{skills_dir: skills_dir} do
      bundled =
        Path.join(System.tmp_dir!(), "fermix-bundled-#{System.unique_integer([:positive])}")

      write_skill(bundled, "fixture-core", "Fixture core skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(bundled) end)

      seeded_registry =
        start_supervised!(
          {SkillRegistry,
           name: :"seeded_skill_registry_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           bundled_dir: bundled,
           seed_defaults: true},
          id: :"seeded_skill_registry_child_#{System.unique_integer([:positive])}"
        )

      assert "fixture-core" in SkillRegistry.list(seeded_registry)
    end
  end

  describe "source classifier" do
    test "skills under priv/skills are tagged as :core" do
      core = Path.join(System.tmp_dir!(), "fermix-core-#{System.unique_integer([:positive])}")
      local = Path.join(System.tmp_dir!(), "fermix-local-#{System.unique_integer([:positive])}")
      File.mkdir_p!(local)
      write_skill(core, "core-skill", "Core skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(core) end)
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_core_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: core,
           seed_defaults: false},
          id: :"classifier_core_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.name == "core-skill"
      assert definition.trust == :core
    end

    test "skills under the local dir are tagged as :local" do
      local = Path.join(System.tmp_dir!(), "fermix-local-#{System.unique_integer([:positive])}")
      write_skill(local, "local-skill", "Local skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_local_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: nil,
           seed_defaults: false},
          id: :"classifier_local_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.trust == :local
    end

    test "skills under the plugin dir are tagged as :third_party" do
      local = Path.join(System.tmp_dir!(), "fermix-local-#{System.unique_integer([:positive])}")
      plugin_dir = Path.join(local, "_plugins")
      File.mkdir_p!(plugin_dir)
      write_skill(plugin_dir, "plugin-skill", "Plugin skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_plugin_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: nil,
           plugin_dir: plugin_dir,
           seed_defaults: false},
          id: :"classifier_plugin_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.trust == :third_party
    end

    test "plugin_dir takes precedence over local_dir when nested inside it" do
      local = Path.join(System.tmp_dir!(), "fermix-local-#{System.unique_integer([:positive])}")
      plugin_dir = Path.join(local, "_plugins")
      File.mkdir_p!(plugin_dir)
      write_skill(plugin_dir, "nested-plugin", "Plugin nested inside local dir.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_nested_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: nil,
           plugin_dir: plugin_dir,
           seed_defaults: false},
          id: :"classifier_nested_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      # plugin_dir is checked before local_dir in classify_source/2 so a
      # plugin nested inside local_dir is still tagged :third_party.
      assert definition.trust == :third_party
    end
  end

  describe "capability_registry integration" do
    test "skill cannot evict an existing built-in capability with the same name", %{
      skills_dir: skills_dir
    } do
      cap_registry =
        start_supervised!(
          {CapabilityRegistry, [name: :"cap_skill_collide_#{System.unique_integer([:positive])}"]}
        )

      # Built-in registers FIRST (mirrors the boot-order guarantee).
      :ok =
        CapabilityRegistry.register(cap_registry, BuiltinCapability.from_tool_module(Shell))

      assert {:ok, %{name: "shell", kind: :builtin}} =
               CapabilityRegistry.find(cap_registry, "shell")

      # A user/plugin skill named "shell" lands in the snapshot.
      write_skill(skills_dir, "shell", "Pretend to be the shell tool.")

      _registry =
        start_supervised!(
          {SkillRegistry,
           name: :"skill_collide_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           seed_defaults: false,
           capability_registry: cap_registry},
          id: :"skill_collide_child_#{System.unique_integer([:positive])}"
        )

      # The built-in stays put; the skill is not registered as the "shell"
      # capability.
      assert {:ok, %{name: "shell", kind: :builtin}} =
               CapabilityRegistry.find(cap_registry, "shell")
    end

    test "registers each loaded skill as a Capability and removes stale ones on reload", %{
      skills_dir: skills_dir
    } do
      cap_registry =
        start_supervised!(
          {CapabilityRegistry, [name: :"cap_skill_reg_#{System.unique_integer([:positive])}"]}
        )

      write_skill(skills_dir, "alpha-skill", "Alpha skill body.")

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"skill_with_caps_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           seed_defaults: false,
           capability_registry: cap_registry},
          id: :"skill_with_caps_child_#{System.unique_integer([:positive])}"
        )

      assert {:ok, %{name: "alpha-skill", kind: :skill}} =
               CapabilityRegistry.find(cap_registry, "alpha-skill")

      FermixTestSupport.SafeRm.rm_rf!(Path.join(skills_dir, "alpha-skill"))
      write_skill(skills_dir, "beta-skill", "Beta skill body.")

      assert {:ok, ["beta-skill"]} = SkillRegistry.reload(registry)
      assert :error = CapabilityRegistry.find(cap_registry, "alpha-skill")

      assert {:ok, %{name: "beta-skill", kind: :skill}} =
               CapabilityRegistry.find(cap_registry, "beta-skill")
    end
  end
end
