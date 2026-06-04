defmodule FermixCore.Tools.MemoryStore do
  @moduledoc """
  Store a fact to the agent's memory.
  Uses ETS-backed Memory.Store scoped by conversation key.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Store
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

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
  def when_to_use, do: "Store a durable user or conversation fact in Fermix memory."

  @impl true
  def examples do
    [%{args: %{"key" => "timezone", "value" => "America/New_York"}, note: "remember a fact"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "key or value is absent"},
      %{tag: "missing_context", description: "conversation context is unavailable"},
      %{tag: "store_failed", description: "memory backend rejected the write"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :memory

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = do_execute(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("memory_store", context, success, duration, input: args, result: result)

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
