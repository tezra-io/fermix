defmodule FermixCore.Transcription.DeepgramStreamTest do
  # async: false — the session tests register a named observer and the telemetry
  # test establishes the global content-capture posture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Transcription.Deepgram
  alias FermixCore.Transcription.DeepgramStream
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.StreamSession

  @moduletag :capture_log

  @fixtures Path.join(__DIR__, "fixtures/deepgram_stream")
  @observer :deepgram_ws_observer
  # 30s of s16le/16k/mono audio: exactly @pcm_buffer_max_bytes.
  @buffer_cap_bytes 960_000

  defmodule FakeWsSocket do
    @moduledoc false
    # Scripted stand-in for the transport: it never opens a socket, it reports
    # every call to the registered observer (the test) and hands back a live pid
    # the session can monitor.

    @observer :deepgram_ws_observer

    def start(opts) do
      parent = Keyword.fetch!(opts, :parent)
      socket = spawn(fn -> follow(parent) end)

      notify(
        {:ws_started, socket, Keyword.fetch!(opts, :url), Keyword.fetch!(opts, :headers), parent}
      )

      {:ok, socket}
    end

    def send_binary(socket, payload), do: notify({:ws_binary, socket, payload})
    def send_text(socket, payload), do: notify({:ws_text, socket, payload})
    def close(socket), do: notify({:ws_close, socket})

    # The stand-in socket outlives nothing: it goes away with the session that
    # owns it, so a test module never leaks idle processes.
    defp follow(parent) do
      Process.monitor(parent)

      receive do
        _anything -> :ok
      end
    end

    defp notify(message) do
      case Process.whereis(@observer) do
        nil -> :ok
        observer -> send(observer, message)
      end

      :ok
    end
  end

  defmodule FailingWsSocket do
    @moduledoc false
    def start(_opts), do: {:error, :econnrefused}
  end

  defmodule OneShotWsSocket do
    @moduledoc false
    # Connects once (the session's init) and refuses every reconnect after it.
    # init and the reconnect both run in the session process, so its dictionary
    # is the whole state this needs.

    def start(opts) do
      case Process.put(:one_shot_used, true) do
        nil -> FakeWsSocket.start(opts)
        true -> {:error, :econnrefused}
      end
    end

    def send_binary(socket, payload), do: FakeWsSocket.send_binary(socket, payload)
    def send_text(socket, payload), do: FakeWsSocket.send_text(socket, payload)
    def close(socket), do: FakeWsSocket.close(socket)
  end

  setup do
    telemetry = Application.get_env(:fermix_core, :telemetry)
    transcription = Application.get_env(:fermix_core, :transcription)
    # Establish both postures this module reads rather than inheriting whatever
    # an earlier module left behind.
    Application.put_env(:fermix_core, :telemetry, capture_content: false)
    Application.put_env(:fermix_core, :transcription, [])
    Process.register(self(), @observer)

    on_exit(fn ->
      restore(:telemetry, telemetry)
      restore(:transcription, transcription)
    end)

    :ok
  end

  describe "wire constants" do
    test "url/1 pins the model and the one PCM format a session speaks" do
      assert DeepgramStream.url("nova-3") ==
               "wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16" <>
                 "&sample_rate=16000&channels=1&smart_format=true&interim_results=false"
    end

    test "headers/1 uses Deepgram's Token scheme" do
      assert DeepgramStream.headers("dg-key") == [{"Authorization", "Token dg-key"}]
    end

    test "control frames are exact bytes" do
      assert DeepgramStream.keepalive_frame() == ~s({"type":"KeepAlive"})
      assert DeepgramStream.close_frame() == ~s({"type":"CloseStream"})
    end
  end

  describe "decode_frame/2" do
    test "a final Results frame becomes a segment on the stream clock" do
      assert {:segment, segment} = DeepgramStream.decode_frame(fixture("results_final"), 0)

      assert %Segment{
               text: "the quarterly numbers look good.",
               t0_ms: 1500,
               t1_ms: 3750,
               final?: true,
               words: nil
             } = segment
    end

    test "the reconnect offset is added to both bounds" do
      assert {:segment, %Segment{t0_ms: 61_500, t1_ms: 63_750}} =
               DeepgramStream.decode_frame(fixture("results_final"), 60_000)
    end

    test "word timings are mapped when present, offset included" do
      assert {:segment, %Segment{words: words}} =
               DeepgramStream.decode_frame(fixture("results_words"), 1_000)

      assert words == [
               %{text: "hello", t0_ms: 1080, t1_ms: 1480},
               %{text: "there", t0_ms: 1560, t1_ms: 2120}
             ]
    end

    test "a silence flush (empty transcript) is ignored, not an empty segment" do
      assert :ignore = DeepgramStream.decode_frame(fixture("results_empty"), 0)
    end

    test "Metadata and other known frame types are ignored" do
      assert :ignore = DeepgramStream.decode_frame(fixture("metadata"), 0)

      assert :ignore =
               DeepgramStream.decode_frame(~s({"type":"UtteranceEnd","last_word_end":3.2}), 0)
    end

    test "a Results frame with the wrong shape is reported malformed" do
      assert {:error, {:malformed, detail}} = DeepgramStream.decode_frame(fixture("malformed"), 0)
      assert detail =~ "Results"
    end

    test "undecodable JSON, a non-object body and a typeless map are all malformed" do
      assert {:error, {:malformed, "{not json"}} = DeepgramStream.decode_frame("{not json", 0)
      assert {:error, {:malformed, _}} = DeepgramStream.decode_frame("[1,2,3]", 0)
      assert {:error, {:malformed, _}} = DeepgramStream.decode_frame(~s({"start":0}), 0)
    end

    test "the malformed detail is bounded to the frame's first bytes" do
      payload = "{" <> String.duplicate("x", 500)
      assert {:error, {:malformed, detail}} = DeepgramStream.decode_frame(payload, 0)
      assert byte_size(detail) == 120
    end
  end

  describe "session lifecycle" do
    test "connects, streams audio, delivers segments, drains on finish" do
      {session, socket} = open_session()

      pcm = :binary.copy(<<0, 1>>, 16_000)
      StreamSession.push_pcm(session, pcm)
      assert_receive {:ws_binary, ^socket, ^pcm}

      inject(session, socket, fixture("results_final"))
      assert_receive {:transcript_segment, ^session, %Segment{text: text, t0_ms: 1500}}
      assert text == "the quarterly numbers look good."

      # An empty flush must not reach the consumer.
      inject(session, socket, fixture("results_empty"))

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"CloseStream"})}

      send(session, {:transcription_ws, socket, {:disconnect, %{reason: {:remote, :normal}}}})
      assert_receive {:transcript_stream_closed, ^session, %{segments: 1, dropped: 0}}
      refute_received {:transcript_segment, ^session, _segment}
    end

    test "the keepalive frame goes out while streaming" do
      {session, socket} = open_session()

      send(session, :keepalive)
      assert_receive {:ws_text, ^socket, ~s({"type":"KeepAlive"})}
    end

    test "a drain that never completes fails the stream on the named deadline" do
      {session, _socket} = open_session()

      StreamSession.finish(session)
      # `:drain_timeout` is the session's own timer message and part of its
      # testable surface: the deadline value itself is fixed in Timeouts.
      send(session, :drain_timeout)

      assert_receive {:transcript_stream_error, ^session,
                      {:timeout, :transcription_ws_close_drain, 10_000}}
    end

    test "stop/1 aborts synchronously without a closed message" do
      {session, socket} = open_session()
      ref = Process.monitor(session)

      assert :ok = StreamSession.stop(session)
      assert_receive {:ws_close, ^socket}
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute_received {:transcript_stream_closed, ^session, _summary}
    end

    test "the session exits silently when its consumer dies" do
      consumer = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, session} =
        DeepgramStream.open(consumer, "dg-key", "nova-3", socket_mod: FakeWsSocket)

      assert_receive {:ws_started, _socket, _url, _headers, ^session}

      ref = Process.monitor(session)
      Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    end

    test "a socket that will not start refuses the open instead of handing back a dead session" do
      assert {:error, {:ws_start_failed, :econnrefused}} =
               DeepgramStream.open(self(), "dg-key", "nova-3", socket_mod: FailingWsSocket)
    end
  end

  describe "reconnect" do
    test "a mid-stream disconnect reconnects and keeps timestamps stream-absolute" do
      {session, socket} = open_session()

      # 1s of audio on the first connection: Deepgram restarts its media clock,
      # so everything after the reconnect must carry that second.
      StreamSession.push_pcm(session, :binary.copy(<<0, 0>>, 16_000))
      assert_receive {:ws_binary, ^socket, _pcm}

      send(session, {:transcription_ws, socket, {:disconnect, :closed}})
      assert_receive {:ws_started, socket2, _url, _headers, ^session}, 1_000

      inject(session, socket2, fixture("results_final"))
      assert_receive {:transcript_segment, ^session, %Segment{t0_ms: 2500, t1_ms: 4750}}
    end

    test "the reconnect budget is per stream lifetime and then fails loud" do
      {session, socket} = open_session()

      socket4 =
        Enum.reduce(1..3, socket, fn _attempt, current ->
          send(session, {:transcription_ws, current, {:disconnect, :closed}})
          assert_receive {:ws_started, next, _url, _headers, ^session}, 1_000
          next
        end)

      send(session, {:transcription_ws, socket4, {:disconnect, :closed}})
      assert_receive {:transcript_stream_error, ^session, {:reconnect_exhausted, :closed}}
      refute_receive {:ws_started, _socket, _url, _headers, ^session}, 500
    end

    test "audio pushed while reconnecting is buffered, capped, and flushed on the new socket" do
      {session, socket} = open_session()

      log =
        capture_log(fn ->
          send(session, {:transcription_ws, socket, {:disconnect, :closed}})
          StreamSession.push_pcm(session, :binary.copy(<<0>>, @buffer_cap_bytes))
          StreamSession.push_pcm(session, :binary.copy(<<1>>, 32_000))
          :sys.get_state(session)
        end)

      assert log =~ "buffer full while reconnecting"

      assert_receive {:ws_started, socket2, _url, _headers, ^session}, 1_000
      assert_receive {:ws_binary, ^socket2, flushed}
      assert byte_size(flushed) == @buffer_cap_bytes
    end

    test "a reconnect that cannot open a socket is terminal" do
      {session, socket} = open_session(socket_mod: OneShotWsSocket)

      send(session, {:transcription_ws, socket, {:disconnect, :closed}})

      assert_receive {:transcript_stream_error, ^session, {:ws_start_failed, :econnrefused}},
                     1_000
    end
  end

  # The clean drain (a remote-normal close, and the bare `:closed` shape in the
  # telemetry test) is pinned in "session lifecycle"; these are its abnormal
  # twins, which used to be indistinguishable from it.
  describe "drain interruption" do
    test "a socket that crashes during the drain fails instead of closing clean" do
      {session, socket} = open_session()

      inject(session, socket, fixture("results_final"))
      assert_receive {:transcript_segment, ^session, _segment}

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"CloseStream"})}

      # The socket died before Deepgram's post-CloseStream final Results: the
      # wrap-up that tail carries is gone, so this is not a finished stream.
      send(session, {:DOWN, socket_ref(session), :process, socket, :killed})

      assert_receive {:transcript_stream_error, ^session, {:drain_interrupted, {:down, :killed}}}

      refute_received {:transcript_stream_closed, ^session, _summary}
    end

    test "a transport error during the drain fails instead of closing clean" do
      {session, socket} = open_session()

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"CloseStream"})}

      status = %{reason: {:error, :econnreset}}
      send(session, {:transcription_ws, socket, {:disconnect, status}})

      assert_receive {:transcript_stream_error, ^session, {:drain_interrupted, ^status}}
      refute_received {:transcript_stream_closed, ^session, _summary}
    end
  end

  describe "protocol errors" do
    test "undecodable frames are tolerated up to the cap, then the stream fails" do
      {session, socket} = open_session()

      Enum.each(1..5, fn _frame -> inject(session, socket, "{not json") end)
      :sys.get_state(session)
      refute_received {:transcript_stream_error, ^session, _reason}

      inject(session, socket, "{not json")
      assert_receive {:transcript_stream_error, ^session, {:protocol_error, "{not json"}}
    end

    test "a binary frame counts against the same cap" do
      {session, socket} = open_session()

      Enum.each(1..6, fn _frame ->
        send(session, {:transcription_ws, socket, {:frame, {:binary, <<0, 1>>}}})
      end)

      assert_receive {:transcript_stream_error, ^session,
                      {:protocol_error, "unexpected binary frame"}}
    end
  end

  describe "telemetry" do
    setup do
      handler_id = "deepgram-stream-provider-call-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:provider_call, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "one span per stream lifetime, previewing the transcript on a clean close" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)
      {session, socket} = open_session(session_id: "sess-stream")

      inject(session, socket, fixture("results_final"))
      assert_receive {:transcript_segment, ^session, _segment}

      StreamSession.finish(session)
      send(session, {:transcription_ws, socket, {:disconnect, :closed}})
      assert_receive {:transcript_stream_closed, ^session, _summary}

      assert_receive {:provider_call, %{duration_ms: duration_ms}, metadata}
      assert is_integer(duration_ms) and duration_ms >= 0
      assert metadata.provider == :deepgram
      assert metadata.adapter == :deepgram
      assert metadata.model == "nova-3"
      assert metadata.status == :ok
      assert metadata.purpose == :transcription
      assert metadata.tokens == %{}
      assert metadata.session_id == "sess-stream"
      assert metadata.output == "the quarterly numbers look good."
      refute_received {:provider_call, _measurements, _metadata}
    end

    test "a drain cut short reports an error span rather than a transcript preview" do
      {session, socket} = open_session()

      StreamSession.finish(session)
      send(session, {:transcription_ws, socket, {:disconnect, %{reason: {:error, :closed}}}})
      assert_receive {:transcript_stream_error, ^session, _reason}

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.error_summary =~ "drain_interrupted"
    end

    test "an aborted stream reports the abort rather than a silent success" do
      {session, _socket} = open_session()

      assert :ok = StreamSession.stop(session)

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.error_summary =~ "aborted"
    end
  end

  describe "Deepgram.open_stream/2" do
    test "resolves the configured key and hands the model to the session" do
      assert {:ok, session} =
               Deepgram.open_stream(self(), api_key: "dg-opts", socket_mod: FakeWsSocket)

      assert_receive {:ws_started, _socket, url, headers, ^session}
      assert url =~ "model=nova-3"
      assert headers == [{"Authorization", "Token dg-opts"}]
    end

    test "a caller's model: opt reaches the streaming URL, not the shared key" do
      # Same cross-family hazard as the batch path: the shared key belongs to
      # the GLOBAL backend, so an explicit per-call model must win here too.
      Application.put_env(:fermix_core, :transcription, model: "gpt-4o-mini-transcribe")

      assert {:ok, session} =
               Deepgram.open_stream(self(),
                 api_key: "dg-opts",
                 model: "nova-2",
                 socket_mod: FakeWsSocket
               )

      assert_receive {:ws_started, _socket, url, _headers, ^session}
      assert url =~ "model=nova-2"
      refute url =~ "gpt-4o-mini-transcribe"
    end

    test "a missing key refuses synchronously, without starting a process" do
      assert {:error, :not_configured} =
               Deepgram.open_stream(self(), socket_mod: FakeWsSocket)

      refute_received {:ws_started, _socket, _url, _headers, _parent}
    end

    test "declares streaming so the dispatcher never wraps it in the chunked adapter" do
      assert Deepgram.capabilities() == %{streaming?: true, local?: false}
    end
  end

  defp open_session(opts \\ []) do
    opts = Keyword.put_new(opts, :socket_mod, FakeWsSocket)
    {:ok, session} = DeepgramStream.open(self(), "dg-key", "nova-3", opts)
    assert_receive {:ws_started, socket, _url, _headers, ^session}
    {session, socket}
  end

  defp socket_ref(session), do: :sys.get_state(session).socket_ref

  defp inject(session, socket, payload),
    do: send(session, {:transcription_ws, socket, {:frame, {:text, payload}}})

  defp fixture(name) do
    @fixtures |> Path.join("#{name}.json") |> File.read!() |> String.trim_trailing("\n")
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
