defmodule FermixCore.Capabilities.SkillTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Skill

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @responses :skill_capability_mock_responses
    @captured :skill_capability_mock_captured

    def init do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      {:ok, _} = Agent.start_link(fn -> [] end, name: @captured)
      :ok
    end

    def set_responses(responses), do: Agent.update(@responses, fn _ -> responses end)
    def captured_messages, do: Agent.get(@captured, & &1)

    def cleanup do
      Enum.each([@responses, @captured], fn name ->
        case Process.whereis(name) do
          nil -> :ok
          pid -> try_stop(pid)
        end
      end)
    end

    defp try_stop(pid) do
      Agent.stop(pid)
    catch
      :exit, _ -> :ok
    end

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: pop_response()

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, _opts) do
      Agent.update(@captured, fn prior -> prior ++ [messages] end)

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

      chat(prior ++ tool_messages, capabilities, opts)
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
      assistant = %{role: "assistant", content: content || ""}

      %{
        content: content || "",
        tool_calls: [],
        provider_state: %{
          messages: messages ++ [assistant],
          capabilities: capabilities
        },
        usage: usage,
        model: Map.get(response, :model, "mock-model")
      }
    end
  end

  defp mock_response(content) do
    {:ok,
     %{
       content: content,
       tool_calls: [],
       usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
       model: "mock-model"
     }}
  end

  defp build_definition(name, prompt) do
    {:ok, definition} =
      AgentDefinition.new(%{
        "name" => name,
        "description" => "Use #{name}.",
        "system_prompt" => prompt,
        "model" => "mock-model",
        "allowed_tools" => [],
        "max_iterations" => 4,
        "timeout_seconds" => 30
      })

    AgentDefinition.with_trust(definition, :operator)
  end

  setup do
    :ok = MockProvider.init()
    suffix = System.unique_integer([:positive])
    agent_supervisor_name = :"skill_capability_agent_supervisor_#{suffix}"
    task_supervisor_name = :"skill_capability_task_supervisor_#{suffix}"
    journal_dir = Path.join(System.tmp_dir!(), "fermix-skill-capability-journals-#{suffix}")

    {:ok, _} = start_supervised({Task.Supervisor, name: task_supervisor_name})
    {:ok, _} = start_supervised({AgentSupervisor, name: agent_supervisor_name})

    on_exit(fn ->
      MockProvider.cleanup()
      FermixTestSupport.SafeRm.rm_rf!(journal_dir)
    end)

    %{
      agent_supervisor: agent_supervisor_name,
      task_supervisor: task_supervisor_name,
      journal_dir: journal_dir
    }
  end

  describe "from_definition/1" do
    test "produces a :skill capability with policy_class :exec and metadata" do
      definition = build_definition("alpha", "Alpha skill body.")
      cap = Skill.from_definition(definition)

      assert %Capability{kind: :skill, policy_class: :exec, name: "alpha"} = cap
      assert cap.metadata.skill == "alpha"
      assert cap.metadata.trust == :operator
      assert {Skill, :invoke, [^definition]} = cap.executor
    end

    test "description comes from the skill definition" do
      definition = build_definition("beta", "Headline line\n\nDetail paragraph here.")
      cap = Skill.from_definition(definition)
      assert cap.description == "Use beta."
    end
  end

  describe "invoke/3" do
    test "spawns sub-agent, returns success tool result, and writes journal", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      definition = build_definition("alpha", "Alpha skill body.")
      MockProvider.set_responses([mock_response("Did the work.")])

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: 0
      }

      assert {:ok, result} =
               Skill.invoke(
                 %{"task" => "Do the thing", "context" => "extra"},
                 context,
                 definition
               )

      assert result.success
      assert result.output =~ "Skill 'alpha' completed"
      assert result.output =~ "Did the work."

      [forced_messages | _] = MockProvider.captured_messages()

      forced_user =
        Enum.find(forced_messages, fn msg ->
          Map.get(msg, :role, Map.get(msg, "role")) == "user"
        end)

      content = Map.get(forced_user, :content, Map.get(forced_user, "content"))
      assert content =~ ~s(running as the "alpha" skill)
      assert content =~ "Do the thing"
      assert content =~ "extra"

      journal =
        Path.join([journal_dir, "alpha"])
        |> Path.join("*.md")
        |> Path.wildcard()
        |> List.first()

      assert is_binary(journal)
      assert File.read!(journal) =~ "Do the thing"
      assert File.read!(journal) =~ "**Status:** completed"

      Process.sleep(50)
      assert AgentSupervisor.list_agents(agent_supervisor) == []
    end

    test "caps recursion at max_skill_depth and emits telemetry", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      definition = build_definition("alpha", "Alpha skill body.")

      handler_id = :"skill_recursion_capped_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :capability, :recursion_capped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:recursion_capped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: Skill.max_skill_depth()
      }

      assert {:ok, result} = Skill.invoke(%{"task" => "Do work"}, context, definition)
      refute result.success
      assert result.error =~ "Max skill depth"

      assert_receive {:recursion_capped, %{count: 1}, %{skill: "alpha", depth: depth, cap: cap}},
                     200

      assert depth == Skill.max_skill_depth()
      assert cap == Skill.max_skill_depth()
    end

    test "missing task arg returns a tool error before spawn", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      definition = build_definition("alpha", "Alpha skill body.")

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: 0
      }

      assert {:ok, result} = Skill.invoke(%{}, context, definition)
      refute result.success
      assert result.error =~ "missing_argument"
      assert AgentSupervisor.list_agents(agent_supervisor) == []
    end
  end
end
