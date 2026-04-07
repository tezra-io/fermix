defmodule FermixCore.AgentLoop do
  @moduledoc """
  Core LLM conversation loop with tool execution.

  Calls the LLM, checks for tool calls, executes them via the Registry,
  appends results, and loops until the LLM returns a final response
  or max_iterations is reached.
  """

  require Logger

  alias FermixCore.Providers.OpenAI
  alias FermixCore.Tools.Registry

  @max_iterations 25
  @max_context_messages 100

  @type loop_opts :: [
          messages: [map()],
          tools: [map()],
          allowed_tools: [String.t()] | nil,
          provider: module(),
          model: String.t(),
          temperature: float(),
          max_iterations: pos_integer(),
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
      total_tokens: 0
    }

    do_loop(state)
  end

  defp do_loop(%{iteration: i, max_iter: max} = _state) when i >= max do
    {:error, "Maximum iterations (#{max}) reached"}
  end

  defp do_loop(state) do
    state = %{state | messages: truncate_messages(state.messages)}
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

    tool_results =
      execute_tool_calls(
        response.tool_calls,
        state.context,
        state.registry,
        state.allowed_tools
      )

    assistant_message = %{
      role: "assistant",
      content: response.content,
      tool_calls: response.tool_calls
    }

    tool_messages =
      Enum.map(tool_results, fn {tool_call_id, content} ->
        %{role: "tool", tool_call_id: tool_call_id, content: content}
      end)

    do_loop(%{
      state
      | messages: state.messages ++ [assistant_message | tool_messages],
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

  defp truncate_messages(messages) when length(messages) <= @max_context_messages, do: messages

  defp truncate_messages(messages) do
    {system, rest} = Enum.split_while(messages, fn msg -> msg.role == "system" end)
    keep = @max_context_messages - length(system)
    system ++ Enum.take(rest, -keep)
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

  defp emit_telemetry(iteration, duration_ms, has_tool_calls) do
    :telemetry.execute(
      [:fermix, :agent, :iteration],
      %{duration_ms: duration_ms},
      %{iteration: iteration, has_tool_calls: has_tool_calls}
    )
  end
end
