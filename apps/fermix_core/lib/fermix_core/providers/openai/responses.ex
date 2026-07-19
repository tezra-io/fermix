defmodule FermixCore.Providers.OpenAI.Responses do
  @moduledoc """
  OpenAI Responses API adapter — `api.openai.com/v1/responses`.

  The Responses API is item-list, not message-list. A response is
  `output: [item, item, ...]` and the next request is `input: [previous
  items + new items]`. Three item types matter:

  | Type                 | Direction  | Required fields                             |
  |----------------------|------------|---------------------------------------------|
  | `function_call`      | model → us | `call_id`, `name`, `arguments`, `id`        |
  | `function_call_output` | us → model | `call_id`, `output`                        |
  | `reasoning`          | model → us | `id`, `encrypted_content`                   |

  Continuation:
    1. `chat/3` posts initial `input` + `tools`. Returns `provider_state`
       holding the prior input, every output item, and the tools list.
    2. `AgentLoop` executes tool calls and hands results back to
       `continue/3`.
    3. `continue/3` builds next `input = prior_input ++ output_items ++
       function_call_outputs` and posts again. Reasoning items pass
       through `output_items` unchanged so the model can resume its
       chain of thought.

  Wire-shape conversion (tool list, item-list `input`, item-list
  `output` parsing, `call_id` fallback) lives in `OpenAI.ResponsesShared`
  and is shared with `OpenAI.Codex`. Only the URL, headers, and the
  fact that this surface is non-streaming differ here.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.OpenAI.ResponsesShared
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  require Logger

  @default_base_url "https://api.openai.com/v1"

  # No temperature: every model this adapter serves (the gpt-5 reasoning
  # family) rejects the param with a 400 "Unsupported parameter" — sampling
  # control on this API is the `reasoning` effort field. A caller-supplied
  # :temperature opt is deliberately ignored.

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, bearer} <- fetch_bearer_token(opts) do
      do_chat(messages, capabilities, bearer, req_options, opts)
    end
  end

  defp do_chat(messages, capabilities, bearer, req_options, opts) do
    model = Keyword.fetch!(opts, :model)
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    {instructions, input} = ResponsesShared.build_input(messages)
    tools = ResponsesShared.to_provider_tools(capabilities)
    invariant_metrics = ResponsesShared.invariant_metrics(tools, capabilities)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning = ResponsesShared.maybe_reasoning_field(reasoning_effort, :openai)
    text = text_field(opts)

    body =
      %{model: model, input: input, store: false}
      |> maybe_put(:instructions, instructions)
      |> maybe_put(:tools, tools)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: input,
      tools: tools,
      capabilities: capabilities,
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      reasoning_effort: reasoning_effort,
      invariant_metrics: invariant_metrics,
      request_metrics:
        Map.merge(ResponsesShared.input_metrics(input, instructions), invariant_metrics)
    }

    post(base_url, bearer, body, req_options, turn_state)
  end

  @impl true
  def continue(provider_state, tool_results, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    with {:ok, bearer} <- fetch_bearer_token(opts) do
      do_continue(provider_state, tool_results, bearer, req_options, opts)
    end
  end

  defp do_continue(provider_state, tool_results, bearer, req_options, opts) do
    model = Keyword.fetch!(opts, :model)
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    %{
      input: prior_input,
      output_items: output_items,
      tools: tools,
      capabilities: caps
    } = provider_state

    # invariant_metrics is precomputed once per turn in the chat/continue path
    # and carried in provider_state; recompute here only if an isolated caller
    # built the state without it (identical value — memoization, not a fallback).
    invariant_metrics =
      Map.get(provider_state, :invariant_metrics) ||
        ResponsesShared.invariant_metrics(tools, caps)

    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning = ResponsesShared.maybe_reasoning_field(reasoning_effort, :openai)
    text = text_field(opts)
    outputs = ResponsesShared.build_function_call_outputs(tool_results)

    next_input =
      (prior_input ++ output_items ++ outputs)
      |> ResponsesShared.retain_screenshots(Keyword.get(opts, :max_retained_screenshots))

    body =
      %{model: model, input: next_input, store: false}
      |> maybe_put(:tools, tools)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: next_input,
      tools: tools,
      capabilities: caps,
      agent: Keyword.get(opts, :agent),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      reasoning_effort: reasoning_effort,
      invariant_metrics: invariant_metrics,
      request_metrics:
        Map.merge(ResponsesShared.input_metrics(next_input, nil), invariant_metrics)
    }

    post(base_url, bearer, body, req_options, turn_state)
  end

  @impl true
  def to_provider_tools(capabilities), do: ResponsesShared.to_provider_tools(capabilities)

  @impl true
  def parse_tool_calls(response), do: ResponsesShared.parse_tool_calls(response)

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} = ResponsesShared.build_turn(body, body["model"] || "unknown", [], [], [])
    turn
  end

  @impl true
  def supports_streaming?, do: false

  defp post(base_url, bearer, body, req_options, turn_state) do
    start = System.monotonic_time(:millisecond)

    result =
      Req.new(
        url: "#{base_url}/responses",
        method: :post,
        json: body,
        receive_timeout: TimeoutPolicy.receive_timeout_for(:llm_buffered),
        headers: [
          {"authorization", "Bearer #{bearer}"},
          {"content-type", "application/json"}
        ]
      )
      |> Req.merge(req_options)
      |> HttpClient.request("OpenAI Responses")
      |> handle_response(turn_state)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, turn_state, duration_ms)
    result
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, turn_state)
       when is_map(body) do
    ResponsesShared.build_turn(
      body,
      turn_state.model,
      turn_state.input,
      turn_state.tools,
      turn_state.capabilities,
      turn_state.invariant_metrics
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    if ResponsesShared.context_length_error?(body) do
      {:error, :context_length_exceeded}
    else
      Logger.error("OpenAI Responses API error: #{status} - #{inspect(body)}")
      {:error, ProviderError.api(:openai, :responses, status, body)}
    end
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _turn_state) do
    Logger.error("OpenAI Responses transport error: #{inspect(reason)}")
    {:error, ProviderError.transport(:openai, :responses, reason)}
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("OpenAI Responses request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp text_field(opts) do
    case Keyword.get(opts, :text_format) do
      nil -> nil
      format -> %{format: format}
    end
  end

  defp fetch_bearer_token(opts) do
    cond do
      key = nonempty_string(Keyword.get(opts, :api_key)) ->
        {:ok, key}

      key = nonempty_string(Keyword.get(opts, :access_token)) ->
        {:ok, key}

      token_server = Keyword.get(opts, :token_server) ->
        bearer_from_token_server(token_server)

      true ->
        {:error,
         ProviderError.auth(
           :openai,
           :responses,
           "OpenAI.Responses requires :api_key, :access_token, or :token_server"
         )}
    end
  end

  defp bearer_from_token_server(token_server) do
    case TokenManager.get_token(token_server) do
      {:ok, token} ->
        {:ok, token}

      {:error, reason} ->
        {:error,
         ProviderError.auth(
           :openai,
           :responses,
           "OpenAI.Responses requires a bearer token: TokenManager returned #{inspect(reason)}"
         )}
    end
  end

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_), do: nil

  defp emit_telemetry(result, turn_state, duration_ms) do
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
        adapter: :responses,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        reasoning_effort: Map.get(turn_state, :reasoning_effort)
      }
      |> Map.merge(Map.get(turn_state, :request_metrics, %{}))
      |> Map.merge(error_metadata)
      |> maybe_put(:agent, Map.get(turn_state, :agent))

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: Map.get(turn_state, :session_id),
      parent_session: Map.get(turn_state, :parent_session),
      output: output,
      tool_calls: tool_calls
    )
  end
end
