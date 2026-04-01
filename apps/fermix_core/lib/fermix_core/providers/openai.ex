defmodule FermixCore.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API provider.
  Supports function calling (tool use).
  """

  @behaviour FermixCore.Providers.Provider

  require Logger

  @base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"
  @default_temperature 0.7

  @impl true
  @spec chat([FermixCore.Providers.Provider.chat_message()], keyword()) ::
          {:ok, FermixCore.Providers.Provider.response()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    {key, opts} = Keyword.pop_lazy(opts, :api_key, &api_key/0)
    {url, opts} = Keyword.pop_lazy(opts, :base_url, &base_url/0)
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    tools = Keyword.get(opts, :tools)

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
      |> handle_response()

    duration_ms = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, model, duration_ms)
    result
  end

  @impl true
  @spec models() :: {:ok, [String.t()]}
  def models do
    {:ok, ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]}
  end

  # -- internals --

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    parse_response(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("OpenAI API error: #{status} - #{inspect(body)}")
    {:error, "OpenAI API error: #{status}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}) do
    Logger.error("OpenAI request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp handle_response({:error, reason}) do
    Logger.error("OpenAI request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parse_response(%{"choices" => [choice | _], "usage" => usage}) do
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

  defp parse_response(response) do
    Logger.error("Unexpected OpenAI response format: #{inspect(response)}")
    {:error, "Unexpected response format"}
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg.role, content: msg.content}
      |> maybe_add_field(:tool_call_id, Map.get(msg, :tool_call_id))
      |> maybe_add_field(:tool_calls, Map.get(msg, :tool_calls))
    end)
  end

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools) when is_list(tools), do: Map.put(body, :tools, tools)

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
    {:ok, key} = FermixCore.Config.provider_api_key(:openai)
    key
  end

  defp base_url do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :base_url, @base_url)
      _ -> @base_url
    end
  end
end
