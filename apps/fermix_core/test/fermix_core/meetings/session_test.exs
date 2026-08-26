defmodule FermixCore.Meetings.SessionTest.Observer do
  @moduledoc false
  # The one channel every stub in this file reports through. Registering the
  # running test process under a fixed name keeps the stubs plain modules with
  # no state of their own, so nothing leaks from one test into the next.

  @name :meetings_session_test_observer

  def register, do: Process.register(self(), @name)

  def notify(message) do
    case Process.whereis(@name) do
      # A stub that outlived its test has nobody to report to; the test it
      # belonged to is already over.
      nil -> :ok
      observer -> send(observer, message)
    end
  end
end

defmodule FermixCore.Meetings.SessionTest.StubSource do
  @moduledoc false
  # An `AudioSource` that only records what the Session asked of it. The tests
  # send the normalized messages to the Session directly, which is exactly what
  # a real source does.

  @behaviour FermixCore.Meetings.AudioSource

  use GenServer, restart: :temporary

  alias FermixCore.Meetings.SessionTest.Observer

  @impl FermixCore.Meetings.AudioSource
  def start_link(session, args), do: GenServer.start_link(__MODULE__, {session, args})

  @impl FermixCore.Meetings.AudioSource
  def leave(source), do: GenServer.cast(source, :leave)

  @impl FermixCore.Meetings.AudioSource
  def stop(source) do
    if Process.alive?(source), do: GenServer.stop(source, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl FermixCore.Meetings.AudioSource
  def self_count, do: 1

  @impl GenServer
  def init({session, args}) do
    Observer.notify({:source_started, self(), args})
    {:ok, %{session: session}}
  end

  @impl GenServer
  def handle_cast(:leave, state) do
    Observer.notify({:source_leave, self()})
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Observer.notify({:source_stopped, self()})
    :ok
  end
end

defmodule FermixCore.Meetings.SessionTest.SeatlessSource do
  @moduledoc false
  # The RTMS-shaped lane: the app is not a participant, so a roster of one is a
  # roster with one human in it.

  @behaviour FermixCore.Meetings.AudioSource

  alias FermixCore.Meetings.SessionTest.StubSource

  @impl FermixCore.Meetings.AudioSource
  def start_link(session, args), do: StubSource.start_link(session, args)

  @impl FermixCore.Meetings.AudioSource
  def leave(source), do: StubSource.leave(source)

  @impl FermixCore.Meetings.AudioSource
  def stop(source), do: StubSource.stop(source)

  @impl FermixCore.Meetings.AudioSource
  def self_count, do: 0
end

defmodule FermixCore.Meetings.SessionTest.RefusingSource do
  @moduledoc false

  @behaviour FermixCore.Meetings.AudioSource

  @impl FermixCore.Meetings.AudioSource
  def start_link(_session, _args), do: {:error, :chromium_missing}

  @impl FermixCore.Meetings.AudioSource
  def leave(_source), do: :ok

  @impl FermixCore.Meetings.AudioSource
  def stop(_source), do: :ok

  @impl FermixCore.Meetings.AudioSource
  def self_count, do: 1
end

defmodule FermixCore.Meetings.SessionTest.StubStream do
  @moduledoc false
  # Speaks the `Transcription.StreamSession` message contract from the session
  # side: `finish/1` and `stop/1` land here as the real API sends them, and the
  # test decides when the stream closes.

  use GenServer

  alias FermixCore.Meetings.SessionTest.Observer

  def start(consumer), do: GenServer.start(__MODULE__, consumer)

  @impl GenServer
  def init(consumer) do
    Observer.notify({:stt_opened, self()})
    {:ok, %{consumer: consumer}}
  end

  @impl GenServer
  def handle_cast({:push_pcm, pcm}, state) do
    Observer.notify({:stt_pcm, byte_size(pcm)})
    {:noreply, state}
  end

  def handle_cast(:finish, state) do
    Observer.notify({:stt_finish, self()})
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    Observer.notify({:stt_stop, self()})
    {:stop, :normal, :ok, state}
  end
end

defmodule FermixCore.Meetings.SessionTest.StubTranscription do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer
  alias FermixCore.Meetings.SessionTest.StubStream

  def open_stream(consumer, opts) do
    Observer.notify({:stt_open, opts})
    StubStream.start(consumer)
  end
end

defmodule FermixCore.Meetings.SessionTest.FailingTranscription do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer

  def open_stream(_consumer, opts) do
    Observer.notify({:stt_open, opts})
    {:error, :missing_api_key}
  end
end

defmodule FermixCore.Meetings.SessionTest.OkSummarizer do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer

  @text "## TL;DR\n- shipped the thing\n"

  def text, do: @text

  def run(meeting, transcript_md, opts) do
    Observer.notify({:summarize, meeting, transcript_md, opts})
    {:ok, %{text: @text, chunks_used: 1, truncated?: false}}
  end
end

defmodule FermixCore.Meetings.SessionTest.FailingSummarizer do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer

  def run(_meeting, _transcript_md, _opts) do
    Observer.notify(:summarize_called)
    {:error, :provider_unavailable}
  end
end

defmodule FermixCore.Meetings.SessionTest.HangingSummarizer do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer

  def run(_meeting, _transcript_md, _opts) do
    Observer.notify(:summarize_called)
    Process.sleep(:infinity)
  end
end

defmodule FermixCore.Meetings.SessionTest.OkDelivery do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer

  def deliver(meeting, text, opts) do
    Observer.notify({:deliver, meeting, text, opts})
    {:ok, :sent}
  end

  def notice(origin_session_id, text, opts) do
    Observer.notify({:notice, origin_session_id, text, opts})
    {:ok, :sent}
  end
end

defmodule FermixCore.Meetings.SessionTest.NoTargetDelivery do
  @moduledoc false

  def deliver(_meeting, _text, _opts), do: {:error, :no_delivery_target}
  def notice(_origin, _text, _opts), do: {:error, :no_delivery_target}
end

defmodule FermixCore.Meetings.SessionTest.FailingDelivery do
  @moduledoc false

  def deliver(_meeting, _text, _opts), do: {:error, {:delivery_failed, :closed}}
  def notice(_origin, _text, _opts), do: {:error, {:delivery_failed, :closed}}
end

defmodule FermixCore.Meetings.SessionTest.StubCaffeinate do
  @moduledoc false

  alias FermixCore.Meetings.SessionTest.Observer

  def start(mode) do
    Observer.notify({:caffeinate_start, mode})
    {:ok, :stub_guard}
  end

  def stop(guard) do
    Observer.notify({:caffeinate_stop, guard})
    :ok
  end
end

defmodule FermixCore.Meetings.SessionTest.PresentInstaller do
  @moduledoc false

  def binary_path, do: {:ok, "/nonexistent/fermix-meetbot"}
end

defmodule FermixCore.Meetings.SessionTest.MissingInstaller do
  @moduledoc false

  def binary_path, do: {:error, :not_installed}
end

defmodule FermixCore.Meetings.SessionTest do
  @moduledoc false
  # One test per row of the C2 §2.2 transition table. Every collaborator is a
  # stub injected through `Session.start_link/1`: no browser, no socket, no
  # provider call, and no file outside a per-test SafeRm root.

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Meetings.Config
  alias FermixCore.Meetings.Session
  alias FermixCore.Meetings.SessionTest.FailingDelivery
  alias FermixCore.Meetings.SessionTest.FailingSummarizer
  alias FermixCore.Meetings.SessionTest.FailingTranscription
  alias FermixCore.Meetings.SessionTest.HangingSummarizer
  alias FermixCore.Meetings.SessionTest.MissingInstaller
  alias FermixCore.Meetings.SessionTest.NoTargetDelivery
  alias FermixCore.Meetings.SessionTest.Observer
  alias FermixCore.Meetings.SessionTest.OkDelivery
  alias FermixCore.Meetings.SessionTest.OkSummarizer
  alias FermixCore.Meetings.SessionTest.PresentInstaller
  alias FermixCore.Meetings.SessionTest.RefusingSource
  alias FermixCore.Meetings.SessionTest.SeatlessSource
  alias FermixCore.Meetings.SessionTest.StubCaffeinate
  alias FermixCore.Meetings.SessionTest.StubSource
  alias FermixCore.Meetings.SessionTest.StubTranscription
  alias FermixCore.Meetings.Store
  alias FermixCore.Memory.Repo
  alias FermixCore.Transcription.Segment

  @meet_url "https://meet.google.com/abc-defg-hij"
  @zoom_url "https://zoom.us/j/123456789"

  @events [
    [:fermix, :meeting, :run_start],
    [:fermix, :meeting, :run_complete],
    [:fermix, :meeting, :run_error],
    [:fermix, :meeting, :phase]
  ]

  setup do
    Observer.register()

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-meetings-session-#{unique}.db")
    repo_name = :"memory_repo_meetings_session_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    root = FermixTestSupport.SafeRm.make_tmp_dir!("meetings-session")

    handler = "meetings-session-#{unique}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:meeting_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      FermixTestSupport.SafeRm.rm_rf!(root)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name, root: root}
  end

  describe "requested → installing" do
    test "resolves the sidecar and moves on", ctx do
      meeting = start!(ctx)

      assert_receive {:source_started, _source, args}
      assert args.url == @meet_url
      assert args.meet_code == "abc-defg-hij"
      assert Session.status(meeting.pid) == :launching
      assert phase_recorded?(meeting.id, "requested", "installing")
      assert phase_recorded?(meeting.id, "installing", "launching")
    end

    test "fails loud when the sidecar went missing after the join gate", ctx do
      meeting = start!(ctx, installer: MissingInstaller)

      await_stop(meeting)
      assert %{status: "failed", error: ":sidecar_not_installed"} = row(ctx, meeting.id)
      assert is_binary(row(ctx, meeting.id).ended_at)
    end

    test "the zoom lane never enters installing", ctx do
      meeting = start!(ctx, platform: "zoom")

      assert_receive {:source_started, _source, args}
      assert args.meeting_no == "123456789"
      assert phase_recorded?(meeting.id, "requested", "launching")
      refute phase_recorded?(meeting.id, "requested", "installing")
    end
  end

  describe "launching" do
    test "a source that cannot start fails the meeting", ctx do
      meeting = start!(ctx, source_module: RefusingSource)

      await_stop(meeting)
      assert %{status: "failed", error: ":chromium_missing"} = row(ctx, meeting.id)
    end

    test "the zoom lane bounds the wait for the stream to start", ctx do
      meeting = start!(ctx, platform: "zoom", timers: %{launch_ms: 30})

      await_stop(meeting, 2_000)
      assert %{status: "failed", error: ":rtms_start_timeout"} = row(ctx, meeting.id)
    end
  end

  describe "joining and knocking" do
    test "joining records when the meeting started", ctx do
      meeting = start!(ctx)
      send(meeting.pid, {:meeting_phase, :joining, %{}})

      assert Session.status(meeting.pid) == :joining
      assert %{status: "joining", started_at: started_at} = row(ctx, meeting.id)
      assert is_binary(started_at)
    end

    test "joining is bounded by the meetbot join deadline", ctx do
      meeting = start!(ctx, timers: %{join_ms: 30})
      send(meeting.pid, {:meeting_phase, :joining, %{}})

      await_stop(meeting, 2_000)
      assert %{status: "failed", error: ":join_timeout"} = row(ctx, meeting.id)
    end

    test "knocking is entered from joining and answered by admission", ctx do
      meeting = start!(ctx)
      send(meeting.pid, {:meeting_phase, :joining, %{}})
      send(meeting.pid, {:meeting_phase, :knocking, %{}})

      assert Session.status(meeting.pid) == :knocking
      assert row(ctx, meeting.id).status == "knocking"

      send(meeting.pid, {:meeting_join_result, :admitted, %{}})
      assert Session.status(meeting.pid) == :capturing
    end

    test "an unanswered knock leaves and ends as knock_timeout", ctx do
      meeting = start!(ctx, timers: %{knock_ms: 30})
      assert_receive {:source_started, source, _args}
      send(meeting.pid, {:meeting_phase, :joining, %{}})
      send(meeting.pid, {:meeting_phase, :knocking, %{}})

      assert_receive {:source_leave, ^source}, 2_000
      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "knock_timeout"
    end

    test "a sidecar-reported knock timeout ends the same way", ctx do
      meeting = start!(ctx)
      send(meeting.pid, {:meeting_phase, :joining, %{}})
      send(meeting.pid, {:meeting_join_result, :knock_timeout, %{}})

      await_stop(meeting)
      assert row(ctx, meeting.id).status == "knock_timeout"
    end

    for result <- [:denied, :login_required, :signin_required, :bot_blocked] do
      test "a #{result} join result is its own terminal status", ctx do
        result = unquote(result)
        meeting = start!(ctx)
        send(meeting.pid, {:meeting_phase, :joining, %{}})
        send(meeting.pid, {:meeting_join_result, result, %{}})

        await_stop(meeting)
        assert row(ctx, meeting.id).status == Atom.to_string(result)
        assert phase_recorded?(meeting.id, "joining", Atom.to_string(result))
        # The requester who was told "joining" is told why it did not.
        assert_receive {:notice, "telegram:99:root", text, _opts}
        assert text =~ "couldn't join"
      end
    end

    test "a not-signed-in join failure is logged and names the fix", ctx do
      meeting = start!(ctx)

      log =
        capture_log(fn ->
          send(meeting.pid, {:meeting_phase, :joining, %{}})
          send(meeting.pid, {:meeting_join_result, :signin_required, %{}})
          await_stop(meeting)
        end)

      assert log =~ "meetings: #{meeting.id} signin_required"
      assert_receive {:notice, "telegram:99:root", text, _opts}
      assert text =~ "isn't signed in"
    end
  end

  describe "admitted" do
    test "opens the stream, the transcript and the sleep guard", ctx do
      meeting = admitted!(ctx)

      assert_receive {:stt_open, opts}
      assert opts[:session_id] =~ "meeting_#{meeting.id}_"
      assert opts[:parent_session] == "main-1"
      refute Keyword.has_key?(opts, :backend)
      refute Keyword.has_key?(opts, :model)

      assert_receive {:caffeinate_start, {:bounded, seconds}}
      assert seconds > 0

      row = row(ctx, meeting.id)
      assert row.status == "capturing"
      assert row.artifact_dir == Path.join([ctx.root, "meetings", meeting.id])
      assert File.regular?(Path.join(row.artifact_dir, "transcript.jsonl"))
    end

    test "a named transcription backend is resolved through the registry", ctx do
      meeting = admitted!(ctx, config: config(transcription_backend: "deepgram"))

      assert_receive {:stt_open, opts}
      assert opts[:backend] == FermixCore.Transcription.Deepgram
      # The shared `model` key is snapped to the GLOBAL backend's family, so an
      # override that inherited it would call this backend with a foreign id.
      assert opts[:model] == "nova-3"
      assert Session.status(meeting.pid) == :capturing
    end

    test "a modelless backend override passes no model at all", ctx do
      meeting = admitted!(ctx, config: config(transcription_backend: "xai"))

      assert_receive {:stt_open, opts}
      assert opts[:backend] == FermixCore.Transcription.XAI
      refute Keyword.has_key?(opts, :model)
      assert Session.status(meeting.pid) == :capturing
    end

    test "an unknown transcription backend fails the meeting loudly", ctx do
      meeting = start!(ctx, config: config(transcription_backend: "wishful"))
      assert_receive {:source_started, source, _args}
      send(meeting.pid, {:meeting_phase, :joining, %{}})
      send(meeting.pid, {:meeting_join_result, :admitted, %{}})

      assert_receive {:source_leave, ^source}
      await_stop(meeting)
      assert %{status: "failed", error: error} = row(ctx, meeting.id)
      assert error =~ "stt_open_failed"
      assert error =~ "wishful"
    end

    test "a stream that will not open leaves the meeting and fails", ctx do
      meeting = start!(ctx, transcription: FailingTranscription)
      assert_receive {:source_started, source, _args}
      send(meeting.pid, {:meeting_phase, :joining, %{}})
      send(meeting.pid, {:meeting_join_result, :admitted, %{}})

      assert_receive {:source_leave, ^source}
      await_stop(meeting)
      assert %{status: "failed", error: error} = row(ctx, meeting.id)
      assert error =~ "stt_open_failed"
      assert error =~ "missing_api_key"
    end
  end

  describe "capturing" do
    test "audio rides the stream on the sample clock", ctx do
      meeting = admitted!(ctx)
      send(meeting.pid, {:meeting_audio, pcm(320)})
      send(meeting.pid, {:meeting_audio, pcm(320)})

      assert Session.status(meeting.pid) == :capturing
      assert_receive {:stt_pcm, 320}
      assert_receive {:stt_pcm, 320}
    end

    test "audio is only kept on disk when the operator asked for it", ctx do
      kept = admitted!(ctx, config: config(retain_audio: true))
      send(kept.pid, {:meeting_audio, pcm(320)})
      assert Session.status(kept.pid) == :capturing
      assert File.regular?(Path.join(artifact_dir(ctx, kept.id), "audio.raw"))

      dropped = admitted!(ctx)
      send(dropped.pid, {:meeting_audio, pcm(320)})
      assert Session.status(dropped.pid) == :capturing
      refute File.exists?(Path.join(artifact_dir(ctx, dropped.id), "audio.raw"))
    end

    test "segments are attributed to the speaker the roster named", ctx do
      meeting = admitted!(ctx)
      send(meeting.pid, {:meeting_roster, [participant("p1", "Ada"), participant("p2", "Grace")]})
      send(meeting.pid, {:meeting_active_speaker, "p2", 0})
      send(meeting.pid, {:transcript_segment, self(), segment(0, 2_000, "morning all")})

      assert Session.status(meeting.pid) == :capturing

      assert [line] = transcript_lines(ctx, meeting.id)
      assert line["speaker"] == "Grace"
      assert line["text"] == "morning all"
      assert line["t0_ms"] == 0
    end

    test "the alone timer waits for the room to empty, and stands down when it refills", ctx do
      meeting = admitted!(ctx, timers: %{alone_ms: 60})

      # Just the notetaker: the countdown starts.
      send(meeting.pid, {:meeting_roster, [participant("bot", "Fermix Notetaker")]})
      # Someone joined before it fired: it is cancelled, not merely restarted.
      send(meeting.pid, {:meeting_roster, [participant("bot", "Bot"), participant("p1", "Ada")]})
      assert Session.status(meeting.pid) == :capturing
      Process.sleep(120)
      assert Session.status(meeting.pid) == :capturing

      send(meeting.pid, {:meeting_roster, [participant("bot", "Bot")]})
      assert_receive {:source_leave, _source}, 2_000
      assert_row_status(ctx, meeting.id, "alone_timeout", 2_000)
    end

    test "a lane with no roster seat of its own counts humans directly", ctx do
      meeting = admitted!(ctx, source_module: SeatlessSource, timers: %{alone_ms: 60})

      # One participant is one human here, so nothing is armed.
      send(meeting.pid, {:meeting_roster, [participant("p1", "Ada")]})
      Process.sleep(120)
      assert Session.status(meeting.pid) == :capturing

      send(meeting.pid, {:meeting_roster, []})
      assert_row_status(ctx, meeting.id, "alone_timeout", 2_000)
    end

    test "the standing watchdog ends a meeting nobody closed", ctx do
      meeting = admitted!(ctx, timers: %{max_duration_ms: 40, leave_grace_ms: 5_000})

      assert_receive {:source_leave, _source}, 2_000
      assert_row_status(ctx, meeting.id, "max_duration", 2_000)
    end

    test "the chat announcement is noted and changes nothing", ctx do
      meeting = admitted!(ctx)
      send(meeting.pid, {:meeting_chat_posted})

      assert Session.status(meeting.pid) == :capturing
    end
  end

  describe "ending the capture" do
    test "the host removing the bot is recorded as its own status", ctx do
      meeting = capturing_with_segment!(ctx)
      send(meeting.pid, {:meeting_ended, :host_removed})

      assert Session.status(meeting.pid) == :summarizing
      assert phase_recorded?(meeting.id, "capturing", "removed_by_host")
      assert phase_recorded?(meeting.id, "removed_by_host", "summarizing")
    end

    test "a meeting that simply ended goes straight to the notes", ctx do
      meeting = capturing_with_segment!(ctx)
      send(meeting.pid, {:meeting_ended, :meeting_closed})

      assert Session.status(meeting.pid) == :summarizing
      assert phase_recorded?(meeting.id, "capturing", "meeting_ended")
    end

    test "the operator's leave winds down through the grace window", ctx do
      meeting = capturing_with_segment!(ctx, timers: %{leave_grace_ms: 40})
      source = meeting.source

      Session.leave(meeting.pid)
      assert_receive {:source_leave, ^source}
      assert Session.status(meeting.pid) == :leaving

      # The source never confirms; the grace expires and the notes are written.
      assert_receive {:stt_finish, _stream}, 2_000
      assert phase_recorded?(meeting.id, "capturing", "leaving")
    end

    test "a source that fails on its way out still owes the notes", ctx do
      meeting = capturing_with_segment!(ctx, timers: %{leave_grace_ms: 5_000})
      assert_receive {:stt_opened, stream}

      Session.leave(meeting.pid)
      assert_receive {:source_leave, _source}
      send(meeting.pid, {:meeting_source_error, {:sidecar_error, "page_crash", "gone"}})

      assert_receive {:stt_finish, ^stream}, 2_000
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"
    end

    test "a leave before capture ends the meeting with the operator's reason", ctx do
      meeting = start!(ctx)
      assert_receive {:source_started, source, _args}

      Session.leave(meeting.pid)
      assert_receive {:source_leave, ^source}
      await_stop(meeting)
      assert %{status: "failed", error: ":operator_left"} = row(ctx, meeting.id)

      # The leave was the operator's own act: a "couldn't join" warning after
      # asking to stop would read as a malfunction, so no notice goes out.
      refute_received {:notice, _origin, _text, _opts}
    end
  end

  describe "summarizing" do
    test "drains the transcription tail before writing the notes", ctx do
      meeting = capturing_with_segment!(ctx)
      source = meeting.source
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})

      # The source and the sleep guard stop first; the stream is finished, not
      # aborted, so the tail still arrives.
      assert_receive {:source_stopped, ^source}
      assert_receive {:caffeinate_stop, :stub_guard}
      assert_receive {:stt_finish, ^stream}

      send(meeting.pid, {:transcript_segment, stream, segment(2_000, 4_000, "one last thing")})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 2, dropped: 0}})

      assert_receive {:summarize, summarized, transcript_md, opts}, 2_000
      assert transcript_md =~ "one last thing"
      assert summarized.title == "Weekly sync"
      assert opts[:session_id] =~ "meeting_#{meeting.id}_"

      assert_receive {:deliver, delivered, text, _opts}, 2_000
      assert text == OkSummarizer.text()
      assert delivered.artifact_dir == artifact_dir(ctx, meeting.id)
      assert delivered.origin_session_id == "telegram:99:root"

      await_stop(meeting, 2_000)
      assert %{status: "delivered", error: nil} = row(ctx, meeting.id)

      assert File.read!(Path.join(artifact_dir(ctx, meeting.id), "summary.md")) =~
               "shipped the thing"

      assert File.regular?(Path.join(artifact_dir(ctx, meeting.id), "meta.json"))
    end

    test "a meeting with nothing said still reports back", ctx do
      meeting = admitted!(ctx)
      assert_receive {:stt_opened, stream}
      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 0, dropped: 0}})

      assert_receive {:deliver, _meeting, text, _opts}, 2_000
      assert text =~ "No speech was captured"
      refute_received {:summarize, _meeting, _md, _opts}

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"
    end

    test "a stalled drain keeps what was captured and moves on", ctx do
      meeting = capturing_with_segment!(ctx, timers: %{summarize_ms: 40})
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      assert_receive {:stt_finish, ^stream}

      # The stream never closes; the watchdog releases it and the notes are
      # written from what already landed.
      assert_receive {:stt_stop, ^stream}, 2_000
      assert_receive {:summarize, _meeting, transcript_md, _opts}, 2_000
      assert transcript_md =~ "morning all"

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"
    end

    test "a drain that dropped segments is labelled, not silently shorter", ctx do
      meeting = capturing_with_segment!(ctx)
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 3}})

      assert_receive {:deliver, delivered, _text, _opts}, 2_000
      assert delivered.end_reason == :stt_stream_failed

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"

      assert File.read!(Path.join(artifact_dir(ctx, meeting.id), "summary.md")) =~
               "Capture ended early (stt_stream_failed)"
    end

    test "a stream that dies during the drain is labelled cut short, not whole", ctx do
      meeting = capturing_with_segment!(ctx)
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      # The stream errors instead of closing: the tail — the wrap-up content
      # the drain exists to protect — may be lost.
      send(meeting.pid, {:transcript_stream_error, stream, {:timeout, :drain, 10_000}})

      assert_receive {:deliver, delivered, _text, _opts}, 2_000
      assert delivered.end_reason == :stt_stream_failed

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"

      assert File.read!(Path.join(artifact_dir(ctx, meeting.id), "summary.md")) =~
               "Capture ended early (stt_stream_failed)"
    end

    test "a drain that dropped everything fails instead of reporting silence", ctx do
      meeting = admitted!(ctx)
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 0, dropped: 40}})

      await_stop(meeting, 2_000)
      assert %{status: "failed", error: ":stt_stream_failed"} = row(ctx, meeting.id)
      refute_received {:deliver, _meeting, _text, _opts}
    end

    test "a second close from the same stream is ignored, not re-finalized", ctx do
      meeting = capturing_with_segment!(ctx)
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})
      # The stream is released by the first close; the second must not re-enter
      # the tail pipeline on a transcript that is already finalized.
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      assert_receive {:deliver, _meeting, _text, _opts}, 2_000
      await_stop(meeting, 2_000)
      assert %{status: "delivered", error: nil} = row(ctx, meeting.id)
    end

    test "a close that raced the drain watchdog still delivers the notes", ctx do
      meeting = capturing_with_segment!(ctx, timers: %{summarize_ms: 60})
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      assert_receive {:stt_finish, ^stream}

      # The watchdog aborts the drain and finalizes; the stream's own close was
      # already in the mailbox behind the timeout.
      assert_receive {:stt_stop, ^stream}, 2_000
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      assert_receive {:deliver, _meeting, _text, _opts}, 2_000
      await_stop(meeting, 2_000)
      assert %{status: "delivered", error: nil} = row(ctx, meeting.id)
    end

    test "a summarizer that never returns is killed and the meeting fails", ctx do
      meeting =
        capturing_with_segment!(ctx, summarizer: HangingSummarizer, timers: %{summarize_ms: 60})

      assert_receive {:stt_opened, stream}
      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      assert_receive :summarize_called, 2_000
      await_stop(meeting, 3_000)
      assert %{status: "failed", error: ":summarize_timeout"} = row(ctx, meeting.id)
    end

    test "a summarizer error fails the meeting rather than delivering nothing", ctx do
      meeting = capturing_with_segment!(ctx, summarizer: FailingSummarizer)
      assert_receive {:stt_opened, stream}
      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      await_stop(meeting, 2_000)
      assert %{status: "failed", error: error} = row(ctx, meeting.id)
      assert error =~ "summarize_failed"
      assert error =~ "provider_unavailable"
    end
  end

  describe "delivery" do
    test "an unroutable summary says where it was saved", ctx do
      meeting = capturing_with_segment!(ctx, delivery: NoTargetDelivery)
      assert_receive {:stt_opened, stream}
      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      await_stop(meeting, 2_000)
      assert %{status: "failed", error: error} = row(ctx, meeting.id)
      assert error == "delivery_unresolvable: summary saved at #{artifact_dir(ctx, meeting.id)}"
      assert File.regular?(Path.join(artifact_dir(ctx, meeting.id), "summary.md"))
    end

    test "a send that never lands fails the meeting with the reason", ctx do
      meeting = capturing_with_segment!(ctx, delivery: FailingDelivery)
      assert_receive {:stt_opened, stream}
      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      await_stop(meeting, 2_000)
      assert %{status: "failed", error: error} = row(ctx, meeting.id)
      assert error =~ "delivery_failed"
    end
  end

  describe "partial capture" do
    test "a crashed source still delivers what was heard, labelled", ctx do
      meeting = capturing_with_segment!(ctx)
      assert_receive {:stt_opened, stream}

      GenServer.stop(meeting.source, :kill)
      assert_receive {:stt_finish, ^stream}, 2_000
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      assert_receive {:deliver, delivered, _text, _opts}, 2_000
      assert delivered.end_reason == :sidecar_crashed

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"

      summary = File.read!(Path.join(artifact_dir(ctx, meeting.id), "summary.md"))
      assert summary =~ "Capture ended early (sidecar_crashed)"
      assert summary =~ "notes cover the first"
    end

    test "a zoom stream that drops is labelled for its own lane", ctx do
      meeting = capturing_with_segment!(ctx, platform: "zoom", source_module: SeatlessSource)
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:meeting_source_error, :rtms_stream_lost})
      assert_receive {:stt_finish, ^stream}, 2_000
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})

      assert_receive {:deliver, delivered, _text, _opts}, 2_000
      assert delivered.end_reason == :rtms_stream_lost

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"
    end

    test "a capture interrupted before anything was said fails", ctx do
      meeting = admitted!(ctx)

      GenServer.stop(meeting.source, :kill)
      await_stop(meeting, 2_000)

      assert %{status: "failed", error: ":sidecar_crashed"} = row(ctx, meeting.id)
      assert phase_recorded?(meeting.id, "capturing", "failed")
    end

    test "a transcription stream that dies mid-meeting is a partial capture", ctx do
      meeting = capturing_with_segment!(ctx)
      assert_receive {:stt_opened, stream}

      send(meeting.pid, {:transcript_stream_error, stream, {:reconnect_exhausted, 500}})

      assert_receive {:deliver, delivered, _text, _opts}, 2_000
      assert delivered.end_reason == :stt_stream_failed

      await_stop(meeting, 2_000)
      assert row(ctx, meeting.id).status == "delivered"
    end
  end

  describe "the capacity slot" do
    @tag :capture_log
    test "a second session refuses the slot the first one holds", ctx do
      # A refused `init/1` exits the linked caller with its reason; the real
      # caller is a DynamicSupervisor, which traps exactly this.
      Process.flag(:trap_exit, true)
      key = capacity_key()
      first = start!(ctx, capacity_key: key)
      {:ok, meeting} = Store.insert(attrs("meet"), server: ctx.repo)

      assert {:error, {:max_concurrent, held}} =
               Session.start_link(
                 Keyword.merge(defaults(ctx, meeting, "meet"), capacity_key: key)
               )

      assert held == first.id
      assert Session.status(first.pid) == :launching
    end

    test "the slot is free again the moment the session has terminated", ctx do
      key = capacity_key()
      first = start!(ctx, capacity_key: key)
      assert :ok = GenServer.stop(first.pid, :normal)

      second = start!(ctx, capacity_key: key)
      assert Session.status(second.pid) == :launching
    end
  end

  describe "telemetry" do
    test "bookends a delivered run with its counters", ctx do
      meeting = capturing_with_segment!(ctx)
      assert_receive {:stt_opened, stream}

      assert_receive {:meeting_telemetry, [:fermix, :meeting, :run_start], %{}, start_meta}
      assert start_meta.meeting_id == meeting.id
      assert start_meta.agent == "meeting:#{meeting.id}"
      assert start_meta.platform == "meet"
      assert start_meta.origin == "channel"

      send(meeting.pid, {:meeting_ended, :meeting_closed})
      send(meeting.pid, {:transcript_stream_closed, stream, %{segments: 1, dropped: 0}})
      await_stop(meeting, 2_000)

      assert_receive {:meeting_telemetry, [:fermix, :meeting, :run_complete], measurements, meta}
      assert meta.status == "delivered"
      assert measurements.segments == 1
      assert measurements.words == 2
      assert measurements.participants_peak == 2
      assert measurements.duration_ms >= 0
    end

    test "bookends a failed run with its terminal status", ctx do
      meeting = start!(ctx, installer: MissingInstaller)
      await_stop(meeting)

      assert_receive {:meeting_telemetry, [:fermix, :meeting, :run_error], measurements, meta}
      assert meta.status == "failed"
      assert meta.error == ":sidecar_not_installed"
      assert measurements.count == 1
    end
  end

  # --- helpers --------------------------------------------------------------

  defp start!(ctx, opts \\ []) do
    {platform, opts} = Keyword.pop(opts, :platform, "meet")
    {:ok, meeting} = Store.insert(attrs(platform), server: ctx.repo)
    {:ok, pid} = Session.start_link(Keyword.merge(defaults(ctx, meeting, platform), opts))

    %{id: meeting.id, pid: pid}
  end

  # The capacity slot is claimed in `init/1` against the application's meetings
  # registry, so a session started without a key of its own would compete with
  # every other session in this async file. One key per session leaves the claim
  # itself under test only where two sessions are given the same key.
  defp capacity_key, do: {:capacity_slot, System.unique_integer([:positive])}

  defp admitted!(ctx, opts \\ []) do
    meeting = start!(ctx, opts)
    assert_receive {:source_started, source, _args}
    send(meeting.pid, {:meeting_phase, :joining, %{}})
    send(meeting.pid, {:meeting_join_result, :admitted, %{}})
    assert Session.status(meeting.pid) == :capturing

    Map.put(meeting, :source, source)
  end

  defp capturing_with_segment!(ctx, opts \\ []) do
    meeting = admitted!(ctx, opts)
    send(meeting.pid, {:meeting_roster, [participant("bot", "Bot"), participant("p1", "Ada")]})
    send(meeting.pid, {:meeting_active_speaker, "p1", 0})
    send(meeting.pid, {:transcript_segment, self(), segment(0, 2_000, "morning all")})
    assert Session.status(meeting.pid) == :capturing

    meeting
  end

  defp defaults(ctx, meeting, platform) do
    [
      meeting: meeting,
      link: link(platform),
      config: config(),
      parent_session: "main-1",
      source_module: StubSource,
      installer: PresentInstaller,
      transcription: StubTranscription,
      summarizer: OkSummarizer,
      delivery: OkDelivery,
      caffeinate: StubCaffeinate,
      capacity_key: capacity_key(),
      store_opts: [server: ctx.repo],
      transcript_opts: [root: ctx.root]
    ]
  end

  defp attrs(platform) do
    %{
      id: mint_id(),
      platform: platform,
      url: url(platform),
      title: "Weekly sync",
      requested_by: "operator",
      origin_session_id: "telegram:99:root",
      created_at: DateTime.utc_now()
    }
  end

  defp mint_id,
    do: "mtg_" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  defp url("meet"), do: @meet_url
  defp url("zoom"), do: @zoom_url

  defp link("meet"), do: %{platform: :meet, meeting_id: "abc-defg-hij", passcode: nil}
  defp link("zoom"), do: %{platform: :zoom, meeting_id: "123456789", passcode: nil}

  defp config(overrides \\ []) do
    struct!(%Config{enabled: true}, overrides)
  end

  defp participant(id, name), do: %{id: id, name: name}

  defp segment(t0_ms, t1_ms, text), do: %Segment{text: text, t0_ms: t0_ms, t1_ms: t1_ms}

  defp pcm(bytes), do: :binary.copy(<<0, 1>>, div(bytes, 2))

  defp row(ctx, id) do
    {:ok, meeting} = Store.get(id, server: ctx.repo)
    meeting
  end

  defp artifact_dir(ctx, id), do: Path.join([ctx.root, "meetings", id])

  defp transcript_lines(ctx, id) do
    ctx
    |> artifact_dir(id)
    |> Path.join("transcript.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp await_stop(meeting, timeout \\ 1_000) do
    ref = Process.monitor(meeting.pid)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, timeout
  end

  # The row is written before the process stops, but a timer-driven transition
  # lands whenever the timer fires — so this polls the durable record rather
  # than racing the process.
  defp assert_row_status(ctx, id, status, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_row_status(ctx, id, status, deadline)
  end

  defp poll_row_status(ctx, id, status, deadline) do
    cond do
      row(ctx, id).status == status -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk_status(ctx, id, status)
      true -> retry_row_status(ctx, id, status, deadline)
    end
  end

  defp retry_row_status(ctx, id, status, deadline) do
    Process.sleep(10)
    poll_row_status(ctx, id, status, deadline)
  end

  defp flunk_status(ctx, id, status) do
    flunk("expected #{id} to reach #{status}, still #{row(ctx, id).status}")
  end

  defp phase_recorded?(meeting_id, from, to) do
    receive_phase(meeting_id, from, to, [])
  end

  defp receive_phase(meeting_id, from, to, seen) do
    receive do
      {:meeting_telemetry, [:fermix, :meeting, :phase], _measurements,
       %{meeting_id: ^meeting_id, from: ^from, to: ^to}} ->
        Enum.each(seen, &send(self(), &1))
        true

      {:meeting_telemetry, _event, _measurements, _metadata} = other ->
        receive_phase(meeting_id, from, to, [other | seen])
    after
      200 ->
        Enum.each(seen, &send(self(), &1))
        false
    end
  end
end
