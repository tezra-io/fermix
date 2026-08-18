defmodule FermixCore.Meetings.Rtms.MixerTest do
  # Pure module — no processes, no I/O, no global state.
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Rtms.Mixer

  # One bucket's worth of audio: 100 ms of 16 kHz mono s16le.
  @bucket_samples 1_600
  @bucket_ms 100

  defp pcm(value, samples \\ @bucket_samples) do
    for _ <- 1..samples, into: <<>>, do: <<value::little-signed-16>>
  end

  defp samples(binary), do: for(<<sample::little-signed-16 <- binary>>, do: sample)

  # Pushes one bucket of audio per participant and returns {mixer, events}.
  defp bucket(mixer, bucket_index, participants) do
    Enum.reduce(participants, {mixer, []}, fn {id, name, value}, {acc, events} ->
      {acc, produced} = Mixer.push(acc, id, name, pcm(value), bucket_index * @bucket_ms)
      {acc, events ++ produced}
    end)
  end

  defp buckets(mixer, range, participants) do
    Enum.reduce(range, {mixer, []}, fn index, {acc, events} ->
      {acc, produced} = bucket(acc, index, participants)
      {acc, events ++ produced}
    end)
  end

  defp audio(events), do: for({:audio, frame} <- events, do: frame)
  defp speakers(events), do: for({:active_speaker, id, t} <- events, do: {id, t})
  defp rosters(events), do: for({:roster, entries} <- events, do: entries)

  describe "mixing" do
    test "two participants in one bucket are summed sample by sample" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 1_000}, {"b", "Grace", 2_000}])
      {_mixer, events} = Mixer.flush(mixer)

      assert [frame] = audio(events)
      assert byte_size(frame) == @bucket_samples * 2
      assert Enum.uniq(samples(frame)) == [3_000]
    end

    test "a sum past the int16 range saturates instead of wrapping" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 30_000}, {"b", "Grace", 30_000}])
      {_mixer, events} = Mixer.flush(mixer)

      assert [frame] = audio(events)
      assert Enum.uniq(samples(frame)) == [32_767]
    end

    test "a negative sum saturates at the int16 floor" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", -30_000}, {"b", "Grace", -30_000}])
      {_mixer, events} = Mixer.flush(mixer)

      assert [frame] = audio(events)
      assert Enum.uniq(samples(frame)) == [-32_768]
    end

    test "channels of unequal length treat the shorter one as silence past its end" do
      {mixer, _pushed} = Mixer.push(Mixer.new(), "a", "Ada", pcm(1_000, 4), 0)
      {mixer, _pushed} = Mixer.push(mixer, "b", "Grace", pcm(500, 2), 0)
      {_mixer, events} = Mixer.flush(mixer)

      assert [frame] = audio(events)
      assert samples(frame) == [1_500, 1_500, 1_000, 1_000]
    end

    test "an empty mixer flushes to nothing" do
      assert Mixer.flush(Mixer.new()) == {Mixer.new(), []}
    end
  end

  describe "bucket buffering" do
    test "buckets are held until the buffer bound, then the oldest flushes" do
      # Ten buckets fit in the alignment window; the eleventh push pushes the
      # first one out. Without this bound a late channel could buffer forever.
      {mixer, events} = buckets(Mixer.new(), 0..9, [{"a", "Ada", 1_000}])

      assert audio(events) == []

      {_mixer, events} = bucket(mixer, 10, [{"a", "Ada", 1_000}])

      assert length(audio(events)) == 1
    end

    test "flush empties whatever the window is still holding" do
      {mixer, _events} = buckets(Mixer.new(), 0..4, [{"a", "Ada", 1_000}])
      {_mixer, events} = Mixer.flush(mixer)

      assert length(audio(events)) == 5
    end

    test "buckets flush in timestamp order regardless of channel arrival order" do
      {mixer, _pushed} = Mixer.push(Mixer.new(), "a", "Ada", pcm(100, 2), 200)
      {mixer, _pushed} = Mixer.push(mixer, "b", "Grace", pcm(700, 2), 0)
      {_mixer, events} = Mixer.flush(mixer)

      assert [first, second] = audio(events)
      assert Enum.uniq(samples(first)) == [700]
      assert Enum.uniq(samples(second)) == [100]
    end
  end

  describe "active speaker" do
    test "the loudest channel takes the mark once it has led for the hangover window" do
      {mixer, _pushed} = buckets(Mixer.new(), 0..4, [{"a", "Ada", 8_000}, {"b", "Grace", 100}])
      {_mixer, events} = Mixer.flush(mixer)

      # Marked at the start of the third bucket, on the emitted-audio clock.
      assert speakers(events) == [{"a", 200}]
    end

    test "nobody is marked while every channel is below the speech threshold" do
      {mixer, _pushed} = buckets(Mixer.new(), 0..9, [{"a", "Ada", 100}, {"b", "Grace", 80}])
      {_mixer, events} = Mixer.flush(mixer)

      assert speakers(events) == []
    end

    test "a two-bucket interjection does not steal the mark, a three-bucket one does" do
      {mixer, _pushed} = buckets(Mixer.new(), 0..4, [{"a", "Ada", 8_000}, {"b", "Grace", 0}])
      {mixer, _pushed} = buckets(mixer, 5..6, [{"a", "Ada", 0}, {"b", "Grace", 8_000}])
      {mixer, events_before} = Mixer.flush(mixer)

      assert speakers(events_before) == [{"a", 200}]

      {mixer, _pushed} = buckets(mixer, 7..9, [{"a", "Ada", 0}, {"b", "Grace", 8_000}])
      {_mixer, events_after} = Mixer.flush(mixer)

      assert speakers(events_after) == [{"b", 700}]
    end

    test "the mark is emitted only on change, not once per bucket" do
      {mixer, _pushed} = buckets(Mixer.new(), 0..9, [{"a", "Ada", 8_000}])
      {_mixer, events} = Mixer.flush(mixer)

      assert speakers(events) == [{"a", 200}]
    end
  end

  describe "roster" do
    test "a new participant emits a fresh full snapshot" do
      {_mixer, events} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}, {"b", "Grace", 100}])

      assert rosters(events) == [
               [%{id: "a", name: "Ada"}],
               [%{id: "a", name: "Ada"}, %{id: "b", name: "Grace"}]
             ]
    end

    test "an unchanged roster emits nothing" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}])
      {_mixer, events} = bucket(mixer, 1, [{"a", "Ada", 100}])

      assert rosters(events) == []
    end

    test "a rename is a roster change" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}])
      {_mixer, events} = bucket(mixer, 1, [{"a", "Ada Lovelace", 100}])

      assert rosters(events) == [[%{id: "a", name: "Ada Lovelace"}]]
    end

    test "a participant silent past the TTL drops off the roster" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}, {"b", "Grace", 100}])
      {mixer, events} = Mixer.push(mixer, "b", "Grace", pcm(100, 2), 40_000)

      assert rosters(events) == [[%{id: "b", name: "Grace"}]]
      assert Mixer.roster(mixer) == [%{id: "b", name: "Grace"}]
    end

    # Expiry driven by audio alone can never report the room emptying, because
    # the audio it would need is exactly what stopped.
    test "a tick past the TTL empties a roster nobody is transmitting into" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}, {"b", "Grace", 100}])
      {mixer, events} = Mixer.tick(mixer, Mixer.roster_ttl_ms() + 1_000)

      assert rosters(events) == [[]]
      assert Mixer.roster(mixer) == []
    end

    test "a tick inside the TTL changes nothing and emits nothing" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}])
      {mixer, events} = Mixer.tick(mixer, 1_000)

      assert events == []
      assert Mixer.roster(mixer) == [%{id: "a", name: "Ada"}]
    end

    test "a participant who transmits after a tick is kept, not expired by the ticked clock" do
      {mixer, _pushed} = bucket(Mixer.new(), 0, [{"a", "Ada", 100}])
      {mixer, _ticked} = Mixer.tick(mixer, 20_000)
      {mixer, events} = Mixer.push(mixer, "a", "Ada", pcm(100, 2), 100)

      assert rosters(events) == []
      assert Mixer.roster(mixer) == [%{id: "a", name: "Ada"}]
    end

    test "the roster is capped so a hostile or looping stream cannot grow it without bound" do
      mixer =
        Enum.reduce(1..250, Mixer.new(), fn n, acc ->
          {acc, _events} = Mixer.push(acc, "u#{n}", "Participant #{n}", pcm(10, 2), 0)
          acc
        end)

      assert length(Mixer.roster(mixer)) == 200
    end

    test "names are capped so one participant cannot bloat every snapshot" do
      {mixer, _pushed} = Mixer.push(Mixer.new(), "a", String.duplicate("x", 400), pcm(10, 2), 0)

      assert [%{name: name}] = Mixer.roster(mixer)
      assert name == String.duplicate("x", 120)
    end
  end
end
