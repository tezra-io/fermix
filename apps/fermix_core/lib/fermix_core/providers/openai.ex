defmodule FermixCore.Providers.OpenAI do
  @moduledoc """
  OpenAI provider. Supports Chat Completions API (api_key mode)
  and Codex Responses API (oauth mode via chatgpt.com).
  """

  @behaviour FermixCore.Providers.Provider

  alias FermixCore.Auth.TokenManager

  require Logger

  @base_url "https://api.openai.com/v1"
  @responses_url "https://chatgpt.com/backend-api/codex/responses"
  @default_model "gpt-4o-mini"
  @default_temperature 0.7

  @impl true
  @spec chat([FermixCore.Providers.Provider.chat_message()], keyword()) ::
          {:ok, FermixCore.Providers.Provider.response()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    case resolve_auth(opts) do
      {:ok, key, :oauth, opts} ->
        do_responses_chat(messages, key, opts, req_options)

      {:ok, key, :api_key, opts} ->
        do_completions_chat(messages, key, opts, req_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec models() :: {:ok, [String.t()]}
  def models do
    {:ok, ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]}
  end

  # --- Chat Completions (api_key mode) ---

  defp do_completions_chat(messages, key, opts, req_options) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    tools = Keyword.get(opts, :tools)
    url = Keyword.get(opts, :base_url, base_url())

    body =
      %{model: model, messages: format_messages(messages), temperature: temperature}
      |> maybe_add_tools(tools)

    start = System.monotonic_time(:millisecond)

    result =
      Req.new(
        url: "#{url}/chat/completions",
        method: :post,
        json: body,
        headers: [{"authorization", "Bearer #{key}"}]
      )
      |> Req.merge(req_options)
      |> Req.request()
      |> handle_completions_response()

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms)
    result
  end

  defp handle_completions_response({:ok, %Req.Response{status: 200, body: body}}) do
    parse_completions_body(body)
  end

  defp handle_completions_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("OpenAI API error: #{status} - #{inspect(body)}")
    {:error, "OpenAI API error: #{status}"}
  end

  defp handle_completions_response({:error, %Req.TransportError{reason: reason}}) do
    Logger.error("OpenAI request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp handle_completions_response({:error, reason}) do
    Logger.error("OpenAI request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parse_completions_body(%{"choices" => [choice | _], "usage" => usage}) do
    message = choice["message"]

    {:ok,
     %{
       content: message["content"] || "",
       tool_calls: message["tool_calls"] || [],
       usage: %{
         prompt_tokens: usage["prompt_tokens"] || 0,
         completion_tokens: usage["completion_tokens"] || 0,
         total_tokens: usage["total_tokens"] || 0
       },
       model: choice["model"] || "unknown"
     }}
  end

  defp parse_completions_body(response) do
    Logger.error("Unexpected OpenAI response format: #{inspect(response)}")
    {:error, "Unexpected response format"}
  end

  # --- Responses API (oauth mode) ---

  defp do_responses_chat(messages, key, opts, req_options) do
    model = Keyword.get(opts, :model, @default_model)
    url = Keyword.get(opts, :responses_url, responses_url())
    {instructions, input} = build_responses_input(messages)
    account_id = decode_jwt_account_id(key)

    body = %{
      model: model,
      input: input,
      instructions: instructions,
      store: false,
      stream: false
    }

    headers =
      [
        {"authorization", "Bearer #{key}"},
        {"openai-beta", "responses=experimental"},
        {"originator", "pi"},
        {"content-type", "application/json"}
      ]
      |> maybe_add_header("chatgpt-account-id", account_id)

    start = System.monotonic_time(:millisecond)

    result =
      Req.new(url: url, method: :post, json: body, headers: headers)
      |> Req.merge(req_options)
      |> Req.request()
      |> handle_responses_response(model)

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms)
    result
  end

  defp build_responses_input(messages) do
    {system_parts, rest} =
      Enum.split_with(messages, fn msg -> msg.role == "system" end)

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

  defp handle_responses_response({:ok, %Req.Response{status: 200, body: body}}, model) do
    parse_responses_body(body, model)
  end

  defp handle_responses_response({:ok, %Req.Response{status: status, body: body}}, _model) do
    Logger.error("Codex Responses API error: #{status} - #{inspect(body)}")
    {:error, "Codex API error: #{status}"}
  end

  defp handle_responses_response({:error, %Req.TransportError{reason: reason}}, _model) do
    Logger.error("Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp handle_responses_response({:error, reason}, _model) do
    Logger.error("Codex request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parse_responses_body(body, model) when is_map(body) do
    text = extract_responses_text(body)
    usage = body["usage"] || %{}

    {:ok,
     %{
       content: text || "",
       tool_calls: [],
       usage: %{
         prompt_tokens: usage["input_tokens"] || 0,
         completion_tokens: usage["output_tokens"] || 0,
         total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
       },
       model: body["model"] || model
     }}
  end

  defp parse_responses_body(body, model) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_responses_body(decoded, model)
      {:error, _} -> {:error, "Failed to parse Codex response"}
    end
  end

  defp parse_responses_body(_body, _model), do: {:error, "Unexpected Codex response format"}

  defp extract_responses_text(%{"output_text" => text}) when is_binary(text) and text != "" do
    text
  end

  defp extract_responses_text(%{"output" => output}) when is_list(output) do
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

  defp extract_responses_text(_), do: nil

  defp decode_jwt_account_id(token) when is_binary(token) do
    with [_, payload | _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      find_account_id(claims)
    else
      _ -> nil
    end
  end

  defp find_account_id(claims) do
    Enum.find_value(
      ["account_id", "accountId", "sub", "https://api.openai.com/account_id"],
      fn key ->
        case claims[key] do
          id when is_binary(id) and id != "" -> id
          _ -> nil
        end
      end
    )
  end

  defp maybe_add_header(headers, _key, nil), do: headers
  defp maybe_add_header(headers, key, value), do: [{key, value} | headers]

  # --- Shared helpers ---

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg.role, content: msg.content || ""}
      |> maybe_add_field(:tool_call_id, Map.get(msg, :tool_call_id))
      |> maybe_add_tool_calls(Map.get(msg, :tool_calls))
    end)
  end

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_tool_calls(map, nil), do: map
  defp maybe_add_tool_calls(map, []), do: map
  defp maybe_add_tool_calls(map, calls) when is_list(calls), do: Map.put(map, :tool_calls, calls)
  defp maybe_add_tool_calls(map, _invalid), do: map

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools) when is_list(tools), do: Map.put(body, :tools, tools)

  defp resolve_auth(opts) do
    {mode, opts} = Keyword.pop_lazy(opts, :auth_mode, &auth_mode/0)

    case mode do
      :oauth ->
        {_, opts} = Keyword.pop(opts, :api_key)
        token_server = Keyword.get(opts, :token_server, TokenManager)

        case TokenManager.get_token(token_server) do
          {:ok, token} -> {:ok, token, :oauth, opts}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {key, opts} = Keyword.pop_lazy(opts, :api_key, &api_key/0)

        if is_nil(key) or key == "" do
          {:error, :not_configured}
        else
          {:ok, key, :api_key, opts}
        end
    end
  end

  defp auth_mode do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :auth_mode, :api_key)
      _ -> :api_key
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
      %{provider: :openai, model: model, status: status, tokens: tokens}
    )
  end

  defp api_key do
    case FermixCore.Config.provider_api_key(:openai) do
      {:ok, key} -> key
      {:error, _} -> nil
    end
  end

  defp base_url do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :base_url, @base_url)
      _ -> @base_url
    end
  end

  defp responses_url do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :responses_url, @responses_url)
      _ -> @responses_url
    end
  end
end
