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

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_view_registry_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         seed_defaults: false}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)
    %{registry: registry}
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
end
