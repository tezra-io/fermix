defmodule FermixCore.Tools.ToolSearch do
  @moduledoc """
  Search the deferred tool catalog by capability (M10 §3.1/§3.3).

  Scores BM25 at query time directly over the live capability registry — no
  prebuilt index, nothing to invalidate. The corpus per tool is its name
  (tokenized), description, and top-level parameter names; schema bodies are
  excluded as ranking noise. A literal name-substring fallback guards the
  zero-IDF degenerate case (e.g. query "github" when every deferred tool
  contains "github").
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.Support

  @default_limit 5
  @max_limit 20
  @description_cap 400
  @bm25_k1 1.5
  @bm25_b 0.75

  @impl true
  def name, do: "tool_search"

  @impl true
  def description do
    "Search the deferred plugin/MCP tool catalog by capability; returns matching tool names."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["query"],
      properties: %{
        query: %{
          type: "string",
          description: "What the tool should do, e.g. \"post to X\" or \"search notion pages\"."
        },
        limit: %{
          type: "integer",
          description: "Max results (default #{@default_limit}, max #{@max_limit})."
        }
      }
    }
  end

  @impl true
  def when_to_use,
    do: "Discover a deferred plugin/MCP tool by what it does when its name is not already known."

  @impl true
  def examples,
    do: [%{args: %{"query" => "create a github issue"}, note: "find the issue-creation tool"}]

  @impl true
  def failure_modes do
    [
      %{tag: "missing_query", description: "query is absent or blank"},
      %{tag: "no_matches", description: "empty matches list — vary the query terms"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, query} <- Support.required_string(args, "query") do
      registry = Map.get(context, :capability_registry, Registry)
      limit = clamp_limit(Map.get(args, "limit"))
      catalog = deferred_catalog(registry)
      matches = search(query, catalog, limit)

      emit_query_telemetry(query, matches, catalog, context)

      {:ok,
       Tool.success(
         Jason.encode!(%{
           query: query,
           total_available: length(catalog),
           matches: Enum.map(matches, &render_match/1)
         })
       )}
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_limit), do: @default_limit

  # The catalog is read from the registry at query time (stateless — M10
  # freshness guarantee): the search surface is always exactly the live
  # deferred set.
  defp deferred_catalog(registry) do
    registry
    |> Registry.list_for([])
    |> Enum.filter(&Deferral.deferred?/1)
  end

  defp render_match({%Capability{} = capability, _score}) do
    %{
      name: capability.name,
      plugin: capability_owner(capability),
      description: String.slice(capability.description || "", 0, @description_cap)
    }
  end

  defp capability_owner(%Capability{kind: :mcp}), do: "mcp"

  defp capability_owner(%Capability{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :plugin, "plugin")

  defp capability_owner(_capability), do: "plugin"

  # --- BM25, inlined (no deps, ~30 lines) ---

  defp search(query, catalog, limit) do
    query_tokens = tokenize(query)
    docs = Enum.map(catalog, fn cap -> {cap, doc_tokens(cap)} end)
    avg_len = average_length(docs)

    scored =
      docs
      |> Enum.map(fn {cap, tokens} ->
        {cap, bm25_score(query_tokens, tokens, docs, avg_len)}
      end)
      |> Enum.filter(fn {_cap, score} -> score > 0 end)

    case scored do
      [] -> substring_fallback(query, catalog, limit)
      scored -> scored |> Enum.sort_by(fn {_cap, score} -> -score end) |> Enum.take(limit)
    end
  end

  defp doc_tokens(%Capability{} = capability) do
    tokenize(capability.name) ++
      tokenize(capability.description || "") ++ param_name_tokens(capability.parameters)
  end

  defp param_name_tokens(%{} = parameters) do
    properties = Map.get(parameters, :properties) || Map.get(parameters, "properties") || %{}
    properties |> Map.keys() |> Enum.flat_map(&tokenize(to_string(&1)))
  end

  defp param_name_tokens(_parameters), do: []

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp average_length([]), do: 1.0

  defp average_length(docs) do
    total = Enum.reduce(docs, 0, fn {_cap, tokens}, acc -> acc + length(tokens) end)
    max(total / length(docs), 1.0)
  end

  defp bm25_score(query_tokens, doc_tokens, docs, avg_len) do
    doc_len = length(doc_tokens)
    frequencies = Enum.frequencies(doc_tokens)

    query_tokens
    |> Enum.uniq()
    |> Enum.reduce(0.0, fn term, acc ->
      tf = Map.get(frequencies, term, 0)

      if tf == 0 do
        acc
      else
        idf = inverse_doc_frequency(term, docs)
        norm = @bm25_k1 * (1 - @bm25_b + @bm25_b * doc_len / avg_len)
        acc + idf * (tf * (@bm25_k1 + 1)) / (tf + norm)
      end
    end)
  end

  defp inverse_doc_frequency(term, docs) do
    df = Enum.count(docs, fn {_cap, tokens} -> term in tokens end)
    n = length(docs)
    :math.log((n - df + 0.5) / (df + 0.5) + 1)
  end

  # Zero-IDF guard: when BM25 has no positive scores (a term present in every
  # doc carries no signal), fall back to literal name-substring matching.
  defp substring_fallback(query, catalog, limit) do
    needle = String.downcase(query)

    catalog
    |> Enum.filter(fn cap -> String.contains?(String.downcase(cap.name), needle) end)
    |> Enum.take(limit)
    |> Enum.map(fn cap -> {cap, 0.1} end)
  end

  defp emit_query_telemetry(query, matches, catalog, context) do
    top_score =
      case matches do
        [{_cap, score} | _rest] -> score
        [] -> 0.0
      end

    :telemetry.execute(
      [:fermix, :tool_search, :query],
      %{match_count: length(matches), catalog_size: length(catalog), top_score: top_score},
      %{query: query, agent: Map.get(context, :agent_name, "unknown")}
    )
  end
end
