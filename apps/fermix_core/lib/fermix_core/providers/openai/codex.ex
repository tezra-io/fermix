defmodule FermixCore.Providers.OpenAI.Codex do
  @moduledoc """
  OpenAI Codex adapter (ChatGPT Plus / OAuth path).

  Posts to `chatgpt.com/backend-api/codex/responses` with the SSE-streamed
  Codex Responses shape. Codex is a separate provider key (`:openai_codex`)
  because the URL, headers, and the fact that the surface is streaming
  diverge from the standard `api.openai.com/v1/responses` flow handled by
  `OpenAI.Responses`. The wire shape (item-list `input`, item-list
  `output`, `function_call`/`function_call_output` pairs keyed by
  `call_id`) is identical and lives in `OpenAI.ResponsesShared`.

  Codex tool-call flow:

    1. `chat/3` posts initial `input` + `tools` (`stream: true`) and
       consumes the SSE stream into a body-shaped map via `SSEParser`.
       Returns `provider_state` carrying the prior `input`, every output
       item, the tools list, and the original capabilities — same shape as
       `OpenAI.Responses`.
    2. `AgentLoop` executes returned tool calls.
    3. `continue/3` builds `input = prior_input ++ output_items ++
       function_call_outputs` (with API-emitted `call_id`s) and posts again.
       Reasoning items pass through unchanged.

  Auth: a ChatGPT Plus OAuth bearer (Codex auth flow). The bearer's JWT
  payload may carry an account id under one of several claims; we extract
  it and forward as `chatgpt-account-id` when present.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Providers.OpenAI.Codex.SSEParser
  alias FermixCore.Providers.OpenAI.ResponsesShared

  require Logger

  @default_url "https://chatgpt.com/backend-api/codex/responses"
  @default_instructions "You are a helpful AI assistant."

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    token = require_token!(opts)
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    {instructions, input} = ResponsesShared.build_input(messages)
    resolved_instructions = instructions || @default_instructions
    tools = ResponsesShared.to_provider_tools(capabilities)
    headers = build_headers(token)

    body =
      %{
        model: model,
        input: input,
        instructions: resolved_instructions,
        store: false,
        stream: true
      }
      |> maybe_put(:tools, tools)

    turn_state = %{
      model: model,
      input: input,
      tools: tools,
      capabilities: capabilities,
      instructions: resolved_instructions
    }

    post(url, body, headers, req_options, turn_state)
  end

  @impl true
  def continue(provider_state, tool_results, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    token = require_token!(opts)
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    %{
      input: prior_input,
      output_items: output_items,
      tools: tools,
      capabilities: caps,
      instructions: instructions
    } = provider_state

    outputs = ResponsesShared.build_function_call_outputs(tool_results)
    next_input = prior_input ++ output_items ++ outputs
    headers = build_headers(token)

    body =
      %{
        model: model,
        input: next_input,
        instructions: instructions,
        store: false,
        stream: true
      }
      |> maybe_put(:tools, tools)

    turn_state = %{
      model: model,
      input: next_input,
      tools: tools,
      capabilities: caps,
      instructions: instructions
    }

    post(url, body, headers, req_options, turn_state)
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
  def supports_streaming?, do: true

  defp build_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"openai-beta", "responses=experimental"},
      {"originator", "pi"},
      {"content-type", "application/json"}
    ]
    |> maybe_put_header("chatgpt-account-id", decode_jwt_account_id(token))
  end

  defp post(url, body, headers, req_options, turn_state) do
    start = System.monotonic_time(:millisecond)

    result =
      Req.new(url: url, method: :post, json: body, headers: headers)
      |> Req.merge(req_options)
      |> Req.request()
      |> handle_response(turn_state)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, turn_state.model, duration_ms)
    result
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, turn_state) do
    parsed = parse_body_to_map(body)

    case ResponsesShared.build_turn(
           parsed,
           turn_state.model,
           turn_state.input,
           turn_state.tools,
           turn_state.capabilities
         ) do
      {:ok, turn} ->
        {:ok, put_in(turn, [:provider_state, :instructions], turn_state.instructions)}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    Logger.error("Codex Responses API error: #{status} - #{inspect(body)}")
    {:error, "Codex API error: #{status}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _turn_state) do
    Logger.error("Codex transport error: #{inspect(reason)}")
    {:error, reason}
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parse_body_to_map(body) when is_binary(body), do: SSEParser.parse(body)
  defp parse_body_to_map(body) when is_map(body), do: body
  defp parse_body_to_map(_), do: %{"output" => [], "usage" => %{}, "model" => nil}

  @account_id_claims ["account_id", "accountId", "sub", "https://api.openai.com/account_id"]

  defp decode_jwt_account_id(token) when is_binary(token) do
    with [_, payload | _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      Enum.find_value(@account_id_claims, &nonempty_string(claims[&1]))
    else
      _ -> nil
    end
  end

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_), do: nil

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: [{key, value} | headers]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp require_token!(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        token_server = Keyword.get(opts, :token_server, TokenManager)

        case TokenManager.get_token(token_server) do
          {:ok, token} -> token
          {:error, reason} -> raise ArgumentError, "Codex auth required: #{inspect(reason)}"
        end
    end
  end

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
      %{provider: :openai_codex, adapter: :codex, model: model, status: status, tokens: tokens}
    )
  end
end
