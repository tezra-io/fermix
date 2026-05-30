defmodule FermixCore.Tools.SkillRunTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Skill
  alias FermixCore.Tools.SkillRun

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @responses :skill_run_mock_responses

    def init do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      :ok
    end

    def set_responses(responses), do: Agent.update(@responses, fn _ -> responses end)

    def cleanup do
      case Process.whereis(@responses) do
        nil -> :ok
        _pid -> Agent.stop(@responses)
      end
    catch
      :exit, _ -> :ok
    end

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: pop_response()

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, _opts) do
      with {:ok, response} <- pop_response() do
        {:ok, turn(response, messages, capabilities)}
      end
    end

    @impl FermixCore.Providers.Adapter
    def continue(provider_state, _tool_results, _opts) do
      turn = %{
        content: "",
        tool_calls: [],
        provider_state: provider_state,
        usage: usage(),
        model: "mock-model"
      }

      {:ok, turn}
    end

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities
    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []
    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response
    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp pop_response do
      Agent.get_and_update(@responses, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, "No mock responses left"}, []}
      end)
    end

    defp turn(%{content: content}, messages, capabilities) do
      %{
        content: content,
        tool_calls: [],
        provider_state: %{messages: messages, capabilities: capabilities},
        usage: usage(),
        model: "mock-model"
      }
    end

    defp usage, do: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
  end

  defp write_skill(skills_dir, name, body) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: Use #{name}.
      allowed_tools: []
      model: mock-model
      ---
      #{body}
      """
    )
  end

  setup do
    :ok = MockProvider.init()
    suffix = System.unique_integer([:positive])
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skill-run-#{suffix}")
    journal_dir = Path.join(System.tmp_dir!(), "fermix-skill-run-journals-#{suffix}")
    agent_supervisor = :"skill_run_agent_supervisor_#{suffix}"
    task_supervisor = :"skill_run_task_supervisor_#{suffix}"

    File.mkdir_p!(skills_dir)
    write_skill(skills_dir, "worker", "Do delegated work.")

    {:ok, _} = start_supervised({AgentSupervisor, name: agent_supervisor})
    {:ok, _} = start_supervised({Task.Supervisor, name: task_supervisor})

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_run_registry_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         seed_defaults: false}
      )

    on_exit(fn ->
      MockProvider.cleanup()
      FermixTestSupport.SafeRm.rm_rf!(skills_dir)
      FermixTestSupport.SafeRm.rm_rf!(journal_dir)
    end)

    %{
      registry: registry,
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    }
  end

  test "invokes the existing skill sub-agent path", ctx do
    MockProvider.set_responses([{:ok, %{content: "delegated result"}}])

    assert {:ok, result} =
             SkillRun.execute(
               %{"name" => "worker", "task" => "Do it", "context" => "extra"},
               tool_context(ctx, 0)
             )

    assert result.success
    assert result.output =~ "Skill 'worker' completed"
    assert result.output =~ "delegated result"
  end

  test "enforces max skill recursion depth", ctx do
    assert {:ok, result} =
             SkillRun.execute(
               %{"name" => "worker", "task" => "Do it"},
               tool_context(ctx, Skill.max_skill_depth())
             )

    refute result.success
    assert result.error =~ "Max skill depth"
  end

  defp tool_context(ctx, depth) do
    %{
      skill_registry: ctx.registry,
      provider: MockProvider,
      agent_supervisor: ctx.agent_supervisor,
      task_supervisor: ctx.task_supervisor,
      journal_base_dir: ctx.journal_dir,
      agent_name: "main",
      session_id: "main-session",
      skill_depth: depth
    }
  end
end
