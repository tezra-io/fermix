defmodule FermixCore.Tools.WebSearch.Backends.Exa do
  @moduledoc """
  Exa Search API backend for web_search.
  """

  @behaviour FermixCore.Tools.WebSearch.Backend

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.WebSearch.Backends.Support

  @endpoint "https://api.exa.ai/search"
  @api_key :exa_api_key

  @impl true
  def name, do: :exa

  @impl true
  def configured?(opts), do: Support.configured?(opts, @api_key)

  @impl true
  def search(query, opts) when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, api_key} <- Support.credential(opts, @api_key, "Exa API key") do
      request_options = request_options(context, query, api_key)
      trace_metadata = Support.trace_metadata(request_options)

      case run_search(request_options, context) do
        {:ok, results} -> {:ok, results, trace_metadata}
        {:error, reason} -> {:error, Support.error_string(reason), trace_metadata}
      end
    else
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  def search(_query, _opts), do: {:error, "invalid_query", %{}}

  defp request_options(context, query, api_key) do
    [
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 3_000],
      headers: [
        {"x-api-key", api_key},
        {"content-type", "application/json"}
      ],
      json: %{
        query: query,
        numResults: 10,
        contents: %{highlights: true}
      }
    ]
    |> Keyword.merge(Map.get(context, :req_options, []))
    |> Keyword.put(:redirect, false)
  end

  defp run_search(request_options, context) do
    with :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- post_search(request_options),
         {:ok, body} <- Support.response_json(response) do
      parse_results(body)
    end
  end

  defp post_search(request_options) do
    case Req.post(@endpoint, request_options) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, "network: #{inspect(reason)}"}
    end
  end

  defp parse_results(%{"results" => results}) do
    Support.normalize_results(results, fn result ->
      %{
        title: Map.get(result, "title"),
        url: Map.get(result, "url"),
        snippet: snippet(result)
      }
    end)
  end

  defp parse_results(_body), do: {:error, "parser_changed: missing results array"}

  defp snippet(result) do
    result
    |> Map.get("highlights")
    |> Support.join_texts()
    |> fallback_text(Map.get(result, "text"))
  end

  defp fallback_text("", fallback), do: Support.text(fallback)
  defp fallback_text(value, _fallback), do: value

  defp resolver(context), do: Map.get(context, :net_resolver, nil)
end
