defmodule FermixCore.Tools.MemoryRecall do
  @moduledoc """
  Recall a previously stored fact from memory.
  If key is omitted, returns all memories for the conversation.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Memory.Store
  alias FermixCore.Tools.Tool

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

  defp do_execute(%{"key" => key}, context) do
    conv_key = Map.fetch!(context, :conversation_key)
    server = Map.get(context, :memory_store, Store)

    case Store.recall(conv_key, key, server: server) do
      {:ok, value} -> {:ok, Tool.success(value)}
      {:error, :not_found} -> {:ok, Tool.error("No memory found for key: #{key}")}
    end
  end

  defp do_execute(_args, context) do
    conv_key = Map.fetch!(context, :conversation_key)
    server = Map.get(context, :memory_store, Store)

    memories = Store.recall_all(conv_key, server: server)

    if map_size(memories) == 0 do
      {:ok, Tool.success("No memories stored for this conversation.")}
    else
      output =
        memories
        |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

      {:ok, Tool.success(output)}
    end
  end
end
