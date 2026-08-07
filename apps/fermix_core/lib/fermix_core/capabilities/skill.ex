defmodule FermixCore.Capabilities.Skill do
  @moduledoc """
  Runs a skill `AgentDefinition` through the sub-agent execution path.

  `invoke/3` is used by the stable `skill_run` built-in. `from_definition/1`
  remains for compatibility with registry/storage tests, but the live runtime
  no longer exposes one provider tool per installed skill.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Agents.PersistencePolicy
  alias FermixCore.Agents.WorkerRun
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.SkillCuration.Usage

  require Logger

  @max_skill_depth 4

  @spec from_definition(AgentDefinition.t()) :: Capability.t()
  def from_definition(%AgentDefinition{} = definition) do
    Capability.new(%{
      name: definition.name,
      description: skill_description(definition),
      parameters: skill_parameters(),
      kind: :skill,
      executor: {__MODULE__, :invoke, [definition]},
      policy_class: :exec,
      hidden_from_agent?: false,
      metadata: %{
        skill: definition.name,
        trust: definition.trust,
        source_path: definition.source_path
      }
    })
  end

  @doc """
  Capability executor entry point.

  Args:
    * `args` — `%{"task" => binary, optional "context" => binary}`
    * `context` — invocation context with `:agent_supervisor`,
      `:task_supervisor`, `:agent_name`, `:session_id`, `:journal_base_dir`,
      `:registry`, `:provider`, `:skill_depth` (defaults 0).
    * `definition` — loaded `AgentDefinition` for this skill.
  """
  @spec invoke(map(), map(), AgentDefinition.t()) :: {:ok, map()}
  def invoke(args, context, %AgentDefinition{} = definition)
      when is_map(args) and is_map(context) do
    start_ms = System.monotonic_time(:millisecond)
    current_depth = Map.get(context, :skill_depth, 0)

    with {:ok, task} <- fetch_required_string(args, "task"),
         :ok <- check_depth(current_depth, definition.name) do
      task_context = optional_string(Map.get(args, "context"))
      run_skill_invocation(definition, task, task_context, context, current_depth, start_ms)
    else
      {:error, {:max_skill_depth_exceeded, depth}} ->
        emit_recursion_capped(definition.name, depth)
        {:ok, Tool.error("Max skill depth (#{@max_skill_depth}) exceeded; refusing to spawn.")}

      {:error, reason} ->
        Logger.error("Skill invocation failed before spawn: #{inspect(reason)}")
        {:ok, Tool.error("Failed to invoke skill: #{format_reason(reason)}")}
    end
  end

  defp run_skill_invocation(definition, task, task_context, context, current_depth, start_ms) do
    forced_task = force_skill_prompt(definition.name, task, task_context)

    worker_context =
      context
      |> Map.delete(:agent_name)
      |> Map.put(:skill_depth, current_depth + 1)

    case WorkerRun.run(definition, forced_task, worker_context,
           parent: self(),
           parent_name: Map.get(context, :agent_name, "main"),
           parent_session: Map.get(context, :session_id),
           provider: Map.get(context, :provider, FermixCore.Providers.OpenAI),
           capability_registry:
             Map.get(context, :capability_registry, FermixCore.Capabilities.Registry),
           task_supervisor: Map.get(context, :task_supervisor, FermixCore.TaskSupervisor),
           agent_supervisor: agent_supervisor(context),
           # Parent turn's route chain (§7) — skill workers without an
           # explicit provider/model override inherit it like `subagents`.
           ordered_routes: Map.get(context, :ordered_routes),
           timeout_seconds: definition.timeout_seconds
         ) do
      {:ok, session_id, terminal} ->
        finalize_invocation(
          definition,
          session_id,
          task,
          task_context,
          terminal,
          start_ms,
          context
        )

      {:error, {:spawn_failed, reason}} ->
        Logger.error("Failed to spawn skill agent #{definition.name}: #{inspect(reason)}")
        {:ok, Tool.error("Failed to spawn skill: #{format_reason(reason)}")}
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

    Usage.record_run(definition.name, usage_opts(context))

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
           "Skill '#{definition.name}' reached terminal status '#{status}' but journal " <>
             "write failed: #{format_reason(reason)}"
         )}

      {:error, {:invalid_journal_entry, reason}} ->
        {:ok,
         Tool.error(
           "Skill '#{definition.name}' produced an invalid journal entry: #{inspect(reason)}"
         )}
    end
  end

  defp usage_opts(context) do
    case Map.get(context, :usage_repo) do
      nil -> []
      repo -> [repo: repo]
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

  defp force_skill_prompt(skill_name, task, nil) do
    """
    You are running as the "#{skill_name}" skill, invoked by your parent agent.
    Your assigned task:

    #{task}

    Use the tools available to you and complete the task. When finished, return
    a concise summary of what was done and any output the parent needs.
    """
    |> String.trim()
  end

  defp force_skill_prompt(skill_name, task, task_context) do
    """
    You are running as the "#{skill_name}" skill, invoked by your parent agent.
    Your assigned task:

    #{task}

    Parent context:
    #{task_context}

    Use the tools available to you and complete the task. When finished, return
    a concise summary of what was done and any output the parent needs.
    """
    |> String.trim()
  end

  defp skill_description(%AgentDefinition{description: description}) when is_binary(description),
    do: description

  defp skill_parameters do
    %{
      type: "object",
      required: ["task"],
      properties: %{
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

  defp check_depth(depth, _name) when depth < @max_skill_depth, do: :ok
  defp check_depth(depth, _name), do: {:error, {:max_skill_depth_exceeded, depth}}

  defp emit_recursion_capped(skill_name, depth) do
    :telemetry.execute(
      [:fermix, :capability, :recursion_capped],
      %{count: 1},
      %{skill: skill_name, depth: depth, cap: @max_skill_depth}
    )
  end

  defp agent_supervisor(context),
    do: Map.get(context, :agent_supervisor, AgentSupervisor)

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

  defp summarize_task(task) do
    task
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  @doc false
  def max_skill_depth, do: @max_skill_depth
end
