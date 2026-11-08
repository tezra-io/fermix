defmodule FermixChannels.Mobile.CallAudioTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.CallAudio

  # 100 ms of PCM16 at 24 kHz mono.
  @frame :binary.copy(<<0, 1>>, 2_400)

  test "a stretch is cut into frames of at most 100 ms, keeping its playback id" do
    {:ok, audio} = CallAudio.put(CallAudio.new(), "p1", @frame <> @frame <> <<0, 0>>, 0)
    {_audio, sent, 0} = CallAudio.take(audio, 0, true)

    assert Enum.map(sent, fn {id, pcm} -> {id, byte_size(pcm)} end) ==
             [{"p1", 4_800}, {"p1", 4_800}, {"p1", 2}]
  end

  test "audio that is not whole PCM16 samples is refused" do
    assert CallAudio.put(CallAudio.new(), "p1", <<0, 0, 0>>, 0) == {:error, :invalid_audio}
  end

  test "no more than 500 ms goes out unplayed; a report frees room" do
    audio = put_frames(CallAudio.new(), "m1", 7, 0)
    {audio, sent, 0} = CallAudio.take(audio, 0, true)

    assert length(sent) == 5
    assert CallAudio.outstanding_ms(audio) == 500

    {:ok, audio} = CallAudio.progress(audio, "m1", 200, false)
    {audio, sent, 0} = CallAudio.take(audio, 10, true)
    assert length(sent) == 2
    assert CallAudio.outstanding_ms(audio) == 500
  end

  test "a playback reported drained holds nothing, until more of it goes out" do
    audio = put_frames(CallAudio.new(), "m1", 3, 0)
    {audio, _sent, 0} = CallAudio.take(audio, 0, true)

    {:ok, audio} = CallAudio.progress(audio, "m1", 120, true)
    assert CallAudio.outstanding_ms(audio) == 0

    audio = put_frames(audio, "m1", 1, 10)
    {audio, [_frame], 0} = CallAudio.take(audio, 10, true)
    assert CallAudio.outstanding_ms(audio) == 300 - 120 + 100
  end

  # As the session refuses them (`GrokPlayback`): the phone can report only on
  # what it was sent, and never backwards.
  test "a report the phone could not have made is refused" do
    audio = put_frames(CallAudio.new(), "m1", 2, 0)
    {audio, _sent, 0} = CallAudio.take(audio, 0, true)

    assert CallAudio.progress(audio, "p9", 0, false) == {:error, :unknown_playback}
    assert CallAudio.progress(audio, "m1", 201, false) == {:error, :playback_beyond_sent}
    assert {:ok, audio} = CallAudio.progress(audio, "m1", 200, false)
    assert CallAudio.progress(audio, "m1", 150, true) == {:error, :playback_regressed}
    assert CallAudio.outstanding_ms(audio) == 0
  end

  test "audio that waited 300 ms is dropped before it is written" do
    audio = put_frames(CallAudio.new(), "m1", 5, 0)
    {audio, _sent, 0} = CallAudio.take(audio, 0, true)
    audio = put_frames(audio, "m1", 2, 100)

    {audio, [], 0} = CallAudio.take(audio, 399, true)
    {audio, [], 2} = CallAudio.take(audio, 400, true)
    refute CallAudio.too_slow?(audio, 400)
  end

  test "a detached phone gets nothing; what waits ages out all the same" do
    audio = put_frames(CallAudio.new(), "m1", 2, 0)

    {audio, [], 0} = CallAudio.take(audio, 100, false)
    {_audio, [], 2} = CallAudio.take(audio, 300, false)
  end

  test "a link that keeps audio waiting for 5 s is too slow; catching up clears it" do
    audio = put_frames(CallAudio.new(), "m1", 6, 0)
    {audio, _sent, 0} = CallAudio.take(audio, 0, true)
    refute CallAudio.too_slow?(audio, 0)

    audio = put_frames(audio, "m1", 1, 4_900)
    {audio, [], _dropped} = CallAudio.take(audio, 4_900, true)
    refute CallAudio.too_slow?(audio, 4_999)
    assert CallAudio.too_slow?(audio, 5_000)

    {:ok, audio} = CallAudio.progress(audio, "m1", 500, true)
    {audio, _sent, 0} = CallAudio.take(audio, 5_000, true)
    refute CallAudio.too_slow?(audio, 20_000)
  end

  test "a playback stop drops what waits" do
    audio = put_frames(CallAudio.new(), "m1", 8, 0)
    {audio, _sent, 0} = CallAudio.take(audio, 0, true)

    {_audio, [], 0} = audio |> CallAudio.clear() |> CallAudio.take(0, true)
  end

  test "at most 64 frames wait; the oldest go first" do
    audio = put_frames(CallAudio.new(), "m1", 70, 0)
    {audio, sent, 0} = CallAudio.take(audio, 0, true)

    assert length(sent) == 5
    assert audio.queued == 59
  end

  defp put_frames(audio, id, count, at) do
    Enum.reduce(1..count, audio, fn _n, audio ->
      {:ok, audio} = CallAudio.put(audio, id, @frame, at)
      audio
    end)
  end
end
