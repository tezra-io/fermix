defmodule FermixCore.Bench.MockProvider do
  @moduledoc """
  Deterministic provider adapter for benchmark runs.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Telemetry

  @default_model "bench-mock"

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    request(:chat, messages, capabilities, opts, 0)
  end

  @impl true
  def continue(provider_state, tool_results, opts) when is_map(provider_state) do
    messages = provider_state.messages ++ tool_messages(tool_results)
    capabilities = Map.get(provider_state, :capabilities, [])
    step = Map.get(provider_state, :step, 0) + 1

    request(:continue, messages, capabilities, opts, step)
  end

  @impl true
  def to_provider_tools(capabilities) when is_list(capabilities) do
    {tools, duration_us} =
      Telemetry.timed_us(fn ->
        Enum.map(capabilities, fn capability ->
          %{
            type: "function",
            name: capability.name,
            description: capability.description,
            parameters: capability.parameters
          }
        end)
      end)

    emit_tool_schema_telemetry(tools, capabilities, duration_us)
    tools
  end

  @impl true
  def parse_tool_calls(_response), do: []

  @impl true
  def parse_response(response), do: response

  @impl true
  def supports_streaming?, do: false

  defp request(kind, messages, capabilities, opts, step) do
    start = System.monotonic_time(:millisecond)
    # Build the provider tool schema on every mock request so the harness
    # records the same tool-schema conversion stage as real providers.
    _tools = to_provider_tools(capabilities)
    maybe_sleep(Keyword.get(opts, :bench_delay_ms, 0))
    result = {:ok, scripted_turn(kind, messages, capabilities, opts, step)}
    duration_ms = System.monotonic_time(:millisecond) - start
    emit_call_telemetry(result, duration_ms, opts)
    result
  end

  defp scripted_turn(kind, messages, capabilities, opts, step) do
    script = Keyword.get(opts, :bench_script, :text)

    case {script, kind, step} do
      {:tool_once, :chat, 0} -> tool_turn(messages, capabilities, step)
      {:repeat_tool, _kind, _step} -> tool_turn(messages, capabilities, step)
      _other -> text_turn(messages, capabilities, step, Keyword.get(opts, :bench_response, "bench final"))
    end
  end

  defp tool_turn(messages, capabilities, step) do
    %{
      content: "",
      tool_calls: [tool_call(step)],
      provider_state: provider_state(messages, capabilities, step),
      usage: usage(12, 4),
      model: @default_model
    }
  end

  defp text_turn(messages, capabilities, step, content) do
    %{
      content: content,
      tool_calls: [],
      provider_state: provider_state(messages, capabilities, step),
      usage: usage(10, 5),
      model: @default_model
    }
  end

  defp provider_state(messages, capabilities, step) do
    %{messages: messages, capabilities: capabilities, step: step}
  end

  defp tool_call(step) do
    id = "bench_call_#{step + 1}"

    %{
      id: id,
      call_id: id,
      name: "bench_echo",
      arguments: Jason.encode!(%{"text" => "bench tool output #{step + 1}"})
    }
  end

  defp tool_messages(tool_results) do
    Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
      %{role: "tool", tool_call_id: call_id, content: to_string(output)}
    end)
  end

  defp usage(prompt, completion) do
    %{prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion}
  end

  defp maybe_sleep(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp maybe_sleep(_ms), do: :ok

  defp emit_tool_schema_telemetry(tools, capabilities, duration_us) do
    :telemetry.execute(
      [:fermix, :provider, :tool_schema],
      %{
        duration_us: duration_us,
        tools_count: length(tools),
        capabilities_count: length(capabilities)
      },
      %{adapter: :bench_mock}
    )
  end

  defp emit_call_telemetry(result, duration_ms, opts) do
    :telemetry.execute(
      [:fermix, :provider, :call],
      %{duration_ms: duration_ms},
      %{
        provider: :bench,
        adapter: :bench_mock,
        model: Keyword.get(opts, :model, @default_model),
        status: call_status(result),
        tokens: %{},
        reasoning_effort: nil
      }
    )
  end

  defp call_status({:ok, _turn}), do: :ok
  defp call_status({:error, _reason}), do: :error
end
