defmodule FermixCore.Agents.SkillRegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.SkillRegistry

  defp write_skill(skills_dir, name, body) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      model: gpt-5.4-mini
      capabilities: ["code"]
      allowed_tools: ["file_read", "shell"]
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
         name: :"skill_registry_#{suffix}", skills_dir: skills_dir, seed_defaults: false}
      )

    on_exit(fn -> File.rm_rf!(skills_dir) end)

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

      File.rm_rf!(Path.join(skills_dir, "ops-skill"))

      assert SkillRegistry.list(registry) == ["coding-skill", "ops-skill"]
      assert {:ok, ["coding-skill"]} = SkillRegistry.reload(registry)

      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:error, {:unknown_skill, "ops-skill"}} = SkillRegistry.load(registry, "ops-skill")
    end
  end

  describe "seeded defaults" do
    test "can seed bundled skill templates into an empty directory", %{skills_dir: skills_dir} do
      seeded_registry =
        start_supervised!(
          {SkillRegistry,
           name: :"seeded_skill_registry_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           seed_defaults: true},
          id: :"seeded_skill_registry_child_#{System.unique_integer([:positive])}"
        )

      assert "coding-skill" in SkillRegistry.list(seeded_registry)
      assert "research-skill" in SkillRegistry.list(seeded_registry)
      assert "review-skill" in SkillRegistry.list(seeded_registry)
    end
  end
end
