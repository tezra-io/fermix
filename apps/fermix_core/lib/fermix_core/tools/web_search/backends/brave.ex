defmodule FermixCore.Tools.WebSearch.Backends.Brave do
  @moduledoc """
  Brave Web Search API backend for web_search.
  """

  @behaviour FermixCore.Tools.WebSearch.Backend

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.WebSearch.Backends.Support

  @endpoint "https://api.search.brave.com/res/v1/web/search"
  @api_key :brave_api_key
  @max_query_chars 400
  @max_query_words 50

  @impl true
  def name, do: :brave

  @impl true
  def configured?(opts), do: Support.configured?(opts, @api_key)

  @impl true
  def search(query, opts) when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with :ok <- validate_query(query),
         {:ok, api_key} <- Support.credential(opts, @api_key, "Brave API key") do
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
    cond do
      String.length(query) > @max_query_chars ->
        {:error, "query_too_long: Brave query max #{@max_query_chars} characters"}

      word_count(query) > @max_query_words ->
        {:error, "query_too_long: Brave query max #{@max_query_words} words"}

      true ->
        :ok
    end
  end

  defp request_options(context, query, api_key) do
    [
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 3_000],
      headers: [
        {"accept", "application/json"},
        {"accept-encoding", "gzip"},
        {"x-subscription-token", api_key}
      ],
      params: [q: query, count: 10, safesearch: "moderate"]
    ]
    |> Keyword.merge(Map.get(context, :req_options, []))
    |> Keyword.put(:redirect, false)
  end

  defp run_search(request_options, context) do
    with :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- get_search(request_options),
         {:ok, body} <- Support.response_json(response) do
      parse_results(body)
    end
  end

  defp get_search(request_options) do
    case Req.get(@endpoint, request_options) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, "network: #{inspect(reason)}"}
    end
  end

  defp parse_results(%{"web" => %{"results" => results}}) do
    Support.normalize_results(results, fn result ->
      %{
        title: Map.get(result, "title"),
        url: Map.get(result, "url"),
        snippet: snippet(result)
      }
    end)
  end

  defp parse_results(_body), do: {:error, "parser_changed: missing web.results array"}

  defp snippet(result) do
    result
    |> Map.get("extra_snippets")
    |> Support.join_texts()
    |> prefix_description(Map.get(result, "description"))
  end

  defp prefix_description("", description), do: Support.text(description)

  defp prefix_description(extra, description) do
    description
    |> Support.text()
    |> append_extra(extra)
  end

  defp append_extra("", extra), do: extra
  defp append_extra(description, extra), do: description <> " " <> extra

  defp word_count(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp resolver(context), do: Map.get(context, :net_resolver, nil)
end
