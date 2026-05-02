defmodule FermixCore.Tools.MemoryRecall do
  @moduledoc """
  Recall a previously stored fact from memory.
  If key is omitted, returns all memories for the conversation.

  Lexical recall intentionally defaults to `scope: "current"` and
  `source: "memories"` so agent tool calls stay local and fact-focused unless
  they explicitly request owner/global scope or message history. This is
  narrower than `FermixCore.Memory.Search.query/2`, whose raw API defaults are
  broad for internal callers.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Search
  alias FermixCore.Memory.Store

  @impl true
  @spec name() :: String.t()
  def name, do: "memory_recall"

  @impl true
  @spec description() :: String.t()
  def description do
    "Recall a previously stored fact from the agent's long-term memory."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        key: %{
          type: "string",
          description: "The key of the memory to recall. If omitted, returns all memories."
        },
        search: %{
          type: "string",
          description: "Keyword or phrase search over durable memories and/or history."
        },
        scope: %{
          type: "string",
          enum: ["current", "owner", "all"],
          description:
            "Search scope for lexical recall. Defaults to current; raw Search.query/2 defaults to all."
        },
        source: %{
          type: "string",
          enum: ["memories", "history", "all"],
          description:
            "Which durable source to search. Defaults to memories; raw Search.query/2 defaults to all."
        }
      }
    }
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")

    result = do_execute(args, context)

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{tool: "memory_recall", agent: agent, success: success}
    )

    result
  end

  defp do_execute(%{"search" => search} = args, context) when is_binary(search) do
    lexical_search(search, args, context)
  end

  defp do_execute(%{"key" => key}, context) do
    case Map.fetch(context, :conversation_key) do
      {:ok, conv_key} ->
        server = Map.get(context, :memory_store, Store)

        case Store.recall(conv_key, key, server: server) do
          {:ok, value} -> {:ok, Tool.success(value)}
          {:error, :not_found} -> {:ok, Tool.error("No memory found for key: #{key}")}
        end

      :error ->
        {:ok, Tool.error("Missing conversation context")}
    end
  end

  defp do_execute(_args, context) do
    case Map.fetch(context, :conversation_key) do
      {:ok, conv_key} -> recall_all(conv_key, context)
      :error -> {:ok, Tool.error("Missing conversation context")}
    end
  end

  defp recall_all(conv_key, context) do
    server = Map.get(context, :memory_store, Store)
    memories = Store.recall_all(conv_key, server: server)

    if map_size(memories) == 0 do
      {:ok, Tool.success("No memories stored for this conversation.")}
    else
      output = Enum.map_join(memories, "\n", fn {k, v} -> "#{k}: #{v}" end)
      {:ok, Tool.success(output)}
    end
  end

  defp lexical_search(search, args, context) do
    opts =
      [
        repo: Map.get(context, :memory_repo, Repo),
        source: Map.get(args, "source", "memories"),
        scope: Map.get(args, "scope", "current"),
        limit: 10,
        agent_id: Map.get(context, :memory_agent_id, Config.agent_id()),
        owner_id: Map.get(context, :memory_owner_id, Config.owner_id())
      ]
      |> maybe_put_conversation_key(context)

    case run_search(search, opts) do
      {:ok, []} ->
        {:ok, Tool.success("No lexical matches found for: #{search}")}

      {:ok, results} ->
        {:ok, Tool.success(Enum.map_join(results, "\n", &format_search_result/1))}

      {:error, message} ->
        {:ok, Tool.error(message)}
    end
  end

  defp run_search(search, opts) do
    {:ok, Search.query(search, opts)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
    error in RuntimeError -> {:error, Exception.message(error)}
  end

  defp maybe_put_conversation_key(opts, context) do
    case Map.fetch(context, :conversation_key) do
      {:ok, conversation_key} -> Keyword.put(opts, :conversation_key, conversation_key)
      :error -> opts
    end
  end

  defp format_search_result(%{source: :memories} = result) do
    "[memories rank=#{format_rank(result.rank)}] scope=#{result.scope_type} " <>
      "key=#{result.key} category=#{result.category} value=#{result.value}"
  end

  defp format_search_result(%{source: :messages} = result) do
    "[history rank=#{format_rank(result.rank)}] channel=#{result.channel} " <>
      "thread=#{result.thread_scope} role=#{result.role} kind=#{result.kind} " <>
      "content=#{result.content}"
  end

  defp format_rank(rank) when is_float(rank) do
    :erlang.float_to_binary(rank, decimals: 4)
  end
end
