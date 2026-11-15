defmodule FermixChannels.Accessories.Call.SpeakerTest do
  @moduledoc """
  The host's speaker accounting for one accessory call
  (`priv/accessory/PROTOCOL.md`, *Speaker and credit*): never a byte past
  credit, frames of at most 3,840 bytes, segments numbered from 1 with only
  one taking audio, at most 8 open, a flush that closes every open segment,
  and the backlog kept on the host.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Accessories.Call.Speaker

  defp pcm(bytes), do: :binary.copy(<<1, 2>>, div(bytes, 2))

  defp sent_bytes(out),
    do:
      out
      |> Enum.filter(&match?({:pcm, _}, &1))
      |> Enum.map(&byte_size(elem(&1, 1)))
      |> Enum.sum()

  test "a call's stream starts with no credit: audio waits on the host" do
    {:ok, speaker} = Speaker.audio(Speaker.new(), pcm(9_600), nil)
    {out, speaker} = Speaker.pump(speaker)

    assert out == [{:begin, 1, nil}]
    assert Speaker.backlog_bytes(speaker) == 9_600
  end

  test "audio goes out within credit, in frames of at most 3,840 bytes" do
    {:ok, speaker} = Speaker.audio(Speaker.new(), pcm(9_600), nil)
    {:ok, speaker} = Speaker.credit(speaker, 8_192)
    {out, speaker} = Speaker.pump(speaker)

    frames = for {:pcm, bytes} <- out, do: byte_size(bytes)
    assert frames == [3_840, 3_840, 512]
    assert Speaker.outstanding(speaker) == 0
    assert Speaker.backlog_bytes(speaker) == 1_408

    {:ok, speaker} = Speaker.credit(speaker, 2_000)
    {out, _speaker} = Speaker.pump(speaker)
    assert sent_bytes(out) == 1_408
  end

  test "a grant that would pass 8,192 outstanding is credit_overgrant" do
    {:ok, speaker} = Speaker.credit(Speaker.new(), 8_192)
    assert {:error, :credit_overgrant} = Speaker.credit(speaker, 1)
  end

  test "a reply's segment ends when the reply ends and its audio is out" do
    {:ok, speaker} = Speaker.audio(Speaker.new(), pcm(1_000), nil)
    {:ok, speaker} = Speaker.credit(speaker, 8_192)
    {out, speaker} = Speaker.pump(speaker)
    assert [{:begin, 1, nil}, {:pcm, _}] = out

    {out, _speaker} = speaker |> Speaker.reply_ended() |> Speaker.pump()
    assert out == [{:end, 1}]
  end

  test "a new playback id is a new segment, numbered one more" do
    {:ok, speaker} = Speaker.credit(Speaker.new(), 8_192)
    {:ok, speaker} = Speaker.audio(speaker, pcm(100), "p1")
    {:ok, speaker} = Speaker.audio(speaker, pcm(100), "p2")
    {out, _speaker} = Speaker.pump(speaker)

    assert [{:begin, 1, "p1"}, {:pcm, _}, {:end, 1}, {:begin, 2, "p2"}, {:pcm, _}] = out
  end

  test "a ninth open segment waits for a drain" do
    {:ok, speaker} = Speaker.credit(Speaker.new(), 8_192)

    speaker =
      Enum.reduce(1..9, speaker, fn _reply, acc ->
        {:ok, acc} = Speaker.audio(acc, pcm(100), nil)
        Speaker.reply_ended(acc)
      end)

    {out, speaker} = Speaker.pump(speaker)
    begins = for {:begin, segment, _id} <- out, do: segment
    assert begins == Enum.to_list(1..8)
    assert Speaker.open_segments(speaker) == 8

    {out, _speaker} = speaker |> Speaker.drained(1) |> Speaker.pump()
    assert {:begin, 9, nil} in out
  end

  test "a flush drops the backlog and closes every open segment; credit is unchanged" do
    {:ok, speaker} = Speaker.audio(Speaker.new(), pcm(20_000), nil)
    {:ok, speaker} = Speaker.credit(speaker, 4_000)
    {_out, speaker} = Speaker.pump(speaker)
    {:ok, speaker} = Speaker.credit(speaker, 1_000)

    assert {true, speaker} = Speaker.flush(speaker)
    assert Speaker.backlog_bytes(speaker) == 0
    assert Speaker.open_segments(speaker) == 0
    assert Speaker.outstanding(speaker) == 1_000

    # Nothing open or queued: a second flush has nothing to say.
    assert {false, _speaker} = Speaker.flush(speaker)
  end

  test "an odd byte is carried to the next audio of the same playback id and reply" do
    {:ok, speaker} = Speaker.credit(Speaker.new(), 8_192)
    {:ok, speaker} = Speaker.audio(speaker, <<1, 2, 3>>, "p1")
    {:ok, speaker} = Speaker.audio(speaker, <<4>>, "p1")
    {out, speaker} = Speaker.pump(speaker)

    assert for({:pcm, pcm} <- out, do: pcm) |> IO.iodata_to_binary() == <<1, 2, 3, 4>>
    assert Speaker.counters(speaker).speaker_bytes_dropped == 0
  end

  test "an odd byte is never carried across a playback id or a reply, and is counted" do
    {:ok, speaker} = Speaker.credit(Speaker.new(), 8_192)
    {:ok, speaker} = Speaker.audio(speaker, <<1, 2, 3>>, "p1")
    {:ok, speaker} = Speaker.audio(speaker, <<9, 9>>, "p2")
    {:ok, speaker} = Speaker.audio(speaker, <<5>>, "p2")
    speaker = Speaker.reply_ended(speaker)
    {:ok, speaker} = Speaker.audio(speaker, <<7, 7>>, "p2")
    {out, speaker} = Speaker.pump(speaker)

    assert for({:pcm, pcm} <- out, do: pcm) == [<<1, 2>>, <<9, 9>>, <<7, 7>>]
    assert Speaker.counters(speaker).speaker_bytes_dropped == 2
  end

  test "a backlog past two minutes of audio is refused" do
    assert {:error, :speaker_backlog} =
             Speaker.audio(Speaker.new(), pcm(Speaker.max_backlog_bytes() + 2), nil)
  end

  test "counters say what went out and how often audio waited on credit" do
    {:ok, speaker} = Speaker.audio(Speaker.new(), pcm(5_000), nil)
    {_out, speaker} = Speaker.pump(speaker)
    {:ok, speaker} = Speaker.credit(speaker, 3_840)
    {_out, speaker} = Speaker.pump(speaker)
    {:ok, speaker} = Speaker.credit(speaker, 2_000)
    {_out, speaker} = Speaker.pump(speaker)

    assert %{
             speaker_frames: 2,
             speaker_bytes: 5_000,
             segments: 1,
             credit_waits: 2,
             backlog_peak_bytes: 5_000
           } = Speaker.counters(speaker)
  end
end
