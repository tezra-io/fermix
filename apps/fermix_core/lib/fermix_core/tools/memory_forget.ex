defmodule FermixCore.Tools.MemoryForget do
  @moduledoc """
  Forget a memory by id.

  The row is archived (`Memory.LongTerm.forget/3`): it leaves USER.md,
  MEMORY.md and every recall at once, instead of waiting for the background
  reviewer to notice it is unwanted. It is not erased — the row stays in SQLite,
  and the result says so.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.LongTerm
  alias FermixCore.Tools.MemorySupport
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @default_reason "the user asked to forget it"

  @impl true
  @spec name() :: String.t()
  def name, do: "memory_forget"

  @impl true
  @spec description() :: String.t()
  def description do
    "Forget a memory: archive it so no conversation or recall shows it. " <>
      "Get its id from memory_recall."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["id"],
      properties: %{
        id: %{
          type: "integer",
          description: "Id of the memory, from memory_recall."
        },
        reason: %{
          type: "string",
          description: "Why, in a few words."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Forget a remembered fact the user wants gone; to change one instead, use " <>
      "memory_store with its id."
  end

  @impl true
  def examples do
    [%{args: %{"id" => 12, "reason" => "no longer true"}, note: "forget one memory"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "id is absent or not a positive integer"},
      %{tag: "not_found", description: "no memory has the given id"},
      %{tag: "store_failed", description: "memory backend rejected the change"}
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

    ToolTelemetry.exec("memory_forget", context, success, duration, input: args, result: result)

    result
  end

  defp do_execute(args, context) do
    case MemorySupport.parse_id(Map.get(args, "id")) do
      {:ok, id} -> forget(id, reason(args), context)
      :error -> {:ok, Tool.error("Missing required parameter: id, a positive integer")}
    end
  end

  defp forget(id, reason, context) do
    case LongTerm.forget(id, reason, MemorySupport.long_term_context(context)) do
      {:ok, receipt} -> {:ok, Tool.success(forgotten(receipt))}
      {:error, refusal} -> {:ok, Tool.error(MemorySupport.refusal(refusal))}
    end
  end

  defp reason(args) do
    case Map.get(args, "reason") do
      reason when is_binary(reason) and reason != "" -> reason
      _absent -> @default_reason
    end
  end

  defp forgotten(%{memory: memory} = receipt) do
    "Forgotten: id=#{memory.id} (#{memory.category}). It is archived rather than erased, " <>
      "and no longer appears in recall." <> MemorySupport.published_note(receipt)
  end
end
