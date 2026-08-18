defmodule FermixCore.Meetings.Rtms.Mixer do
  @moduledoc """
  Per-participant RTMS audio in, one mixed stream plus speaker identity out.

  Zoom hands us a separate channel per participant, which is why this lane can
  promise exact attribution without acoustic diarization: the loudest channel in
  a 100 ms bucket IS the speaker, by name, from the platform's own roster. What
  the Session wants, though, is a single 16 kHz mono stream for transcription —
  so buckets are summed sample-wise with saturation clipping.

  Pure and process-free: `push/5` takes the mixer, returns the new mixer and the
  events it produced. `RtmsSource` forwards those events to the Session.

  ## Clocks

  Every `t_ms` this module emits is measured on the audio it has ALREADY emitted
  (`emitted bytes / 32`), never on Zoom's timestamps. That is the clock the
  Session counts samples on, so speaker marks and transcript segments cannot
  drift apart. Silence nobody transmits is not emitted and therefore does not
  advance the clock — the timeline is meeting audio, not wall time.

  The ROSTER clock is a second, separate one: it advances with pushed audio and
  with `tick/2`, which the caller drives off wall time. Without `tick/2` a
  meeting where everybody stopped transmitting could never empty its roster —
  expiry would wait on the very audio that stopped — and the Session's
  alone-timer would never arm.

  ## Buffering

  Participant channels do not arrive in lockstep, so a bucket is held for up to
  `@max_buffered_buckets` (1 second) before it flushes, giving a late channel a
  chance to land in its own bucket instead of being mixed into a later one. Past
  that bound the oldest bucket flushes as-is, which caps memory and latency
  regardless of what a channel does. `flush/1` empties the buffer at end of
  stream so the last second is not lost.
  """

  # 100 ms of 16 kHz mono s16le: 1600 samples, 3200 bytes, 32 bytes per ms.
  @bucket_ms 100
  @bytes_per_ms 32

  @max_buffered_buckets 10
  @max_participants 200
  @roster_ttl_ms 30_000

  # int16 RMS below this is room noise, not speech.
  @speech_rms_threshold 500

  # A challenger must be the loudest channel for this many consecutive buckets
  # before it takes the active-speaker mark, so a cough or a "mhm" over someone
  # else's sentence does not split the transcript between two names.
  @hangover_buckets 3

  @int16_min -32_768
  @int16_max 32_767

  defstruct buckets: %{},
            participants: %{},
            active: nil,
            pending: nil,
            emitted_bytes: 0,
            now_ms: 0

  @opaque t :: %__MODULE__{
            buckets: %{optional(non_neg_integer()) => %{optional(String.t()) => [binary()]}},
            participants: %{
              optional(String.t()) => %{name: String.t(), seen_ms: non_neg_integer()}
            },
            active: String.t() | nil,
            pending: {String.t(), pos_integer()} | nil,
            emitted_bytes: non_neg_integer(),
            now_ms: non_neg_integer()
          }

  @typedoc "What the mixer hands back for the Session, in emission order."
  @type mixed_event ::
          {:audio, binary()}
          | {:active_speaker, String.t(), non_neg_integer()}
          | {:roster, [%{id: String.t(), name: String.t()}]}

  @doc "An empty mixer: no participants, no buffered audio, clock at zero."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Buckets one participant's PCM at `ts_ms` (Zoom's clock, used only for
  alignment) and returns whatever that completed.
  """
  @spec push(t(), String.t(), String.t(), binary(), non_neg_integer()) ::
          {t(), [mixed_event()]}
  def push(%__MODULE__{} = mixer, user_id, user_name, pcm, ts_ms)
      when is_binary(user_id) and is_binary(user_name) and is_binary(pcm) and
             is_integer(ts_ms) and ts_ms >= 0 do
    {mixer, roster_events} = note_participant(mixer, user_id, user_name, ts_ms)

    mixer
    |> buffer(user_id, pcm, ts_ms)
    |> drain(@max_buffered_buckets)
    |> prepend(roster_events)
  end

  @doc "Flushes every buffered bucket — the stream is over and nothing more will align."
  @spec flush(t()) :: {t(), [mixed_event()]}
  def flush(%__MODULE__{} = mixer), do: drain(mixer, 0)

  @doc """
  Advances the roster clock by `elapsed_ms` of wall time and expires whoever has
  been silent past the TTL, returning a fresh snapshot when the roster changed
  (`[]` included). Buffered audio is untouched — this only ages the roster.
  """
  @spec tick(t(), non_neg_integer()) :: {t(), [mixed_event()]}
  def tick(%__MODULE__{} = mixer, elapsed_ms)
      when is_integer(elapsed_ms) and elapsed_ms >= 0 do
    advance(mixer, mixer.participants, mixer.now_ms + elapsed_ms)
  end

  @doc "How long a participant stays on the roster after their last audio."
  @spec roster_ttl_ms() :: pos_integer()
  def roster_ttl_ms, do: @roster_ttl_ms

  @doc "The current participant roster, newest names, in id order."
  @spec roster(t()) :: [%{id: String.t(), name: String.t()}]
  def roster(%__MODULE__{participants: participants}) do
    participants
    |> Enum.sort_by(fn {id, _entry} -> id end)
    |> Enum.map(fn {id, entry} -> %{id: id, name: entry.name} end)
  end

  # --- Roster ---

  # `seen_ms` is the roster clock, not Zoom's timestamp, so a pusher always
  # survives its own expiry sweep even when `tick/2` has run the clock ahead of
  # the timestamps Zoom is stamping on the audio.
  defp note_participant(mixer, user_id, user_name, ts_ms) do
    now_ms = max(mixer.now_ms, ts_ms)
    advance(mixer, admit(mixer.participants, user_id, user_name, now_ms), now_ms)
  end

  defp advance(mixer, participants, now_ms) do
    before = roster(mixer)
    updated = %{mixer | participants: expire(participants, now_ms), now_ms: now_ms}

    case roster(updated) do
      ^before -> {updated, []}
      changed -> {updated, [{:roster, changed}]}
    end
  end

  defp admit(participants, user_id, user_name, now_ms) do
    entry = %{name: String.slice(user_name, 0, 120), seen_ms: now_ms}

    cond do
      Map.has_key?(participants, user_id) -> Map.put(participants, user_id, entry)
      map_size(participants) < @max_participants -> Map.put(participants, user_id, entry)
      true -> participants
    end
  end

  defp expire(participants, now_ms) do
    Map.reject(participants, fn {_id, entry} -> now_ms - entry.seen_ms > @roster_ttl_ms end)
  end

  # --- Bucketing ---

  defp buffer(mixer, user_id, pcm, ts_ms) do
    index = div(ts_ms, @bucket_ms)
    bucket = Map.get(mixer.buckets, index, %{})
    channel = Map.get(bucket, user_id, [])
    bucket = Map.put(bucket, user_id, [pcm | channel])

    %{mixer | buckets: Map.put(mixer.buckets, index, bucket)}
  end

  # Flushes oldest-first until at most `keep` buckets remain buffered. Bounded by
  # the buffer's own size, which `push/5` grows by at most one bucket per call.
  defp drain(mixer, keep) do
    indexes =
      mixer.buckets
      |> Map.keys()
      |> Enum.sort()
      |> Enum.drop(-keep)

    Enum.reduce(indexes, {mixer, []}, fn index, {acc, events} ->
      {acc, produced} = emit_bucket(acc, index)
      {acc, events ++ produced}
    end)
  end

  defp emit_bucket(mixer, index) do
    {bucket, buckets} = Map.pop!(mixer.buckets, index)

    channels =
      Map.new(bucket, fn {id, chunks} ->
        {id, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      end)

    frame = mix(Map.values(channels))
    {mixer, speaker_events} = note_speaker(%{mixer | buckets: buckets}, channels)

    {%{mixer | emitted_bytes: mixer.emitted_bytes + byte_size(frame)},
     speaker_events ++ [{:audio, frame}]}
  end

  # --- Active speaker ---

  defp note_speaker(mixer, channels) do
    case loudest(channels) do
      nil -> {%{mixer | pending: nil}, []}
      id when id == mixer.active -> {%{mixer | pending: nil}, []}
      id -> challenge(mixer, id)
    end
  end

  defp challenge(mixer, id) do
    count = streak(mixer.pending, id)

    if count >= @hangover_buckets do
      at_ms = div(mixer.emitted_bytes, @bytes_per_ms)
      {%{mixer | active: id, pending: nil}, [{:active_speaker, id, at_ms}]}
    else
      {%{mixer | pending: {id, count}}, []}
    end
  end

  defp streak({id, count}, id), do: count + 1
  defp streak(_pending, _id), do: 1

  defp loudest(channels) do
    channels
    |> Enum.map(fn {id, pcm} -> {id, rms(pcm)} end)
    |> Enum.filter(fn {_id, rms} -> rms >= @speech_rms_threshold end)
    |> Enum.sort_by(fn {_id, rms} -> rms end, :desc)
    |> case do
      [] -> nil
      [{id, _rms} | _rest] -> id
    end
  end

  defp rms(pcm) do
    samples = samples(pcm)

    case length(samples) do
      0 -> 0
      count -> samples |> Enum.reduce(0, &(&1 * &1 + &2)) |> div(count) |> :math.sqrt() |> trunc()
    end
  end

  # --- Mixing ---

  defp mix([]), do: <<>>
  defp mix([only]), do: only |> samples() |> encode()

  defp mix(channels) do
    channels
    |> Enum.map(&samples/1)
    |> Enum.reduce(&add/2)
    |> encode()
  end

  defp samples(pcm), do: for(<<sample::little-signed-16 <- pcm>>, do: sample)

  # Channels in one bucket can differ in length when a participant joined or
  # muted mid-bucket; the shorter one is silence past its end, not a truncation.
  defp add([], other), do: other
  defp add(other, []), do: other
  defp add([a | as], [b | bs]), do: [a + b | add(as, bs)]

  defp encode(samples) do
    for sample <- samples, into: <<>>, do: <<clip(sample)::little-signed-16>>
  end

  defp clip(sample) when sample > @int16_max, do: @int16_max
  defp clip(sample) when sample < @int16_min, do: @int16_min
  defp clip(sample), do: sample

  defp prepend({mixer, events}, []), do: {mixer, events}
  defp prepend({mixer, events}, leading), do: {mixer, leading ++ events}
end
