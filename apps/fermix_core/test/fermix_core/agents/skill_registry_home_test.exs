defmodule FermixCore.Agents.SkillRegistryHomeTest do
  # async: false — mutates the process-global FERMIX_HOME env var.
  use ExUnit.Case, async: false

  alias FermixCore.Agents.SkillRegistry

  test "default local dir follows FERMIX_HOME so skills under the active home are discovered" do
    home = Path.join(System.tmp_dir!(), "fermix-home-#{System.unique_integer([:positive])}")
    skills_dir = Path.join(home, "skills")
    write_skill(skills_dir, "computer-use", "You operate local apps.")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)
    on_exit(fn -> restore_env("FERMIX_HOME", previous) end)

    # No skills_dir opts: force the FERMIX_HOME-derived defaults.
    # core_dir: nil isolates discovery from the bundled priv/skills set.
    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_registry_home_#{System.unique_integer([:positive])}",
         core_dir: nil,
         seed_defaults: false}
      )

    assert "computer-use" in SkillRegistry.list(registry)
  end

  defp write_skill(skills_dir, name, body) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: Use #{name} for focused test work.
    ---
    #{body}
    """)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
