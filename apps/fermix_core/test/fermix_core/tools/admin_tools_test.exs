defmodule FermixCore.Tools.AdminToolsTest do
  # async: false — setup mutates System env (FERMIX_HOME) and one test mutates
  # Application env (:fermix_core, :routing). Running async would race other
  # tests reading those globals.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.ModelRoutingConfig
  alias FermixCore.Tools.SkillCreate

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    home =
      Path.join(System.tmp_dir!(), "fermix-admin-tools-#{System.unique_integer([:positive])}")

    previous_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("FERMIX_HOME", previous_home),
        else: System.delete_env("FERMIX_HOME")

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "skill_create scaffolds SKILL.md and eval cases under FERMIX_HOME", %{home: home} do
    assert {:ok, result} =
             SkillCreate.execute(
               %{"name" => "research_helper", "description" => "Use for focused research."},
               @context
             )

    assert result.success == true
    skill_dir = Path.join([home, "skills", "research_helper"])
    assert File.read!(Path.join(skill_dir, "SKILL.md")) =~ "name: research_helper"
    assert File.exists?(Path.join([skill_dir, "evals", "evals.json"]))

    assert {:ok, duplicate} =
             SkillCreate.execute(
               %{"name" => "research_helper", "description" => "Use for focused research."},
               @context
             )

    assert duplicate.success == false
    assert duplicate.error =~ "already exists"
  end

  test "skill_create rejects names beyond the registry limit" do
    long_name = String.duplicate("a", 65)

    assert {:ok, result} =
             SkillCreate.execute(
               %{"name" => long_name, "description" => "Use for long-name tests."},
               @context
             )

    assert result.success == false
    assert result.error =~ "max 64 chars"
  end

  test "model_routing_config reads and updates the routing TOML section" do
    assert {:ok, set_result} =
             ModelRoutingConfig.execute(
               %{"action" => "set", "key" => "coding_model", "value" => "gpt-5.4-mini"},
               @context
             )

    assert set_result.success == true

    assert {:ok, read_result} =
             ModelRoutingConfig.execute(%{"action" => "read"}, @context)

    assert read_result.success == true
    assert Jason.decode!(read_result.output)["coding_model"] == "gpt-5.4-mini"
  end

  test "model_routing_config read normalizes config load failures", %{home: home} do
    File.write!(home, "not a directory")

    assert {:ok, result} = ModelRoutingConfig.execute(%{"action" => "read"}, @context)

    assert result.success == false
    assert result.error =~ "enotdir"
  end
end
