defmodule FermixCore.Realtime.LiveTurn do
  @moduledoc """
  Where a Live call's turn stands, read from the two audio streams the daemon
  relays to and from the pet.

  Live publishes no turn boundaries: no speech started or stopped, and no
  spoken-response completion (M41: "No Live spoken-response completion
  event"). Nor can a reply be cancelled or truncated; the vendor's playback
  guide puts playback control "at the client or media relay". The daemon is
  that relay, so the pet's `state` frames are read from what passes through it:

    * **The reply has played out** when the audio forwarded to the pet has had
      time to play. Live speaks 24 kHz PCM16, 48 bytes a millisecond.
    * **A stopped reply stays stopped.** Live keeps streaming a reply after an
      interrupt, so its audio is dropped until the stream has been quiet for
      `@stopped_reply_gap_ms`; audio after that gap is a new reply.
    * **The operator has finished speaking** when the microphone, having carried
      speech, has been quiet for `@hangover_ms` and no reply has started. It is
      not read while the reply can still be heard: the app does no echo
      cancellation, so the pet's own voice reaches the microphone.

  Only the pet's presentation follows from this. Nothing here reaches the
  provider, which runs its own turn-taking.

  Pure: every function takes the time. The session owns the clock and the
  timer.
  """

  @bytes_per_ms 48
  # int16 RMS, about -36 dBFS: the level the repo's energy VAD takes for speech.
  @speech_rms 500
  @hangover_ms 700
  @echo_tail_ms 400
  # A reply that never comes (the provider heard noise, or chose silence) must
  # not leave the pet thinking for the rest of the call.
  @thinking_limit_ms 15_000
  @stopped_reply_gap_ms 800

  defstruct playing_until: nil, stopped_at: nil, voice_at: nil, thinking_since: nil

  @type t :: %__MODULE__{
          playing_until: integer() | nil,
          stopped_at: integer() | nil,
          voice_at: integer() | nil,
          thinking_since: integer() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A chunk of the assistant's voice arrives from the provider, base64 PCM16.

  `{:drop, turn}` when it is the rest of a reply the operator stopped. Otherwise
  `{:forward, turn, plays_for_ms}`: how long until everything forwarded so far
  has played. A reply answers the operator's turn, so it ends any thinking.
  """
  @spec output(t(), String.t(), integer()) :: {:forward, t(), non_neg_integer()} | {:drop, t()}
  def output(%__MODULE__{stopped_at: at} = turn, audio, now)
      when is_binary(audio) and is_integer(at) and now - at < @stopped_reply_gap_ms,
      do: {:drop, %{turn | stopped_at: now}}

  def output(%__MODULE__{} = turn, audio, now) when is_binary(audio) and is_integer(now) do
    until = max(turn.playing_until || now, now) + div(base64_bytes(audio), @bytes_per_ms)
    turn = %{turn | playing_until: until, stopped_at: nil, voice_at: nil, thinking_since: nil}

    {:forward, turn, until - now}
  end

  @doc """
  The operator stopped the reply: the pet has already stopped playing it, and
  what is still in flight of it is dropped as it arrives (`output/3`).
  """
  @spec interrupted(t(), integer()) :: t()
  def interrupted(%__MODULE__{} = turn, now) when is_integer(now),
    do: %{turn | playing_until: now, stopped_at: now, voice_at: nil, thinking_since: nil}

  @doc """
  The microphone was muted or unmuted. Speech heard before it is not a turn
  after it.
  """
  @spec muted(t()) :: t()
  def muted(%__MODULE__{} = turn), do: %{turn | voice_at: nil, thinking_since: nil}

  @doc """
  A microphone chunk (PCM16) the provider was sent. Answers the state the pet
  should move to, if any. `speaking?` is whether a reply is being announced.
  """
  @spec input(t(), binary(), integer(), boolean()) :: {:thinking | :listening | nil, t()}
  def input(%__MODULE__{} = turn, pcm, now, speaking?)
      when is_binary(pcm) and is_integer(now) and is_boolean(speaking?) do
    cond do
      speaking? or reply_audible?(turn, now) -> {nil, %{turn | voice_at: nil}}
      speech?(pcm) -> heard(turn, now)
      true -> quiet(turn, now)
    end
  end

  defp reply_audible?(%__MODULE__{playing_until: nil}, _now), do: false
  defp reply_audible?(turn, now), do: now < turn.playing_until + @echo_tail_ms

  defp heard(%__MODULE__{thinking_since: nil} = turn, now), do: {nil, %{turn | voice_at: now}}
  defp heard(turn, now), do: {:listening, %{turn | voice_at: now, thinking_since: nil}}

  defp quiet(%__MODULE__{thinking_since: since} = turn, now)
       when is_integer(since) and now - since >= @thinking_limit_ms,
       do: {:listening, %{turn | thinking_since: nil}}

  defp quiet(%__MODULE__{voice_at: at, thinking_since: nil} = turn, now)
       when is_integer(at) and now - at >= @hangover_ms,
       do: {:thinking, %{turn | voice_at: nil, thinking_since: now}}

  defp quiet(turn, _now), do: {nil, turn}

  defp speech?(pcm), do: rms(pcm) >= @speech_rms

  defp rms(pcm) do
    {sum, count} =
      for <<sample::little-signed-16 <- pcm>>, reduce: {0, 0} do
        {sum, count} -> {sum + sample * sample, count + 1}
      end

    if count == 0, do: 0.0, else: :math.sqrt(sum / count)
  end

  # The decoded size without decoding: every four characters carry three bytes,
  # less one for each `=` of padding.
  defp base64_bytes(audio) do
    padding = byte_size(audio) - byte_size(String.trim_trailing(audio, "="))
    max(0, div(byte_size(audio) * 3, 4) - padding)
  end
end
