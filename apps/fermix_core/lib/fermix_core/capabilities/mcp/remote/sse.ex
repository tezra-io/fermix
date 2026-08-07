defmodule FermixCore.Capabilities.MCP.Remote.SSE do
  @moduledoc """
  Incremental, bounded `text/event-stream` parser for the remote MCP rail
  (M27 §7.4).

  Incremental is the point. Buffering a whole SSE body and then splitting it
  means the byte caps are checked *after* an unbounded allocation has already
  happened — a hostile or broken server would win before the limit was ever
  consulted. `feed/2` enforces the per-event, whole-stream, and event-count
  caps as bytes arrive, so the caller can close the connection mid-stream.

  Nothing here truncates. A cap breach returns an error and the stream is
  finished; a partially-read event is never handed on as if it were complete.

  Line endings are normalized to `\\n` (the SSE line terminators are `\\r\\n`,
  `\\n`, and `\\r`). A `\\r` at a chunk boundary is held back rather than
  normalized eagerly, so a `\\r\\n` split across two chunks cannot be mistaken
  for the blank line that ends an event.
  """

  alias FermixCore.Capabilities.MCP.Remote.Limits

  @type event :: %{data: String.t(), event: String.t() | nil, id: String.t() | nil}

  @type t :: %__MODULE__{
          buffer: binary(),
          events: non_neg_integer(),
          stream_bytes: non_neg_integer()
        }

  defstruct buffer: "", events: 0, stream_bytes: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed one transport chunk. Returns the events completed by this chunk plus the
  updated parser state, or an error naming the exact bound that was exceeded.
  """
  @spec feed(t(), binary()) :: {:ok, [event()], t()} | {:error, term()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    stream_bytes = state.stream_bytes + byte_size(chunk)

    if stream_bytes > Limits.max_sse_stream_bytes() do
      {:error, {:sse_limit, :stream_bytes, stream_bytes}}
    else
      split_events(%{state | stream_bytes: stream_bytes}, chunk)
    end
  end

  @doc """
  End of stream. A non-empty remainder means the peer stopped mid-event; that
  is a truncated response, not a final event to salvage.
  """
  @spec finish(t()) :: :ok | {:error, term()}
  def finish(%__MODULE__{buffer: buffer}) do
    if String.trim(buffer) == "",
      do: :ok,
      else: {:error, {:sse_truncated_event, byte_size(buffer)}}
  end

  defp split_events(state, chunk) do
    case drain(state.buffer <> chunk, state.events, []) do
      {:ok, events, rest, count} ->
        {:ok, Enum.reverse(events), %{state | buffer: rest, events: count}}

      {:error, _reason} = error ->
        error
    end
  end

  # Terminators are matched on the RAW buffer rather than on a normalized copy.
  # Normalizing first would turn a trailing "\r" — which may be the first half
  # of a "\r\n" the next chunk completes — into a "\n" and fabricate the blank
  # line that ends an event. Scanning raw needs no hold-back: a lone trailing
  # "\r" simply matches nothing and stays buffered.
  @terminators ["\r\n\r\n", "\n\n", "\r\r"]

  defp drain(buffer, count, acc) do
    case earliest_terminator(buffer) do
      nil -> finish_drain(buffer, count, acc)
      {at, length} -> take_event(buffer, at, length, count, acc)
    end
  end

  defp earliest_terminator(buffer) do
    @terminators
    |> Enum.flat_map(fn terminator ->
      case :binary.match(buffer, terminator) do
        {at, length} -> [{at, length}]
        :nomatch -> []
      end
    end)
    |> case do
      [] -> nil
      matches -> Enum.min_by(matches, &elem(&1, 0))
    end
  end

  # No terminator yet: the remainder is an event still being received, and it
  # must stay inside the per-event cap even before it completes.
  defp finish_drain(rest, count, acc) do
    if byte_size(rest) > Limits.max_sse_event_bytes() do
      {:error, {:sse_limit, :event_bytes, byte_size(rest)}}
    else
      {:ok, acc, rest, count}
    end
  end

  defp take_event(buffer, at, length, count, acc) do
    raw = binary_part(buffer, 0, at)
    rest = binary_part(buffer, at + length, byte_size(buffer) - at - length)

    cond do
      at > Limits.max_sse_event_bytes() ->
        {:error, {:sse_limit, :event_bytes, at}}

      count + 1 > Limits.max_sse_events() ->
        {:error, {:sse_limit, :event_count, count + 1}}

      true ->
        drain(rest, count + 1, prepend_event(parse_event(raw), acc))
    end
  end

  # A comment-only or field-less block is a legal SSE keep-alive, not an event
  # with empty data — it is counted against the stream but carries nothing.
  defp prepend_event(nil, acc), do: acc
  defp prepend_event(event, acc), do: [event | acc]

  # Line endings are normalized only INSIDE an extracted event, where there is
  # no longer a partial-terminator ambiguity to preserve.
  defp parse_event(raw) do
    fields =
      raw
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.split("\n")
      |> Enum.reduce(%{data: [], event: nil, id: nil}, &parse_line/2)

    case fields.data do
      [] ->
        nil

      lines ->
        %{data: lines |> Enum.reverse() |> Enum.join("\n"), event: fields.event, id: fields.id}
    end
  end

  defp parse_line(":" <> _comment, fields), do: fields

  defp parse_line(line, fields) do
    case String.split(line, ":", parts: 2) do
      ["data", value] -> %{fields | data: [strip_space(value) | fields.data]}
      ["event", value] -> %{fields | event: strip_space(value)}
      ["id", value] -> %{fields | id: strip_space(value)}
      _other -> fields
    end
  end

  # SSE strips exactly one leading space after the colon, not all whitespace.
  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value
end
