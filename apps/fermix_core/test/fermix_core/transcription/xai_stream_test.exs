defmodule FermixCore.Transcription.XAIStreamTest do
  # async: false — the session tests register a named observer and the telemetry
  # test establishes the global content-capture posture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.StreamSession
  alias FermixCore.Transcription.XAI
  alias FermixCore.Transcription.XAIStream

  @moduletag :capture_log

  # Fixture provenance (docs.x.ai, retrieved 2026-08-17) is recorded in the
  # fixture directory's README, along with the live capture still owed.
  @fixtures Path.join(__DIR__, "fixtures/xai_stream")
  @observer :xai_ws_observer
  # 30s of s16le/16k/mono audio: exactly @pcm_buffer_max_bytes.
  @buffer_cap_bytes 960_000

  defmodule FakeWsSocket do
    @moduledoc false
    # Scripted stand-in for the transport: it never opens a socket, it reports
    # every call to the registered observer (the test) and hands back a live pid
    # the session can monitor.

    @observer :xai_ws_observer

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
    providers = Application.get_env(:fermix_core, :providers)
    # Establish every posture this module reads rather than inheriting whatever
    # an earlier module left behind.
    Application.put_env(:fermix_core, :telemetry, capture_content: false)
    Application.put_env(:fermix_core, :transcription, [])
    Application.put_env(:fermix_core, :providers, [])
    Process.register(self(), @observer)

    on_exit(fn ->
      restore(:telemetry, telemetry)
      restore(:transcription, transcription)
      restore(:providers, providers)
    end)

    :ok
  end

  describe "wire constants" do
    test "url/0 carries no model and pins the documented PCM spelling" do
      assert XAIStream.url() ==
               "wss://api.x.ai/v1/stt?encoding=pcm&sample_rate=16000&channels=1" <>
                 "&interim_results=false"
    end

    test "headers/1 uses bearer auth" do
      assert XAIStream.headers("xai-key") == [{"Authorization", "Bearer xai-key"}]
    end

    test "the end-of-audio control frame is exact bytes" do
      assert XAIStream.done_frame() == ~s({"type":"audio.done"})
    end
  end

  describe "decode_frame/2" do
    test "transcript.created reports readiness, not a segment" do
      assert :ready = XAIStream.decode_frame(fixture("transcript_created"), 0)
    end

    test "a final transcript.partial becomes a segment with word timings" do
      assert {:segment, segment} = XAIStream.decode_frame(fixture("transcript"), 0)

      assert %Segment{text: "hello there", t0_ms: 1500, t1_ms: 2700, final?: true} = segment

      assert segment.words == [
               %{text: "hello", t0_ms: 80, t1_ms: 480},
               %{text: "there", t0_ms: 560, t1_ms: 1120}
             ]
    end

    test "the reconnect offset is added to segment and word bounds alike" do
      assert {:segment, segment} = XAIStream.decode_frame(fixture("transcript"), 60_000)
      assert segment.t0_ms == 61_500
      assert segment.t1_ms == 62_700
      assert [%{t0_ms: 60_080} | _rest] = segment.words
    end

    test "transcript.done ends the drain and never repeats the transcript as a segment" do
      assert :done = XAIStream.decode_frame(fixture("transcript_done"), 0)
    end

    test "a vendor error carries xAI's own words out" do
      assert {:error, {:vendor, "unsupported sample_rate: 11025"}} =
               XAIStream.decode_frame(fixture("error"), 0)
    end

    test "interim and empty results are ignored" do
      interim = ~s({"type":"transcript.partial","is_final":false,"text":"hel"})

      empty =
        ~s({"type":"transcript.partial","is_final":true,"text":"  ","start":0,"duration":0.4})

      assert :ignore = XAIStream.decode_frame(interim, 0)
      assert :ignore = XAIStream.decode_frame(empty, 0)
      assert :ignore = XAIStream.decode_frame(~s({"type":"transcript.metadata"}), 0)
    end

    test "a partial without the fields a segment needs is malformed" do
      assert {:error, {:malformed, detail}} = XAIStream.decode_frame(fixture("malformed"), 0)
      assert detail =~ "transcript.partial"
    end

    test "undecodable JSON, a non-object body and a typeless map are all malformed" do
      assert {:error, {:malformed, "{not json"}} = XAIStream.decode_frame("{not json", 0)
      assert {:error, {:malformed, _}} = XAIStream.decode_frame("[1,2,3]", 0)
      assert {:error, {:malformed, _}} = XAIStream.decode_frame(~s({"text":"hi"}), 0)
    end
  end

  describe "session lifecycle" do
    test "audio waits for transcript.created, then flushes in order" do
      {session, socket} = open_session()

      early = :binary.copy(<<7>>, 640)
      StreamSession.push_pcm(session, early)
      :sys.get_state(session)
      # Nothing may reach a server that has not said it is ready.
      refute_received {:ws_binary, ^socket, _payload}

      inject(session, socket, fixture("transcript_created"))
      assert_receive {:ws_binary, ^socket, ^early}

      later = :binary.copy(<<9>>, 640)
      StreamSession.push_pcm(session, later)
      assert_receive {:ws_binary, ^socket, ^later}
    end

    test "streams segments and closes on transcript.done" do
      {session, socket} = ready_session()

      inject(session, socket, fixture("transcript"))
      assert_receive {:transcript_segment, ^session, %Segment{text: "hello there", t0_ms: 1500}}

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"audio.done"})}

      inject(session, socket, fixture("transcript_done"))
      assert_receive {:transcript_stream_closed, ^session, %{segments: 1, dropped: 0}}
    end

    test "a server close during the drain ends the stream just as transcript.done would" do
      {session, socket} = ready_session()

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"audio.done"})}

      send(session, {:transcription_ws, socket, {:disconnect, %{reason: {:remote, :normal}}}})
      assert_receive {:transcript_stream_closed, ^session, %{segments: 0, dropped: 0}}
    end

    test "finishing before the server is ready defers audio.done until it is" do
      {session, socket} = open_session()

      StreamSession.finish(session)
      :sys.get_state(session)
      refute_received {:ws_text, ^socket, _payload}

      inject(session, socket, fixture("transcript_created"))
      assert_receive {:ws_text, ^socket, ~s({"type":"audio.done"})}
    end

    test "a drain that never completes fails the stream on the named deadline" do
      {session, socket} = ready_session()

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, _done}
      # `:drain_timeout` is the session's own timer message and part of its
      # testable surface: the deadline value itself is fixed in Timeouts.
      send(session, :drain_timeout)

      assert_receive {:transcript_stream_error, ^session,
                      {:timeout, :transcription_ws_close_drain, 10_000}}
    end

    test "stop/1 aborts synchronously without a closed message" do
      {session, socket} = ready_session()
      ref = Process.monitor(session)

      assert :ok = StreamSession.stop(session)
      assert_receive {:ws_close, ^socket}
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute_received {:transcript_stream_closed, ^session, _summary}
    end

    test "the session exits silently when its consumer dies" do
      consumer = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, session} = XAIStream.open(consumer, "xai-key", socket_mod: FakeWsSocket)
      assert_receive {:ws_started, _socket, _url, _headers, ^session}

      ref = Process.monitor(session)
      Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    end

    test "a socket that will not start refuses the open instead of handing back a dead session" do
      assert {:error, {:ws_start_failed, :econnrefused}} =
               XAIStream.open(self(), "xai-key", socket_mod: FailingWsSocket)
    end
  end

  describe "reconnect" do
    test "a mid-stream disconnect reconnects, re-waits for readiness, and keeps the clock" do
      {session, socket} = ready_session()

      # 1s of audio on the first connection: everything after the reconnect must
      # carry that second, because xAI's clock restarts with the connection.
      StreamSession.push_pcm(session, :binary.copy(<<0, 0>>, 16_000))
      assert_receive {:ws_binary, ^socket, _pcm}

      send(session, {:transcription_ws, socket, {:disconnect, :closed}})
      assert_receive {:ws_started, socket2, _url, _headers, ^session}, 1_000

      inject(session, socket2, fixture("transcript_created"))
      inject(session, socket2, fixture("transcript"))
      assert_receive {:transcript_segment, ^session, %Segment{t0_ms: 2500, t1_ms: 3700}}
    end

    test "the reconnect budget is per stream lifetime and then fails loud" do
      {session, socket} = ready_session()

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

    test "held audio is capped, and the overflow is dropped loudly" do
      {session, socket} = open_session()

      log =
        capture_log(fn ->
          StreamSession.push_pcm(session, :binary.copy(<<0>>, @buffer_cap_bytes))
          StreamSession.push_pcm(session, :binary.copy(<<1>>, 32_000))
          :sys.get_state(session)
        end)

      assert log =~ "buffer full before the connection was ready"

      inject(session, socket, fixture("transcript_created"))
      assert_receive {:ws_binary, ^socket, flushed}
      assert byte_size(flushed) == @buffer_cap_bytes
    end

    test "a reconnect that cannot open a socket is terminal" do
      {session, socket} = open_session(socket_mod: OneShotWsSocket)

      send(session, {:transcription_ws, socket, {:disconnect, :closed}})

      assert_receive {:transcript_stream_error, ^session, {:ws_start_failed, :econnrefused}},
                     1_000
    end
  end

  # The clean drain (a remote-normal close, and `transcript.done`) is pinned in
  # "session lifecycle"; these are its abnormal twins, which used to be
  # indistinguishable from it.
  describe "drain interruption" do
    test "a socket that crashes during the drain fails instead of closing clean" do
      {session, socket} = ready_session()

      inject(session, socket, fixture("transcript"))
      assert_receive {:transcript_segment, ^session, _segment}

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"audio.done"})}

      # The socket died before `transcript.done`: whatever xAI had still to
      # flush is gone, so this is not a finished stream.
      send(session, {:DOWN, socket_ref(session), :process, socket, :killed})

      assert_receive {:transcript_stream_error, ^session, {:drain_interrupted, {:down, :killed}}}

      refute_received {:transcript_stream_closed, ^session, _summary}
    end

    test "a transport error during the drain fails instead of closing clean" do
      {session, socket} = ready_session()

      StreamSession.finish(session)
      assert_receive {:ws_text, ^socket, ~s({"type":"audio.done"})}

      status = %{reason: {:error, :econnreset}}
      send(session, {:transcription_ws, socket, {:disconnect, status}})

      assert_receive {:transcript_stream_error, ^session, {:drain_interrupted, ^status}}
      refute_received {:transcript_stream_closed, ^session, _summary}
    end
  end

  describe "protocol errors" do
    test "a vendor error fails the stream immediately, message intact" do
      {session, socket} = ready_session()

      inject(session, socket, fixture("error"))

      assert_receive {:transcript_stream_error, ^session,
                      {:protocol_error, "unsupported sample_rate: 11025"}}
    end

    test "undecodable frames are tolerated up to the cap, then the stream fails" do
      {session, socket} = ready_session()

      Enum.each(1..5, fn _frame -> inject(session, socket, "{not json") end)
      :sys.get_state(session)
      refute_received {:transcript_stream_error, ^session, _reason}

      inject(session, socket, "{not json")
      assert_receive {:transcript_stream_error, ^session, {:protocol_error, "{not json"}}
    end

    test "a binary frame counts against the same cap" do
      {session, socket} = ready_session()

      Enum.each(1..6, fn _frame ->
        send(session, {:transcription_ws, socket, {:frame, {:binary, <<0, 1>>}}})
      end)

      assert_receive {:transcript_stream_error, ^session,
                      {:protocol_error, "unexpected binary frame"}}
    end
  end

  describe "telemetry" do
    setup do
      handler_id = "xai-stream-provider-call-#{System.unique_integer([:positive])}"
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

    test "one span per stream lifetime, tagged with the shared modelless label" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)
      {session, socket} = ready_session(session_id: "sess-xai")

      inject(session, socket, fixture("transcript"))
      assert_receive {:transcript_segment, ^session, _segment}

      StreamSession.finish(session)
      inject(session, socket, fixture("transcript_done"))
      assert_receive {:transcript_stream_closed, ^session, _summary}

      assert_receive {:provider_call, %{duration_ms: duration_ms}, metadata}
      assert is_integer(duration_ms) and duration_ms >= 0
      assert metadata.provider == :xai
      assert metadata.adapter == :xai
      # One string, shared with the batch backend rather than copied.
      assert metadata.model == XAI.telemetry_model()
      assert metadata.status == :ok
      assert metadata.purpose == :transcription
      assert metadata.tokens == %{}
      assert metadata.session_id == "sess-xai"
      assert metadata.output == "hello there"
      refute_received {:provider_call, _measurements, _metadata}
    end

    test "a drain cut short reports an error span rather than a transcript preview" do
      {session, socket} = ready_session()

      StreamSession.finish(session)
      send(session, {:transcription_ws, socket, {:disconnect, %{reason: {:error, :closed}}}})
      assert_receive {:transcript_stream_error, ^session, _reason}

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.error_summary =~ "drain_interrupted"
    end

    test "a vendor refusal reaches the span as an error, not a silent success" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)
      {session, socket} = ready_session()

      inject(session, socket, fixture("error"))
      assert_receive {:transcript_stream_error, ^session, _reason}

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.error_summary =~ "unsupported sample_rate"
    end
  end

  describe "XAI.open_stream/2" do
    test "resolves the configured key and opens the session" do
      assert {:ok, session} =
               XAI.open_stream(self(), api_key: "xai-opts", socket_mod: FakeWsSocket)

      assert_receive {:ws_started, _socket, url, headers, ^session}
      assert url == XAIStream.url()
      assert headers == [{"Authorization", "Bearer xai-opts"}]
    end

    test "a missing key refuses synchronously, without starting a process" do
      assert {:error, :not_configured} = XAI.open_stream(self(), socket_mod: FakeWsSocket)
      refute_received {:ws_started, _socket, _url, _headers, _parent}
    end

    test "declares streaming so the dispatcher never wraps it in the chunked adapter" do
      assert XAI.capabilities() == %{streaming?: true, local?: false}
      assert XAI.telemetry_model() == "grok-stt"
    end
  end

  defp open_session(opts \\ []) do
    opts = Keyword.put_new(opts, :socket_mod, FakeWsSocket)
    {:ok, session} = XAIStream.open(self(), "xai-key", opts)
    assert_receive {:ws_started, socket, _url, _headers, ^session}
    {session, socket}
  end

  defp ready_session(opts \\ []) do
    {session, socket} = open_session(opts)
    inject(session, socket, fixture("transcript_created"))
    :sys.get_state(session)
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
