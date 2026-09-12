defmodule FermixCore.Transcription.StreamSession do
  @moduledoc """
  The caller-side API and message contract every transcription stream session
  implements — the chunked batch adapter and, in turn, each native streamer.

  This module is **not** a process: sessions are started by
  `FermixCore.Transcription.open_stream/2`, which dispatches on the backend's
  declared `streaming?` capability. What lives here is the vocabulary both sides
  agree on, so a consumer written against one backend works against all of them.

  ## Audio in

  s16le, mono, 16 000 Hz PCM (32 000 bytes per second) — the only format a
  session speaks. Callers convert before pushing. Any byte count is accepted,
  including odd ones: sessions carry a partial sample across pushes.

  ## Messages out

  A session sends `consumer` exactly these, and nothing else:

  | Message | When |
  |---|---|
  | `{:transcript_segment, session :: pid(), %Segment{}}` | each finalized segment, in `t0_ms` order |
  | `{:transcript_stream_closed, session :: pid(), close_summary()}` | after `finish/1`, all pending resolved |
  | `{:transcript_stream_error, session :: pid(), reason :: term()}` | fatal stream failure |

  The last two are terminal: the session exits `:normal` right after. A
  `:normal` exit following an error message is not a swallowed error — the error
  was delivered, and a consumer that also monitors the pid gets no second,
  contradictory signal.

  There is deliberately no `:started` message. `open_stream/2` returns only once
  the session can accept audio, so a connect failure is `{:error, reason}` from
  the open call rather than an asynchronous surprise.

  ## Lifecycle

  Sessions are started unlinked (`GenServer.start/3`): a session is
  consumer-owned, not tree-owned, and must never take its consumer down. Each
  session monitors its consumer and exits silently when the consumer dies. A
  session terminates only after sending `closed` or `error`, or after its
  consumer died; consumers that want crash visibility monitor the returned pid.

  Fatal error reasons form a closed vocabulary consumers may match on:
  `{:reconnect_exhausted, last_status}`, `{:timeout, name, ms}` (the
  `FermixCore.Timeouts.expired/3` shape), `{:protocol_error, detail}`,
  `{:drain_interrupted, status}` — the connection died after `finish/1` and
  before the vendor's final results, so the tail is lost and the segments
  already delivered are all there will be — `{:sidecar_exit, status}`,
  `{:sidecar_error, code, message}` — the local sidecar reported a terminal
  `error` frame of its own — and `{:ws_start_failed, reason}`.
  """

  # A stop is a local shutdown of an already-connected session: generous enough
  # to cover cancelling in-flight segment work, short enough to fail loud.
  @stop_timeout_ms 10_000

  @typedoc "A running stream session process."
  @type session :: pid()

  @typedoc "What the terminal `closed` message reports about the stream."
  @type close_summary :: %{segments: non_neg_integer(), dropped: non_neg_integer()}

  @doc "Push a chunk of s16le/16k/mono PCM. Any byte count; async; never blocks the caller."
  @spec push_pcm(session(), binary()) :: :ok
  def push_pcm(session, pcm) when is_pid(session) and is_binary(pcm),
    do: GenServer.cast(session, {:push_pcm, pcm})

  @doc """
  No more audio. The session flushes, emits its remaining segments, sends the
  `closed` message and exits `:normal`.
  """
  @spec finish(session()) :: :ok
  def finish(session) when is_pid(session), do: GenServer.cast(session, :finish)

  @doc """
  Abort now: cancel in-flight work, release resources, send no `closed` message,
  exit `:normal`. Synchronous, so the caller knows the resources are gone.
  """
  @spec stop(session()) :: :ok
  def stop(session) when is_pid(session), do: GenServer.call(session, :stop, @stop_timeout_ms)
end
