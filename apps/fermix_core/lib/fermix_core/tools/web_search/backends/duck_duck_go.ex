defmodule FermixCore.Tools.WebSearch.Backends.DuckDuckGo do
  @moduledoc """
  DuckDuckGo HTML backend for keyless web_search.
  """

  @behaviour FermixCore.Tools.WebSearch.Backend

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.WebSearch.Backends.Support

  @endpoint "https://html.duckduckgo.com/html/"

  @impl true
  def name, do: :duckduckgo

  @impl true
  def configured?(_opts), do: true

  @impl true
  def search(query, opts) when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})
    request_options = request_options(context, query)
    trace_metadata = Support.trace_metadata(request_options)

    with :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- post_search(request_options),
         {:ok, results} <- parse_response(response) do
      {:ok, results, trace_metadata}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason, trace_metadata}
      {:error, reason} -> {:error, "network: #{inspect(reason)}", trace_metadata}
    end
  end

  def search(_query, _opts), do: {:error, "invalid_query", %{}}

  defp post_search(request_options) do
    case Req.post(@endpoint, request_options) do
      {:ok, %{status: status, body: body}} when status in [202, 429] ->
        {:ok, %{status: status, body: body}}

      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status}} ->
        {:error, "network: HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_options(context, query) do
    context
    |> base_request_options()
    |> Keyword.put(:form, q: query)
  end

  defp base_request_options(context) do
    [
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 3_000],
      headers: [{"user-agent", user_agent()}]
    ]
    |> Keyword.merge(Map.get(context, :req_options, []))
    |> Keyword.put(:redirect, false)
  end

  defp parse_response(%{status: status}) when status in [202, 429] do
    {:error, "rate_limited: DuckDuckGo returned HTTP #{status}"}
  end

  defp parse_response(%{body: body}) when is_binary(body) do
    if challenge?(body) do
      {:error, "rate_limited: DuckDuckGo returned a bot challenge"}
    else
      parse_html(body)
    end
  end

  defp parse_response(_response), do: {:error, "parser_changed: non-text response body"}

  defp parse_html(body) do
    with {:ok, doc} <- Floki.parse_document(body),
         results <- result_rows(doc) do
      cond do
        results != [] ->
          {:ok, results}

        empty_results?(doc) ->
          {:ok, []}

        true ->
          {:error, "parser_changed: DuckDuckGo result selectors changed"}
      end
    else
      {:error, reason} -> {:error, "parser_changed: #{inspect(reason)}"}
    end
  end

  defp result_rows(doc) do
    anchors = Floki.find(doc, ".result__title a.result__a")
    snippets = Floki.find(doc, ".result__snippet")

    anchors
    |> Enum.with_index()
    |> Enum.map(fn {anchor, index} ->
      %{
        title: anchor |> Floki.text() |> String.trim(),
        url: anchor |> href() |> unwrap_ddg_url(),
        snippet: snippets |> Enum.at(index) |> snippet_text()
      }
    end)
    |> Enum.reject(&(&1.title == "" or &1.url == ""))
  end

  defp href({_tag, attrs, _children}) do
    Enum.find_value(attrs, "", fn
      {"href", value} -> value
      _other -> nil
    end)
  end

  defp unwrap_ddg_url("/l/?" <> query) do
    query
    |> URI.decode_query()
    |> Map.get("uddg", "/l/?#{query}")
  end

  defp unwrap_ddg_url(url), do: url

  defp snippet_text(nil), do: ""

  defp snippet_text(node),
    do: node |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp empty_results?(doc), do: Floki.find(doc, ".no-results") != []

  defp challenge?(body) do
    downcased = String.downcase(body)

    String.contains?(downcased, "checking if the site connection is secure") or
      String.contains?(downcased, "captcha") or
      String.contains?(downcased, "anomaly")
  end

  defp resolver(context), do: Map.get(context, :net_resolver, nil)

  defp user_agent do
    "fermix/#{Application.spec(:fermix_core, :vsn) || "0.1.0"}"
  end
end
