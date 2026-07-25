defmodule FermixCore.Agents.SkillRegistryReferenceTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.SkillRegistry

  defp write_skill(skills_dir, name) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(Path.join(skill_dir, "references"))

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: Use #{name}.
    allowed_tools: []
    ---
    Overview. Full detail: skill_view(name: "#{name}", file: "guide").
    """)

    File.write!(
      Path.join([skill_dir, "references", "guide.md"]),
      "# Guide\n\nDeep reference detail.\n"
    )

    skill_dir
  end

  setup do
    suffix = System.unique_integer([:positive])
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skill-ref-#{suffix}")
    File.mkdir_p!(skills_dir)
    skill_dir = write_skill(skills_dir, "demo")

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_ref_registry_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         plugin_skill_dirs: [],
         seed_defaults: false}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)
    %{registry: registry, skills_dir: skills_dir, skill_dir: skill_dir}
  end

  test "reads a bundled reference file for a loaded skill", %{registry: registry} do
    assert {:ok, body} = SkillRegistry.read_reference(registry, "demo", "guide")
    assert body == "# Guide\n\nDeep reference detail.\n"
  end

  test "rejects an unknown skill", %{registry: registry} do
    assert {:error, {:unknown_skill, "missing"}} =
             SkillRegistry.read_reference(registry, "missing", "guide")
  end

  test "reports an unknown reference distinctly from an unknown skill", %{registry: registry} do
    assert {:error, {:reference_not_found, _}} =
             SkillRegistry.read_reference(registry, "demo", "nope")
  end

  test "rejects traversal, path separators, and malformed names", %{registry: registry} do
    for bad <- ["../SKILL", "..", ".", "foo/bar", "a/../b", "Guide", "guide.md", "a b", ""] do
      assert {:error, {:invalid_reference_name, ^bad}} =
               SkillRegistry.read_reference(registry, "demo", bad),
             "expected #{inspect(bad)} to be rejected as an invalid reference name"
    end
  end

  test "never reads a file outside the skill's references dir", %{
    registry: registry,
    skill_dir: skill_dir
  } do
    # A sibling file in the skill root must be unreachable — the resolver only
    # ever looks under references/, so a valid-looking name misses it.
    File.write!(Path.join(skill_dir, "secret.md"), "top secret")

    assert {:error, {:reference_not_found, _}} =
             SkillRegistry.read_reference(registry, "demo", "secret")
  end

  test "refuses to follow a symlink escaping the references dir", %{
    registry: registry,
    skills_dir: skills_dir,
    skill_dir: skill_dir
  } do
    outside = Path.join(skills_dir, "outside.md")
    File.write!(outside, "outside secret")
    link = Path.join([skill_dir, "references", "escape.md"])
    :ok = File.ln_s(outside, link)

    assert {:error, {:reference_not_found, _}} =
             SkillRegistry.read_reference(registry, "demo", "escape")
  end

  test "refuses when the references dir itself is a symlink escaping the skill", %{
    skills_dir: skills_dir
  } do
    # A skill whose `references/` is a symlink to an outside directory must not
    # let a lexically-confined, real-final-file name escape: Path.expand does not
    # resolve the intermediate symlink, so the confinement rests on refusing a
    # symlinked references dir before any read.
    suffix = System.unique_integer([:positive])
    outside = Path.join(skills_dir, "outside_dir")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.md"), "OWNER SECRET CONTENT")

    linked_dir = Path.join(skills_dir, "linked")
    File.mkdir_p!(linked_dir)

    File.write!(Path.join(linked_dir, "SKILL.md"), """
    ---
    name: linked
    description: Use linked.
    allowed_tools: []
    ---
    Overview.
    """)

    :ok = File.ln_s(outside, Path.join(linked_dir, "references"))

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_ref_symlink_dir_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         plugin_skill_dirs: [],
         seed_defaults: false},
        id: :"skill_ref_symlink_dir_child_#{suffix}"
      )

    assert {:error, {:reference_not_found, _}} =
             SkillRegistry.read_reference(registry, "linked", "secret")
  end
end
