defmodule FermixCore.Realtime.LiveTurn do
  @moduledoc """
  Where a Live call's turn stands, read from the two audio streams the daemon
  relays to and from the pet.

  Live publishes no turn boundaries: no speech started or stopped, and no
  spoken-response completion (M41: "No Live spoken-response completion
  event"). Nor can a reply be cancelled or truncated; the vendor's playback
  guide puts playback control "at the client or media relay". And its output
  never stops: a test call on the dev engine (2026-09-28) carried 249 output
  chunks, one every 100 ms from the first second to the last, of which 7 were
  voice and 242 digital silence. So nothing here reads the presence of audio;
  it reads whether the audio is voice:

    * **A reply is voice.** Output chunks under `@voiced_rms` are forwarded to
      the pet unchanged but are not speech: they neither announce speaking nor
      keep a reply going.
    * **The reply has played out** when its last voiced chunk has had time to
      play. Live speaks 24 kHz PCM16, 48 bytes a millisecond, and the pet plays
      every chunk in order, silence included.
    * **A stopped reply stays stopped.** Live keeps speaking a reply after an
      interrupt, so its voice is dropped until the output has carried no voice
      for `@stopped_reply_gap_ms`; voice after that is a new reply.
    * **The operator has finished speaking** when Live's own recognition has
      stopped sending their words for `@words_hangover_ms` and no reply has
      started. Words, not loudness: an energy detector on the microphone took
      every burst of typing for a sentence (owner, 2026-09-28: "everytime I
      type it goes to thinking mode ... because of keyboard noise"), and Live
      transcribes speech, not keys.
    * **The pet's own voice is not the operator.** Its reply comes back
      through the microphone wherever echo cancellation fails, and a test call
      through display speakers (2026-09-28) heard the reply's last word
      transcribed as the operator's and left the pet thinking until
      `@thinking_limit_ms`. Live's words trail the audio they transcribe, by
      0.6 to 1.2 s in a measured call, so no words count while a reply is
      playing or for `@echo_tail_ms` after it: they are its echo, or the
      operator's own sentence arriving late.

  Only the pet's presentation follows from this. Nothing here reaches the
  provider, which runs its own turn-taking.

  Pure: every function takes the time. The session owns the clock and the
  timer.
  """

  @bytes_per_ms 48
  # int16 RMS. Live's voice measured 244 to 3,667 per 100 ms chunk and its
  # padding 0 to 49, so this sits clear of both.
  @voiced_rms 100
  # Live sends the operator's words in fragments with gaps between them, up to
  # 0.78 s inside one sentence in the measured call; a second without one is
  # the end of what they said.
  @words_hangover_ms 1_000
  # Covers the reply's echo reaching the microphone and Live's delay in
  # transcribing it.
  @echo_tail_ms 2_000
  # A reply that never comes (the provider heard noise, or chose silence) must
  # not leave the pet thinking for the rest of the call.
  @thinking_limit_ms 15_000
  @stopped_reply_gap_ms 800

  defstruct playing_until: nil,
            voiced_until: nil,
            stopped_at: nil,
            voice_at: nil,
            thinking_since: nil

  @type t :: %__MODULE__{
          playing_until: integer() | nil,
          voiced_until: integer() | nil,
          stopped_at: integer() | nil,
          voice_at: integer() | nil,
          thinking_since: integer() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A chunk of the assistant's output arrives from the provider, base64 PCM16.

    * `{:voice, turn, plays_for_ms}`: speech, forwarded; `plays_for_ms` is how
      long until it has played. A reply answers the operator's turn, so voice
      ends any thinking.
    * `{:silence, turn}`: forwarded, and nothing more.
    * `{:drop, turn}`: the voice of a reply the operator stopped.

  Audio that does not decode is not voice.
  """
  @spec output(t(), String.t(), integer()) ::
          {:voice, t(), non_neg_integer()} | {:silence, t()} | {:drop, t()}
  def output(%__MODULE__{} = turn, audio, now) when is_binary(audio) and is_integer(now) do
    pcm = decode(audio)
    until = max(turn.playing_until || now, now) + div(byte_size(pcm), @bytes_per_ms)
    turn = %{turn | playing_until: until}

    cond do
      not voiced?(pcm) -> {:silence, turn}
      stopped?(turn, now) -> {:drop, %{turn | stopped_at: now}}
      true -> {:voice, voice(turn), until - now}
    end
  end

  defp voice(turn) do
    %{
      turn
      | voiced_until: turn.playing_until,
        stopped_at: nil,
        voice_at: nil,
        thinking_since: nil
    }
  end

  defp stopped?(%__MODULE__{stopped_at: at}, now),
    do: is_integer(at) and now - at < @stopped_reply_gap_ms

  @doc """
  The operator stopped the reply: the pet has already stopped playing it, and
  what is still in flight of its voice is dropped as it arrives (`output/3`).
  """
  @spec interrupted(t(), integer()) :: t()
  def interrupted(%__MODULE__{} = turn, now) when is_integer(now) do
    %{
      turn
      | playing_until: now,
        voiced_until: now,
        stopped_at: now,
        voice_at: nil,
        thinking_since: nil
    }
  end

  @doc """
  The microphone was muted or unmuted. Speech heard before it is not a turn
  after it.
  """
  @spec muted(t()) :: t()
  def muted(%__MODULE__{} = turn), do: %{turn | voice_at: nil, thinking_since: nil}

  @doc """
  A fragment of the operator's words arrived from Live's recognition. Answers
  the state the pet should move to, if any: speaking again while the pet is
  thinking is listening. `speaking?` is whether a reply is being announced.
  """
  @spec words(t(), integer(), boolean()) :: {:listening | nil, t()}
  def words(%__MODULE__{} = turn, now, speaking?)
      when is_integer(now) and is_boolean(speaking?) do
    cond do
      speaking? or reply_audible?(turn, now) -> {nil, %{turn | voice_at: nil}}
      is_nil(turn.thinking_since) -> {nil, %{turn | voice_at: now}}
      true -> {:listening, %{turn | voice_at: now, thinking_since: nil}}
    end
  end

  @doc """
  The clock of the operator's turn, advanced by each microphone chunk (the
  pet streams one every 100 ms for the whole call). Answers `:thinking` once
  their words have stopped for `@words_hangover_ms` with no reply started, and
  `:listening` once a reply has failed to come for `@thinking_limit_ms`.
  """
  @spec tick(t(), integer(), boolean()) :: {:thinking | :listening | nil, t()}
  def tick(%__MODULE__{} = turn, now, speaking?) when is_integer(now) and is_boolean(speaking?) do
    if speaking?, do: {nil, turn}, else: quiet(turn, now)
  end

  defp reply_audible?(%__MODULE__{voiced_until: nil}, _now), do: false
  defp reply_audible?(turn, now), do: now < turn.voiced_until + @echo_tail_ms

  defp quiet(%__MODULE__{thinking_since: since} = turn, now)
       when is_integer(since) and now - since >= @thinking_limit_ms,
       do: {:listening, %{turn | thinking_since: nil}}

  defp quiet(%__MODULE__{voice_at: at, thinking_since: nil} = turn, now)
       when is_integer(at) and now - at >= @words_hangover_ms,
       do: {:thinking, %{turn | voice_at: nil, thinking_since: now}}

  defp quiet(turn, _now), do: {nil, turn}

  defp voiced?(pcm), do: rms(pcm) >= @voiced_rms

  defp rms(pcm) do
    {sum, count} =
      for <<sample::little-signed-16 <- pcm>>, reduce: {0, 0} do
        {sum, count} -> {sum + sample * sample, count + 1}
      end

    if count == 0, do: 0.0, else: :math.sqrt(sum / count)
  end

  defp decode(audio) do
    case Base.decode64(audio) do
      {:ok, pcm} -> pcm
      :error -> <<>>
    end
  end
end
