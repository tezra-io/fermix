defmodule FermixCore.Tools.InvokeSkillTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Tools.InvokeSkill
  alias FermixCore.Tools.Registry

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @responses :invoke_skill_mock_responses

    def init do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      :ok
    end

    def set_responses(responses) do
      Agent.update(@responses, fn _ -> responses end)
    end

    def cleanup do
      # `Process.whereis` then `Agent.stop` is racy — the agent can exit
      # between the lookup and the stop. Catch the exit so on_exit cleanup
      # never crashes the test report.
      case Process.whereis(@responses) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: pop_response()

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, _opts) do
      case pop_response() do
        {:ok, response} -> {:ok, to_turn(response, messages, capabilities)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl FermixCore.Providers.Adapter
    def continue(provider_state, tool_results, opts) do
      capabilities = Map.get(provider_state, :capabilities, [])
      prior = Map.get(provider_state, :messages, [])

      tool_messages =
        Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
          %{role: "tool", tool_call_id: call_id, content: to_string(output)}
        end)

      next_messages = prior ++ tool_messages
      chat(next_messages, capabilities, opts)
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

    defp to_turn(%{content: content, usage: usage} = response, messages, capabilities) do
      tool_calls = normalize_tool_calls(Map.get(response, :tool_calls, []))
      assistant = %{role: "assistant", content: content || ""}

      %{
        content: content || "",
        tool_calls: tool_calls,
        provider_state: %{
          messages: messages ++ [assistant],
          capabilities: capabilities
        },
        usage: usage,
        model: Map.get(response, :model, "mock-model")
      }
    end

    defp normalize_tool_calls(calls) do
      Enum.map(calls, fn
        %{"id" => id, "function" => %{"name" => name, "arguments" => args}} ->
          %{id: id, call_id: id, name: name, arguments: args}

        %{name: _name, arguments: _args} = call ->
          Map.put_new(call, :call_id, Map.get(call, :id))
      end)
    end
  end

  defp mock_response(content, opts \\ []) do
    {:ok,
     %{
       content: content,
       tool_calls: Keyword.get(opts, :tool_calls, []),
       usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
       model: "mock-model"
     }}
  end

  defp write_skill(skills_dir, name, body, extra_frontmatter \\ "") do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      model: gpt-5.4-mini
      capabilities: ["code"]
      allowed_tools: []
      max_iterations: 8
      timeout_seconds: 60
      #{extra_frontmatter}---
      #{body}
      """
    )
  end

  setup do
    :ok = MockProvider.init()

    suffix = System.unique_integer([:positive])
    registry_name = :"invoke_skill_registry_#{suffix}"
    skill_registry_name = :"invoke_skill_skill_registry_#{suffix}"
    agent_supervisor_name = :"invoke_skill_agent_supervisor_#{suffix}"
    task_supervisor_name = :"invoke_skill_task_supervisor_#{suffix}"
    skills_dir = Path.join(System.tmp_dir!(), "invoke-skill-fixtures-#{suffix}")
    journal_dir = Path.join(System.tmp_dir!(), "invoke-skill-journals-#{suffix}")

    File.mkdir_p!(skills_dir)

    {:ok, _} = start_supervised({Task.Supervisor, name: task_supervisor_name})
    {:ok, _} = start_supervised({Registry, [name: registry_name]})

    {:ok, _} =
      start_supervised(
        {SkillRegistry, name: skill_registry_name, skills_dir: skills_dir, seed_defaults: false}
      )

    {:ok, _} = start_supervised({AgentSupervisor, name: agent_supervisor_name})

    on_exit(fn ->
      MockProvider.cleanup()
      File.rm_rf!(skills_dir)
      File.rm_rf!(journal_dir)
    end)

    %{
      registry: registry_name,
      skill_registry: skill_registry_name,
      agent_supervisor: agent_supervisor_name,
      task_supervisor: task_supervisor_name,
      skills_dir: skills_dir,
      journal_dir: journal_dir
    }
  end

  test "delegates work to a skill agent and writes a journal", %{
    registry: registry,
    skill_registry: skill_registry,
    agent_supervisor: agent_supervisor,
    task_supervisor: task_supervisor,
    skills_dir: skills_dir,
    journal_dir: journal_dir
  } do
    write_skill(skills_dir, "coding-skill", "You are a coding skill.")
    assert {:ok, ["coding-skill"]} = SkillRegistry.reload(skill_registry)

    MockProvider.set_responses([
      mock_response("Updated the target file and verified the result.")
    ])

    context = %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1"},
      session_id: "main-session",
      provider: MockProvider,
      registry: registry,
      skill_registry: skill_registry,
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_base_dir: journal_dir
    }

    assert {:ok, result} =
             InvokeSkill.execute(
               %{
                 "skill" => "coding-skill",
                 "task" => "Fix the failing test",
                 "context" => "Use the repo."
               },
               context
             )

    assert result.success
    assert result.output =~ "Skill 'coding-skill' completed"
    assert result.output =~ "Updated the target file"

    journal_path =
      Path.join([journal_dir, "coding-skill"])
      |> Path.join("*.md")
      |> Path.wildcard()
      |> List.first()

    assert is_binary(journal_path)
    assert File.read!(journal_path) =~ "Fix the failing test"
    assert File.read!(journal_path) =~ "**Status:** completed"

    Process.sleep(50)
    assert AgentSupervisor.list_agents(agent_supervisor) == []
  end

  test "returns a tool error for unknown skills", %{
    registry: registry,
    skill_registry: skill_registry,
    agent_supervisor: agent_supervisor,
    task_supervisor: task_supervisor,
    journal_dir: journal_dir
  } do
    context = %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1"},
      session_id: "main-session",
      provider: MockProvider,
      registry: registry,
      skill_registry: skill_registry,
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_base_dir: journal_dir
    }

    assert {:ok, result} =
             InvokeSkill.execute(%{"skill" => "missing-skill", "task" => "Do work"}, context)

    refute result.success
    assert result.error =~ "Unknown skill"
  end
end
