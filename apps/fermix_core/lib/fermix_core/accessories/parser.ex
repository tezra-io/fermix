defmodule FermixCore.Accessories.Parser do
  @moduledoc """
  The incremental receive side of the accessory link: bytes in, frames and
  faults out (`priv/accessory/PROTOCOL.md`, *Receiving*, whose algorithm this
  is). A serial read is a fragment of a byte stream, so `feed/2` takes any
  chunk and gives the same frames however the bytes were split.

  It trusts a header's length only as far as waiting for that many bytes: the
  CRC decides, and a CRC failure discards one byte rather than the claimed
  length, so frames inside a corrupted length are found again. Before the
  first good frame everything else (a ROM banner, noise) is discarded silently
  and counted; once synced, every byte that is not a good frame is a fault.
  The buffer never holds more than one frame between feeds.

  Bytes held for a frame that makes no progress for `stall_ms/0` (a header
  whose false length would otherwise hold an idle link until the bytes it
  claims arrive) are a stalled frame: one byte is discarded, counted, a
  `frame_timeout` fault while synced, and the rest read again. The link feeds
  an empty chunk on its own tick so a stall is found with nothing arriving,
  and `reset/1` drops the held bytes when it starts the link again. Time is
  the caller's monotonic milliseconds. Pure.

  One parser reads one peer: `new(:accessory)` is the daemon's, which refuses
  speaker PCM; `new(:host)` is what the firmware's reads, which refuses
  microphone PCM.
  """

  alias FermixCore.Accessories.Frame

  @magic "FX"
  @framing_version Frame.framing_version()
  @header_bytes Frame.header_bytes()
  @max_payload Frame.max_payload()
  @crc_bytes 4
  @resync_limit 8_192
  @stall_ms 1_000

  @enforce_keys [:from]
  defstruct from: nil,
            buffer: <<>>,
            synced?: false,
            scanned: 0,
            waiting_since: nil,
            resync_bytes: 0,
            frames: 0,
            faults: %{}

  @type fault ::
          :bad_magic
          | :frame_version
          | :unknown_frame_type
          | :bad_flags
          | :bad_reserved
          | :over_cap
          | :crc_mismatch
          | :resync_limit
          | :frame_timeout
          | Frame.fault()
  @type event :: {:frame, Frame.t()} | {:fault, fault()}
  @type t :: %__MODULE__{
          from: Frame.sender(),
          buffer: binary(),
          synced?: boolean(),
          scanned: non_neg_integer(),
          waiting_since: integer() | nil,
          resync_bytes: non_neg_integer(),
          frames: non_neg_integer(),
          faults: %{optional(fault()) => pos_integer()}
        }

  @doc "A parser for the frames `from` sends."
  @spec new(Frame.sender()) :: t()
  def new(from) when from in [:host, :accessory], do: %__MODULE__{from: from}

  @doc """
  Takes the next chunk of the byte stream, read at `now_ms`: the frames and
  faults it completes, in order. An empty chunk is a tick.
  """
  @spec feed(t(), binary(), integer()) :: {[event()], t()}
  def feed(%__MODULE__{} = parser, chunk, now_ms) when is_binary(chunk) and is_integer(now_ms) do
    buffer = parser.buffer <> chunk
    {events, next} = scan(%{parser | buffer: buffer})
    settle(next, events, byte_size(next.buffer) < byte_size(buffer), now_ms)
  end

  @doc "How long held bytes may make no progress before they are a stalled frame."
  @spec stall_ms() :: pos_integer()
  def stall_ms, do: @stall_ms

  @doc """
  Starts reading afresh, as after a new HELLO: drops the bytes held for a
  frame (counted as discarded) and the sync, and keeps every counter.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = parser) do
    %{
      parser
      | buffer: <<>>,
        synced?: false,
        scanned: 0,
        waiting_since: nil,
        resync_bytes: parser.resync_bytes + byte_size(parser.buffer)
    }
  end

  @doc "Bytes held for a frame not yet complete."
  @spec pending_bytes(t()) :: non_neg_integer()
  def pending_bytes(%__MODULE__{buffer: buffer}), do: byte_size(buffer)

  @doc "Bytes discarded while looking for a good frame, since the parser began."
  @spec resync_bytes(t()) :: non_neg_integer()
  def resync_bytes(%__MODULE__{resync_bytes: bytes}), do: bytes

  @doc "What the parser has counted: frames delivered, bytes discarded, faults by reason."
  @spec counters(t()) :: %{
          frames: non_neg_integer(),
          resync_bytes: non_neg_integer(),
          faults: map()
        }
  def counters(%__MODULE__{} = parser),
    do: %{frames: parser.frames, resync_bytes: parser.resync_bytes, faults: parser.faults}

  # Every step consumes at least one byte or waits, so the bytes bound the steps.
  defp scan(parser), do: run(parser, [], byte_size(parser.buffer) + 1)

  # The stall clock restarts whenever the held bytes change at their head;
  # after a stall's one byte goes, it starts again from now.
  defp settle(%__MODULE__{buffer: <<>>} = parser, events, _progressed?, _now_ms),
    do: {events, %{parser | waiting_since: nil}}

  defp settle(parser, events, progressed?, now_ms) do
    since = if progressed? or is_nil(parser.waiting_since), do: now_ms, else: parser.waiting_since
    parser = %{parser | waiting_since: since}

    if now_ms - since < @stall_ms do
      {events, parser}
    else
      {next, stalled} = discard(parser, 1, :frame_timeout)
      {more, next} = scan(next)
      settle(next, events ++ stalled ++ more, true, now_ms)
    end
  end

  defp run(_parser, _events, 0), do: raise("accessory frame parser made no progress")

  defp run(parser, events, budget) do
    case step(parser) do
      :wait -> {Enum.reverse(events), parser}
      {next, new_events} -> run(next, Enum.reverse(new_events, events), budget - 1)
    end
  end

  defp step(%__MODULE__{buffer: <<>>}), do: :wait

  defp step(%__MODULE__{buffer: <<@magic, _rest::binary>> = buffer} = parser),
    do: at_magic(parser, buffer)

  defp step(%__MODULE__{buffer: buffer} = parser) do
    case bytes_before_magic(buffer) do
      0 -> :wait
      count -> discard(parser, count, :bad_magic)
    end
  end

  # Up to the next magic, or the whole buffer but a final "F" that may begin one.
  defp bytes_before_magic(buffer) do
    case :binary.match(buffer, @magic) do
      {at, _length} -> at
      :nomatch -> byte_size(buffer) - if(:binary.last(buffer) == ?F, do: 1, else: 0)
    end
  end

  defp at_magic(_parser, buffer) when byte_size(buffer) < @header_bytes, do: :wait

  defp at_magic(parser, buffer) do
    <<@magic, version, type, flags, reserved, _stream::16-little, _seq::32-little,
      length::32-little, _rest::binary>> = buffer

    case plausible(version, type, flags, reserved, length) do
      :ok -> complete(parser, buffer, length)
      {:error, reason} -> discard(parser, 1, reason)
    end
  end

  defp plausible(version, _type, _flags, _reserved, _length) when version != @framing_version,
    do: {:error, :frame_version}

  defp plausible(_version, type, _flags, _reserved, _length) when type not in 1..4,
    do: {:error, :unknown_frame_type}

  defp plausible(_version, _type, flags, _reserved, _length) when flags > 7,
    do: {:error, :bad_flags}

  defp plausible(_version, _type, _flags, reserved, _length) when reserved != 0,
    do: {:error, :bad_reserved}

  defp plausible(_version, _type, _flags, _reserved, length) when length > @max_payload,
    do: {:error, :over_cap}

  defp plausible(_version, _type, _flags, _reserved, _length), do: :ok

  defp complete(_parser, buffer, length)
       when byte_size(buffer) < @header_bytes + length + @crc_bytes,
       do: :wait

  defp complete(parser, buffer, length) do
    body_bytes = @header_bytes + length
    <<body::binary-size(body_bytes), crc::32-little, rest::binary>> = buffer

    if :erlang.crc32(body) == crc,
      do: accept(parser, body, rest),
      else: discard(parser, 1, :crc_mismatch)
  end

  # The CRC proved the frame came from the peer: it is consumed, the parser is
  # synced, and a frame that breaks its type's rules is a fault of its own.
  defp accept(parser, body, rest) do
    <<@magic, _version, code, flags, _reserved, stream::16-little, seq::32-little,
      _length::32-little, payload::binary>> = body

    {:ok, type} = Frame.type(code)
    frame = %Frame{type: type, flags: flags, stream: stream, seq: seq, payload: payload}
    parser = %{parser | buffer: rest, synced?: true, scanned: 0}

    case Frame.check(frame, parser.from) do
      :ok -> {%{parser | frames: parser.frames + 1}, [{:frame, frame}]}
      {:error, reason} -> {count(parser, reason), [{:fault, reason}]}
    end
  end

  defp discard(parser, bytes, reason) do
    <<_dropped::binary-size(bytes), rest::binary>> = parser.buffer
    {parser, lost_sync} = lose_sync(parser, reason)
    crossings = div(parser.scanned + bytes, @resync_limit) - div(parser.scanned, @resync_limit)
    limits = List.duplicate({:fault, :resync_limit}, crossings)

    parser = %{
      count(parser, :resync_limit, crossings)
      | buffer: rest,
        scanned: parser.scanned + bytes,
        resync_bytes: parser.resync_bytes + bytes
    }

    {parser, lost_sync ++ limits}
  end

  defp lose_sync(%__MODULE__{synced?: true} = parser, reason),
    do: {count(%{parser | synced?: false}, reason), [{:fault, reason}]}

  defp lose_sync(parser, _reason), do: {parser, []}

  defp count(parser, reason, times \\ 1)
  defp count(parser, _reason, 0), do: parser

  defp count(parser, reason, times),
    do: %{parser | faults: Map.update(parser.faults, reason, times, &(&1 + times))}
end
