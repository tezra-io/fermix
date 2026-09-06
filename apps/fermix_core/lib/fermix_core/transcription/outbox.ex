defmodule FermixCore.Transcription.Outbox do
  @moduledoc """
  Outbound flow control for a native transcription stream: what a session may
  hand its socket now, what it must hold, and what it has to drop.

  Pure — no sends, no timers, no process state. Both streaming sessions
  (Deepgram, xAI) keep the I/O and their own readiness rules and route the
  decision through here, so the caps have one implementation rather than two
  that drift.

  Two bounds, both counted in bytes of s16le/16 kHz/mono PCM:

    * `inflight_max_bytes/0` — audio cast to the socket process and not yet
      acknowledged. Sends are casts, so a vendor that stops draining leaves the
      socket blocked inside one write while every later cast piles up in its
      mailbox, unbounded and uncounted. Past this window audio waits here, where
      it is bounded and counted, instead of there, where it is neither.
    * `buffer_max_bytes/0` — audio held while there is no socket to send on (a
      reconnect gap, or xAI's wait for readiness) or while the window is full.
      Overflow is dropped and counted; the caller logs the first drop, in its
      own vendor's words.

  The window is deliberately much smaller than the buffer: the session gives a
  full window `FermixCore.Timeouts.transcription_ws_send_stall/0` to clear
  before it treats the socket as wedged, and the audio arriving over that whole
  recovery still fits in the buffer with room to spare.
  """

  # 5 s of audio. The point of the window is to notice a stalled uplink while
  # the buffer can still absorb everything that follows, not to pace a healthy
  # one — a socket that acknowledges its frames never reaches this bound.
  @inflight_max_bytes 160_000
  # 30 s of the same audio: the reconnect gap this has always covered, which
  # also comfortably contains the 5 s window plus the 10 s stall deadline.
  @buffer_max_bytes 960_000

  @type t :: %__MODULE__{
          buffer: iodata(),
          buffer_bytes: non_neg_integer(),
          dropped_bytes: non_neg_integer(),
          inflight_bytes: non_neg_integer()
        }

  defstruct buffer: [], buffer_bytes: 0, dropped_bytes: 0, inflight_bytes: 0

  @doc "An empty outbox: nothing held, nothing in flight, nothing dropped."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Bytes of audio that may be in flight to the socket before pushes are held."
  @spec inflight_max_bytes() :: pos_integer()
  def inflight_max_bytes, do: @inflight_max_bytes

  @doc "Bytes of audio that may be held before the overflow is dropped."
  @spec buffer_max_bytes() :: pos_integer()
  def buffer_max_bytes, do: @buffer_max_bytes

  @doc """
  Decides what happens to one chunk. `sendable?` is the session's own rule for
  whether the socket can take audio at all (Deepgram: a socket exists; xAI: the
  server has said it is ready).

  `{:cast, pcm, outbox}` — send it now, and count it in flight.
  `{:held, outbox}` — it is in the buffer; the caller starts its stall deadline
  when a live socket is the reason.
  `{:dropped, outbox}` — the buffer is full; the caller logs the first drop.
  """
  @spec push(t(), binary(), boolean()) :: {:cast, binary(), t()} | {:held, t()} | {:dropped, t()}
  def push(%__MODULE__{} = outbox, pcm, sendable?)
      when is_binary(pcm) and is_boolean(sendable?) do
    case sendable? and not blocked?(outbox) do
      true -> {:cast, pcm, %{outbox | inflight_bytes: outbox.inflight_bytes + byte_size(pcm)}}
      false -> buffer(outbox, pcm)
    end
  end

  @doc """
  Credits `bytes` the socket has reported written, and hands back the held audio
  when that reopens the window.

  Because the socket process is single-threaded, an acknowledgement for one
  frame proves every earlier send completed — so this credit is what tells the
  session the socket is still draining at all.
  """
  @spec acked(t(), pos_integer()) :: {:flush, binary(), t()} | {:ok, t()}
  def acked(%__MODULE__{} = outbox, bytes) when is_integer(bytes) and bytes > 0 do
    credited = %{outbox | inflight_bytes: max(outbox.inflight_bytes - bytes, 0)}
    reopened(credited, window_full?(credited))
  end

  @doc """
  Takes the held audio out to be sent — on a reconnect, on xAI's readiness, or
  when an ack reopened the window. The flushed bytes become in-flight.
  """
  @spec flush(t()) :: {:flush, binary(), t()} | {:empty, t()}
  def flush(%__MODULE__{buffer_bytes: 0} = outbox), do: {:empty, outbox}

  def flush(%__MODULE__{} = outbox) do
    pcm = IO.iodata_to_binary(outbox.buffer)

    {:flush, pcm,
     %{
       outbox
       | buffer: [],
         buffer_bytes: 0,
         inflight_bytes: outbox.inflight_bytes + byte_size(pcm)
     }}
  end

  @doc """
  Forgets the in-flight window because the socket that owed those
  acknowledgements is gone. Held and dropped audio survive — the reconnect
  flushes what is held.
  """
  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = outbox), do: %{outbox | inflight_bytes: 0}

  @doc "True while the socket owes more acknowledgements than the window allows."
  @spec window_full?(t()) :: boolean()
  def window_full?(%__MODULE__{inflight_bytes: inflight}), do: inflight >= @inflight_max_bytes

  # Held audio waits for the window, not merely for an ack: a credit that leaves
  # the window full changes nothing the caller has to act on.
  defp reopened(outbox, true), do: {:ok, outbox}
  defp reopened(%__MODULE__{buffer_bytes: 0} = outbox, false), do: {:ok, outbox}
  defp reopened(outbox, false), do: flush(outbox)

  # Audio already waiting goes out first: casting a later chunk past a held one
  # would reorder the stream the vendor is transcribing.
  defp blocked?(outbox), do: window_full?(outbox) or outbox.buffer_bytes > 0

  defp buffer(outbox, pcm) do
    case outbox.buffer_bytes + byte_size(pcm) > @buffer_max_bytes do
      true -> {:dropped, %{outbox | dropped_bytes: outbox.dropped_bytes + byte_size(pcm)}}
      false -> {:held, hold(outbox, pcm)}
    end
  end

  defp hold(outbox, pcm) do
    %{outbox | buffer: [outbox.buffer, pcm], buffer_bytes: outbox.buffer_bytes + byte_size(pcm)}
  end
end
