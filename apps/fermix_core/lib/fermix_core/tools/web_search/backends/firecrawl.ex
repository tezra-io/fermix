defmodule FermixCore.Tools.WebSearch.Backends.Firecrawl do
  @moduledoc """
  Firecrawl Search API backend for web_search.

  Cloud Firecrawl only, snippet-only: requests `sources: ["web"]` with no
  `scrapeOptions`, so each call costs the base search credits and the response
  stays on the documented nested `data.web` shape. Richer scrape output
  (markdown/links) is intentionally not requested — `web_search` returns the
  shared `{title, url, snippet}` shape.
  """

  @behaviour FermixCore.Tools.WebSearch.Backend

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.WebSearch.Backends.Support

  @endpoint "https://api.firecrawl.dev/v2/search"
  @api_key :firecrawl_api_key
  @max_query_chars 500

  @impl true
  def name, do: :firecrawl

  @impl true
  def configured?(opts), do: Support.configured?(opts, @api_key)

  @impl true
  def search(query, opts) when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with :ok <- validate_query(query),
         {:ok, api_key} <- Support.credential(opts, @api_key, "Firecrawl API key") do
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

  # Firecrawl rejects a query over 500 chars with a 400. Pre-validate so an
  # over-length query surfaces as a non-degradable `query_too_long` instead of a
  # provider 400 that web_search would degrade to DuckDuckGo. Mirrors Brave.
  defp validate_query(query) do
    if String.length(query) <= @max_query_chars do
      :ok
    else
      {:error, "query_too_long: Firecrawl query max #{@max_query_chars} characters"}
    end
  end

  defp request_options(context, query, api_key) do
    Support.request_options(context,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ],
      # No scrapeOptions: snippet-only, base credits, authoritative nested shape.
      json: %{query: query, sources: ["web"], limit: 10}
    )
  end

  defp run_search(request_options, context) do
    with :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- Support.request(:post, @endpoint, request_options),
         {:ok, body} <- Support.response_json(response) do
      parse_results(body)
    end
  end

  defp parse_results(%{"data" => %{"web" => results}}) do
    Support.normalize_results(results, fn result ->
      %{
        title: Map.get(result, "title"),
        url: Map.get(result, "url"),
        snippet: Map.get(result, "description")
      }
    end)
  end

  defp parse_results(_body), do: {:error, "parser_changed: missing data.web array"}

  defp resolver(context), do: Map.get(context, :net_resolver, nil)
end
