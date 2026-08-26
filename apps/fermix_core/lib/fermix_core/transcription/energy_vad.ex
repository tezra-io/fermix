defmodule FermixCore.Transcription.EnergyVad do
  @moduledoc """
  Pure energy-based speech segmenter for the batch-backend stream adapter.

  Splits a push-fed s16le/16 kHz/mono stream into speech chunks that
  `FermixCore.Transcription.ChunkedStream` sends to a batch backend one file at
  a time. Fixed RMS threshold, fixed hangover, fixed preroll — no adaptive noise
  floor: this is the bridge that lets a batch-only backend serve a live stream,
  not the product's precision path (Deepgram/xAI/local all segment natively).

  The whole module is a pure function of `{state, pcm}`: no process, no clock,
  no I/O. `clock_samples` counts every sample consumed (speech and silence
  alike) and IS the segment clock, so timestamps can never drift from the bytes
  pushed, and re-slicing the same audio differently yields byte-identical
  chunks. A pushed remainder shorter than one analysis frame is carried, which
  is also what keeps odd byte counts sample-aligned.
  """

  @sample_rate 16_000
  @frame_ms 20
  @frame_bytes 640
  @frame_samples 320
  # RMS over int16 amplitudes, ~-36 dBFS.
  @vad_rms_threshold 500
  # 30 consecutive sub-threshold frames end a speech run.
  @vad_hangover_ms 600
  # Audio retained before a detected onset so plosives are not clipped.
  @vad_preroll_ms 300
  @preroll_bytes div(@vad_preroll_ms * @sample_rate * 2, 1000)

  # A shorter speech run stays open and merges with the next burst — but only
  # inside the merge window below; a run that reaches the maximum is cut
  # mid-speech. The maximum bounds runs whose speech keeps interrupting the
  # silence: 30s of audio is emitted regardless of what it contains.
  @min_segment_ms 2_000
  @max_segment_ms 30_000
  # How much trailing silence a sub-minimum run may wait for its next burst.
  # Past this the run is abandoned back to :silence: no utterance spans a 2s
  # pause, and without the decay a 1s cough followed by sustained silence
  # would stay in :speech forever, shipping 30s near-silence chunks to the
  # paid batch backend for the rest of the stream.
  @max_merge_silence_ms 2_000
  @max_segment_bytes div(@max_segment_ms * @sample_rate * 2, 1000)
  @max_segment_samples div(@max_segment_ms * @sample_rate, 1000)
  # finish/1: a pending run shorter than this is dropped rather than sent.
  @flush_min_ms 300

  @typedoc "One emitted speech chunk: its PCM plus stream-absolute millisecond bounds."
  @type chunk :: %{pcm: binary(), t0_ms: non_neg_integer(), t1_ms: non_neg_integer()}

  @type state :: %{
          mode: :silence | :speech,
          carry: binary(),
          preroll: binary(),
          run: binary(),
          run_t0_samples: non_neg_integer(),
          silence_frames: non_neg_integer(),
          clock_samples: non_neg_integer()
        }

  @doc "A fresh segmenter state positioned at stream start."
  @spec new() :: state()
  def new do
    %{
      mode: :silence,
      carry: <<>>,
      preroll: <<>>,
      run: <<>>,
      run_t0_samples: 0,
      silence_frames: 0,
      clock_samples: 0
    }
  end

  @doc """
  Consumes a chunk of PCM (any byte count, including odd ones) and returns the
  advanced state plus every chunk completed by it, in `t0_ms` order.
  """
  @spec push(state(), binary()) :: {state(), [chunk()]}
  def push(state, pcm) when is_map(state) and is_binary(pcm) do
    {frames, carry} = split_frames(state.carry <> pcm)
    {state, chunks} = Enum.reduce(frames, {%{state | carry: carry}, []}, &step/2)
    {state, Enum.reverse(chunks)}
  end

  @doc """
  Ends the stream: emits the pending run when it carries at least
  `#{@flush_min_ms}ms` of audio, drops it otherwise. Always returns a state in
  `:silence` with empty buffers.
  """
  @spec flush(state()) :: {state(), [chunk()]}
  def flush(%{mode: :speech} = state) do
    case run_ms(state) >= @flush_min_ms do
      true ->
        {reset(state), [%{pcm: state.run, t0_ms: run_t0_ms(state), t1_ms: run_t1_ms(state)}]}

      false ->
        {reset(state), []}
    end
  end

  def flush(state) when is_map(state), do: {reset(state), []}

  defp split_frames(data), do: split_frames(data, [])

  defp split_frames(<<frame::binary-size(@frame_bytes), rest::binary>>, acc),
    do: split_frames(rest, [frame | acc])

  defp split_frames(carry, acc), do: {Enum.reverse(acc), carry}

  defp step(frame, {state, chunks}) do
    frame_start = state.clock_samples
    state = %{state | clock_samples: frame_start + @frame_samples}
    advance(state, frame, rms(frame), frame_start, chunks)
  end

  defp rms(frame) do
    sum =
      for <<s::little-signed-16 <- frame>>, reduce: 0 do
        acc -> acc + s * s
      end

    trunc(:math.sqrt(sum / @frame_samples))
  end

  # Onset: the retained preroll joins the run, so the run starts before the
  # frame that crossed the threshold.
  defp advance(%{mode: :silence} = state, frame, rms, frame_start, chunks)
       when rms >= @vad_rms_threshold do
    state = %{
      state
      | mode: :speech,
        preroll: <<>>,
        run: state.preroll <> frame,
        run_t0_samples: frame_start - div(byte_size(state.preroll), 2),
        silence_frames: 0
    }

    {state, chunks}
  end

  defp advance(%{mode: :silence} = state, frame, _rms, _frame_start, chunks) do
    {%{state | preroll: trim_preroll(state.preroll <> frame)}, chunks}
  end

  defp advance(%{mode: :speech} = state, frame, rms, _frame_start, chunks) do
    state = %{state | run: state.run <> frame, silence_frames: silence_frames(state, rms)}
    emit(state, chunks)
  end

  defp silence_frames(_state, rms) when rms >= @vad_rms_threshold, do: 0
  defp silence_frames(state, _rms), do: state.silence_frames + 1

  # The hard split outranks the hangover check: a run that reached the maximum
  # is cut at exactly @max_segment_ms whatever its trailing content looks like.
  defp emit(state, chunks) do
    cond do
      run_ms(state) >= @max_segment_ms -> hard_split(state, chunks)
      end_of_run?(state) -> close_run(state, chunks)
      merge_window_expired?(state) -> abandon_run(state, chunks)
      true -> {state, chunks}
    end
  end

  defp hard_split(state, chunks) do
    <<pcm::binary-size(@max_segment_bytes), rest::binary>> = state.run
    t0_ms = run_t0_ms(state)

    state = %{
      state
      | run: rest,
        run_t0_samples: state.run_t0_samples + @max_segment_samples
    }

    {state, [%{pcm: pcm, t0_ms: t0_ms, t1_ms: t0_ms + @max_segment_ms} | chunks]}
  end

  defp end_of_run?(state) do
    state.silence_frames * @frame_ms >= @vad_hangover_ms and speech_ms(state) >= @min_segment_ms
  end

  # Reached only with sub-minimum speech: an end_of_run? match is closed first.
  defp merge_window_expired?(state) do
    state.silence_frames * @frame_ms >= @max_merge_silence_ms
  end

  # The burst was too short to transcribe and its merge window has closed:
  # drop it and return to :silence. The run's tail — all silence by now —
  # seeds the next preroll, exactly as close_run does with its cut tail.
  defp abandon_run(state, chunks) do
    {%{reset(state) | preroll: trim_preroll(state.run)}, chunks}
  end

  # The trailing silence is cut from the emitted audio and seeds the next
  # preroll, so the pause is neither transcribed nor lost.
  defp close_run(state, chunks) do
    speech_bytes = speech_bytes(state)
    <<pcm::binary-size(speech_bytes), tail::binary>> = state.run

    chunk = %{
      pcm: pcm,
      t0_ms: run_t0_ms(state),
      t1_ms: ms(state.run_t0_samples + div(speech_bytes, 2))
    }

    {%{reset(state) | preroll: trim_preroll(tail)}, [chunk | chunks]}
  end

  defp speech_bytes(state), do: byte_size(state.run) - state.silence_frames * @frame_bytes
  defp speech_ms(state), do: ms(div(speech_bytes(state), 2))
  defp run_ms(state), do: ms(div(byte_size(state.run), 2))
  defp run_t0_ms(state), do: ms(state.run_t0_samples)
  defp run_t1_ms(state), do: ms(state.run_t0_samples + div(byte_size(state.run), 2))
  defp ms(samples), do: div(samples * 1000, @sample_rate)

  defp trim_preroll(preroll) when byte_size(preroll) <= @preroll_bytes, do: preroll

  defp trim_preroll(preroll),
    do: binary_part(preroll, byte_size(preroll) - @preroll_bytes, @preroll_bytes)

  defp reset(state) do
    %{
      state
      | mode: :silence,
        carry: <<>>,
        preroll: <<>>,
        run: <<>>,
        run_t0_samples: 0,
        silence_frames: 0
    }
  end
end
