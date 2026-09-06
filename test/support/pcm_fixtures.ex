defmodule FermixTestSupport.PcmFixtures do
  @moduledoc """
  Deterministic s16le/16 kHz/mono PCM builders for the transcription streaming
  suites.

  `tone/2` is a 1 kHz square wave, so every sample is `+amplitude` or
  `-amplitude` and the frame RMS is exactly the amplitude — no float noise, and
  a VAD threshold assertion means precisely what it says. `silence/1` is zero
  bytes. `pattern/1` composes the two, which is how a fixture spells "three
  seconds of speech, a second of pause, three more seconds".
  """

  @sample_rate 16_000
  @bytes_per_sample 2
  # 1 kHz square wave at 16 kHz: 16 samples per cycle, half high, half low.
  @half_cycle_samples 8

  @doc "Zero-amplitude PCM of `ms` milliseconds."
  @spec silence(non_neg_integer()) :: binary()
  def silence(ms) when is_integer(ms) and ms >= 0 do
    :binary.copy(<<0::little-signed-16>>, samples(ms))
  end

  @doc "A 1 kHz square wave of `ms` milliseconds whose frame RMS equals `amplitude`."
  @spec tone(non_neg_integer(), pos_integer()) :: binary()
  def tone(ms, amplitude \\ 8_000)
      when is_integer(ms) and ms >= 0 and is_integer(amplitude) and amplitude > 0 do
    cycle =
      :binary.copy(<<amplitude::little-signed-16>>, @half_cycle_samples) <>
        :binary.copy(<<-amplitude::little-signed-16>>, @half_cycle_samples)

    total = samples(ms) * @bytes_per_sample
    repeats = div(total, byte_size(cycle)) + 1

    cycle |> :binary.copy(repeats) |> binary_part(0, total)
  end

  @doc "Concatenates `[{:silence, ms} | {:tone, ms}]` segments into one PCM binary."
  @spec pattern([{:silence | :tone, non_neg_integer()}]) :: binary()
  def pattern(segments) when is_list(segments) do
    Enum.map_join(segments, "", fn
      {:silence, ms} -> silence(ms)
      {:tone, ms} -> tone(ms)
    end)
  end

  @doc """
  Parses a canonical 44-byte WAV header into its fields, or `:error` when the
  bytes are not the header this repo writes.
  """
  @spec wav_header(binary()) :: {:ok, map()} | :error
  def wav_header(
        <<"RIFF", riff_size::little-32, "WAVE", "fmt ", 16::little-32, format::little-16,
          channels::little-16, sample_rate::little-32, byte_rate::little-32,
          block_align::little-16, bits::little-16, "data", data_len::little-32, data::binary>>
      ) do
    {:ok,
     %{
       riff_size: riff_size,
       format: format,
       channels: channels,
       sample_rate: sample_rate,
       byte_rate: byte_rate,
       block_align: block_align,
       bits_per_sample: bits,
       data_len: data_len,
       data: data
     }}
  end

  def wav_header(_binary), do: :error

  @doc "Milliseconds of s16le/16 kHz/mono audio in `pcm`."
  @spec duration_ms(binary()) :: non_neg_integer()
  def duration_ms(pcm) when is_binary(pcm),
    do: div(byte_size(pcm) * 1000, @sample_rate * @bytes_per_sample)

  defp samples(ms), do: div(ms * @sample_rate, 1000)
end
