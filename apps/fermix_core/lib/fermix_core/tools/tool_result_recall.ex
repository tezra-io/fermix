defmodule FermixCore.Tools.ToolResultRecall do
  @moduledoc """
  Read back an earlier tool result of the current run that the agent loop
  compressed into a digest to keep the context within budget
  (docs/design/IN_LOOP_CONTEXT_OVERFLOW.md §3.1).

  The raw result lives in the run's `ToolResultStore`, which the loop places
  in the tool context. A search returns the matching lines; a range returns
  the lines themselves. Both are bounded so a recall can never refill the
  context the compression just freed: the model narrows the query or the
  range instead. Read-only; it never runs the original tool again.

  `advertise?/1` offers the tool only to a run that carries a store, so the
  realtime tool bridge and any caller without a loop-owned store never see
  it.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.ToolResultStore
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Text
  alias FermixCore.Tools.Support

  @max_matches 200
  @default_lines 200
  @max_lines 400
  @max_output_bytes 16_000

  @impl true
  @spec name() :: String.t()
  def name, do: "tool_result_recall"

  @impl true
  @spec description() :: String.t()
  def description do
    "Read back the full text of an earlier tool result in this run that was " <>
      "compressed into a digest (the digest names its call_id). Give `query` to " <>
      "get the matching lines, or `offset`/`limit` to read a line range. Output is " <>
      "bounded; narrow the query or range for more. Never re-runs the tool."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["call_id"],
      properties: %{
        call_id: %{
          type: "string",
          description: "The call_id named by the digest of the result to read."
        },
        query: %{
          type: "string",
          description:
            "Phrase to find (literal, case-insensitive). Returns the numbered lines " <>
              "containing it, at most #{@max_matches}."
        },
        offset: %{
          type: "integer",
          minimum: 1,
          description: "First line to read (1-indexed, default 1) when no query is given."
        },
        limit: %{
          type: "integer",
          minimum: 1,
          description: "Lines to read from offset (default #{@default_lines}, max #{@max_lines})."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "A digest in this run left out a detail you need: an exact value, a row, " <>
      "an error line, a quote. Search the original by phrase, or read the range " <>
      "the digest points at, instead of re-running the tool."
  end

  @impl true
  def examples do
    [
      %{args: %{"call_id" => "call_17", "query" => "total"}, note: "find the lines with a total"},
      %{args: %{"call_id" => "call_17", "offset" => 120, "limit" => 40}, note: "read a range"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "no_store", description: "this run keeps no tool results (nothing was compressed)"},
      %{tag: "unknown_call_id", description: "no result of this run has that call_id"},
      %{tag: "invalid_range", description: "offset or limit is not a positive integer"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @doc "Offered only to a run whose loop owns a result store."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: match?(%{tool_result_store: _}, context)

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, store} <- fetch_store(context),
         {:ok, call_id} <- fetch_call_id(args),
         {:ok, entry} <- fetch_entry(store, call_id),
         {:ok, text} <- render(entry, args) do
      {:ok, Tool.success(ToolResultStore.frame(entry, text))}
    else
      {:error, message} -> {:ok, Tool.error(message)}
    end
  end

  defp fetch_store(context) do
    case Map.fetch(context, :tool_result_store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, "This run keeps no tool results; nothing was compressed."}
    end
  end

  defp fetch_call_id(args) do
    case Map.get(args, "call_id") do
      call_id when is_binary(call_id) and call_id != "" -> {:ok, call_id}
      _missing -> {:error, "Missing required parameter: call_id"}
    end
  end

  defp fetch_entry(store, call_id) do
    case ToolResultStore.fetch(store, call_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "No tool result of this run has call_id #{call_id}."}
    end
  end

  defp render(entry, %{"query" => query}) when is_binary(query) and query != "" do
    %{lines: lines, truncated?: truncated?} = ToolResultStore.search(entry, query, @max_matches)

    case lines do
      [] ->
        {:ok, "No line of #{entry.tool_name} result #{entry.call_id} contains #{inspect(query)}."}

      _found ->
        header =
          "Lines of #{entry.tool_name} result #{entry.call_id} containing #{inspect(query)}"

        note = if truncated?, do: " (first #{@max_matches} matches; narrow the query for more)"
        {:ok, bounded(header <> (note || "") <> ":\n" <> join(lines))}
    end
  end

  defp render(entry, args) do
    with {:ok, offset} <- positive_int(args, "offset", 1),
         {:ok, limit} <- positive_int(args, "limit", @default_lines) do
      limit = min(limit, @max_lines)
      lines = ToolResultStore.slice(entry, offset, limit)
      total = entry.output |> String.split("\n") |> length()

      header =
        "Lines #{offset}-#{offset + length(lines) - 1} of #{total} from #{entry.tool_name} " <>
          "result #{entry.call_id}:\n"

      {:ok, bounded(header <> join(lines))}
    end
  end

  defp positive_int(args, key, default) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= 1 -> {:ok, value}
      value -> {:error, "#{key} must be a positive integer (1-indexed), got: #{inspect(value)}"}
    end
  end

  defp join(lines), do: Enum.map_join(lines, "\n", fn {number, line} -> "#{number}: #{line}" end)

  # The cap keeps a recall from re-filling the context; the marker tells the
  # model how to get the rest.
  defp bounded(text) when byte_size(text) <= @max_output_bytes, do: text

  defp bounded(text) do
    Text.truncate_utf8(text, @max_output_bytes) <>
      "\n[capped at #{@max_output_bytes} bytes; narrow the query or read a smaller range]"
  end
end
