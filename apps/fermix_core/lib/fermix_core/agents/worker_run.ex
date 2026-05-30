defmodule FermixCore.Agents.WorkerRun do
  @moduledoc """
  Shared lifecycle for a one-shot delegated agent worker.

  Spawns a supervised `AgentServer`, runs a single task with a wall-clock
  timeout, normalizes the terminal state, and stops the worker on every path.
  Used by `FermixCore.Capabilities.Skill` (the `skill_run` built-in) and by the
  generic `subagents` tool, so the two share one fragile-to-get-right pipeline.

  The caller owns everything domain-specific: building the task prompt, shaping
  the worker `tool_context` (depth markers, context sanitizing), and turning the
  normalized terminal result into a tool result, journal, or aggregate. This
  module owns only `spawn -> run -> await -> normalize -> stop` and returns a
  neutral terminal map.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentServer
  alias FermixCore.Agents.AgentSupervisor

  @type terminal :: %{
          required(:success?) => boolean(),
          required(:status) => :completed | :timed_out | :crashed | :failed,
          required(:summary) => String.t(),
          required(:result) => String.t() | nil,
          required(:failure) => String.t() | nil,
          optional(:output) => String.t(),
          optional(:message) => String.t(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:iterations) => pos_integer() | nil,
          optional(:total_tokens) => non_neg_integer() | nil
        }

  @doc """
  Run `task` on a freshly spawned worker for `definition`, returning the
  worker's `session_id` and a normalized terminal result, or a spawn failure.

  Options:
    * `:agent_supervisor` — defaults to `AgentSupervisor`
    * `:task_supervisor` — defaults to `FermixCore.TaskSupervisor`
    * `:capability_registry` — defaults to `FermixCore.Capabilities.Registry`
    * `:provider` — defaults to `FermixCore.Providers.OpenAI`
    * `:parent`, `:parent_name`, `:parent_session` — parent metadata for the
      worker's lifecycle monitor and telemetry (`:parent` defaults to `self()`)
    * `:timeout_seconds` — wall-clock cap, defaults to `definition.timeout_seconds`
    * `:task_context` — optional `task_context` string folded into the worker's
      user message (defaults to `nil`; callers usually fold context into `task`)
  """
  @spec run(AgentDefinition.t(), String.t(), map(), keyword()) ::
          {:ok, String.t(), terminal()} | {:error, {:spawn_failed, term()}}
  def run(%AgentDefinition{} = definition, task, tool_context, opts \\ [])
      when is_binary(task) and is_map(tool_context) and is_list(opts) do
    agent_supervisor = Keyword.get(opts, :agent_supervisor, AgentSupervisor)
    timeout_seconds = Keyword.get(opts, :timeout_seconds, definition.timeout_seconds)
    run_context = %{task_context: Keyword.get(opts, :task_context), tool_context: tool_context}

    case AgentSupervisor.spawn_agent(agent_supervisor, definition, spawn_opts(opts)) do
      {:ok, pid, session_id} ->
        start_ms = System.monotonic_time(:millisecond)

        terminal =
          pid
          |> start_waiter(task, run_context)
          |> await_result(timeout_seconds)
          |> normalize(agent_supervisor, pid, timeout_seconds)

        duration_ms = System.monotonic_time(:millisecond) - start_ms
        {:ok, session_id, Map.put(terminal, :duration_ms, duration_ms)}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp spawn_opts(opts) do
    [
      parent: Keyword.get(opts, :parent, self()),
      parent_name: Keyword.get(opts, :parent_name, "main"),
      parent_session: Keyword.get(opts, :parent_session),
      provider: Keyword.get(opts, :provider, FermixCore.Providers.OpenAI),
      capability_registry:
        Keyword.get(opts, :capability_registry, FermixCore.Capabilities.Registry),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    ]
  end

  defp start_waiter(pid, task, run_context) do
    Task.async(fn ->
      try do
        AgentServer.run_task(pid, task, run_context, timeout: :infinity)
      catch
        :exit, reason -> {:error, {:agent_server_exit, reason}}
      end
    end)
  end

  defp await_result(waiter, timeout_seconds) do
    timeout_ms = max(timeout_seconds, 1) * 1_000

    case Task.yield(waiter, timeout_ms) || Task.shutdown(waiter, :brutal_kill) do
      {:ok, reply} -> reply
      nil -> {:error, :timeout}
    end
  end

  defp normalize({:ok, loop_result}, agent_supervisor, pid, _timeout_seconds) do
    AgentSupervisor.stop_agent(agent_supervisor, pid, :normal)

    %{
      success?: true,
      status: :completed,
      output: loop_result.response,
      summary: loop_result.response,
      result: loop_result.response,
      failure: nil,
      iterations: loop_result.iterations,
      total_tokens: loop_result.total_tokens
    }
  end

  defp normalize({:error, :timeout}, agent_supervisor, pid, timeout_seconds) do
    AgentSupervisor.stop_agent(agent_supervisor, pid, :timeout)
    message = "Worker timed out after #{timeout_seconds}s"

    %{
      success?: false,
      status: :timed_out,
      message: message,
      summary: message,
      result: nil,
      failure: message
    }
  end

  defp normalize({:error, {:task_crashed, reason}}, agent_supervisor, pid, _timeout_seconds) do
    # The task crashed but the AgentServer GenServer survived and is now idle —
    # stop it so it does not linger until the parent process exits.
    AgentSupervisor.stop_agent(agent_supervisor, pid, :crashed)

    %{
      success?: false,
      status: :crashed,
      message: "Worker crashed: #{format_reason(reason)}",
      summary: "Worker crashed during execution.",
      result: nil,
      failure: format_reason(reason)
    }
  end

  defp normalize({:error, {:agent_server_exit, reason}}, agent_supervisor, pid, _timeout_seconds) do
    # The AgentServer itself exited; stop_agent is a safe no-op if it is already
    # gone, and guarantees cleanup if only the run_task call failed.
    AgentSupervisor.stop_agent(agent_supervisor, pid, :crashed)

    %{
      success?: false,
      status: :crashed,
      message: "Worker exited unexpectedly: #{format_reason(reason)}",
      summary: "Worker exited unexpectedly.",
      result: nil,
      failure: format_reason(reason)
    }
  end

  defp normalize({:error, reason}, agent_supervisor, pid, _timeout_seconds) do
    AgentSupervisor.stop_agent(agent_supervisor, pid, :error)

    %{
      success?: false,
      status: :failed,
      message: format_reason(reason),
      summary: "Worker execution failed.",
      result: nil,
      failure: format_reason(reason)
    }
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
