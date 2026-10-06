defmodule FermixCore.Tools.MemoryStore do
  @moduledoc """
  Save something to memory.

  With a `category` the fact becomes long-term memory (`Memory.LongTerm`): a
  row USER.md or MEMORY.md renders into every conversation. With an `id` it
  corrects a row already there. With neither it is a note kept for the current
  conversation (`Memory.Store`). The result says which of those happened and
  whether it is durable — never "stored" for a write that did not land.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.LongTerm
  alias FermixCore.Memory.Store
  alias FermixCore.Tools.MemorySupport
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "memory_store"

  @impl true
  @spec description() :: String.t()
  def description do
    "Save to memory. With a category: long-term, present in every future conversation. " <>
      "Without: a note for this conversation only. With an id: correct an existing memory. " <>
      "Never a secret, a credential or a precise address."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["value"],
      properties: %{
        key: %{
          type: "string",
          description:
            "Short stable name, e.g. 'report_format'; saving a key again replaces its value. " <>
              "Required unless id is given."
        },
        value: %{
          type: "string",
          description: "One short self-contained sentence."
        },
        category: %{
          type: "string",
          enum: Admission.categories(),
          description:
            "Makes it long-term. About the user: identity, preference, interest, goal. " <>
              "About their work: context (a durable fact), directive (a standing rule they set)."
        },
        id: %{
          type: "integer",
          description: "Id of an existing memory (from memory_recall) whose value this replaces."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Save what the user asks you to remember or correct; give a category for anything " <>
      "meant to outlast this conversation."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "key" => "timezone",
          "value" => "Works in America/New_York",
          "category" => "identity"
        },
        note: "remember a fact about the user in every conversation"
      },
      %{
        args: %{"id" => 12, "value" => "Works in Europe/Lisbon"},
        note: "correct an existing memory by its id"
      },
      %{
        args: %{"key" => "draft_title", "value" => "Q3 plan"},
        note: "keep a note for this conversation only"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "value is absent, or key with no id"},
      %{tag: "missing_context", description: "conversation context is unavailable"},
      %{tag: "not_found", description: "no memory has the given id"},
      %{tag: "value_too_long", description: "a long-term value is over the one-sentence limit"},
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
    result = args |> given() |> do_execute(context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("memory_store", context, success, duration, input: args, result: result)

    result
  end

  # A model that fills every schema property sends the optional ones as null;
  # an absent argument and a null one are the same request.
  defp given(args), do: Map.reject(args, fn {_name, value} -> is_nil(value) end)

  defp do_execute(%{"value" => value, "id" => id}, context) when is_binary(value) do
    case MemorySupport.parse_id(id) do
      {:ok, id} -> replace(id, value, context)
      :error -> {:ok, Tool.error("id must be a positive integer")}
    end
  end

  defp do_execute(%{"value" => value, "key" => key, "category" => category}, context)
       when is_binary(value) and is_binary(key) and is_binary(category) do
    category
    |> LongTerm.save(key, value, MemorySupport.long_term_context(context))
    |> report(&saved/1)
  end

  defp do_execute(%{"value" => value, "key" => key}, context)
       when is_binary(value) and is_binary(key) do
    case Map.fetch(context, :conversation_key) do
      {:ok, conv_key} -> note(conv_key, key, value, context)
      :error -> {:ok, Tool.error("Missing conversation context")}
    end
  end

  defp do_execute(_args, _context) do
    {:ok, Tool.error("Missing required parameters: value, and key unless id is given")}
  end

  defp replace(id, value, context) do
    id
    |> LongTerm.replace(value, MemorySupport.long_term_context(context))
    |> report(&replaced/1)
  end

  defp note(conv_key, key, value, context) do
    server = Map.get(context, :memory_store, Store)

    case Store.store(conv_key, key, value, server: server) do
      {:ok, :durable} ->
        {:ok,
         Tool.success(
           "Saved as a note for this conversation only: #{key}. It is not long-term " <>
             "memory; give a category to keep something across conversations."
         )}

      {:ok, :session_only} ->
        {:ok,
         Tool.success(
           "Durable memory is turned off, so this note is kept only until Fermix " <>
             "restarts: #{key}."
         )}

      {:error, reason} ->
        {:ok, Tool.error(MemorySupport.refusal(reason))}
    end
  end

  defp report({:ok, receipt}, describe), do: {:ok, Tool.success(describe.(receipt))}
  defp report({:error, reason}, _describe), do: {:ok, Tool.error(MemorySupport.refusal(reason))}

  defp saved(%{memory: memory} = receipt) do
    "Saved to long-term memory: id=#{memory.id} #{memory.category} #{memory.key}." <>
      MemorySupport.published_note(receipt)
  end

  defp replaced(%{memory: memory} = receipt) do
    "Updated memory id=#{memory.id} (#{memory.category}): #{memory.value}" <>
      MemorySupport.published_note(receipt)
  end
end
