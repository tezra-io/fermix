defmodule FermixCore.Tools.Subagents do
  @moduledoc """
  Run one or more temporary subagents for independent delegated work.

  The model supplies only the work (task goals) and orchestration knobs
  (concurrency, timeout, result shape) — never `policy`, `allowed_tools`, or
  `trust`. Fermix computes the worker surface from the parent turn's
  `:source_trust`: a worker runs at the parent's trust with the parent's policy
  classes **minus `:read_write`**, so it can read, browse the web, use MCP/plugin
  tools, run skills, and run sandbox-bounded `shell`, but cannot directly mutate
  local/Fermix state. The worker `tool_context` is sanitized so a subagent cannot
  reply on Fermix's channel or reach the parent's memory.

  Workers run concurrently up to a bounded cap; each is a one-shot
  `FermixCore.Agents.WorkerRun` pass with its own wall-clock timeout. The caller
  (main agent) synthesizes the structured results. `subagents` is main-agent-only
  in v1 — it requires `:source_trust` and refuses to run from inside a subagent.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.IterationLimits
  alias FermixCore.Agents.WorkerRun
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.Support

  @default_max_concurrency 3
  @hard_max_concurrency 8
  @default_timeout_seconds 300
  @hard_timeout_seconds 900
  @max_tasks 8
  @max_result_bytes 60_000

  # Context keys stripped before a worker runs: channel-reply targeting and the
  # parent's memory/sandbox handles. The worker keeps the infra keys it needs to
  # function (registries, supervisors, provider, journal dir).
  @stripped_context_keys [
    :reply_fn,
    :channel,
    :source_channel,
    :source_trust,
    :sandbox_config,
    :conversation_key,
    :memory_agent_id,
    :memory_owner_id,
    :memory_store,
    :memory_repo
  ]

  @impl true
  def name, do: "subagents"

  @impl true
  def description do
    "Run one or more temporary subagents for independent delegated work. Each " <>
      "subagent gets a bounded task and a controlled tool surface (read, web, " <>
      "MCP/plugins, skills; no direct writes) and returns findings. Describe goals, " <>
      "not tools; the caller must synthesize the returned results."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["tasks"],
      properties: %{
        tasks: %{
          type: "array",
          minItems: 1,
          maxItems: @max_tasks,
          description: "Independent subagent assignments.",
          items: %{
            type: "object",
            required: ["id", "task"],
            properties: %{
              id: %{type: "string", description: "Stable caller-chosen id for the result."},
              task: %{
                type: "string",
                description:
                  "Goal-level assignment — what to accomplish, not which tools to call."
              },
              context: %{type: "string", description: "Optional task-specific context."}
            }
          }
        },
        shared_context: %{type: "string", description: "Context all subagents receive."},
        max_concurrency: %{
          type: "integer",
          minimum: 1,
          maximum: @hard_max_concurrency,
          description:
            "Max concurrently running subagents. Defaults to #{@default_max_concurrency}."
        },
        timeout_seconds: %{
          type: "integer",
          minimum: 5,
          maximum: @hard_timeout_seconds,
          description: "Per-subagent timeout. Defaults to #{@default_timeout_seconds}."
        },
        result_format: %{
          type: "string",
          enum: ["concise", "detailed", "structured"],
          description: "Requested result shape from each subagent. Defaults to structured."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "When a request has independent substantial parts and delegating them improves " <>
      "speed, coverage, or quality. Skip it for simple or tightly-coupled work."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "tasks" => [
            %{"id" => "flights", "task" => "Find round-trip flight options SFO->TYO in May."},
            %{"id" => "hotels", "task" => "Find 4-star hotels near Shinjuku under $250/night."}
          ]
        },
        note: "fan out two independent research tasks"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{
        tag: "no_source_trust",
        description: "called outside a main-agent turn (no source_trust)"
      },
      %{tag: "recursion", description: "called from inside a subagent (subagent_depth > 0)"},
      %{tag: "invalid_tasks", description: "tasks missing, empty, over the cap, or duplicate ids"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :delegation

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, depth} <- check_recursion(context),
         {:ok, source_trust} <- fetch_source_trust(context),
         {:ok, tasks} <- validate_tasks(args),
         {:ok, max_concurrency} <- validate_concurrency(args),
         {:ok, timeout_seconds} <- validate_timeout(args) do
      run_fanout(tasks, source_trust, max_concurrency, timeout_seconds, depth, args, context)
    else
      {:error, message} -> Support.error(message)
    end
  end

  defp run_fanout(tasks, source_trust, max_concurrency, timeout_seconds, depth, args, context) do
    policy = worker_policy(source_trust)
    worker_context = sanitize_context(context, depth)
    spawn_opts = base_spawn_opts(context)
    task_supervisor = Map.get(context, :task_supervisor, FermixCore.TaskSupervisor)
    shared_context = Support.optional_string(args, "shared_context")
    result_format = Support.optional_string(args, "result_format", "structured")
    per_worker_bytes = max(1, div(@max_result_bytes, length(tasks)))

    results =
      task_supervisor
      |> Task.Supervisor.async_stream_nolink(
        tasks,
        fn task ->
          run_one(task, %{
            source_trust: source_trust,
            policy: policy,
            timeout_seconds: timeout_seconds,
            worker_context: worker_context,
            spawn_opts: spawn_opts,
            shared_context: shared_context,
            result_format: result_format,
            per_worker_bytes: per_worker_bytes
          })
        end,
        max_concurrency: max_concurrency,
        timeout: :infinity,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(tasks)
      |> Enum.map(fn {stream_result, task} -> normalize_stream(stream_result, task) end)

    Support.success_json(%{
      status: "completed",
      results: results,
      summary: summarize(results)
    })
  end

  defp run_one(task, run) do
    definition = build_definition(task.id, run.source_trust, run.policy, run.timeout_seconds)
    prompt = worker_prompt(task, run.shared_context, run.result_format)
    opts = Keyword.put(run.spawn_opts, :timeout_seconds, run.timeout_seconds)

    case WorkerRun.run(definition, prompt, run.worker_context, opts) do
      {:ok, session_id, terminal} ->
        result_map(task.id, session_id, terminal, run.per_worker_bytes)

      {:error, {:spawn_failed, reason}} ->
        failed_result(task.id, "spawn failed: #{inspect(reason)}")
    end
  end

  defp build_definition(id, trust, policy, timeout_seconds) do
    %AgentDefinition{
      name: "subagent:#{id}",
      description: "Temporary generic Fermix subagent for #{id}",
      role: :sub,
      persistent: false,
      system_prompt: worker_system_prompt(),
      model: nil,
      provider: nil,
      temperature: nil,
      capabilities: [],
      allowed_tools: nil,
      policy: policy,
      trust: trust,
      max_iterations: IterationLimits.subagent(),
      timeout_seconds: timeout_seconds,
      parent: "main",
      delegates_to: []
    }
  end

  defp worker_policy(source_trust) do
    CapabilityRegistry.default_policy_classes(source_trust) -- [:read_write]
  end

  defp sanitize_context(context, depth) do
    context
    |> Map.drop(@stripped_context_keys)
    |> Map.put(:subagent_depth, depth + 1)
  end

  defp base_spawn_opts(context) do
    [
      # Runs in the coordinator (the inline tool call on the turn task), so
      # `self()` is the coordinator process. Parenting workers to it lets
      # `AgentServer`'s parent-down monitor reap them when the coordinator is
      # cancelled (e.g. `/stop` terminating the turn) — otherwise the workers,
      # spawned nolink under the task supervisor, would outlive the stopped turn.
      parent: self(),
      parent_name: Map.get(context, :agent_name, "main"),
      parent_session: Map.get(context, :session_id),
      provider: Map.get(context, :provider, FermixCore.Providers.OpenAI),
      capability_registry: Map.get(context, :capability_registry, CapabilityRegistry),
      task_supervisor: Map.get(context, :task_supervisor, FermixCore.TaskSupervisor),
      agent_supervisor: Map.get(context, :agent_supervisor, AgentSupervisor)
    ]
  end

  defp worker_system_prompt do
    """
    You are a temporary Fermix subagent invoked by the main agent.

    You do not talk to the user directly. Complete only the assigned task and
    return your findings to the parent agent.

    Return: concise findings; the sources or evidence you used; important
    uncertainty; any failures or missing information; and follow-up work the
    parent should consider.
    """
    |> String.trim()
  end

  defp worker_prompt(task, shared_context, result_format) do
    [
      shared_context && "Shared context:\n#{shared_context}",
      "Task:\n#{task.task}",
      task.context && "Task context:\n#{task.context}",
      result_hint(result_format)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp result_hint("concise"), do: "Keep your response brief."
  defp result_hint("detailed"), do: "Provide a thorough, detailed response."

  defp result_hint(_structured),
    do: "Structure your response clearly for synthesis by the parent."

  defp result_map(id, session_id, terminal, per_worker_bytes) do
    {output, truncated} = truncate(terminal.result, per_worker_bytes)

    %{
      id: id,
      status: Atom.to_string(terminal.status),
      agent_name: "subagent:#{id}",
      session_id: session_id,
      duration_ms: Map.get(terminal, :duration_ms),
      iterations: Map.get(terminal, :iterations),
      output: output,
      error: terminal.failure,
      truncated: truncated
    }
  end

  defp failed_result(id, message) do
    %{
      id: id,
      status: "failed",
      agent_name: "subagent:#{id}",
      session_id: nil,
      output: nil,
      error: message,
      truncated: false
    }
  end

  defp normalize_stream({:ok, result}, _task), do: result

  defp normalize_stream({:exit, reason}, task) do
    %{
      id: task.id,
      status: "crashed",
      agent_name: "subagent:#{task.id}",
      session_id: nil,
      output: nil,
      error: "stream task exited: #{inspect(reason)}",
      truncated: false
    }
  end

  defp truncate(nil, _max), do: {nil, false}

  defp truncate(text, max) when is_binary(text) do
    if byte_size(text) > max do
      {valid_prefix(binary_part(text, 0, max)), true}
    else
      {text, false}
    end
  end

  # Trim trailing bytes (at most 3 for UTF-8) so a multibyte character split by
  # the byte budget does not leave an invalid sequence that crashes JSON encoding.
  defp valid_prefix(binary) do
    if String.valid?(binary) do
      binary
    else
      valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  defp summarize(results) do
    counts = Enum.frequencies_by(results, & &1.status)

    %{
      requested: length(results),
      completed: Map.get(counts, "completed", 0),
      failed: Map.get(counts, "failed", 0) + Map.get(counts, "crashed", 0),
      timed_out: Map.get(counts, "timed_out", 0),
      canceled: Map.get(counts, "canceled", 0)
    }
  end

  defp check_recursion(context) do
    case Map.get(context, :subagent_depth, 0) do
      0 -> {:ok, 0}
      depth -> {:error, "subagents cannot be called from within a subagent (depth #{depth})."}
    end
  end

  defp fetch_source_trust(context) do
    case Map.get(context, :source_trust) do
      trust when trust in [:operator, :guest] ->
        {:ok, trust}

      _ ->
        {:error, "subagents requires a source_trust in context (main-agent only in v1)."}
    end
  end

  defp validate_tasks(args) do
    case Map.get(args, "tasks") do
      [] ->
        {:error, "tasks must be a non-empty array."}

      tasks when is_list(tasks) and length(tasks) > @max_tasks ->
        {:error, "Too many tasks: #{length(tasks)} (max #{@max_tasks})."}

      tasks when is_list(tasks) ->
        parse_tasks(tasks)

      _ ->
        {:error, "tasks must be a non-empty array."}
    end
  end

  defp parse_tasks(tasks) do
    parsed = Enum.map(tasks, &parse_task/1)

    case Enum.find(parsed, &match?({:error, _}, &1)) do
      {:error, _} = error -> error
      nil -> dedupe_ids(Enum.map(parsed, fn {:ok, task} -> task end))
    end
  end

  defp parse_task(%{"id" => id, "task" => task} = task_map)
       when is_binary(id) and id != "" and is_binary(task) and task != "" do
    {:ok, %{id: id, task: task, context: Support.optional_string(task_map, "context")}}
  end

  defp parse_task(_other),
    do: {:error, "each task needs a non-empty string id and a non-empty string task."}

  defp dedupe_ids(tasks) do
    ids = Enum.map(tasks, & &1.id)

    if length(Enum.uniq(ids)) == length(ids) do
      {:ok, tasks}
    else
      {:error, "task ids must be unique."}
    end
  end

  defp validate_concurrency(args) do
    case Map.get(args, "max_concurrency", @default_max_concurrency) do
      n when is_integer(n) and n >= 1 and n <= @hard_max_concurrency ->
        {:ok, n}

      n when is_integer(n) ->
        {:error, "max_concurrency #{n} is out of range (1..#{@hard_max_concurrency})."}

      _ ->
        {:error, "max_concurrency must be an integer."}
    end
  end

  defp validate_timeout(args) do
    case Map.get(args, "timeout_seconds", @default_timeout_seconds) do
      n when is_integer(n) and n >= 5 and n <= @hard_timeout_seconds ->
        {:ok, n}

      n when is_integer(n) ->
        {:error, "timeout_seconds #{n} is out of range (5..#{@hard_timeout_seconds})."}

      _ ->
        {:error, "timeout_seconds must be an integer."}
    end
  end
end
