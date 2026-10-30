defmodule FermixChannels.Mobile.Chunks do
  @moduledoc """
  Chunked payloads on the mobile wire (M75 §5.2), on both sides of it.

  A payload larger than one frame travels as frames of one event, each with
  `index` (from 0) and `last` (boolean) in its header and at most 60 KiB of it
  as the raw tail. `split/2` cuts a payload into those pieces; the accumulator
  (`new/1`, `add/4`) puts one payload back together, in order and within the
  byte bound its event allows (`bound/1`), and refuses a gap, a repeat or a
  payload past its bound. An accumulator ends at its `last` frame: a later
  frame of the same payload is a gap, while a frame at `index` 0 begins the
  next payload under the same key.

  Which header field tells one payload from another on a session is
  `key_field/1`'s: a channel's lines arrive one after another under the same
  `channel`, each a payload of its own.

  Pure: no process, no I/O. `Desktop.Peer` reassembles what a desktop sends
  the primary; the desktop's own engine reassembles what the primary sends it.
  """

  @max_chunk_bytes 60 * 1_024
  @mib 1_024 * 1_024

  # The bound of each chunked event's whole payload.
  @bounds %{
    "companion_line" => @mib,
    "manage" => @mib,
    "manage_result" => 4 * @mib,
    "loopback_response" => 256 * 1_024
  }

  @key_fields %{
    "companion_line" => "channel",
    "manage" => "call_id",
    "manage_result" => "call_id",
    "loopback_response" => "request_id"
  }

  @typedoc "One piece of a split payload: its index, whether it is the last, and its bytes."
  @type piece :: {non_neg_integer(), boolean(), binary()}

  @typedoc "One payload being put back together."
  @opaque acc :: %{
            bound: non_neg_integer(),
            next: non_neg_integer(),
            size: non_neg_integer(),
            parts: [binary()]
          }

  @type refusal ::
          {:chunk_gap, non_neg_integer(), non_neg_integer()}
          | {:chunk_repeat, non_neg_integer(), non_neg_integer()}
          | {:chunk_payload_too_large, non_neg_integer(), non_neg_integer()}

  @doc "Every chunked event, in either direction."
  @spec chunked_events() :: [String.t()]
  def chunked_events, do: @key_fields |> Map.keys() |> Enum.sort()

  @doc "Whether `type` is a chunked event (`index` and `last` in its header)."
  @spec chunked?(String.t()) :: boolean()
  def chunked?(type) when is_binary(type), do: Map.has_key?(@key_fields, type)

  @doc "The header field that tells one payload of `type` from another on a session."
  @spec key_field(String.t()) :: {:ok, String.t()} | :error
  def key_field(type) when is_binary(type), do: Map.fetch(@key_fields, type)

  @doc "The largest whole payload one `type` event may carry."
  @spec bound(String.t()) :: {:ok, pos_integer()} | :error
  def bound(type) when is_binary(type), do: Map.fetch(@bounds, type)

  @doc """
  Cuts `payload` into pieces of at most `chunk_bytes`, in order, the last one
  marked. An empty payload is one empty piece, so every payload has a `last`.
  """
  @spec split(binary(), pos_integer()) :: [piece(), ...]
  def split(payload, chunk_bytes \\ @max_chunk_bytes)
      when is_binary(payload) and is_integer(chunk_bytes) and chunk_bytes in 1..@max_chunk_bytes do
    count = max(div(byte_size(payload) + chunk_bytes - 1, chunk_bytes), 1)

    for index <- 0..(count - 1) do
      start = index * chunk_bytes
      size = min(chunk_bytes, byte_size(payload) - start)
      {index, index == count - 1, binary_part(payload, start, size)}
    end
  end

  @doc "An empty accumulator for one payload of at most `bound` bytes."
  @spec new(non_neg_integer()) :: acc()
  def new(bound) when is_integer(bound) and bound >= 0,
    do: %{bound: bound, next: 0, size: 0, parts: []}

  @doc """
  Takes the frame `index` of the payload. `{:more, acc}` until its `last`,
  then `{:done, payload}`. A frame out of order (`{:chunk_gap, expected,
  got}`), one already taken (`{:chunk_repeat, expected, got}`) or one that
  takes the payload past its bound is refused, and the payload with it.
  """
  @spec add(acc(), non_neg_integer(), boolean(), binary()) ::
          {:more, acc()} | {:done, binary()} | {:error, refusal()}
  def add(%{next: next} = acc, index, last, bytes)
      when is_integer(index) and index >= 0 and is_boolean(last) and is_binary(bytes) do
    size = acc.size + byte_size(bytes)

    cond do
      index > next -> {:error, {:chunk_gap, next, index}}
      index < next -> {:error, {:chunk_repeat, next, index}}
      size > acc.bound -> {:error, {:chunk_payload_too_large, size, acc.bound}}
      last -> {:done, IO.iodata_to_binary(Enum.reverse([bytes | acc.parts]))}
      true -> {:more, %{acc | next: next + 1, size: size, parts: [bytes | acc.parts]}}
    end
  end
end
