defmodule FermixCore.Providers.OpenAI do
  @moduledoc """
  OpenAI provider. Supports Chat Completions API using API-key auth.
  """

  @behaviour FermixCore.Providers.Provider

  alias FermixCore.Net.HttpClient
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  require Logger

  @base_url "https://api.openai.com/v1"

  @doc false
  @spec default_model() :: String.t()
  def default_model do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :default_model, "gpt-4o")
      _ -> "gpt-4o"
    end
  end

  defp default_temperature do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :default_temperature, 0.7)
      _ -> 0.7
    end
  end

  @impl true
  @spec chat([FermixCore.Providers.Provider.chat_message()], keyword()) ::
          {:ok, FermixCore.Providers.Provider.response()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])

    case resolve_auth(opts) do
      {:ok, key, opts} ->
        do_completions_chat(messages, key, opts, req_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec models() :: {:ok, [String.t()]}
  def models do
    {:ok, ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex"]}
  end

  # --- Chat Completions (api_key mode) ---

  defp do_completions_chat(messages, key, opts, req_options) do
    model = Keyword.get(opts, :model, default_model())
    temperature = Keyword.get(opts, :temperature, default_temperature())
    tools = Keyword.get(opts, :tools)
    response_format = Keyword.get(opts, :response_format)
    url = Keyword.get(opts, :base_url, base_url())

    body =
      %{model: model, messages: format_messages(messages), temperature: temperature}
      |> maybe_add_tools(tools)
      |> maybe_add_response_format(response_format)

    start = System.monotonic_time(:millisecond)

    result =
      Req.new(
        url: "#{url}/chat/completions",
        method: :post,
        json: body,
        headers: [{"authorization", "Bearer #{key}"}]
      )
      |> Req.merge(req_options)
      |> HttpClient.request("OpenAI base")
      |> handle_completions_response()

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms, opts)
    result
  end

  defp handle_completions_response({:ok, %Req.Response{status: 200, body: body}}) do
    parse_completions_body(body)
  end

  defp handle_completions_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("OpenAI API error: #{status} - #{inspect(body)}")
    {:error, ProviderError.api(:openai, :chat_completions, status, body)}
  end

  defp handle_completions_response({:error, %Req.TransportError{reason: reason}}) do
    Logger.error("OpenAI request failed: #{inspect(reason)}")
    {:error, ProviderError.transport(:openai, :chat_completions, reason)}
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

  defp maybe_add_response_format(body, nil), do: body

  defp maybe_add_response_format(body, response_format),
    do: Map.put(body, :response_format, response_format)

  defp resolve_auth(opts) do
    {mode, opts} = Keyword.pop_lazy(opts, :auth_mode, &auth_mode/0)

    case mode do
      :oauth ->
        {:error, {:unsupported_auth_mode, :oauth}}

      :api_key ->
        {key, opts} = Keyword.pop_lazy(opts, :api_key, &api_key/0)

        if is_nil(key) or key == "" do
          {:error, :not_configured}
        else
          {:ok, key, opts}
        end

      other ->
        {:error, {:unsupported_auth_mode, other}}
    end
  end

  defp auth_mode do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :auth_mode, :api_key)
      _ -> :api_key
    end
  end

  defp emit_telemetry(result, model, duration_ms, opts) do
    {status, tokens, output, tool_calls, error_metadata} = telemetry_result(result)

    metadata =
      %{provider: :openai, model: model, status: status, tokens: tokens, reasoning_effort: nil}
      |> Map.merge(error_metadata)
      |> maybe_add_field(:agent, Keyword.get(opts, :agent))

    ProviderTelemetry.emit_call(metadata, duration_ms,
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      output: output,
      tool_calls: tool_calls
    )
  end

  defp telemetry_result({:ok, resp}) do
    {:ok, %{prompt: resp.usage.prompt_tokens, completion: resp.usage.completion_tokens},
     Map.get(resp, :content), Map.get(resp, :tool_calls), %{}}
  end

  defp telemetry_result({:error, reason}),
    do: {:error, %{}, nil, nil, ProviderError.telemetry_metadata(reason)}

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
end
