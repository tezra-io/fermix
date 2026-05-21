defmodule FermixCore.AgentLoop do
  @moduledoc """
  Core LLM conversation loop with capability execution.

  Calls the provider adapter, executes any returned tool calls via the
  capability registry, hands the results back through the adapter's
  continuation surface, and repeats until the adapter returns no more
  tool calls or the iteration cap is reached.

  Adapter dispatch is a deterministic function of `(provider, model,
  auth_mode, base_url)` — see `FermixCore.Providers.Adapter.for_route/1`.
  """

  require Logger

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Config
  alias FermixCore.Providers.Adapter
  alias FermixCore.Telemetry

  @max_iterations 25

  @type loop_opts :: [
          messages: [map()],
          capabilities: [Capability.t()],
          allowed_tools: [String.t()] | nil,
          policy: CapabilityRegistry.policy_spec(),
          trust: CapabilityRegistry.trust(),
          excluded_categories: [atom()] | nil,
          route_key: Adapter.route_key(),
          adapter_opts: keyword(),
          model: String.t(),
          temperature: float(),
          max_iterations: pos_integer(),
          compaction_enabled: boolean(),
          compaction_token_budget: pos_integer(),
          compaction_persist_checkpoints: boolean(),
          loop_detection_window: pos_integer(),
          loop_detection_warn_threshold: pos_integer(),
          loop_detection_kill_threshold: pos_integer(),
          activity_callback: (term() -> any()) | nil,
          context: map(),
          capability_registry: GenServer.server()
        ]

  @type loop_result :: %{
          response: String.t(),
          iterations: pos_integer(),
          total_tokens: non_neg_integer()
        }

  @spec run(loop_opts()) :: {:ok, loop_result()} | {:error, term()}
  def run(opts) do
    state = build_state(opts)

    case initial_chat(state) do
      {:ok, turn, state} -> continue_until_terminal(turn, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_state(opts) do
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    allowed_tools = Keyword.get(opts, :allowed_tools)
    policy = Keyword.get(opts, :policy)
    trust = Keyword.get(opts, :trust)
    excluded_categories = Keyword.get(opts, :excluded_categories)
    {adapter, route_key} = resolve_adapter(opts)
    context = Keyword.get(opts, :context, %{})

    {capabilities, capability_duration_us} =
      Telemetry.timed_us(fn ->
        opts
        |> Keyword.get(:capabilities)
        |> default_capabilities(capability_registry,
          allowed_tools: allowed_tools,
          policy: policy,
          trust: trust,
          excluded_categories: excluded_categories
        )
      end)

    emit_capability_selection_telemetry(capabilities, capability_duration_us, route_key, context, %{
      trust: trust,
      policy: policy,
      allowed_tools: allowed_tools,
      excluded_categories: excluded_categories
    })

    %{
      messages: Keyword.fetch!(opts, :messages),
      capabilities: capabilities,
      capabilities_by_name: index_by_name(capabilities),
      allowed_tools: allowed_tools,
      capability_registry: capability_registry,
      adapter: adapter,
      route_key: route_key,
      adapter_opts: build_adapter_opts(opts, route_key, context),
      max_iter: Keyword.get(opts, :max_iterations, @max_iterations),
      context: context,
      iteration: 0,
      total_tokens: 0,
      compaction: compaction_state(opts),
      loop_detector: loop_detector_state(opts),
      activity_callback: Keyword.get(opts, :activity_callback)
    }
  end

  defp index_by_name(capabilities) do
    Map.new(capabilities, fn %Capability{name: name} = capability -> {name, capability} end)
  end

  defp resolve_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      nil ->
        route_key = Keyword.fetch!(opts, :route_key)
        {Adapter.for_route(route_key), route_key}

      adapter when is_atom(adapter) ->
        route_key =
          Keyword.get(opts, :route_key, %{
            provider: :mock,
            model: Keyword.get(opts, :model, "mock"),
            auth_mode: :api_key,
            base_url: "mock://"
          })

        {adapter, route_key}
    end
  end

  defp default_capabilities(nil, registry, opts) do
    CapabilityRegistry.list_for(registry, opts)
  end

  defp default_capabilities(capabilities, _registry, _opts)
       when is_list(capabilities),
       do: capabilities

  defp emit_capability_selection_telemetry(capabilities, duration_us, route_key, context, opts) do
    :telemetry.execute(
      [:fermix, :capabilities, :select],
      %{
        duration_us: duration_us,
        count: length(capabilities),
        description_bytes: capability_description_bytes(capabilities)
      },
      %{
        agent: context_agent(context) || "unknown",
        provider: route_key.provider,
        model: route_key.model,
        trust: opts.trust,
        policy: opts.policy,
        allowed_tools_filtered: not is_nil(opts.allowed_tools),
        excluded_categories: opts.excluded_categories || [],
        kind_counts: capability_counts(capabilities, & &1.kind),
        policy_counts: capability_counts(capabilities, & &1.policy_class)
      }
    )
  end

  defp capability_description_bytes(capabilities) do
    Enum.reduce(capabilities, 0, fn %Capability{description: description}, total ->
      total + byte_size(description || "")
    end)
  end

  defp capability_counts(capabilities, key_fun) do
    capabilities
    |> Enum.frequencies_by(key_fun)
    |> Map.reject(fn {_key, count} -> count == 0 end)
  end

  defp build_adapter_opts(opts, route_key, context) do
    [
      model: route_key.model,
      base_url: route_key.base_url,
      temperature: Keyword.get(opts, :temperature, 0.7)
    ]
    |> maybe_put_adapter_opt(:agent, context_agent(context))
    |> Keyword.merge(Keyword.get(opts, :adapter_opts, []))
  end

  defp maybe_put_adapter_opt(opts, _key, nil), do: opts
  defp maybe_put_adapter_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp context_agent(%{agent_name: agent}) when is_binary(agent) or is_atom(agent), do: agent
  defp context_agent(_context), do: nil

  defp initial_chat(state) do
    with {:ok, state} <- compact_state_messages(state),
         start = System.monotonic_time(:millisecond),
         :ok <- emit_activity(state, :provider_start),
         {:ok, turn} <- state.adapter.chat(state.messages, state.capabilities, state.adapter_opts) do
      emit_activity(state, :provider_response)
      duration_ms = System.monotonic_time(:millisecond) - start
      emit_telemetry(state.iteration + 1, duration_ms, turn.tool_calls != [])

      {:ok, turn,
       %{
         state
         | iteration: state.iteration + 1,
           total_tokens: state.total_tokens + turn.usage.total_tokens
       }}
    else
      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp continue_until_terminal(%{tool_calls: []} = turn, state) do
    {:ok,
     %{
       response: turn.content,
       iterations: state.iteration,
       total_tokens: state.total_tokens
     }}
  end

  defp continue_until_terminal(_turn, %{iteration: i, max_iter: max}) when i >= max do
    {:error, "Maximum iterations (#{max}) reached"}
  end

  defp continue_until_terminal(turn, state) do
    case detect_tool_loop(turn.tool_calls, state) do
      {:kill, reason} ->
        {:error, reason}

      {warning, state} ->
        run_continuation(turn, state, warning)
    end
  end

  defp run_continuation(turn, state, warning) do
    case execute_tool_calls(turn.tool_calls, state) do
      {:ok, tool_results} ->
        case continuation_call(turn.provider_state, tool_results, warning, state) do
          {:ok, next_turn, state} -> continue_until_terminal(next_turn, state)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continuation_call(provider_state, tool_results, _warning, state) do
    start = System.monotonic_time(:millisecond)

    emit_activity(state, :provider_start)

    case state.adapter.continue(provider_state, tool_results, state.adapter_opts) do
      {:ok, next_turn} ->
        emit_activity(state, :provider_response)
        duration_ms = System.monotonic_time(:millisecond) - start
        emit_telemetry(state.iteration + 1, duration_ms, next_turn.tool_calls != [])

        {:ok, next_turn,
         %{
           state
           | iteration: state.iteration + 1,
             total_tokens: state.total_tokens + next_turn.usage.total_tokens
         }}

      {:error, reason} ->
        Logger.error("LLM continuation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_tool_calls(tool_calls, state) do
    with :ok <- enforce_channel_side_effect_bound(tool_calls, state) do
      results =
        Enum.map(tool_calls, fn tool_call ->
          output = run_tool_call(tool_call, state)
          %{call_id: tool_call.call_id, output: output}
        end)

      {:ok, results}
    end
  end

  defp enforce_channel_side_effect_bound(tool_calls, state) do
    count = Enum.count(tool_calls, &channel_side_effect_call?(&1, state))

    if count > 1 do
      {:error,
       "Multiple channel side-effect tool calls in one iteration are not allowed; " <>
         "retry with one channel send per iteration."}
    else
      :ok
    end
  end

  defp channel_side_effect_call?(%{name: name}, state) when is_binary(name) do
    capability_allowed?(name, state.allowed_tools) and channel_capability?(name, state)
  end

  defp channel_side_effect_call?(_tool_call, _state), do: false

  defp channel_capability?(name, state) do
    case Map.fetch(state.capabilities_by_name, name) do
      {:ok, %Capability{metadata: metadata}} -> Map.get(metadata, :category) == :channel
      :error -> false
    end
  end

  defp run_tool_call(%{name: name, arguments: arguments_raw}, state) do
    emit_activity(state, {:tool_start, name})

    case parse_arguments(arguments_raw) do
      {:ok, arguments} ->
        output = invoke_capability(name, arguments, state)
        emit_activity(state, {:tool_finish, name})
        output

      {:error, reason} ->
        emit_activity(state, {:tool_finish, name})
        reason
    end
  end

  defp invoke_capability(name, arguments, state) do
    if capability_allowed?(name, state.allowed_tools) do
      lookup_and_dispatch(name, arguments, state)
    else
      "Error: Tool '#{name}' not available"
    end
  end

  defp lookup_and_dispatch(name, arguments, state) do
    case Map.fetch(state.capabilities_by_name, name) do
      {:ok, capability} -> dispatch_capability(capability, arguments, state.context)
      :error -> "Error: Tool '#{name}' not found"
    end
  end

  defp capability_allowed?(_name, nil), do: true
  defp capability_allowed?(name, allowed) when is_list(allowed), do: name in allowed

  defp dispatch_capability(%Capability{} = capability, arguments, context) do
    case Capability.execute(capability, arguments, context) do
      {:ok, %{success: true, output: output}} ->
        output

      {:ok, %{success: false, error: error}} ->
        "Error: #{error}"

      {:ok, other} when is_binary(other) ->
        other

      {:ok, other} ->
        inspect(other)

      {:error, reason} ->
        "Error executing tool: #{inspect(reason)}"
    end
  rescue
    e -> "Error: tool raised #{Exception.message(e)}"
  end

  defp parse_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, args} -> {:ok, args}
      {:error, err} -> {:error, "Invalid JSON arguments: #{Exception.message(err)}"}
    end
  end

  defp parse_arguments(args) when is_map(args), do: {:ok, args}
  defp parse_arguments(_), do: {:ok, %{}}

  defp compact_state_messages(state) do
    opts = [
      enabled: state.compaction.enabled,
      token_budget: state.compaction.token_budget,
      persist_checkpoints: state.compaction.persist_checkpoints,
      cache: state.compaction.cache,
      route: {state.route_key, state.adapter_opts},
      context: state.context
    ]

    case Compactor.compact(state.messages, opts) do
      {:ok, result} ->
        compaction = %{state.compaction | cache: result.cache || state.compaction.cache}
        {:ok, %{state | messages: result.messages, compaction: compaction}}

      {:error, reason} ->
        Logger.error("Message compaction failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp detect_tool_loop(tool_calls, state) do
    signatures = Enum.map(tool_calls, &tool_signature/1)
    detector = update_detector(state.loop_detector, signatures)

    cond do
      detector.kill_signature ->
        {:kill, loop_kill_message(detector.kill_signature, detector.kill_threshold)}

      detector.warning ->
        {loop_warning_message(detector.warning, detector.warn_threshold),
         %{state | loop_detector: detector}}

      true ->
        {nil, %{state | loop_detector: detector}}
    end
  end

  defp update_detector(detector, signatures) do
    detector = %{detector | warning: nil, kill_signature: nil}

    Enum.reduce(signatures, detector, fn signature, current ->
      recent = Enum.take([signature | current.recent], current.window)
      count = Enum.count(recent, &(&1 == signature))
      warned = MapSet.member?(current.warned, signature)

      cond do
        count >= current.kill_threshold ->
          %{current | recent: recent, kill_signature: signature}

        count >= current.warn_threshold and not warned ->
          %{
            current
            | recent: recent,
              warning: signature,
              warned: MapSet.put(current.warned, signature)
          }

        true ->
          %{current | recent: recent}
      end
    end)
  end

  defp tool_signature(%{name: name, arguments: arguments}) do
    {name, normalize_arguments(arguments)}
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> normalize_arguments(decoded)
      {:error, _reason} -> arguments
    end
  end

  defp normalize_arguments(arguments) do
    Jason.encode!(sort_json(arguments))
  end

  defp sort_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), sort_json(value)} end)
  end

  defp sort_json(list) when is_list(list), do: Enum.map(list, &sort_json/1)
  defp sort_json(value), do: value

  defp loop_warning_message({name, arguments}, threshold) do
    "Repeated tool call warning: #{name} with #{arguments} has repeated #{threshold} times. " <>
      "Do not call it again unless the arguments or plan meaningfully change."
  end

  defp loop_kill_message({name, arguments}, threshold) do
    "Repeated tool call loop detected: #{name} with #{arguments} reached #{threshold} repeats"
  end

  defp compaction_state(opts) do
    [
      enabled: Keyword.get(opts, :compaction_enabled, Config.compaction_enabled?(opts)),
      token_budget:
        Keyword.get(opts, :compaction_token_budget, Config.compaction_token_budget(opts)),
      persist_checkpoints:
        Keyword.get(
          opts,
          :compaction_persist_checkpoints,
          Config.checkpoint_persistence_enabled?(opts)
        ),
      cache: nil
    ]
    |> Enum.into(%{})
  end

  defp loop_detector_state(opts) do
    warn =
      Keyword.get(
        opts,
        :loop_detection_warn_threshold,
        Config.loop_detection_warn_threshold(opts)
      )

    kill =
      Keyword.get(
        opts,
        :loop_detection_kill_threshold,
        Config.loop_detection_kill_threshold(opts)
      )

    %{
      recent: [],
      warned: MapSet.new(),
      warning: nil,
      kill_signature: nil,
      window: Keyword.get(opts, :loop_detection_window, Config.loop_detection_window(opts)),
      warn_threshold: warn,
      kill_threshold: max(kill, warn)
    }
  end

  defp emit_telemetry(iteration, duration_ms, has_tool_calls) do
    :telemetry.execute(
      [:fermix, :agent, :iteration],
      %{duration_ms: duration_ms},
      %{iteration: iteration, has_tool_calls: has_tool_calls}
    )
  end

  defp emit_activity(%{activity_callback: callback}, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  rescue
    error ->
      Logger.warning("AgentLoop activity callback raised: #{Exception.message(error)}")
      :ok
  end

  defp emit_activity(_state, _event), do: :ok
end
