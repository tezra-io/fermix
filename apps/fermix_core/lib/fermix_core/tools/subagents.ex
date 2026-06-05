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

  # Regular-mode caps (fallback defaults; the live values come from the
  # :subagents config block). /ultra raises these via context.subagent_mode ==
  # :ultra reading the :ultra config block — see the *_cap/1 resolvers below.
  @default_max_concurrency 4
  @hard_max_concurrency 8
  @default_timeout_seconds 300
  @hard_timeout_seconds 900
  @max_tasks 10
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
    :memory_repo,
    # Main-turn-only marker — a worker can never call `subagents` (depth guard),
    # so it must not inherit the ultra mode and advertise the wide (unreachable)
    # fan-out schema in its own prompt.
    :subagent_mode
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

  # The arity-0 callback (baked into the Capability at registration) advertises
  # the *regular* caps. `dynamic_parameters/1` is the context-aware schema the
  # agent loop refreshes per-turn (`AgentLoop` calls it for any tool whose
  # backing module exports `dynamic_parameters/1`), so an `/ultra` turn
  # advertises the wider ultra caps (50 tasks / 12 concurrency) and the model
  # can request wide fan-out through the tool. The hook is a *distinct* name
  # (not `parameters/1`) so it can never collide with a tool module that
  # happens to export `parameters/1` for another purpose (e.g. the plugin
  # `ToolExecutor`'s name→schema lookup).
  @impl true
  def parameters, do: dynamic_parameters(%{})

  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context) do
    %{
      type: "object",
      required: ["tasks"],
      properties: %{
        tasks: %{
          type: "array",
          minItems: 1,
          maxItems: max_tasks_cap(context),
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
          maximum: hard_max_concurrency_cap(context),
          description:
            "Max concurrently running subagents. Defaults to #{default_max_concurrency_cap(context)}."
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
         {:ok, tasks} <- validate_tasks(args, context),
         {:ok, max_concurrency} <- validate_concurrency(args, context),
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
    per_worker_bytes = max(1, div(max_result_bytes_cap(context), length(tasks)))

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
            per_worker_bytes: per_worker_bytes,
            worker_iterations: worker_iterations_cap(context)
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
    definition =
      build_definition(
        task.id,
        run.source_trust,
        run.policy,
        run.timeout_seconds,
        run.worker_iterations
      )

    prompt = worker_prompt(task, run.shared_context, run.result_format)
    opts = Keyword.put(run.spawn_opts, :timeout_seconds, run.timeout_seconds)

    case WorkerRun.run(definition, prompt, run.worker_context, opts) do
      {:ok, session_id, terminal} ->
        result_map(task.id, session_id, terminal, run.per_worker_bytes)

      {:error, {:spawn_failed, reason}} ->
        failed_result(task.id, "spawn failed: #{inspect(reason)}")
    end
  end

  defp build_definition(id, trust, policy, timeout_seconds, max_iterations) do
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
      max_iterations: max_iterations,
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
    You are a temporary Fermix subagent invoked by the main agent. You are one of many
    parallel workers; you handle one narrow slice, not the whole problem.

    You do not talk to the user directly. Complete only the assigned task and return your
    findings to the parent agent.

    Work efficiently: gather just enough evidence to answer your one task well, then stop and
    return. Use as few tool calls as you can — the moment you can answer, you are done. Do not
    broaden the task, chase tangents, collect extra confirmation, or compare across topics;
    breadth and synthesis are the main agent's job, not yours. If the task is impossible or a
    source fails, say so briefly and return — do not keep retrying variations.

    Return: concise findings; the sources or evidence you used; important uncertainty; any
    failures or missing information; and follow-up work the parent should consider.
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

  defp validate_tasks(args, context) do
    max_tasks = max_tasks_cap(context)

    case Map.get(args, "tasks") do
      [] ->
        {:error, "tasks must be a non-empty array."}

      tasks when is_list(tasks) and length(tasks) > max_tasks ->
        {:error, "Too many tasks: #{length(tasks)} (max #{max_tasks})."}

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

  defp validate_concurrency(args, context) do
    hard = hard_max_concurrency_cap(context)

    case Map.get(args, "max_concurrency", default_max_concurrency_cap(context)) do
      n when is_integer(n) and n >= 1 and n <= hard ->
        {:ok, n}

      n when is_integer(n) ->
        {:error, "max_concurrency #{n} is out of range (1..#{hard})."}

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

  # --- Cap resolvers: regular (:subagents config) vs /ultra (:ultra config) ---
  # One code path — the cap resolves from context.subagent_mode + config, never a
  # second fan-out flow. /ultra tags its context `subagent_mode: :ultra` and reads
  # the :ultra block; everything else reads the :subagents block. Literal defaults
  # match the module attributes / the :ultra config so a missing key still behaves.

  defp max_tasks_cap(%{subagent_mode: :ultra}), do: ultra_cfg(:max_subtasks, 50)
  defp max_tasks_cap(_context), do: sub_cfg(:max_tasks, @max_tasks)

  defp hard_max_concurrency_cap(%{subagent_mode: :ultra}),
    do: ultra_cfg(:fanout_max_concurrency, 12)

  defp hard_max_concurrency_cap(_context),
    do: sub_cfg(:hard_max_concurrency, @hard_max_concurrency)

  # Ultra omitting max_concurrency defaults to the ultra fan-out concurrency,
  # not the regular 2 — otherwise a wide ultra fan-out runs nearly serial.
  defp default_max_concurrency_cap(%{subagent_mode: :ultra}),
    do: ultra_cfg(:fanout_max_concurrency, 12)

  defp default_max_concurrency_cap(_context),
    do: sub_cfg(:default_max_concurrency, @default_max_concurrency)

  defp max_result_bytes_cap(%{subagent_mode: :ultra}),
    do: ultra_cfg(:fanout_max_result_bytes, 300_000)

  defp max_result_bytes_cap(_context), do: sub_cfg(:max_result_bytes, @max_result_bytes)

  defp worker_iterations_cap(%{subagent_mode: :ultra}),
    do: ultra_cfg(:fanout_worker_iterations, 40)

  defp worker_iterations_cap(_context), do: IterationLimits.subagent()

  defp sub_cfg(key, default), do: cfg(:subagents, key, default)
  defp ultra_cfg(key, default), do: cfg(:ultra, key, default)

  defp cfg(block, key, default) do
    value = :fermix_core |> Application.get_env(block, []) |> Keyword.get(key, default)

    if is_integer(value) and value > 0 do
      value
    else
      raise ArgumentError,
            "invalid #{block}.#{key} #{inspect(value)}; expected a positive integer"
    end
  end
end
