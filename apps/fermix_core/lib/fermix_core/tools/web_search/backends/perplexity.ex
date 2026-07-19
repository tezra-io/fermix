defmodule FermixCore.Tools.WebSearch.Backends.Perplexity do
  @moduledoc """
  Perplexity Search API backend for web_search.
  """

  @behaviour FermixCore.Tools.WebSearch.Backend

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.WebSearch.Backends.Support

  @endpoint "https://api.perplexity.ai/search"
  @api_key :perplexity_api_key

  @impl true
  def name, do: :perplexity

  @impl true
  def configured?(opts), do: Support.configured?(opts, @api_key)

  @impl true
  def search(query, opts) when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, api_key} <- Support.credential(opts, @api_key, "Perplexity API key") do
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
    Support.request_options(context,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ],
      json: %{query: query, max_results: 10, max_tokens_per_page: 512}
    )
  end

  defp run_search(request_options, context) do
    with :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- Support.request(:post, @endpoint, request_options),
         {:ok, body} <- Support.response_json(response) do
      parse_results(body)
    end
  end

  defp parse_results(%{"results" => results}) do
    Support.normalize_results(results, fn result ->
      %{
        title: Map.get(result, "title"),
        url: Map.get(result, "url"),
        snippet: Map.get(result, "snippet")
      }
    end)
  end

  defp parse_results(_body), do: {:error, "parser_changed: missing results array"}

  defp resolver(context), do: Map.get(context, :net_resolver, nil)
end
