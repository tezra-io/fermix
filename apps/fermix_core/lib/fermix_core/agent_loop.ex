defmodule FermixCore.AgentLoop do
  @moduledoc """
  Core LLM conversation loop with tool execution.

  Calls the LLM, checks for tool calls, executes them via the Registry,
  appends results, and loops until the LLM returns a final response
  or max_iterations is reached.
  """

  require Logger

  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Config
  alias FermixCore.Providers.OpenAI
  alias FermixCore.Tools.Registry

  @max_iterations 25

  @type loop_opts :: [
          messages: [map()],
          tools: [map()],
          allowed_tools: [String.t()] | nil,
          provider: module(),
          model: String.t(),
          temperature: float(),
          max_iterations: pos_integer(),
          compaction_enabled: boolean(),
          compaction_token_budget: pos_integer(),
          compaction_persist_checkpoints: boolean(),
          loop_detection_window: pos_integer(),
          loop_detection_warn_threshold: pos_integer(),
          loop_detection_kill_threshold: pos_integer(),
          context: map(),
          registry: GenServer.server()
        ]

  @type loop_result :: %{
          response: String.t(),
          iterations: pos_integer(),
          total_tokens: non_neg_integer()
        }

  @spec run(loop_opts()) :: {:ok, loop_result()} | {:error, term()}
  def run(opts) do
    allowed_tools = Keyword.get(opts, :allowed_tools)

    state = %{
      messages: Keyword.fetch!(opts, :messages),
      tools: filter_tools_for_llm(Keyword.get(opts, :tools, []), allowed_tools),
      allowed_tools: allowed_tools,
      provider: Keyword.get(opts, :provider, OpenAI),
      model: Keyword.get(opts, :model, OpenAI.default_model()),
      temp: Keyword.get(opts, :temperature, 0.7),
      max_iter: Keyword.get(opts, :max_iterations, @max_iterations),
      context: Keyword.get(opts, :context, %{}),
      registry: Keyword.get(opts, :registry, Registry),
      iteration: 0,
      total_tokens: 0,
      compaction: compaction_state(opts),
      loop_detector: loop_detector_state(opts)
    }

    do_loop(state)
  end

  defp do_loop(%{iteration: i, max_iter: max} = _state) when i >= max do
    {:error, "Maximum iterations (#{max}) reached"}
  end

  defp do_loop(state) do
    with {:ok, state} <- compact_state_messages(state) do
      start = System.monotonic_time(:millisecond)

      case call_provider(state) do
        {:ok, response} ->
          duration_ms = System.monotonic_time(:millisecond) - start
          handle_response(response, duration_ms, state)

        {:error, reason} ->
          Logger.error("LLM call failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp call_provider(state) do
    state.provider.chat(state.messages,
      model: state.model,
      temperature: state.temp,
      tools: state.tools
    )
  end

  defp handle_response(%{tool_calls: tc} = response, duration_ms, state)
       when tc == nil or tc == [] do
    emit_telemetry(state.iteration + 1, duration_ms, false)

    {:ok,
     %{
       response: response.content,
       iterations: state.iteration + 1,
       total_tokens: state.total_tokens + response.usage.total_tokens
     }}
  end

  defp handle_response(response, duration_ms, state) do
    emit_telemetry(state.iteration + 1, duration_ms, true)

    case detect_tool_loop(response.tool_calls, state) do
      {:kill, reason} ->
        {:error, reason}

      {warning, state} ->
        continue_with_tool_calls(response, state, warning)
    end
  end

  defp continue_with_tool_calls(response, state, warning) do
    tool_results =
      execute_tool_calls(response.tool_calls, state.context, state.registry, state.allowed_tools)

    assistant_message = %{
      role: "assistant",
      content: response.content,
      tool_calls: response.tool_calls
    }

    tool_messages =
      Enum.map(tool_results, fn {tool_call_id, content} ->
        %{role: "tool", tool_call_id: tool_call_id, content: content}
      end)

    next_messages =
      [assistant_message | tool_messages]
      |> maybe_append_loop_warning(warning)

    do_loop(%{
      state
      | messages: state.messages ++ next_messages,
        iteration: state.iteration + 1,
        total_tokens: state.total_tokens + response.usage.total_tokens
    })
  end

  defp execute_tool_calls(tool_calls, context, registry, allowed_tools) do
    Enum.map(tool_calls, fn tool_call ->
      function = tool_call["function"]

      result =
        case parse_arguments(function["arguments"]) do
          {:ok, arguments} ->
            execute_tool(registry, function["name"], arguments, context, allowed_tools)

          {:error, reason} ->
            reason
        end

      {tool_call["id"], result}
    end)
  end

  defp parse_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, args} -> {:ok, args}
      {:error, err} -> {:error, "Invalid JSON arguments: #{Exception.message(err)}"}
    end
  end

  defp parse_arguments(args) when is_map(args), do: {:ok, args}
  defp parse_arguments(_), do: {:ok, %{}}

  defp execute_tool(registry, name, arguments, context, allowed_tools) do
    case Registry.find_tool(registry, name, allowed_tools) do
      {:ok, tool_module} -> run_tool(tool_module, arguments, context)
      {:error, :not_allowed} -> "Error: Tool '#{name}' not available"
      :error -> "Error: Tool '#{name}' not found"
    end
  end

  defp run_tool(tool_module, arguments, context) do
    case tool_module.execute(arguments, context) do
      {:ok, result} -> if result.success, do: result.output, else: "Error: #{result.error}"
      {:error, reason} -> "Error executing tool: #{inspect(reason)}"
    end
  rescue
    e -> "Error: tool raised #{Exception.message(e)}"
  end

  defp compact_state_messages(state) do
    opts = [
      enabled: state.compaction.enabled,
      token_budget: state.compaction.token_budget,
      persist_checkpoints: state.compaction.persist_checkpoints,
      cache: state.compaction.cache,
      provider: state.provider,
      model: state.model,
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

  defp filter_tools_for_llm(tools, nil), do: tools

  defp filter_tools_for_llm(tools, allowed_tools) when is_list(allowed_tools) do
    Enum.filter(tools, fn tool ->
      case tool_name_for_llm(tool) do
        {:ok, name} -> name in allowed_tools
        :error -> false
      end
    end)
  end

  defp tool_name_for_llm(%{function: %{name: name}}) when is_binary(name), do: {:ok, name}
  defp tool_name_for_llm(%{"function" => %{"name" => name}}) when is_binary(name), do: {:ok, name}
  defp tool_name_for_llm(_tool), do: :error

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

  defp tool_signature(tool_call) do
    function = tool_call["function"] || tool_call[:function] || %{}
    name = function["name"] || function[:name] || "unknown"
    arguments = function["arguments"] || function[:arguments] || %{}

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

  defp maybe_append_loop_warning(messages, nil), do: messages

  defp maybe_append_loop_warning(messages, warning) do
    messages ++ [%{role: "system", content: warning}]
  end

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
end
