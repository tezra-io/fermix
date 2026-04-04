defmodule FermixCore.Tools.MemoryStore do
  @moduledoc """
  Store a fact to the agent's memory.
  Uses ETS-backed Memory.Store scoped by conversation key.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Memory.Store
  alias FermixCore.Tools.Tool

  @impl true
  @spec name() :: String.t()
  def name, do: "memory_store"

  @impl true
  @spec description() :: String.t()
  def description do
    "Store a fact or piece of information to the agent's long-term memory."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["key", "value"],
      properties: %{
        key: %{
          type: "string",
          description: "A unique key for this memory (e.g., 'user_timezone', 'project_name')"
        },
        value: %{
          type: "string",
          description: "The value to store"
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
      %{tool: "memory_store", agent: agent, success: success}
    )

    result
  end

  defp do_execute(args, context) do
    with {:ok, key} <- Map.fetch(args, "key"),
         {:ok, value} <- Map.fetch(args, "value"),
         {:ok, conv_key} <- Map.fetch(context, :conversation_key) do
      server = Map.get(context, :memory_store, Store)
      Store.store(conv_key, key, value, server: server)
      {:ok, Tool.success("Stored memory: #{key} = #{value}")}
    else
      :error -> {:ok, Tool.error("Missing required parameters: key and value")}
    end
  end
end
