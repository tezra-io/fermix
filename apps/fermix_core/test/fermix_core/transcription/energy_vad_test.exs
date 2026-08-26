defmodule FermixCore.Transcription.EnergyVadTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias FermixCore.Transcription.EnergyVad
  alias FermixTestSupport.PcmFixtures

  @max_segment_ms 30_000
  @frame_bytes 640
  @frame_samples 320

  describe "segmentation" do
    test "a pure-silence stream yields no chunks at all (and so no backend calls)" do
      assert segment(PcmFixtures.silence(5_000)) == []
    end

    test "one continuous speech run is emitted by flush with the stream clock" do
      assert [chunk] = segment(PcmFixtures.tone(3_000))
      assert chunk.t0_ms == 0
      assert chunk.t1_ms == 3_000
      assert PcmFixtures.duration_ms(chunk.pcm) == 3_000
    end

    test "a pause long enough to end a run splits it, and the next run keeps its preroll" do
      pcm = PcmFixtures.pattern([{:tone, 3_000}, {:silence, 1_000}, {:tone, 3_000}])

      assert [first, second] = segment(pcm)
      assert {first.t0_ms, first.t1_ms} == {0, 3_000}
      # The second run starts 300ms of preroll before its onset at 4_000ms, so
      # the opening consonant is not clipped off the segment.
      assert {second.t0_ms, second.t1_ms} == {3_700, 7_000}
    end

    test "bursts shorter than the minimum keep the run open and merge" do
      pcm =
        PcmFixtures.pattern([
          {:tone, 1_000},
          {:silence, 1_000},
          {:tone, 1_000},
          {:silence, 1_000}
        ])

      # Neither burst clears @min_segment_ms alone; the pause is retained inside
      # one run that does.
      assert [chunk] = segment(pcm)
      assert {chunk.t0_ms, chunk.t1_ms} == {0, 3_000}
    end

    test "a run that reaches the maximum is hard split at exactly the ceiling" do
      assert [first, second, tail] = segment(PcmFixtures.tone(65_000))

      assert first.t1_ms - first.t0_ms == @max_segment_ms
      assert second.t1_ms - second.t0_ms == @max_segment_ms
      assert {first.t0_ms, second.t0_ms} == {0, 30_000}
      assert {tail.t0_ms, tail.t1_ms} == {60_000, 65_000}
    end

    test "flush emits a pending run at the floor and drops one below it" do
      assert [chunk] = segment(PcmFixtures.tone(400))
      assert {chunk.t0_ms, chunk.t1_ms} == {0, 400}

      assert segment(PcmFixtures.tone(200)) == []
    end

    test "quiet audio below the threshold is never treated as speech" do
      assert segment(PcmFixtures.tone(3_000, 100)) == []
    end

    # The stuck-:speech decay: without it a 1s cough followed by sustained
    # silence never leaves :speech — silence accumulates to the 30s ceiling and
    # ships to the paid batch backend as a near-silence chunk every 30s for the
    # rest of the stream.
    test "a sub-minimum burst followed by sustained silence yields nothing at all" do
      pcm = PcmFixtures.pattern([{:tone, 1_000}, {:silence, 60_000}])

      assert segment(pcm) == []
    end

    test "a burst after the merge window starts a fresh run, not a resumed one" do
      pcm = PcmFixtures.pattern([{:tone, 1_000}, {:silence, 3_000}, {:tone, 3_000}])

      # The 1s burst is abandoned once the merge window closes; the second run
      # stands alone with its own preroll before its 4_000ms onset.
      assert [chunk] = segment(pcm)
      assert {chunk.t0_ms, chunk.t1_ms} == {3_700, 7_000}
    end
  end

  describe "properties" do
    property "chunks are ordered, non-overlapping, and never exceed the ceiling" do
      check all(segments <- audio(), max_runs: 25) do
        chunks = segment(PcmFixtures.pattern(segments))

        Enum.each(chunks, fn chunk ->
          assert chunk.t1_ms >= chunk.t0_ms
          assert chunk.t1_ms - chunk.t0_ms <= @max_segment_ms
          assert PcmFixtures.duration_ms(chunk.pcm) == chunk.t1_ms - chunk.t0_ms
        end)

        chunks
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [earlier, later] -> assert earlier.t1_ms <= later.t0_ms end)
      end
    end

    property "re-slicing the same audio yields byte-identical chunks" do
      check all(
              segments <- audio(),
              sizes <- list_of(integer(1..7_000), min_length: 1, max_length: 12),
              max_runs: 25
            ) do
        pcm = PcmFixtures.pattern(segments)

        # Odd byte counts included: the carry buffer is what keeps a sliced
        # push sample-aligned with a single one.
        assert segment(pcm) == sliced_segment(pcm, sizes)
      end
    end

    property "emitted audio never exceeds pushed audio and the clock tracks whole frames" do
      check all(segments <- audio(), max_runs: 25) do
        pcm = PcmFixtures.pattern(segments)
        {state, chunks} = EnergyVad.push(EnergyVad.new(), pcm)
        {_state, tail} = EnergyVad.flush(state)

        emitted = Enum.reduce(chunks ++ tail, 0, &(byte_size(&1.pcm) + &2))
        assert emitted <= byte_size(pcm)
        assert state.clock_samples == div(byte_size(pcm), @frame_bytes) * @frame_samples
      end
    end
  end

  defp audio do
    list_of(tuple({member_of([:silence, :tone]), integer(20..800)}),
      min_length: 1,
      max_length: 6
    )
  end

  defp segment(pcm) do
    {state, chunks} = EnergyVad.push(EnergyVad.new(), pcm)
    {_state, tail} = EnergyVad.flush(state)
    chunks ++ tail
  end

  defp sliced_segment(pcm, sizes) do
    {state, chunks} =
      pcm
      |> slices(sizes)
      |> Enum.reduce({EnergyVad.new(), []}, fn slice, {state, acc} ->
        {state, emitted} = EnergyVad.push(state, slice)
        {state, acc ++ emitted}
      end)

    {_state, tail} = EnergyVad.flush(state)
    chunks ++ tail
  end

  defp slices(<<>>, _sizes), do: []
  defp slices(pcm, []), do: [pcm]

  defp slices(pcm, [size | rest]) do
    take = min(size, byte_size(pcm))
    <<slice::binary-size(take), remainder::binary>> = pcm
    [slice | slices(remainder, rest)]
  end
end
