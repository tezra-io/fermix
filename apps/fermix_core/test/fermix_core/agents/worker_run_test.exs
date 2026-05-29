defmodule FermixCore.Agents.WorkerRunTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.WorkerRun

  defmodule MockProvider do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @responses :worker_run_mock_responses
    @delay :worker_run_mock_delay

    def init do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      {:ok, _} = Agent.start_link(fn -> 0 end, name: @delay)
      :ok
    end

    def set_responses(responses), do: Agent.update(@responses, fn _ -> responses end)
    def set_delay(ms), do: Agent.update(@delay, fn _ -> ms end)

    def cleanup do
      Enum.each([@responses, @delay], fn name ->
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

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, _opts) do
      case Agent.get(@delay, & &1) do
        ms when ms > 0 -> Process.sleep(ms)
        _ -> :ok
      end

      case pop_response() do
        {:ok, response} -> {:ok, to_turn(response, messages, capabilities)}
        :raise -> raise "mock provider boom"
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

    defp to_turn(%{content: content} = response, messages, capabilities) do
      assistant = %{role: "assistant", content: content || ""}

      %{
        content: content || "",
        tool_calls: [],
        provider_state: %{messages: messages ++ [assistant], capabilities: capabilities},
        usage:
          Map.get(response, :usage, %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1}),
        model: Map.get(response, :model, "mock-model")
      }
    end
  end

  defp build_definition(timeout_seconds) do
    {:ok, definition} =
      AgentDefinition.new(%{
        "name" => "worker",
        "description" => "A worker.",
        "system_prompt" => "Worker body.",
        "model" => "mock-model",
        "allowed_tools" => [],
        "max_iterations" => 4,
        "timeout_seconds" => timeout_seconds
      })

    AgentDefinition.with_trust(definition, :operator)
  end

  defp run_opts(ctx) do
    [
      parent: self(),
      parent_name: "main",
      parent_session: "main-session",
      provider: MockProvider,
      agent_supervisor: ctx.agent_supervisor,
      task_supervisor: ctx.task_supervisor
    ]
  end

  setup do
    :ok = MockProvider.init()
    suffix = System.unique_integer([:positive])
    agent_supervisor_name = :"worker_run_agent_supervisor_#{suffix}"
    task_supervisor_name = :"worker_run_task_supervisor_#{suffix}"

    {:ok, _} = start_supervised({Task.Supervisor, name: task_supervisor_name})
    {:ok, _} = start_supervised({AgentSupervisor, name: agent_supervisor_name})

    on_exit(fn -> MockProvider.cleanup() end)

    %{agent_supervisor: agent_supervisor_name, task_supervisor: task_supervisor_name}
  end

  test "completed: returns session_id and a completed terminal, stops the worker", ctx do
    MockProvider.set_responses([{:ok, %{content: "Did the work."}}])
    definition = build_definition(30)

    assert {:ok, session_id, terminal} =
             WorkerRun.run(definition, "Task:\nDo it", %{}, run_opts(ctx))

    assert is_binary(session_id)
    assert terminal.success?
    assert terminal.status == :completed
    assert terminal.output == "Did the work."
    assert terminal.failure == nil

    Process.sleep(50)
    assert AgentSupervisor.list_agents(ctx.agent_supervisor) == []
  end

  test "timed_out: a worker slower than the timeout normalizes to :timed_out and is stopped",
       ctx do
    MockProvider.set_responses([{:ok, %{content: "too late"}}])
    MockProvider.set_delay(2_500)
    definition = build_definition(1)

    assert {:ok, _session_id, terminal} =
             WorkerRun.run(definition, "Task:\nSlow", %{}, run_opts(ctx))

    refute terminal.success?
    assert terminal.status == :timed_out
    assert terminal.summary =~ "Worker timed out after 1s"
    assert terminal.result == nil

    Process.sleep(50)
    assert AgentSupervisor.list_agents(ctx.agent_supervisor) == []
  end

  test "crashed: a worker whose task crashes normalizes to :crashed and is stopped", ctx do
    MockProvider.set_responses([:raise])
    definition = build_definition(30)

    assert {:ok, _session_id, terminal} =
             WorkerRun.run(definition, "Task:\nboom", %{}, run_opts(ctx))

    refute terminal.success?
    assert terminal.status == :crashed

    # the AgentServer survives a task crash but must be stopped, not left idle
    Process.sleep(50)
    assert AgentSupervisor.list_agents(ctx.agent_supervisor) == []
  end

  test "tool_context is threaded into the worker run", ctx do
    MockProvider.set_responses([{:ok, %{content: "ok"}}])
    definition = build_definition(30)

    assert {:ok, _session_id, terminal} =
             WorkerRun.run(definition, "Task:\nUse ctx", %{custom_key: "present"}, run_opts(ctx))

    assert terminal.status == :completed
  end
end
