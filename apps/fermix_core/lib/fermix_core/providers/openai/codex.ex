defmodule FermixCore.Providers.OpenAI.Codex do
  @moduledoc """
  OpenAI Codex adapter (ChatGPT Plus / OAuth path).

  Posts to `chatgpt.com/backend-api/codex/responses` with the SSE-streamed
  Codex Responses shape. Codex is a separate provider key (`:openai_codex`)
  because the URL, request body, response shape, and streaming surface
  diverge from the standard `api.openai.com/v1/responses` flow handled by
  `OpenAI.Responses`.

  Tool calls are not yet supported on the Codex surface — the model
  returns text only. `to_provider_tools/1` returns `[]`; `chat/3` ignores
  the capabilities list. When tool calls are needed, route to
  `OpenAI.Responses` instead.
  """

  @behaviour FermixCore.Providers.Adapter

  alias FermixCore.Auth.TokenManager

  require Logger

  @default_url "https://chatgpt.com/backend-api/codex/responses"

  @impl true
  def chat(messages, _capabilities, opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    token = require_token!(opts)
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :base_url, @default_url)

    {instructions, input} = build_input(messages)
    account_id = decode_jwt_account_id(token)

    body = %{
      model: model,
      input: input,
      instructions: instructions,
      store: false,
      stream: true
    }

    headers =
      [
        {"authorization", "Bearer #{token}"},
        {"openai-beta", "responses=experimental"},
        {"originator", "pi"},
        {"content-type", "application/json"}
      ]
      |> maybe_put_header("chatgpt-account-id", account_id)

    post(url, body, headers, req_options, model)
  end

  @impl true
  def continue(_provider_state, _tool_results, _opts) do
    {:error, :tool_calls_not_supported_on_codex}
  end

  @impl true
  def to_provider_tools(_capabilities), do: []

  @impl true
  def parse_tool_calls(_response), do: []

  @impl true
  def parse_response(_body) do
    %{content: "", tool_calls: [], provider_state: %{}, usage: zero_usage(), model: "unknown"}
  end

  @impl true
  def supports_streaming?, do: true

  defp post(url, body, headers, req_options, model) do
    start = System.monotonic_time(:millisecond)

    result =
      Req.new(url: url, method: :post, json: body, headers: headers)
      |> Req.merge(req_options)
      |> Req.request()
      |> handle_response(model)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms)
    result
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, model) do
    {text, usage, parsed_model} = parse_body(body)

    {:ok,
     %{
       content: text || "",
       tool_calls: [],
       provider_state: %{},
       usage: %{
         prompt_tokens: usage["input_tokens"] || 0,
         completion_tokens: usage["output_tokens"] || 0,
         total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
       },
       model: parsed_model || model
     }}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _model) do
    Logger.error("Codex Responses API error: #{status} - #{inspect(body)}")
    {:error, "Codex API error: #{status}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _model) do
    Logger.error("Codex transport error: #{inspect(reason)}")
    {:error, reason}
  end

  defp handle_response({:error, reason}, _model) do
    Logger.error("Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parse_body(body) when is_binary(body) do
    events = parse_sse_events(body)
    {text, completed} = extract_from_events(events)
    {text, extract_usage(completed), completed && completed["model"]}
  end

  defp parse_body(body) when is_map(body) do
    {extract_text(body), body["usage"] || %{}, body["model"]}
  end

  defp parse_body(_body), do: {nil, %{}, nil}

  defp build_input(messages) do
    {system_parts, rest} = Enum.split_while(messages, fn msg -> msg.role == "system" end)

    instructions =
      case system_parts do
        [] -> "You are a helpful AI assistant."
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

  defp parse_sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(&parse_sse_chunk/1)
  end

  defp parse_sse_chunk(chunk) do
    chunk
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.flat_map(&decode_sse_line/1)
  end

  defp decode_sse_line("data: [DONE]"), do: []

  defp decode_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, event} -> [event]
      _ -> []
    end
  end

  defp extract_from_events(events) do
    {deltas, completed_response} =
      Enum.reduce(events, {"", nil}, fn
        %{"type" => "response.output_text.delta", "delta" => d}, {acc, c} ->
          {acc <> d, c}

        %{"type" => t} = e, {acc, nil} when t in ["response.completed", "response.done"] ->
          {acc, e["response"]}

        _, acc ->
          acc
      end)

    text =
      if deltas != "" do
        deltas
      else
        case completed_response do
          %{} -> extract_text(completed_response)
          _ -> nil
        end
      end

    {text, completed_response}
  end

  defp extract_usage(%{"usage" => usage}), do: usage
  defp extract_usage(_), do: %{}

  defp extract_text(%{"output_text" => text}) when is_binary(text) and text != "", do: text

  defp extract_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"content" => contents} when is_list(contents) -> contents
      _ -> []
    end)
    |> Enum.find_value(fn
      %{"type" => "output_text", "text" => t} when is_binary(t) and t != "" -> t
      %{"text" => t} when is_binary(t) and t != "" -> t
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil

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

  defp zero_usage, do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

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
