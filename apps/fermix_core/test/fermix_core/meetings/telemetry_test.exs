defmodule FermixCore.Meetings.TelemetryTest do
  # async: false — content capture is global app env, and both postures are
  # established in-test.
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.Telemetry, as: MeetingTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  @events [
    [:fermix, :meeting, :run_start],
    [:fermix, :meeting, :run_complete],
    [:fermix, :meeting, :run_error],
    [:fermix, :meeting, :phase]
  ]

  setup do
    handler = "meeting-tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:meeting_event, event, measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])

    # Establish the production default (content capture off) so the "no :url"
    # assertion never inherits a capture_content = true left by another module.
    Application.put_env(:fermix_core, :telemetry, capture_content: false)

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    meeting = %{
      id: "mtg_AbCdEfGhIjK",
      platform: :meet,
      session_id: "meeting_mtg_AbCdEfGhIjK_20260817_101500",
      parent_session: "telegram:123:root",
      origin: :channel,
      duration_ms: 42_000
    }

    %{meeting: meeting}
  end

  test "run_start carries the meeting correlation ids", %{meeting: meeting} do
    MeetingTelemetry.run_start(meeting,
      url: "https://meet.google.com/abc-defg-hij",
      title: "Sync",
      max_duration_ms: 14_400_000
    )

    assert_receive {:meeting_event, [:fermix, :meeting, :run_start], %{}, metadata}
    assert metadata.agent == "meeting:mtg_AbCdEfGhIjK"
    assert metadata.meeting_id == "mtg_AbCdEfGhIjK"
    assert metadata.platform == "meet"
    assert metadata.session_id == "meeting_mtg_AbCdEfGhIjK_20260817_101500"
    assert metadata.parent_session == "telegram:123:root"
    assert metadata.origin == "channel"
    assert metadata.max_duration_ms == 14_400_000
  end

  test "the url and title are withheld unless content capture is on", %{meeting: meeting} do
    MeetingTelemetry.run_start(meeting,
      url: "https://meet.google.com/abc-defg-hij",
      title: "Sync"
    )

    assert_receive {:meeting_event, [:fermix, :meeting, :run_start], _measurements, metadata}
    refute Map.has_key?(metadata, :url)
    refute Map.has_key?(metadata, :title)

    Application.put_env(:fermix_core, :telemetry, capture_content: true)

    MeetingTelemetry.run_start(meeting,
      url: "https://meet.google.com/abc-defg-hij",
      title: "Sync"
    )

    assert_receive {:meeting_event, [:fermix, :meeting, :run_start], _m, captured}
    assert captured.url == "https://meet.google.com/abc-defg-hij"
    assert captured.title == "Sync"
  end

  test "a nil title is dropped even with capture on", %{meeting: meeting} do
    Application.put_env(:fermix_core, :telemetry, capture_content: true)

    MeetingTelemetry.run_start(meeting, url: "https://meet.google.com/abc-defg-hij")

    assert_receive {:meeting_event, [:fermix, :meeting, :run_start], _m, metadata}
    refute Map.has_key?(metadata, :title)
  end

  test "run_complete reports the run counters", %{meeting: meeting} do
    MeetingTelemetry.run_complete(meeting, %{
      duration_ms: 1_800_000,
      segments: 412,
      words: 7_310,
      participants_peak: 5
    })

    assert_receive {:meeting_event, [:fermix, :meeting, :run_complete], measurements, metadata}
    assert measurements.duration_ms == 1_800_000
    assert measurements.segments == 412
    assert measurements.words == 7_310
    assert measurements.participants_peak == 5
    assert metadata.status == "delivered"
  end

  test "run_error carries the terminal status and a bounded error", %{meeting: meeting} do
    MeetingTelemetry.run_error(meeting, "failed", {:stt_open_failed, :not_configured})

    assert_receive {:meeting_event, [:fermix, :meeting, :run_error], measurements, metadata}
    assert measurements == %{count: 1, duration_ms: 42_000}
    assert metadata.status == "failed"
    assert metadata.error == "{:stt_open_failed, :not_configured}"
  end

  test "run_error truncates a long error", %{meeting: meeting} do
    MeetingTelemetry.run_error(meeting, "failed", String.duplicate("x", 900))

    assert_receive {:meeting_event, [:fermix, :meeting, :run_error], _measurements, metadata}
    assert String.length(metadata.error) == 500
  end

  test "phase records the transition and its reason", %{meeting: meeting} do
    MeetingTelemetry.phase(meeting, :capturing, :summarizing, :host_removed)

    assert_receive {:meeting_event, [:fermix, :meeting, :phase], %{count: 1}, metadata}
    assert metadata.from == "capturing"
    assert metadata.to == "summarizing"
    assert metadata.reason == "host_removed"
  end

  test "phase drops an absent reason", %{meeting: meeting} do
    MeetingTelemetry.phase(meeting, :requested, :installing)

    assert_receive {:meeting_event, [:fermix, :meeting, :phase], _measurements, metadata}
    refute Map.has_key?(metadata, :reason)
  end

  test "the definitions are registered, so a meeting phase lands in the trace", %{
    meeting: meeting
  } do
    dir = Path.join(System.tmp_dir!(), "fermix_meeting_tel_#{System.unique_integer([:positive])}")
    server = :"meeting_trace_#{System.unique_integer([:positive])}"
    prefix = "meeting-trace-#{System.unique_integer([:positive])}"

    start_supervised!({Trace, base_dir: dir, name: server})
    TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    MeetingTelemetry.phase(meeting, :capturing, :summarizing, :meeting_closed)
    :sys.get_state(server)

    entry =
      dir
      |> agent_events()
      |> Enum.find(&(&1["event"] == "meeting_phase")) ||
        flunk("no meeting_phase row in the agent_event trace")

    assert entry["agent"] == "meeting:mtg_AbCdEfGhIjK"
    assert entry["to"] == "summarizing"
    assert entry["reason"] == "meeting_closed"
  end

  test "every meeting definition maps to a named trace event" do
    definitions = MeetingTelemetry.trace_event_definitions()

    assert Enum.map(definitions, & &1.event) == @events

    assert Enum.map(definitions, & &1.trace_event) == [
             "meeting_run_start",
             "meeting_run_complete",
             "meeting_run_error",
             "meeting_phase"
           ]

    assert Enum.all?(definitions, &(&1.trace_type == :agent_event and &1.agent_field == :agent))
  end

  defp agent_events(dir) do
    [dir, Date.utc_today() |> Date.to_iso8601(), "agent_event.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
