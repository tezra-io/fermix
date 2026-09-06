defmodule FermixCore.Transcription.ChunkedStreamTest do
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog

  alias FermixCore.Transcription.ChunkedStream
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.StreamSession
  alias FermixTestSupport.PcmFixtures

  @max_inflight 8
  @max_pending 24

  # A batch backend under the test's control: it reports every call to the test
  # process and then behaves per `opts[:mode]`. `:block` parks the task until the
  # test releases it, which is how in-flight counts and completion order become
  # observable.
  defmodule FakeBatchBackend do
    @behaviour FermixCore.Transcription.Backend

    @impl true
    def name, do: :fake_batch

    @impl true
    def capabilities, do: %{streaming?: false, local?: false}

    @impl true
    def configured?(_opts), do: :ok

    @impl true
    def transcribe(path, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:transcribe, path, self()})
      reply(Keyword.fetch!(opts, :mode))
    end

    defp reply(:ok), do: {:ok, "segment text"}
    defp reply(:empty), do: {:ok, "   "}
    defp reply(:error), do: {:error, "provider_error: HTTP 500"}

    defp reply(:block) do
      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :test_release_timeout}
      end
    end
  end

  describe "segment delivery" do
    test "delivers one segment per transcribed chunk and a closed summary" do
      session = open(mode: :ok)

      StreamSession.push_pcm(session, bursts(2))
      StreamSession.finish(session)

      assert_receive {:transcript_segment, ^session, %Segment{text: "segment text"} = first}
      assert_receive {:transcript_segment, ^session, %Segment{} = second}
      assert first.t0_ms < second.t0_ms
      assert first.final?
      assert first.words == nil

      assert_receive {:transcript_stream_closed, ^session, %{segments: 2, dropped: 0}}
    end

    test "an empty transcript emits no segment but still advances the order gate" do
      session = open(mode: :empty)

      StreamSession.push_pcm(session, bursts(1))
      StreamSession.finish(session)

      assert_receive {:transcript_stream_closed, ^session, %{segments: 0, dropped: 0}}
      refute_received {:transcript_segment, _session, _segment}
    end

    test "segments are delivered in t0 order even when the backend completes out of order" do
      session = open(mode: :block)

      StreamSession.push_pcm(session, bursts(2))
      StreamSession.finish(session)

      calls = collect_calls(2)
      # Finish the SECOND chunk first; the gate must hold it back.
      release(calls, 1, {:ok, "second"})
      refute_receive {:transcript_segment, ^session, _segment}, 100

      release(calls, 0, {:ok, "first"})
      assert_receive {:transcript_segment, ^session, %Segment{text: "first"}}
      assert_receive {:transcript_segment, ^session, %Segment{text: "second"}}
      assert_receive {:transcript_stream_closed, ^session, %{segments: 2}}
    end
  end

  describe "bounded work" do
    test "at most @max_inflight transcribe calls run at once" do
      chunk_count = 12
      session = open(mode: :block)

      StreamSession.push_pcm(session, bursts(chunk_count))
      StreamSession.finish(session)

      calls = collect_calls(@max_inflight)
      refute_receive {:transcribe, _path, _task}, 100

      Enum.each(calls, fn call -> send(call.task, {:release, {:ok, "text"}}) end)

      # The in-order gate reaches the eighth segment only once every one of the
      # eight results has been folded in, and `dispatch/1` refills the freed
      # slots inside that same message. Reading the session's own state with a
      # call it can only answer afterwards is the synchronisation point: no
      # wall-clock window decides whether the queued chunks made it into flight.
      Enum.each(1..@max_inflight, fn _ ->
        assert_receive {:transcript_segment, ^session, %Segment{}}, 5_000
      end)

      state = :sys.get_state(session)
      assert map_size(state.inflight) == chunk_count - @max_inflight
      assert :queue.is_empty(state.pending)
    end

    test "a failing segment is retried once, then dropped, logged, and counted" do
      session = open(mode: :error)

      log =
        capture_log(fn ->
          StreamSession.push_pcm(session, bursts(1))
          StreamSession.finish(session)
          assert_receive {:transcript_stream_closed, ^session, %{segments: 0, dropped: 1}}
        end)

      assert log =~ "transcription segment dropped after 2 attempts"
      assert log =~ "provider_error: HTTP 500"

      # Exactly two attempts on the one chunk: no unbounded retry loop.
      assert length(drain_calls()) == 2
    end

    test "pending overflow drops the newest chunk, loudly and counted" do
      session = open(mode: :block)

      log =
        capture_log(fn ->
          # One push carrying more chunks than the queue holds: the queue fills
          # to its cap and the newest three are refused, so what is delivered
          # stays timestamp-monotone.
          StreamSession.push_pcm(session, bursts(@max_pending + 3))
          StreamSession.finish(session)
          release_all(@max_pending, {:ok, "text"})

          assert_receive {:transcript_stream_closed, ^session, summary}, 5_000
          assert summary == %{segments: @max_pending, dropped: 3}
        end)

      assert log =~ "transcription chunk dropped (pending queue full)"
    end
  end

  describe "WAV handoff" do
    test "writes the canonical 16 kHz mono s16le header the batch backends expect" do
      session = open(mode: :block)

      StreamSession.push_pcm(session, bursts(1))
      [call] = collect_calls(1)

      assert {:ok, header} = PcmFixtures.wav_header(File.read!(call.path))
      assert header.format == 1
      assert header.channels == 1
      assert header.sample_rate == 16_000
      assert header.byte_rate == 32_000
      assert header.block_align == 2
      assert header.bits_per_sample == 16
      assert header.data_len == byte_size(header.data)
      assert header.riff_size == 36 + header.data_len

      send(call.task, {:release, {:ok, "text"}})
    end
  end

  describe "resource ownership" do
    test "the session temp dir is gone after a normal close" do
      session = open(mode: :ok)
      tmp_dir = tmp_dir(session)
      ref = Process.monitor(session)

      StreamSession.push_pcm(session, bursts(1))
      StreamSession.finish(session)

      assert_receive {:transcript_stream_closed, ^session, _summary}
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute File.exists?(tmp_dir)
    end

    test "the session temp dir is owner-only while speech WAVs are in flight" do
      session = open(mode: :block)
      tmp_dir = tmp_dir(session)

      StreamSession.push_pcm(session, bursts(1))
      [call] = collect_calls(1)

      # The shared tmp dir is world-traversable, and these WAVs are the same
      # speech TranscriptStore keeps at 0700/0600 — no other local user may
      # read a meeting while its segments are still in flight.
      assert File.exists?(call.path)
      assert {:ok, stat} = File.stat(tmp_dir)
      assert (stat.mode &&& 0o777) == 0o700

      send(call.task, {:release, {:ok, "text"}})
    end

    test "stop/1 aborts in-flight work, cleans up, and sends no closed message" do
      session = open(mode: :block)
      tmp_dir = tmp_dir(session)
      ref = Process.monitor(session)

      StreamSession.push_pcm(session, bursts(1))
      collect_calls(1)

      assert :ok = StreamSession.stop(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute File.exists?(tmp_dir)
      refute_received {:transcript_stream_closed, _session, _summary}
    end

    test "a dead consumer takes the session down silently" do
      test_pid = self()

      consumer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session} =
        ChunkedStream.open(consumer, FakeBatchBackend, test_pid: test_pid, mode: :ok)

      tmp_dir = tmp_dir(session)
      ref = Process.monitor(session)

      send(consumer, :stop)

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute File.exists?(tmp_dir)
    end
  end

  defp open(opts) do
    {:ok, session} =
      ChunkedStream.open(self(), FakeBatchBackend, Keyword.put(opts, :test_pid, self()))

    session
  end

  defp tmp_dir(session), do: :sys.get_state(session).tmp_dir

  # One 2s speech burst plus a pause long enough to end the run, per chunk.
  defp bursts(count) do
    [{:tone, 2_000}, {:silence, 700}]
    |> List.duplicate(count)
    |> List.flatten()
    |> PcmFixtures.pattern()
  end

  defp collect_calls(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:transcribe, path, task}, 5_000
      %{index: segment_index(path), path: path, task: task}
    end)
  end

  defp drain_calls do
    receive do
      {:transcribe, path, _task} -> [path | drain_calls()]
    after
      0 -> []
    end
  end

  defp release(calls, index, result) do
    call = Enum.find(calls, &(&1.index == index))
    send(call.task, {:release, result})
  end

  # Bounded: releases exactly `count` calls, waiting for each in turn.
  defp release_all(count, result) do
    Enum.each(1..count, fn _ ->
      assert_receive {:transcribe, _path, task}, 5_000
      send(task, {:release, result})
    end)
  end

  defp segment_index(path) do
    path |> Path.basename(".wav") |> String.replace_prefix("seg_", "") |> String.to_integer()
  end
end
