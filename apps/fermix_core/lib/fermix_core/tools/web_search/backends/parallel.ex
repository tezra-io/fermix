defmodule FermixCore.Tools.WebSearch.Backends.Parallel do
  @moduledoc """
  Parallel Search API backend for web_search.
  """

  @behaviour FermixCore.Tools.WebSearch.Backend

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.WebSearch.Backends.Support

  @endpoint "https://api.parallel.ai/v1/search"
  @api_key :parallel_api_key
  @max_query_chars 200

  @impl true
  def name, do: :parallel

  @impl true
  def configured?(opts), do: Support.configured?(opts, @api_key)

  @impl true
  def search(query, opts) when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with :ok <- validate_query(query),
         {:ok, api_key} <- Support.credential(opts, @api_key, "Parallel API key") do
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

  defp validate_query(query) do
    if String.length(query) <= @max_query_chars do
      :ok
    else
      {:error, "query_too_long: Parallel search query max #{@max_query_chars} characters"}
    end
  end

  defp request_options(context, query, api_key) do
    Support.request_options(context,
      headers: [
        {"x-api-key", api_key},
        {"content-type", "application/json"}
      ],
      json: %{
        objective: "Find current, reliable web sources for: #{query}",
        search_queries: [query]
      }
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
        snippet: result |> Map.get("excerpts") |> Support.join_texts()
      }
    end)
  end

  defp parse_results(_body), do: {:error, "parser_changed: missing results array"}

  defp resolver(context), do: Map.get(context, :net_resolver, nil)
end
