defmodule FermixCore.Providers.OpenAI.ChatCompletions do
  @moduledoc """
  OpenAI Chat Completions adapter.

  Posts to `<base_url>/chat/completions` with the standard `tools: [{type:
  "function", function: {...}}]` shape. Used for OpenAI-compatible
  providers (OpenRouter, Together, Groq) and as the fallback for OpenAI
  models the Responses route doesn't claim.

  Continuation model: assistant messages carry `tool_calls`; results go
  back as `role: "tool"` messages keyed by `tool_call_id`. The same shape
  `Providers.OpenAI` has used since M1.

  `provider_state` carries only adapter-internal continuation data
  (messages history + capabilities). Opts (api_key, model, base_url) are
  re-passed by `AgentLoop` on every `continue/3` so secrets don't sit in
  per-turn state.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Net.HttpClient
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Telemetry

  require Logger

  @default_base_url "https://api.openai.com/v1"
  @default_temperature 0.7

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    request(messages, capabilities, opts)
  end

  @impl true
  def continue(
        %{messages: prior, assistant: assistant, capabilities: capabilities},
        tool_results,
        opts
      ) do
    tool_messages =
      Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
        %{role: "tool", tool_call_id: call_id, content: to_string(output)}
      end)

    next_messages = prior ++ [assistant] ++ tool_messages
    request(next_messages, capabilities, opts)
  end

  @impl true
  def to_provider_tools(capabilities) when is_list(capabilities) do
    {tools, duration_us} =
      Telemetry.timed_us(fn ->
        Enum.map(capabilities, fn %Capability{} = cap ->
          %{
            type: "function",
            function: %{
              name: cap.name,
              description: cap.description,
              parameters: cap.parameters
            }
          }
        end)
      end)

    emit_tool_schema_telemetry(tools, capabilities, duration_us)
    tools
  end

  @impl true
  def parse_tool_calls(%{"choices" => [%{"message" => %{"tool_calls" => calls}} | _]})
      when is_list(calls) do
    Enum.map(calls, &normalize_tool_call/1)
  end

  def parse_tool_calls(_), do: []

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} = build_turn(body, body["model"] || "unknown", [], [])
    turn
  end

  @impl true
  def supports_streaming?, do: false

  defp request(messages, capabilities, opts) do
    api_key = require_api_key!(opts)
    model = Keyword.fetch!(opts, :model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    response_format = Keyword.get(opts, :response_format)
    correlation = Keyword.take(opts, [:agent, :session_id, :parent_session])
    {req_options, _opts} = Keyword.pop(opts, :req_options, [])

    body =
      %{model: model, messages: format_messages(messages), temperature: temperature}
      |> maybe_put_tools(to_provider_tools(capabilities))
      |> maybe_put(:response_format, response_format)

    post(base_url, api_key, body, req_options, model, messages, capabilities, correlation)
  end

  defp post(
         base_url,
         api_key,
         body,
         req_options,
         model,
         prior_messages,
         capabilities,
         correlation
       ) do
    start = System.monotonic_time(:millisecond)

    result =
      Req.new(
        url: "#{base_url}/chat/completions",
        method: :post,
        json: body,
        headers: [{"authorization", "Bearer #{api_key}"}]
      )
      |> Req.merge(req_options)
      |> HttpClient.request("OpenAI ChatCompletions")
      |> handle_response(model, prior_messages, capabilities)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms, correlation)
    result
  end

  defp handle_response(
         {:ok, %Req.Response{status: 200, body: body}},
         model,
         prior_messages,
         capabilities
       ) do
    case body do
      %{"choices" => [_ | _]} ->
        build_turn(body, model, prior_messages, capabilities)

      _ ->
        Logger.error("Unexpected OpenAI Chat Completions response: #{inspect(body)}")
        {:error, "Unexpected response format"}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _model, _prior, _caps) do
    Logger.error("OpenAI Chat Completions error: #{status} - #{inspect(body)}")
    {:error, ProviderError.api(:openai, :chat_completions, status, body)}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _model, _prior, _caps) do
    Logger.error("OpenAI Chat Completions transport error: #{inspect(reason)}")
    {:error, ProviderError.transport(:openai, :chat_completions, reason)}
  end

  defp handle_response({:error, reason}, _model, _prior, _caps) do
    Logger.error("OpenAI Chat Completions request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp build_turn(
         %{"choices" => [choice | _], "usage" => usage},
         model,
         prior_messages,
         capabilities
       ) do
    message = choice["message"]
    raw_tool_calls = message["tool_calls"] || []
    normalized = Enum.map(raw_tool_calls, &normalize_tool_call/1)
    assistant_message = build_assistant_message(message, raw_tool_calls)

    {:ok,
     %{
       content: message["content"] || "",
       tool_calls: normalized,
       provider_state: %{
         messages: prior_messages,
         assistant: assistant_message,
         capabilities: capabilities
       },
       usage: %{
         prompt_tokens: usage["prompt_tokens"] || 0,
         completion_tokens: usage["completion_tokens"] || 0,
         total_tokens: usage["total_tokens"] || 0
       },
       model: choice["model"] || model
     }}
  end

  defp build_assistant_message(message, raw_tool_calls) do
    base = %{role: "assistant", content: message["content"] || ""}
    if raw_tool_calls == [], do: base, else: Map.put(base, :tool_calls, raw_tool_calls)
  end

  defp normalize_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, call_id: id, name: name, arguments: args}
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg.role, content: msg.content || ""}
      |> maybe_put_field(:tool_call_id, Map.get(msg, :tool_call_id))
      |> maybe_put_tool_calls(Map.get(msg, :tool_calls))
    end)
  end

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tool_calls(map, nil), do: map
  defp maybe_put_tool_calls(map, []), do: map
  defp maybe_put_tool_calls(map, calls) when is_list(calls), do: Map.put(map, :tool_calls, calls)
  defp maybe_put_tool_calls(map, _invalid), do: map

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, tools) when is_list(tools), do: Map.put(body, :tools, tools)
  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp emit_tool_schema_telemetry(tools, capabilities, duration_us) do
    :telemetry.execute(
      [:fermix, :provider, :tool_schema],
      %{
        duration_us: duration_us,
        tools_count: length(tools),
        capabilities_count: length(capabilities)
      },
      %{adapter: :chat_completions}
    )
  end

  defp require_api_key!(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> key
      _ -> raise ArgumentError, "OpenAI.ChatCompletions.chat/3 requires :api_key"
    end
  end

  defp emit_telemetry(result, model, duration_ms, correlation) do
    {status, tokens, output, tool_calls, error_metadata} =
      case result do
        {:ok, resp} ->
          {:ok, %{prompt: resp.usage.prompt_tokens, completion: resp.usage.completion_tokens},
           Map.get(resp, :content), Map.get(resp, :tool_calls), %{}}

        {:error, reason} ->
          {:error, %{}, nil, nil, ProviderError.telemetry_metadata(reason)}
      end

    metadata =
      %{
        provider: :openai,
        adapter: :chat_completions,
        model: model,
        status: status,
        tokens: tokens,
        reasoning_effort: nil
      }
      |> Map.merge(error_metadata)
      |> maybe_put(:agent, Keyword.get(correlation, :agent))

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: Keyword.get(correlation, :session_id),
      parent_session: Keyword.get(correlation, :parent_session),
      output: output,
      tool_calls: tool_calls
    )
  end
end
