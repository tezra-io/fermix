defmodule FermixCore.Tools.WebSearch do
  @moduledoc """
  Keyless DuckDuckGo HTML web search.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Net.Guard
  alias FermixCore.Tools.Support

  @endpoint "https://html.duckduckgo.com/html/"
  @max_query_length 1_024
  @max_results 10

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web using DuckDuckGo's keyless HTML results page."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["query"],
      properties: %{query: %{type: "string", description: "Search query, max 1024 chars."}}
    }
  end

  @impl true
  def when_to_use, do: "Search the current public web by query when no known URL is available."

  @impl true
  def examples, do: [%{args: %{"query" => "latest Elixir release"}, note: "search public web"}]

  @impl true
  def failure_modes do
    [
      %{tag: "query_too_long", description: "query exceeds 1024 characters"},
      %{tag: "rate_limited", description: "DuckDuckGo returned a challenge or rate limit"},
      %{
        tag: "parser_changed",
        description: "result selectors did not match and no empty marker was present"
      },
      %{tag: "network", description: "transport or HTTP failure"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :web

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), put_trace_metadata(context), fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, query} <- Support.required_string(args, "query"),
         :ok <- validate_query(query),
         :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- post_search(query, context) do
      parse_response(response)
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error("network: #{inspect(reason)}")
    end
  end

  defp validate_query(query) do
    if String.length(query) <= @max_query_length do
      :ok
    else
      {:error, "query_too_long: max #{@max_query_length} characters"}
    end
  end

  defp post_search(query, context) do
    case Req.post(@endpoint, request_options(context, query)) do
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
  end

  defp parse_response(%{status: status}) when status in [202, 429] do
    Support.error(
      "rate_limited: DuckDuckGo returned HTTP #{status}; pluggable backends are a future milestone."
    )
  end

  defp parse_response(%{body: body}) when is_binary(body) do
    if challenge?(body) do
      Support.error(
        "rate_limited: DuckDuckGo returned a bot challenge; pluggable backends are a future milestone."
      )
    else
      parse_html(body)
    end
  end

  defp parse_response(_response), do: Support.error("parser_changed: non-text response body")

  defp parse_html(body) do
    with {:ok, doc} <- Floki.parse_document(body),
         results <- result_rows(doc) do
      cond do
        results != [] ->
          results |> Enum.take(@max_results) |> Support.success_json()

        empty_results?(doc) ->
          Support.success_json([])

        true ->
          Support.error(
            "parser_changed: DuckDuckGo result selectors changed; pluggable backends are a future milestone."
          )
      end
    else
      {:error, reason} -> Support.error("parser_changed: #{inspect(reason)}")
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

  defp put_trace_metadata(context) do
    Map.put(context, :tool_trace, %{request_headers: redacted_request_headers(context)})
  end

  defp redacted_request_headers(context) do
    context
    |> base_request_options()
    |> Keyword.get(:headers, [])
    |> Guard.redact_headers_for_trace()
  end

  defp user_agent do
    "fermix/#{Application.spec(:fermix_core, :vsn) || "0.1.0"}"
  end
end
