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
       item, the tools list, and the original capabilities.
    2. `AgentLoop` executes returned tool calls.
    3. `continue/3` builds `input = prior_input ++ replayable output_items ++
       function_call_outputs` (with API-emitted `call_id`s) and posts again.
       Codex requires `store: false`, so continuation replays inline
       function calls/reasoning and strips response item ids that would
       require provider-side storage.

  Auth: a ChatGPT Plus OAuth bearer (Codex auth flow). The bearer's JWT
  payload may carry an account id under one of several claims; we extract
  it and forward as `chatgpt-account-id` when present.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Net.HttpClient
  alias FermixCore.Providers.OpenAI.Codex.SSEParser
  alias FermixCore.Providers.OpenAI.ResponsesShared

  require Logger

  @default_url "https://chatgpt.com/backend-api/codex/responses"
  @default_instructions "You are a helpful AI assistant."

  @impl true
  def chat(messages, capabilities, opts) when is_list(messages) and is_list(capabilities) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    auth = resolve_auth!(opts)
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    {instructions, input} = ResponsesShared.build_input(messages)
    resolved_instructions = instructions || @default_instructions
    tools = ResponsesShared.to_provider_tools(capabilities)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning = codex_reasoning(ResponsesShared.maybe_reasoning_field(reasoning_effort))
    include = codex_include(reasoning)
    text = text_field(opts)

    body =
      %{
        model: model,
        input: input,
        instructions: resolved_instructions,
        store: false,
        stream: true
      }
      |> maybe_put(:tools, tools)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:include, include)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: input,
      tools: tools,
      capabilities: capabilities,
      instructions: resolved_instructions,
      agent: Keyword.get(opts, :agent),
      reasoning_effort: reasoning_effort
    }

    post(url, body, auth, req_options, turn_state)
  end

  @impl true
  def continue(provider_state, tool_results, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    auth = resolve_auth!(opts)
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    %{
      input: prior_input,
      output_items: output_items,
      tools: tools,
      capabilities: caps,
      instructions: instructions
    } = provider_state

    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    reasoning = codex_reasoning(ResponsesShared.maybe_reasoning_field(reasoning_effort))
    include = codex_include(reasoning)
    text = text_field(opts)
    outputs = ResponsesShared.build_function_call_outputs(tool_results)
    next_input = prior_input ++ replayable_output_items(output_items) ++ outputs

    body =
      %{
        model: model,
        input: next_input,
        instructions: instructions,
        store: false,
        stream: true
      }
      |> maybe_put(:tools, tools)
      |> maybe_put(:reasoning, reasoning)
      |> maybe_put(:include, include)
      |> maybe_put(:text, text)

    turn_state = %{
      model: model,
      input: next_input,
      tools: tools,
      capabilities: caps,
      instructions: instructions,
      agent: Keyword.get(opts, :agent),
      reasoning_effort: reasoning_effort
    }

    post(url, body, auth, req_options, turn_state)
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

  defp post(url, body, auth, req_options, turn_state) do
    start = System.monotonic_time(:millisecond)

    result =
      request_once(url, body, auth.token, req_options)
      |> maybe_refresh_and_retry(url, body, auth, req_options)
      |> handle_response(turn_state)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, turn_state, duration_ms)
    result
  end

  # SSE responses are consumed via Req's `:into` callback so the parser
  # runs incrementally and `receive_timeout` measures gaps between
  # chunks, not the whole turn. Without this, `Req.request()` buffers the
  # entire SSE body and the default 15 s receive_timeout fires while
  # Codex is still reasoning, surfacing as a `:closed` transport error.
  # The HttpClient wrapper retries once on stale-pool transport errors
  # (`:closed`, `:econnrefused`) so the first request after macOS sleep
  # recovers transparently.
  defp request_once(url, body, token, req_options) do
    Req.new(
      url: url,
      method: :post,
      json: body,
      headers: build_headers(token),
      receive_timeout: 60_000,
      connect_options: [timeout: 5_000],
      into: &collect_sse/2
    )
    |> Req.merge(req_options)
    |> HttpClient.request("Codex")
    |> finalize_streamed_body()
  end

  defp collect_sse({:data, chunk}, {req, response}) when is_binary(chunk) do
    if response.status in 200..299 do
      state = current_sse_state(response) |> SSEParser.feed(chunk)
      {:cont, {req, Req.Response.put_private(response, :codex_sse_state, state)}}
    else
      body = ensure_binary_body(response.body)
      {:cont, {req, %{response | body: body <> chunk}}}
    end
  end

  defp current_sse_state(%{private: %{codex_sse_state: %SSEParser{} = state}}), do: state
  defp current_sse_state(_response), do: SSEParser.new()

  defp ensure_binary_body(body) when is_binary(body), do: body
  defp ensure_binary_body(_body), do: ""

  defp finalize_streamed_body({:ok, %Req.Response{private: private} = response}) do
    case Map.get(private, :codex_sse_state) do
      %SSEParser{} = state -> {:ok, %{response | body: SSEParser.finalize(state)}}
      nil -> {:ok, response}
    end
  end

  defp finalize_streamed_body(other), do: other

  defp maybe_refresh_and_retry(
         {:ok, %Req.Response{status: 401, body: response_body}} = response,
         url,
         request_body,
         %{refreshable?: true, token_server: token_server},
         req_options
       ) do
    if token_invalidated?(response_body) do
      Logger.warning("Codex bearer was invalidated; refreshing token and retrying once")

      case TokenManager.refresh(token_server) do
        {:ok, refreshed_token} ->
          request_once(url, request_body, refreshed_token, req_options)

        {:error, :auth_invalidated} ->
          {:auth_invalidated, response_body}

        {:error, reason} ->
          Logger.error("Codex token refresh after invalidation failed: #{inspect(reason)}")
          {:refresh_failed, reason}
      end
    else
      response
    end
  end

  defp maybe_refresh_and_retry(response, _url, _body, _auth, _req_options), do: response

  defp handle_response({:auth_invalidated, body}, _turn_state) do
    Logger.error("Codex auth invalidated and refresh exhausted: #{inspect(body)}")

    {:error,
     "Codex auth invalidated. Run `fermix auth login` to mint fresh tokens, " <>
       "then restart the daemon."}
  end

  defp handle_response({:refresh_failed, reason}, _turn_state) do
    Logger.error("Codex token refresh failed: #{inspect(reason)}")
    {:error, "Codex token refresh failed: #{inspect(reason)}"}
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
        provider_state =
          turn.provider_state
          |> Map.put(:instructions, turn_state.instructions)

        {:ok, %{turn | provider_state: provider_state}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: 404, body: body}}, _turn_state) do
    if unpersisted_item_error?(body) do
      {:error,
       "Codex requires store=false, and this continuation referenced a persisted response item id. " <>
         "Restart the request/server so Fermix can replay inline encrypted reasoning instead of stale item ids."}
    else
      log_api_error(404, body)
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _turn_state) do
    log_api_error(status, body)
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _turn_state) do
    Logger.error("Codex transport error: #{inspect(reason)}")
    {:error, transport_error_message(reason)}
  end

  defp handle_response({:error, reason}, _turn_state) do
    Logger.error("Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp transport_error_message(:closed) do
    "Codex stream closed by peer mid-response. Retry; if it persists, lower " <>
      "reasoning_effort or check ChatGPT account status."
  end

  defp transport_error_message(:timeout) do
    "Codex stream had no data for the configured receive_timeout. Lower " <>
      "reasoning_effort, raise [fermix_core.memory] extraction_timeout_ms " <>
      "(for extraction calls), or pass req_options: [receive_timeout: ms] " <>
      "to extend the between-chunk window."
  end

  defp transport_error_message(:econnrefused) do
    "Codex endpoint refused the connection (chatgpt.com unreachable from this host)."
  end

  defp transport_error_message(reason), do: "Codex transport error: #{inspect(reason)}"

  defp parse_body_to_map(body) when is_binary(body), do: SSEParser.parse(body)
  defp parse_body_to_map(body) when is_map(body), do: body
  defp parse_body_to_map(_), do: %{"output" => [], "usage" => %{}, "model" => nil}

  @account_id_claims ["account_id", "accountId", "sub", "https://api.openai.com/account_id"]

  defp decode_jwt_account_id(token) when is_binary(token) do
    case account_id_from_jwt(token) do
      {:ok, account_id} ->
        account_id

      {:error, reason} ->
        Logger.debug("Codex account id decode skipped: #{inspect(reason)}")
        nil
    end
  end

  defp account_id_from_jwt(token) do
    case String.split(token, ".") do
      [_, payload | _] -> account_id_from_payload(payload)
      _parts -> {:error, :missing_payload}
    end
  end

  defp account_id_from_payload(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, decoded} -> account_id_from_decoded_payload(decoded)
      :error -> {:error, :invalid_payload_base64}
    end
  end

  defp account_id_from_decoded_payload(decoded) do
    case Jason.decode(decoded) do
      {:ok, claims} -> account_id_from_claims(claims)
      {:error, reason} -> {:error, {:invalid_payload_json, reason}}
    end
  end

  defp account_id_from_claims(claims) when is_map(claims) do
    case Enum.find_value(@account_id_claims, &nonempty_string(claims[&1])) do
      nil -> {:error, :missing_account_id_claim}
      account_id -> {:ok, account_id}
    end
  end

  defp account_id_from_claims(_claims), do: {:error, :invalid_payload_claims}

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_), do: nil

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: [{key, value} | headers]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp text_field(opts) do
    case Keyword.get(opts, :text_format) do
      nil -> nil
      format -> %{format: format}
    end
  end

  defp codex_reasoning(nil), do: nil

  defp codex_reasoning(%{effort: _effort} = reasoning) do
    Map.put(reasoning, :summary, "auto")
  end

  defp codex_include(nil), do: nil
  defp codex_include(_reasoning), do: ["reasoning.encrypted_content"]

  defp replayable_output_items(output_items) do
    output_items
    |> Enum.flat_map(&replayable_output_item/1)
  end

  defp replayable_output_item(%{"type" => "function_call"} = item) do
    with call_id when is_binary(call_id) and call_id != "" <- item["call_id"],
         name when is_binary(name) and name != "" <- item["name"] do
      [
        %{
          "type" => "function_call",
          "call_id" => call_id,
          "name" => name,
          "arguments" => normalize_arguments(item["arguments"])
        }
      ]
    else
      _ -> []
    end
  end

  defp replayable_output_item(%{"type" => "reasoning"} = item) do
    case item["encrypted_content"] do
      encrypted when is_binary(encrypted) and encrypted != "" ->
        [
          %{
            "type" => "reasoning",
            "encrypted_content" => encrypted,
            "summary" => normalize_reasoning_summary(item["summary"])
          }
        ]

      _ ->
        []
    end
  end

  defp replayable_output_item(%{"type" => "message"} = item) do
    case message_text(item) do
      "" -> []
      text -> [%{"role" => "assistant", "content" => text}]
    end
  end

  defp replayable_output_item(_item), do: []

  defp normalize_arguments(arguments) when is_binary(arguments) and arguments != "", do: arguments
  defp normalize_arguments(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp normalize_arguments(_arguments), do: "{}"

  defp normalize_reasoning_summary(summary) when is_list(summary), do: summary
  defp normalize_reasoning_summary(_summary), do: []

  defp message_text(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp message_text(_item), do: ""

  defp resolve_auth!(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" ->
        %{token: token, refreshable?: false, token_server: nil}

      _ ->
        token_server = Keyword.get(opts, :token_server, TokenManager)

        case TokenManager.get_token(token_server) do
          {:ok, token} -> %{token: token, refreshable?: true, token_server: token_server}
          {:error, reason} -> raise ArgumentError, "Codex auth required: #{inspect(reason)}"
        end
    end
  end

  defp token_invalidated?(body) do
    body
    |> decode_error_body()
    |> get_in(["error", "code"])
    |> Kernel.==("token_invalidated")
  end

  defp decode_error_body(body) when is_map(body), do: body

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_error_body(_body), do: %{}

  defp unpersisted_item_error?(body) do
    body
    |> decode_error_body()
    |> get_in(["error", "message"])
    |> then(fn
      message when is_binary(message) ->
        String.contains?(message, "Items are not persisted") or
          String.contains?(message, "store` is set to false")

      _ ->
        false
    end)
  end

  defp log_api_error(status, body) do
    Logger.error("Codex Responses API error: #{status} - #{inspect(body)}")
    {:error, "Codex API error: #{status}"}
  end

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
        provider: :openai_codex,
        adapter: :codex,
        model: turn_state.model,
        status: status,
        tokens: tokens,
        reasoning_effort: Map.get(turn_state, :reasoning_effort)
      }
      |> maybe_put(:agent, Map.get(turn_state, :agent))
    )
  end
end
