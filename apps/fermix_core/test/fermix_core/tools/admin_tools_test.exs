defmodule FermixCore.Tools.AdminToolsTest do
  # async: false — setup mutates System env (FERMIX_HOME) and one test mutates
  # Application env (:fermix_core, :routing). Running async would race other
  # tests reading those globals.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Delegate
  alias FermixCore.Tools.ModelRoutingConfig
  alias FermixCore.Tools.SkillCreate

  @context %{agent_name: "test_agent", conversation_key: :test}

  defmodule DelegateAdapter do
    def chat(messages, capabilities, opts) do
      send(self(), {:delegate_seen, messages, capabilities, opts})

      {:ok,
       %{
         content: "delegated answer",
         tool_calls: [],
         provider_state: nil,
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: Keyword.fetch!(opts, :model)
       }}
    end
  end

  setup do
    home =
      Path.join(System.tmp_dir!(), "fermix-admin-tools-#{System.unique_integer([:positive])}")

    previous_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("FERMIX_HOME", previous_home),
        else: System.delete_env("FERMIX_HOME")

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "delegate uses routing.delegate_model from config; main agent does not pass model" do
    previous_routing = Application.get_env(:fermix_core, :routing)
    Application.put_env(:fermix_core, :routing, delegate_model: "gpt-routed")

    on_exit(fn ->
      case previous_routing do
        nil -> Application.delete_env(:fermix_core, :routing)
        value -> Application.put_env(:fermix_core, :routing, value)
      end
    end)

    context = Map.merge(@context, %{delegate_adapter: DelegateAdapter})

    assert {:ok, result} = Delegate.execute(%{"prompt" => "Summarize this."}, context)

    assert result.success == true
    assert result.output == "delegated answer"
    assert_received {:delegate_seen, [%{role: "user", content: "Summarize this."}], [], opts}
    assert Keyword.fetch!(opts, :model) == "gpt-routed"
  end

  test "delegate parameters schema exposes only prompt" do
    schema = Delegate.parameters()

    assert schema.required == ["prompt"]
    assert Map.keys(schema.properties) == [:prompt]
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

  test "model_routing_config reads and updates the routing TOML section" do
    assert {:ok, set_result} =
             ModelRoutingConfig.execute(
               %{"action" => "set", "key" => "delegate_model", "value" => "gpt-5.4-mini"},
               @context
             )

    assert set_result.success == true

    assert {:ok, read_result} =
             ModelRoutingConfig.execute(%{"action" => "read"}, @context)

    assert read_result.success == true
    assert Jason.decode!(read_result.output)["delegate_model"] == "gpt-5.4-mini"
  end

  test "model_routing_config read normalizes config load failures", %{home: home} do
    File.write!(home, "not a directory")

    assert {:ok, result} = ModelRoutingConfig.execute(%{"action" => "read"}, @context)

    assert result.success == false
    assert result.error =~ "enotdir"
  end
end
