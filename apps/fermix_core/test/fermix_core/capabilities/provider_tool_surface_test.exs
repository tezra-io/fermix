defmodule FermixCore.Capabilities.ProviderToolSurfaceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Providers.Anthropic.Messages
  alias FermixCore.Providers.OpenAI.ChatCompletions
  alias FermixCore.Providers.OpenAI.Responses
  alias FermixCore.Realtime.ToolBridge

  setup do
    suffix = System.unique_integer([:positive])
    skills_dir = FermixTestSupport.SafeRm.make_tmp_dir!("provider-tool-surface-#{suffix}")
    capability_registry = :"provider_tool_surface_caps_#{suffix}"
    skill_registry = :"provider_tool_surface_skills_#{suffix}"

    {:ok, _} = start_supervised({CapabilityRegistry, [name: capability_registry]})
    seed_skill_lifecycle_tools(capability_registry)

    {:ok, _} =
      start_supervised(
        {SkillRegistry,
         name: skill_registry,
         skills_dir: skills_dir,
         core_dir: nil,
         seed_defaults: false,
         capability_registry: capability_registry}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)

    %{
      capability_registry: capability_registry,
      skill_registry: skill_registry,
      skills_dir: skills_dir
    }
  end

  test "provider tool schemas remain stable across skill add and remove", ctx do
    before_caps = operator_capabilities(ctx.capability_registry)
    before_names = serialized_tool_names(before_caps)

    write_skill(ctx.skills_dir, "provider_surface_skill")
    assert {:ok, %{added: ["provider_surface_skill"]}} = SkillRegistry.reload(ctx.skill_registry)

    after_add_caps = operator_capabilities(ctx.capability_registry)
    after_add_names = serialized_tool_names(after_add_caps)

    FermixTestSupport.SafeRm.rm_rf!(Path.join(ctx.skills_dir, "provider_surface_skill"))

    assert {:ok, %{removed: ["provider_surface_skill"]}} =
             SkillRegistry.reload(ctx.skill_registry)

    after_remove_caps = operator_capabilities(ctx.capability_registry)
    after_remove_names = serialized_tool_names(after_remove_caps)

    assert Enum.all?(after_add_caps, &(&1.kind != :skill))
    assert before_names == after_add_names
    assert before_names == after_remove_names
  end

  defp operator_capabilities(registry) do
    CapabilityRegistry.list_for(registry, trust: :operator)
  end

  defp serialized_tool_names(capabilities) do
    %{
      openai_responses: capabilities |> Responses.to_provider_tools() |> flat_names(),
      openai_chat: capabilities |> ChatCompletions.to_provider_tools() |> chat_names(),
      anthropic: capabilities |> Messages.to_provider_tools() |> flat_names(),
      realtime: capabilities |> ToolBridge.to_openai_tools() |> flat_names()
    }
  end

  defp flat_names(tools), do: tools |> Enum.map(& &1.name) |> Enum.sort()
  defp chat_names(tools), do: tools |> Enum.map(& &1.function.name) |> Enum.sort()

  defp seed_skill_lifecycle_tools(registry) do
    [FermixCore.Tools.SkillView, FermixCore.Tools.SkillRun]
    |> Enum.each(fn tool_module ->
      :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(tool_module))
    end)
  end

  defp write_skill(skills_dir, name) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: Use #{name} for provider surface tests.
      allowed_tools: []
      ---
      Provider surface skill body.
      """
    )
  end
end
