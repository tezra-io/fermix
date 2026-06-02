defmodule FermixCore.Agents.BrowserGuidanceSkillTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.SkillRegistry

  test "bundled browser guidance skill loads as a core skill for the browser tool" do
    local =
      Path.join(
        System.tmp_dir!(),
        "fermix-browser-guidance-skill-local-#{System.unique_integer([:positive])}"
      )

    core = Path.expand("../../../priv/skills", __DIR__)
    File.mkdir_p!(local)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"browser_guidance_skill_#{System.unique_integer([:positive])}",
         skills_dir: local,
         core_dir: core,
         seed_defaults: false},
        id: :"browser_guidance_skill_child_#{System.unique_integer([:positive])}"
      )

    assert {:ok, definition} = SkillRegistry.load(registry, "browser_guidance")
    assert definition.trust == :operator
    assert definition.allowed_tools == ["browser"]
    assert definition.system_prompt =~ "Use the built-in `browser` tool"
    assert definition.system_prompt =~ "Do not pass a headless setting"
  end
end
