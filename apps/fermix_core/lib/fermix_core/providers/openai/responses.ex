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

  `call_id` always comes from the API. We fall back to a deterministic
  SHA256 hash only when the API response omits one — out-of-spec but
  observed in practice.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Capabilities.Capability

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

    {instructions, input} = build_input(messages)
    tools = to_provider_tools(capabilities)

    body =
      %{model: model, input: input, store: false}
      |> maybe_put(:instructions, instructions)
      |> maybe_put(:tools, tools)
      |> maybe_put(:temperature, temperature)

    post(base_url, bearer, body, req_options, model, input, tools, capabilities)
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

    outputs =
      Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
        %{type: "function_call_output", call_id: call_id, output: to_string(output)}
      end)

    next_input = prior_input ++ output_items ++ outputs

    body =
      %{model: model, input: next_input, store: false}
      |> maybe_put(:tools, tools)
      |> maybe_put(:temperature, temperature)

    post(base_url, bearer, body, req_options, model, next_input, tools, caps)
  end

  @impl true
  def to_provider_tools([]), do: []

  def to_provider_tools(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, fn %Capability{} = cap ->
      %{
        type: "function",
        name: cap.name,
        description: cap.description,
        parameters: cap.parameters,
        strict: false
      }
    end)
  end

  @impl true
  def parse_tool_calls(%{"output" => items}) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} -> normalize_tool_call(item, idx) end)
  end

  def parse_tool_calls(_), do: []

  @impl true
  def parse_response(body) when is_map(body) do
    {:ok, turn} =
      build_turn(body, body["model"] || "unknown", _input = [], _tools = [], _caps = [])

    turn
  end

  @impl true
  def supports_streaming?, do: false

  defp post(base_url, bearer, body, req_options, model, input, tools, capabilities) do
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
      |> handle_response(model, input, tools, capabilities)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms)
    result
  end

  defp handle_response(
         {:ok, %Req.Response{status: 200, body: body}},
         model,
         input,
         tools,
         capabilities
       )
       when is_map(body) do
    build_turn(body, model, input, tools, capabilities)
  end

  defp handle_response(
         {:ok, %Req.Response{status: status, body: body}},
         _model,
         _input,
         _tools,
         _caps
       ) do
    Logger.error("OpenAI Responses API error: #{status} - #{inspect(body)}")
    {:error, "OpenAI Responses API error: #{status}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _model, _i, _t, _c) do
    Logger.error("OpenAI Responses transport error: #{inspect(reason)}")
    {:error, reason}
  end

  defp handle_response({:error, reason}, _model, _i, _t, _c) do
    Logger.error("OpenAI Responses request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp build_turn(body, model, input, tools, capabilities) do
    output_items = Map.get(body, "output", [])
    usage = Map.get(body, "usage", %{})

    tool_calls =
      output_items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} -> normalize_tool_call(item, idx) end)

    {:ok,
     %{
       content: extract_text(output_items),
       tool_calls: tool_calls,
       provider_state: %{
         input: input,
         output_items: output_items,
         tools: tools,
         capabilities: capabilities
       },
       usage: %{
         prompt_tokens: Map.get(usage, "input_tokens", 0),
         completion_tokens: Map.get(usage, "output_tokens", 0),
         total_tokens: Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
       },
       model: Map.get(body, "model", model)
     }}
  end

  defp normalize_tool_call(%{"type" => "function_call"} = item, idx) do
    name = Map.get(item, "name", "")
    raw_args = Map.get(item, "arguments", "{}")
    id = Map.get(item, "id", "fc_#{idx}")
    call_id = Map.get(item, "call_id") || deterministic_call_id(name, raw_args, idx)

    [%{id: id, call_id: call_id, name: name, arguments: raw_args}]
  end

  defp normalize_tool_call(_item, _idx), do: []

  defp build_input(messages) do
    {system_parts, rest} = Enum.split_while(messages, fn msg -> msg.role == "system" end)

    instructions =
      case system_parts do
        [] -> nil
        parts -> Enum.map_join(parts, "\n\n", & &1.content)
      end

    input =
      Enum.map(rest, fn msg ->
        case msg.role do
          "user" ->
            %{role: "user", content: [%{type: "input_text", text: msg.content || ""}]}

          "assistant" ->
            %{role: "assistant", content: [%{type: "output_text", text: msg.content || ""}]}

          _ ->
            %{role: "user", content: [%{type: "input_text", text: msg.content || ""}]}
        end
      end)

    {instructions, input}
  end

  defp extract_text(items) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => parts} when is_list(parts) -> parts
      _ -> []
    end)
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => t} when is_binary(t) -> [t]
      %{"text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp deterministic_call_id(name, arguments, idx) do
    hash =
      :crypto.hash(:sha256, "#{name}:#{arguments}:#{idx}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "call_#{hash}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp emit_telemetry(result, model, duration_ms) do
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
      %{provider: :openai, adapter: :responses, model: model, status: status, tokens: tokens}
    )
  end
end
