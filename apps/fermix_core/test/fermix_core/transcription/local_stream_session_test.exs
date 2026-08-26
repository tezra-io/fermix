defmodule FermixCore.Transcription.Local.StreamSessionTest do
  # async: true — each case owns its own sidecar process and consumer mailbox.
  use ExUnit.Case, async: true

  alias FermixCore.Transcription.Local.StreamSession
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.StreamSession, as: Contract

  @fake Path.expand("fake_stt_sidecar.pl", __DIR__)

  # 100 ms of s16le/16 kHz/mono silence: 1 600 samples, 3 200 bytes.
  @pcm :binary.copy(<<0, 0>>, 1_600)

  test "pushes audio, then delivers a segment and a close summary on finish" do
    {:ok, session} = StreamSession.open(self(), opts())
    ref = Process.monitor(session)

    Contract.push_pcm(session, @pcm)
    Contract.finish(session)

    assert_receive {:transcript_segment, ^session, %Segment{} = segment}, 2_000
    assert segment.text == "fake segment"
    assert segment.final?
    assert segment.words == nil
    assert segment.t0_ms == 0
    # The fake reports t1 from the bytes it actually decoded: 3 200 / 32 = 100 ms.
    assert segment.t1_ms == 100

    assert_receive {:transcript_stream_closed, ^session, %{segments: 1, dropped: 0}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
  end

  test "splits a push larger than one audio frame across frames" do
    {:ok, session} = StreamSession.open(self(), opts())

    # 96 KB of audio is two frames at the 64 KB cap; the fake counts the decoded
    # bytes, so the segment's t1 proves every frame arrived.
    Contract.push_pcm(session, :binary.copy(<<0, 0>>, 49_152))
    Contract.finish(session)

    assert_receive {:transcript_segment, ^session, %Segment{t1_ms: 3_072}}, 2_000
    assert_receive {:transcript_stream_closed, ^session, %{segments: 1}}, 2_000
  end

  test "a sidecar that dies mid-stream is terminal, never retried" do
    {:ok, session} = StreamSession.open(self(), opts(~c"die"))
    ref = Process.monitor(session)

    Contract.push_pcm(session, @pcm)

    assert_receive {:transcript_stream_error, ^session, {:sidecar_exit, 3}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
    refute_received {:transcript_stream_closed, ^session, _summary}
  end

  test "a stream_start refusal fails the open call, leaving no session behind" do
    assert {:error, {:sidecar_error, "decode_failed", "fake decode failure"}} =
             StreamSession.open(self(), opts(~c"error"))
  end

  test "a sidecar that never handshakes trips the hello deadline" do
    assert {:error, {:timeout, :stt_sidecar_hello, 300}} =
             StreamSession.open(
               self(),
               opts(~c"hang_hello") |> Keyword.put(:hello_timeout_ms, 300)
             )
  end

  test "an unresolvable model directory refuses before spawning" do
    assert StreamSession.open(self(), binary_path: @fake) == {:error, :model_not_installed}
  end

  test "stop/1 aborts synchronously without a close summary" do
    {:ok, session} = StreamSession.open(self(), opts())

    ref = Process.monitor(session)

    assert Contract.stop(session) == :ok
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
    refute_received {:transcript_stream_closed, ^session, _summary}
  end

  test "the session dies silently with its consumer" do
    test_pid = self()

    consumer =
      spawn(fn ->
        {:ok, session} = StreamSession.open(self(), opts())
        send(test_pid, {:session, session})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:session, session}, 2_000
    ref = Process.monitor(session)
    Process.exit(consumer, :kill)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
  end

  test "emits one provider-call span for the whole stream" do
    handler = "stt-local-stream-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :provider, :call],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:span, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, session} = StreamSession.open(self(), opts())
    Contract.push_pcm(session, @pcm)
    Contract.finish(session)

    assert_receive {:transcript_stream_closed, ^session, _summary}, 2_000
    assert_receive {:span, measurements, metadata}, 2_000

    assert metadata.provider == :local
    assert metadata.model == "parakeet-tdt-0.6b-v3-int8"
    assert metadata.purpose == :transcription
    assert metadata.status == :ok
    assert metadata.tokens == %{}
    assert is_integer(measurements.duration_ms)
  end

  # A consumer crash is the one terminal where post-mortem tracing matters
  # most: nobody is left to report the stream, so only the span says why it
  # ended.
  test "a consumer death still reports the stream's terminal span" do
    handler = "stt-local-consumer-down-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :provider, :call],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:span, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    consumer =
      spawn(fn ->
        {:ok, session} = StreamSession.open(self(), opts())
        send(test_pid, {:session, session})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:session, session}, 2_000
    ref = Process.monitor(session)
    Process.exit(consumer, :kill)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
    assert_receive {:span, _measurements, metadata}, 2_000
    assert metadata.status == :error
    assert metadata.error_summary =~ "consumer_down"
  end

  defp opts(mode \\ nil) do
    env = if mode, do: [{~c"FAKE_STT_MODE", mode}], else: []

    [
      binary_path: @fake,
      model_dir: "/tmp/fake-model",
      hello_timeout_ms: 2_000,
      flush_timeout_ms: 2_000,
      env: env
    ]
  end
end
