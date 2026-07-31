defmodule FermixCore.Tools.SkillViewTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Tools.SkillView

  defp write_skill(skills_dir, name, body, opts \\ []) do
    description = Keyword.get(opts, :description, "Use #{name}.")
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: #{description}
      allowed_tools: []
      ---
      #{body}
      """
    )
  end

  setup do
    suffix = System.unique_integer([:positive])
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skill-view-#{suffix}")
    File.mkdir_p!(skills_dir)
    write_skill(skills_dir, "inspect_skill", "Read the repo carefully.")

    File.mkdir_p!(Path.join([skills_dir, "inspect_skill", "references"]))

    File.write!(
      Path.join([skills_dir, "inspect_skill", "references", "notes.md"]),
      "# Notes\n\nDeeper reference detail.\n"
    )

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_view_registry_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         seed_defaults: false}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)
    %{registry: registry, skills_dir: skills_dir}
  end

  test "returns full skill body only on explicit view", %{registry: registry} do
    assert {:ok, result} =
             SkillView.execute(%{"name" => "inspect_skill"}, %{skill_registry: registry})

    assert result.success

    decoded = Jason.decode!(result.output)
    assert decoded["name"] == "inspect_skill"
    assert decoded["description"] == "Use inspect_skill."
    assert decoded["body"] == "Read the repo carefully."
    assert decoded["source_path"] =~ "inspect_skill/SKILL.md"
  end

  test "validates skill names", %{registry: registry} do
    assert {:ok, result} =
             SkillView.execute(%{"name" => "../inspect_skill"}, %{skill_registry: registry})

    refute result.success
    assert result.error =~ "invalid_skill_name"
  end

  test "handles unknown skills loudly", %{registry: registry} do
    assert {:ok, result} = SkillView.execute(%{"name" => "missing"}, %{skill_registry: registry})
    refute result.success
    assert result.error =~ "unknown_skill: missing"
  end

  test "loads a named reference file when file is given", %{registry: registry} do
    assert {:ok, result} =
             SkillView.execute(
               %{"name" => "inspect_skill", "file" => "notes"},
               %{skill_registry: registry}
             )

    assert result.success

    decoded = Jason.decode!(result.output)
    assert decoded["name"] == "inspect_skill"
    assert decoded["file"] == "notes"
    assert decoded["body"] == "# Notes\n\nDeeper reference detail.\n"
    refute Map.has_key?(decoded, "source_path")
  end

  test "rejects a malformed reference file name at the tool boundary", %{registry: registry} do
    assert {:ok, result} =
             SkillView.execute(
               %{"name" => "inspect_skill", "file" => "../SKILL"},
               %{skill_registry: registry}
             )

    refute result.success
    assert result.error =~ "invalid_reference_file"
  end

  test "rejects a reference name the registry confinement forbids", %{registry: registry} do
    # Uppercase passes the tool's looser check but the registry's strict
    # confinement pattern rejects it, surfacing as an invalid-file error.
    assert {:ok, result} =
             SkillView.execute(
               %{"name" => "inspect_skill", "file" => "Notes"},
               %{skill_registry: registry}
             )

    refute result.success
    assert result.error =~ "invalid_reference_file"
  end

  test "reports an unknown reference file loudly", %{registry: registry} do
    assert {:ok, result} =
             SkillView.execute(
               %{"name" => "inspect_skill", "file" => "missing"},
               %{skill_registry: registry}
             )

    refute result.success
    assert result.error =~ "reference_not_found"
  end

  test "enforces the per-file size ceiling on a reference", %{
    registry: registry,
    skills_dir: skills_dir
  } do
    big = String.duplicate("x", 65_537)

    File.write!(Path.join([skills_dir, "inspect_skill", "references", "huge.md"]), big)

    assert {:ok, result} =
             SkillView.execute(
               %{"name" => "inspect_skill", "file" => "huge"},
               %{skill_registry: registry}
             )

    refute result.success
    assert result.error =~ "skill_body_too_large"
  end
end
