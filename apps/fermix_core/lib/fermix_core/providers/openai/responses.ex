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
  alias FermixCore.Providers.OpenAI.ResponsesShared

  require Logger

  @default_base_url "https://api.openai.com/v1"
  @default_temperature 0.7

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    bearer = require_bearer_token!(opts)
    model = Keyword.fetch!(opts, :model)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    temperature = Keyword.get(opts, :temperature, @default_temperature)

    {instructions, input} = ResponsesShared.build_input(messages)
    tools = ResponsesShared.to_provider_tools(capabilities)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning = ResponsesShared.maybe_reasoning_field(reasoning_effort)
    text = text_field(opts)

    body =
      %{model: model, input: input, store: false}
      |> maybe_put(:instructions, instructions)
      |> maybe_put(:tools, tools)
      |> maybe_put(:temperature, temperature)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: input,
      tools: tools,
      capabilities: capabilities,
      reasoning_effort: reasoning_effort
    }

    post(base_url, bearer, body, req_options, turn_state)
  end

  @impl true
  def continue(provider_state, tool_results, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    bearer = require_bearer_token!(opts)
    model = Keyword.fetch!(opts, :model)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    temperature = Keyword.get(opts, :temperature, @default_temperature)

    %{input: prior_input, output_items: output_items, tools: tools, capabilities: caps} =
      provider_state

    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning = ResponsesShared.maybe_reasoning_field(reasoning_effort)
    text = text_field(opts)
    outputs = ResponsesShared.build_function_call_outputs(tool_results)
    next_input = prior_input ++ output_items ++ outputs

    body =
      %{model: model, input: next_input, store: false}
      |> maybe_put(:tools, tools)
      |> maybe_put(:temperature, temperature)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: next_input,
      tools: tools,
      capabilities: caps,
      reasoning_effort: reasoning_effort
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
        headers: [
          {"authorization", "Bearer #{bearer}"},
          {"content-type", "application/json"}
        ]
      )
      |> Req.merge(req_options)
      |> Req.request()
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
      turn_state.capabilities
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    Logger.error("OpenAI Responses API error: #{status} - #{inspect(body)}")
    {:error, "OpenAI Responses API error: #{status}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _turn_state) do
    Logger.error("OpenAI Responses transport error: #{inspect(reason)}")
    {:error, reason}
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

  defp require_bearer_token!(opts) do
    cond do
      key = nonempty_string(Keyword.get(opts, :api_key)) ->
        key

      key = nonempty_string(Keyword.get(opts, :access_token)) ->
        key

      token_server = Keyword.get(opts, :token_server) ->
        case TokenManager.get_token(token_server) do
          {:ok, token} ->
            token

          {:error, reason} ->
            raise ArgumentError,
                  "OpenAI.Responses requires a bearer token: TokenManager returned #{inspect(reason)}"
        end

      true ->
        raise ArgumentError,
              "OpenAI.Responses requires :api_key, :access_token, or :token_server"
    end
  end

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_), do: nil

  defp emit_telemetry(result, turn_state, duration_ms) do
    {status, tokens} =
      case result do
        {:ok, resp} ->
          {:ok, %{prompt: resp.usage.prompt_tokens, completion: resp.usage.completion_tokens}}

        {:error, _} ->
          {:error, %{}}
      end

    :telemetry.execute(
      [:fermix, :provider, :call],
      %{duration_ms: duration_ms},
      %{
        provider: :openai,
        adapter: :responses,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        reasoning_effort: Map.get(turn_state, :reasoning_effort)
      }
    )
  end
end
