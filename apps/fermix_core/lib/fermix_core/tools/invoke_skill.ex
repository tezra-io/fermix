defmodule FermixCore.Tools.InvokeSkill do
  @moduledoc """
  Delegate a task to a supervised skill worker.
  """

  @behaviour FermixCore.Tools.Tool

  require Logger

  alias FermixCore.Agents.AgentServer
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Agents.PersistencePolicy
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Tools.Tool

  @impl true
  def name, do: "invoke_skill"

  @impl true
  def description do
    "Delegate a focused task to a specialized skill agent and return its result summary."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["skill", "task"],
      properties: %{
        skill: %{
          type: "string",
          description: "Registered skill name to invoke, such as coding-skill or review-skill."
        },
        task: %{
          type: "string",
          description: "Clear description of the work the skill should perform."
        },
        context: %{
          type: "string",
          description: "Optional extra context like error output, target files, or constraints."
        }
      }
    }
  end

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    start_ms = System.monotonic_time(:millisecond)

    with {:ok, skill_name} <- fetch_required_string(args, "skill"),
         {:ok, task} <- fetch_required_string(args, "task"),
         {:ok, definition} <- SkillRegistry.load(skill_registry(context), skill_name),
         {:ok, pid, session_id} <-
           AgentSupervisor.spawn_agent(agent_supervisor(context), definition,
             parent: self(),
             parent_name: Map.get(context, :agent_name, "main"),
             parent_session: Map.get(context, :session_id),
             provider: Map.get(context, :provider, FermixCore.Providers.OpenAI),
             registry: Map.get(context, :registry, FermixCore.Tools.Registry),
             task_supervisor: Map.get(context, :task_supervisor, FermixCore.TaskSupervisor)
           ) do
      task_context = optional_string(Map.get(args, "context"))

      terminal =
        run_skill_worker(
          agent_supervisor(context),
          pid,
          task,
          %{
            task_context: task_context,
            tool_context: Map.delete(context, :agent_name)
          },
          definition.timeout_seconds
        )

      finalize_invocation(
        definition,
        session_id,
        task,
        task_context,
        terminal,
        start_ms,
        context
      )
    else
      {:error, {:unknown_skill, skill_name}} ->
        {:ok, Tool.error("Unknown skill: #{skill_name}")}

      {:error, reason} ->
        Logger.error("invoke_skill failed before worker execution: #{inspect(reason)}")
        {:ok, Tool.error("Failed to invoke skill: #{format_reason(reason)}")}
    end
  end

  defp finalize_invocation(
         definition,
         session_id,
         task,
         task_context,
         terminal,
         start_ms,
         context
       ) do
    duration_ms = System.monotonic_time(:millisecond) - start_ms
    parent_name = Map.get(context, :agent_name, "main")
    parent_session = Map.get(context, :session_id, "main")

    LifecycleTelemetry.skill_invoke(
      definition.name,
      session_id,
      summarize_task(task),
      terminal.success?,
      duration_ms,
      parent_session,
      parent: parent_name
    )

    case write_journal(
           definition.name,
           session_id,
           task,
           task_context,
           terminal,
           duration_ms,
           parent_name,
           Map.get(context, :journal_base_dir)
         ) do
      {:ok, _path} ->
        {:ok, build_tool_result(definition.name, terminal)}

      {:error, {:journal_write_failed, status, reason}} ->
        {:ok,
         Tool.error(
           "Skill '#{definition.name}' reached terminal status '#{status}' but journal write failed: #{format_reason(reason)}"
         )}

      {:error, {:invalid_journal_entry, reason}} ->
        {:ok,
         Tool.error(
           "Skill '#{definition.name}' produced an invalid journal entry: #{inspect(reason)}"
         )}
    end
  end

  defp build_tool_result(skill_name, %{success?: true, output: output}) do
    Tool.success("Skill '#{skill_name}' completed:\n#{output}")
  end

  defp build_tool_result(skill_name, %{message: message}) do
    Tool.error("Skill '#{skill_name}' failed: #{message}")
  end

  defp write_journal(
         skill_name,
         session_id,
         task,
         task_context,
         terminal,
         duration_ms,
         parent_name,
         journal_base_dir
       ) do
    entry = %{
      skill: skill_name,
      task: task,
      summary: terminal.summary,
      status: terminal.status,
      context: task_context,
      duration_ms: duration_ms,
      failure: terminal.failure,
      invoked_by: parent_name,
      result: terminal.result,
      session_id: session_id
    }

    case journal_base_dir do
      nil -> PersistencePolicy.write_skill_journal(entry)
      base_dir -> PersistencePolicy.write_skill_journal(entry, base_dir: base_dir)
    end
  end

  defp run_skill_worker(agent_supervisor, pid, task, context, timeout_seconds) do
    pid
    |> start_skill_waiter(task, context)
    |> await_skill_result(timeout_seconds)
    |> normalize_worker_result(agent_supervisor, pid, timeout_seconds)
  end

  defp start_skill_waiter(pid, task, context) do
    Task.async(fn ->
      try do
        AgentServer.run_task(pid, task, context, timeout: :infinity)
      catch
        :exit, reason -> {:error, {:agent_server_exit, reason}}
      end
    end)
  end

  defp await_skill_result(waiter, timeout_seconds) do
    timeout_ms = max(timeout_seconds, 1) * 1_000

    case Task.yield(waiter, timeout_ms) || Task.shutdown(waiter, :brutal_kill) do
      {:ok, reply} -> reply
      nil -> {:error, :timeout}
    end
  end

  defp normalize_worker_result({:ok, loop_result}, agent_supervisor, pid, _timeout_seconds) do
    AgentSupervisor.stop_agent(agent_supervisor, pid, :normal)

    %{
      success?: true,
      status: :completed,
      output: loop_result.response,
      summary: loop_result.response,
      result: loop_result.response,
      failure: nil
    }
  end

  defp normalize_worker_result({:error, :timeout}, agent_supervisor, pid, timeout_seconds) do
    AgentSupervisor.stop_agent(agent_supervisor, pid, :timeout)

    timeout_message = "Skill timed out after #{timeout_seconds}s"

    %{
      success?: false,
      status: :timed_out,
      message: timeout_message,
      summary: timeout_message,
      result: nil,
      failure: timeout_message
    }
  end

  defp normalize_worker_result(
         {:error, {:task_crashed, reason}},
         _agent_supervisor,
         _pid,
         _timeout_seconds
       ) do
    %{
      success?: false,
      status: :crashed,
      message: "Skill crashed: #{format_reason(reason)}",
      summary: "Skill worker crashed during execution.",
      result: nil,
      failure: format_reason(reason)
    }
  end

  defp normalize_worker_result(
         {:error, {:agent_server_exit, reason}},
         _agent_supervisor,
         _pid,
         _timeout_seconds
       ) do
    %{
      success?: false,
      status: :crashed,
      message: "Skill exited unexpectedly: #{format_reason(reason)}",
      summary: "Skill worker exited unexpectedly.",
      result: nil,
      failure: format_reason(reason)
    }
  end

  defp normalize_worker_result({:error, reason}, agent_supervisor, pid, _timeout_seconds) do
    AgentSupervisor.stop_agent(agent_supervisor, pid, :error)

    %{
      success?: false,
      status: :failed,
      message: format_reason(reason),
      summary: "Skill execution failed.",
      result: nil,
      failure: format_reason(reason)
    }
  end

  defp fetch_required_string(args, key) do
    case optional_string(Map.get(args, key)) do
      nil -> {:error, {:missing_argument, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value), do: value |> to_string() |> optional_string()

  defp skill_registry(context), do: Map.get(context, :skill_registry, SkillRegistry)
  defp agent_supervisor(context), do: Map.get(context, :agent_supervisor, AgentSupervisor)

  defp summarize_task(task) do
    task
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
