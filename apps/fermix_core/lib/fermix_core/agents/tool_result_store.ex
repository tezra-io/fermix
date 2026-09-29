defmodule FermixCore.Agents.ToolResultStore do
  @moduledoc """
  Every tool result of one agent-loop run, kept for the life of that run.

  The loop writes each result here the moment it is built, before the
  provider sees it. When the loop later compresses a result in the
  transcript to keep the context within budget
  (docs/design/IN_LOOP_CONTEXT_OVERFLOW.md §2), the raw text is still here,
  and `tool_result_recall` reads it back by call id. A summary may be lossy;
  the captured evidence is not.

  One ETS table per run, owned by the loop process and deleted by the loop
  on every exit path (`delete/1`). The table is `:protected`: only the loop
  writes, and a tool executing on the loop's behalf can read.
  """

  alias FermixCore.Capabilities.UntrustedContent

  @type t :: :ets.tid()

  @type entry :: %{
          call_id: String.t(),
          step: non_neg_integer(),
          tool_name: String.t(),
          bytes: non_neg_integer(),
          output: String.t(),
          external?: boolean()
        }

  @typedoc "An entry without its `output`: what a caller choosing what to compress needs."
  @type meta :: %{
          call_id: String.t(),
          step: non_neg_integer(),
          tool_name: String.t(),
          bytes: non_neg_integer(),
          external?: boolean()
        }

  @type line :: {pos_integer(), String.t()}

  @spec new() :: t()
  def new, do: :ets.new(__MODULE__, [:set, :protected])

  @doc """
  Record one result. `step` is the loop iteration whose tool calls produced
  it; `external?` says whether the tool returns third-party content, so a
  digest or a recalled slice can be framed as untrusted the way the original
  result was.
  """
  @spec put(t(), %{
          call_id: String.t(),
          step: non_neg_integer(),
          tool_name: String.t(),
          output: String.t(),
          external?: boolean()
        }) :: :ok
  def put(store, %{call_id: call_id, step: step, tool_name: tool_name, output: output} = attrs)
      when is_binary(call_id) and is_integer(step) and step >= 0 and is_binary(tool_name) and
             is_binary(output) do
    external? = Map.fetch!(attrs, :external?)
    seq = System.unique_integer([:monotonic, :positive])

    true =
      :ets.insert(store, {call_id, seq, step, tool_name, byte_size(output), output, external?})

    :ok
  end

  @spec fetch(t(), String.t()) :: {:ok, entry()} | :error
  def fetch(store, call_id) when is_binary(call_id) do
    case :ets.lookup(store, call_id) do
      [row] -> {:ok, to_entry(row)}
      [] -> :error
    end
  end

  @doc "Every stored result, in the order the loop recorded them."
  @spec entries(t()) :: [entry()]
  def entries(store) do
    store
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&to_entry/1)
  end

  @doc """
  Every stored result's metadata, in recording order, without copying the
  bodies out of the table: the loop picks what to compress from this and
  fetches only the chosen bodies.
  """
  @spec index(t()) :: [meta()]
  def index(store) do
    match_spec = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :_, :"$6"}, [],
       [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6"}}]}
    ]

    store
    |> :ets.select(match_spec)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {call_id, _seq, step, tool_name, bytes, external?} ->
      %{call_id: call_id, step: step, tool_name: tool_name, bytes: bytes, external?: external?}
    end)
  end

  @spec delete(t()) :: :ok
  def delete(store) do
    true = :ets.delete(store)
    :ok
  end

  @doc """
  The lines of `entry` containing `query` (a literal, case-insensitive
  match), numbered from 1, at most `max_matches` of them. `truncated?` says
  whether more matched.
  """
  @spec search(entry(), String.t(), pos_integer()) :: %{lines: [line()], truncated?: boolean()}
  def search(%{output: output}, query, max_matches)
      when is_binary(query) and query != "" and is_integer(max_matches) and max_matches > 0 do
    needle = String.downcase(query)

    matches =
      output
      |> numbered_lines()
      |> Stream.filter(fn {_number, line} -> String.contains?(String.downcase(line), needle) end)
      |> Enum.take(max_matches + 1)

    %{lines: Enum.take(matches, max_matches), truncated?: length(matches) > max_matches}
  end

  @doc "Lines `offset`..`offset + limit - 1` of `entry`, numbered from 1."
  @spec slice(entry(), pos_integer(), pos_integer()) :: [line()]
  def slice(%{output: output}, offset, limit)
      when is_integer(offset) and offset > 0 and is_integer(limit) and limit > 0 do
    output
    |> numbered_lines()
    |> Stream.drop(offset - 1)
    |> Enum.take(limit)
  end

  @doc """
  `text` framed as untrusted content attributed to the entry's tool when the
  original result was, unchanged otherwise. Digests and recalled slices go
  through here so provenance survives compression.
  """
  @spec frame(entry(), String.t()) :: String.t()
  def frame(%{external?: true, tool_name: tool_name}, text) when is_binary(text),
    do: UntrustedContent.frame(tool_name, text)

  def frame(%{external?: false}, text) when is_binary(text), do: text

  defp numbered_lines(output) do
    output
    |> String.split("\n")
    |> Stream.with_index(1)
    |> Stream.map(fn {line, number} -> {number, line} end)
  end

  defp to_entry({call_id, _seq, step, tool_name, bytes, output, external?}) do
    %{
      call_id: call_id,
      step: step,
      tool_name: tool_name,
      bytes: bytes,
      output: output,
      external?: external?
    }
  end
end
