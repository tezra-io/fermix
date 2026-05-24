defmodule FermixCore.Tools.WebSearch do
  @moduledoc """
  Search the web using the configured backend.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Tools.Support
  alias FermixCore.Tools.WebSearch.Backends.Brave
  alias FermixCore.Tools.WebSearch.Backends.DuckDuckGo
  alias FermixCore.Tools.WebSearch.Backends.Exa
  alias FermixCore.Tools.WebSearch.Backends.Parallel
  alias FermixCore.Tools.WebSearch.Backends.Perplexity
  alias FermixCore.Tools.WebSearch.Backends.Tavily

  @backend_modules %{
    brave: Brave,
    duckduckgo: DuckDuckGo,
    exa: Exa,
    parallel: Parallel,
    perplexity: Perplexity,
    tavily: Tavily
  }
  @backend_names Map.keys(@backend_modules)
  @max_query_length 1_024
  @max_results 10

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web using the configured backend."

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
      %{tag: "auth_failed", description: "configured backend credential is missing or invalid"},
      %{tag: "rate_limited", description: "search provider returned a challenge or rate limit"},
      %{tag: "provider_error", description: "search provider returned an unexpected HTTP error"},
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
    Support.run(name(), Map.delete(context, :tool_trace), fn -> do_execute(args, context) end)
  end

  @doc """
  Resolves the active backend `{name, module}` from the given (or current)
  `[fermix_core.tools.web_search]` config. Exposed for `fermix doctor`.
  """
  @spec active_backend(keyword()) :: {atom(), module()}
  def active_backend(config \\ config()) do
    name = config |> lookup(:backend) |> normalize_backend_name()
    {name, backend_module(name)}
  end

  @doc """
  Returns the resolved `[fermix_core.tools.web_search]` config keyword.
  """
  @spec config() :: keyword()
  def config, do: web_search_config()

  defp do_execute(args, context) do
    config = config()
    {backend_name, backend} = active_backend(config)

    with {:ok, query} <- Support.required_string(args, "query"),
         :ok <- validate_query(query),
         {:ok, results, backend_trace} <- backend.search(query, backend_opts(config, context)) do
      trimmed = Enum.take(results, @max_results)
      metadata = Map.merge(backend_trace, result_metadata(backend.name(), length(trimmed)))
      Support.success_json(trimmed, metadata)
    else
      {:error, reason, backend_trace} -> error_result(reason, backend_name, backend_trace)
      {:error, reason} -> error_result(reason, backend_name, %{})
    end
  end

  defp validate_query(query) do
    if String.length(query) <= @max_query_length do
      :ok
    else
      {:error, "query_too_long: max #{@max_query_length} characters"}
    end
  end

  defp backend_module(name), do: Map.get(@backend_modules, name, DuckDuckGo)

  defp web_search_config do
    tools = Application.get_env(:fermix_core, :tools, [])

    if is_list(tools), do: Keyword.get(tools, :web_search, []), else: []
  end

  defp backend_opts(config, context), do: Keyword.put(config, :context, context)

  defp lookup(config, key) when is_list(config), do: Keyword.get(config, key)
  defp lookup(_config, _key), do: nil

  defp normalize_backend_name(name) when is_atom(name) do
    if name in @backend_names, do: name, else: :duckduckgo
  end

  defp normalize_backend_name(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase()

    @backend_names
    |> Enum.find(:duckduckgo, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_backend_name(_name), do: :duckduckgo

  defp result_metadata(backend_name, result_count) do
    %{backend: Atom.to_string(backend_name), result_count: result_count}
  end

  defp error_result(reason, backend_name, trace_metadata) do
    {:ok, result} = Support.error(format_error(reason))
    {:ok, result, Map.put(trace_metadata, :backend, Atom.to_string(backend_name))}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "network: #{inspect(reason)}"
end
