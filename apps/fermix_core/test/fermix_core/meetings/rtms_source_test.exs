defmodule FermixCore.Meetings.RtmsSourceTest do
  # Every leg is scripted: no socket opens, no Zoom credential is read, and the
  # phase deadlines are shortened through the `:timers` seam.
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Config
  alias FermixCore.Meetings.Rtms.Protocol
  alias FermixCore.Meetings.RtmsSource

  @fixtures Path.expand("rtms/fixtures", __DIR__)

  @meeting_no "8123456789"
  @meeting_uuid "aBcD1234EfGh5678=="
  @stream_id "rtms_stream_fixture_001"
  @signaling_url "wss://rtms.example.zoom.us/signaling"
  @media_url "wss://rtms.example.zoom.us/media/audio"

  defmodule ScriptedTransport do
    @moduledoc false
    @behaviour FermixCore.Meetings.Rtms.Transport

    @impl true
    def connect(url, owner, opts) do
      test = Keyword.fetch!(opts, :test)
      tag = Keyword.fetch!(opts, :tag)

      if tag in Keyword.get(opts, :refuse, []) do
        {:error, :econnrefused}
      else
        send(test, {:connected, tag, url, owner})
        {:ok, %{tag: tag, test: test}}
      end
    end

    @impl true
    def send_json(%{tag: tag, test: test}, payload) do
      send(test, {:sent, tag, payload})
      :ok
    end

    @impl true
    def close(%{tag: tag, test: test}) do
      send(test, {:leg_closed, tag})
      :ok
    end
  end

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp config do
    %Config{
      enabled: true,
      zoom_account_id: "acct-1",
      zoom_client_id: "client-fixture",
      zoom_client_secret: "s3cr3t-fixture",
      zoom_ws_subscription_id: "sub-9"
    }
  end

  defp start_source(overrides \\ %{}) do
    args =
      Map.merge(
        %{
          meeting_no: @meeting_no,
          config: config(),
          transport: ScriptedTransport,
          transport_opts: [test: self()],
          token_fn: fn _config -> {:ok, "tok-1"} end
        },
        overrides
      )

    {:ok, source} = RtmsSource.start_link(self(), args)
    source
  end

  # Walks the three-leg choreography to `:streaming` and returns the signaling
  # handshake the source sent, so tests can inspect it.
  defp admit(source) do
    assert_receive {:connected, :event, _url, ^source}
    send(source, {:rtms_ws, :event, {:message, fixture("event_rtms_started.json")}})

    assert_receive {:meeting_phase, :joining, %{}}
    assert_receive {:connected, :signaling, @signaling_url, ^source}
    assert_receive {:sent, :signaling, handshake}

    send(source, {:rtms_ws, :signaling, {:message, fixture("signaling_handshake_ok.json")}})

    assert_receive {:connected, :media, @media_url, ^source}
    assert_receive {:sent, :media, _media_handshake}

    send(source, {:rtms_ws, :media, {:message, fixture("media_handshake_ok.json")}})
    assert_receive {:meeting_join_result, :admitted, %{}}

    handshake
  end

  defp push_audio(source, name, bucket) do
    message = name |> fixture() |> Map.put("timestamp", bucket * 100)
    send(source, {:rtms_ws, :media, {:message, message}})
  end

  # Thirteen buckets is three past the mixer's alignment window, so three have
  # been emitted by the time this returns — enough for the loud channel to clear
  # the active-speaker hangover.
  defp push_meeting_audio(source) do
    for bucket <- 0..12 do
      push_audio(source, "audio_participant_one.json", bucket)
      push_audio(source, "audio_participant_two.json", bucket)
    end
  end

  describe "the happy path" do
    test "reaches admitted, streams mixed audio with speaker marks, and ends cleanly" do
      source = start_source()
      admit(source)

      push_meeting_audio(source)

      assert_receive {:meeting_roster, [%{id: "u-1001", name: "Ada Lovelace"}]}
      assert_receive {:meeting_roster, [%{id: "u-1001"}, %{id: "u-1002", name: "Grace Hopper"}]}

      # The loud channel takes the mark after the hangover window; the quiet one
      # never crosses the speech threshold.
      assert_receive {:meeting_active_speaker, "u-1001", 200}
      assert_receive {:meeting_audio, frame}
      assert byte_size(frame) == 3_200

      send(source, {:rtms_ws, :event, {:message, fixture("event_rtms_stopped.json")}})

      assert_receive {:meeting_ended, :meeting_closed}
      refute_receive {:meeting_source_error, _reason}
    end

    test "the signaling handshake carries the signature Zoom will verify" do
      source = start_source()
      handshake = admit(source)

      assert handshake["msg_type"] == "SIGNALING_HAND_SHAKE_REQ"
      assert handshake["meeting_uuid"] == @meeting_uuid
      assert handshake["rtms_stream_id"] == @stream_id

      assert handshake["signature"] ==
               Protocol.signature("client-fixture", "s3cr3t-fixture", @meeting_uuid, @stream_id)
    end

    test "audio buffered when the meeting ends is flushed, not dropped" do
      source = start_source()
      admit(source)

      push_audio(source, "audio_participant_one.json", 0)
      send(source, {:rtms_ws, :media, {:message, fixture("stream_terminated.json")}})

      assert_receive {:meeting_audio, _frame}
      assert_receive {:meeting_ended, :meeting_closed}
    end

    test "a keep-alive is answered on the leg that asked, with its own timestamp" do
      source = start_source()
      admit(source)

      send(source, {:rtms_ws, :media, {:message, fixture("keep_alive_req.json")}})

      assert_receive {:sent, :media,
                      %{"msg_type" => "KEEP_ALIVE_RESP", "timestamp" => 1_760_000_030_000}}
    end
  end

  describe "refusals" do
    test "a rejected signaling handshake is a denied join, not a retry" do
      source = start_source()

      assert_receive {:connected, :event, _url, ^source}
      send(source, {:rtms_ws, :event, {:message, fixture("event_rtms_started.json")}})
      assert_receive {:connected, :signaling, @signaling_url, ^source}

      send(source, {:rtms_ws, :signaling, {:message, fixture("signaling_handshake_denied.json")}})

      assert_receive {:meeting_join_result, :denied, %{detail: detail}}
      assert detail.status_code == "STATUS_UNAUTHORIZED"
      refute_receive {:connected, :media, _url, _owner}
    end

    test "a rejected media handshake is a denied join" do
      source = start_source()

      assert_receive {:connected, :event, _url, ^source}
      send(source, {:rtms_ws, :event, {:message, fixture("event_rtms_started.json")}})
      assert_receive {:connected, :signaling, @signaling_url, ^source}
      send(source, {:rtms_ws, :signaling, {:message, fixture("signaling_handshake_ok.json")}})
      assert_receive {:connected, :media, @media_url, ^source}

      send(source, {:rtms_ws, :media, {:message, fixture("media_handshake_denied.json")}})

      assert_receive {:meeting_join_result, :denied, %{detail: detail}}
      assert detail.status_code == "STATUS_INVALID_MESSAGE"
    end

    test "an OAuth refusal never opens a socket" do
      start_source(%{token_fn: fn _config -> {:error, {:oauth_rejected, 401}} end})

      assert_receive {:meeting_source_error, {:rtms_connect_failed, {:oauth_rejected, 401}}}
      refute_receive {:connected, _tag, _url, _owner}
    end

    test "an event socket that will not open fails the source loud" do
      start_source(%{transport_opts: [test: self(), refuse: [:event]]})

      assert_receive {:meeting_source_error, {:rtms_connect_failed, :econnrefused}}
    end
  end

  describe "bounds" do
    test "a meeting whose RTMS stream never starts releases the source" do
      start_source(%{timers: %{rtms_start_timeout_ms: 40}})

      assert_receive {:meeting_source_error, :rtms_start_timeout}, 500
    end

    test "a signaling handshake that is never answered times out" do
      source = start_source(%{timers: %{handshake_timeout_ms: 40}})

      assert_receive {:connected, :event, _url, ^source}
      send(source, {:rtms_ws, :event, {:message, fixture("event_rtms_started.json")}})

      assert_receive {:meeting_source_error, {:rtms_handshake_timeout, :signaling}}, 500
    end

    test "a stream that goes quiet past the keep-alive grace is reported lost" do
      source = start_source(%{timers: %{keepalive_grace_ms: 60}})
      admit(source)

      assert_receive {:meeting_source_error, :rtms_stream_lost}, 500
    end

    test "traffic on the media leg keeps the grace alive" do
      # Total activity (5 × 150ms) exceeds the grace, so the pass proves the
      # pushes RESET the timer; each inter-push gap sits far enough under the
      # grace that a slow CI scheduler cannot starve one past it.
      source = start_source(%{timers: %{keepalive_grace_ms: 500}})
      admit(source)

      for bucket <- 0..4 do
        Process.sleep(150)
        push_audio(source, "audio_participant_one.json", bucket)
      end

      refute_received {:meeting_source_error, :rtms_stream_lost}
    end

    test "a dropped leg is terminal — there is no reconnect in v1" do
      source = start_source()
      admit(source)

      push_audio(source, "audio_participant_one.json", 0)
      send(source, {:rtms_ws, :media, {:closed, :remote_closed}})

      # What was captured is flushed before the source reports the loss.
      assert_receive {:meeting_audio, _frame}
      assert_receive {:meeting_source_error, {:rtms_leg_closed, :media, :remote_closed}}
      refute_receive {:connected, :media, _url, _owner}
    end
  end

  describe "roster sweep" do
    # Roster expiry used to ride on audio pushes alone, so a meeting everybody
    # left (or muted) could never report an empty roster and the Session's
    # alone-timer could never arm.
    test "a meeting nobody transmits in still reports the roster emptying" do
      clock = :atomics.new(1, signed: true)

      source =
        start_source(%{
          timers: %{roster_sweep_ms: 20},
          clock_fn: fn -> :atomics.get(clock, 1) end
        })

      admit(source)
      push_audio(source, "audio_participant_one.json", 0)

      assert_receive {:meeting_roster, [%{id: "u-1001"}]}

      # Everyone stops transmitting; only wall time moves from here.
      :atomics.put(clock, 1, 60_000)

      assert_receive {:meeting_roster, []}, 500
    end

    test "each sweep re-arms exactly one timer" do
      source = start_source(%{timers: %{roster_sweep_ms: 20}})
      admit(source)

      %{sweep_timer: first} = :sys.get_state(source)
      Process.sleep(60)
      %{sweep_timer: second} = :sys.get_state(source)

      assert second != first
      assert is_integer(Process.read_timer(second))
    end

    test "teardown leaves no sweep timer behind" do
      source = start_source(%{timers: %{roster_sweep_ms: 5_000}})
      admit(source)

      %{sweep_timer: timer} = :sys.get_state(source)
      assert is_integer(Process.read_timer(timer))

      ref = Process.monitor(source)
      assert RtmsSource.leave(source) == :ok
      assert_receive {:DOWN, ^ref, :process, ^source, :normal}

      assert Process.read_timer(timer) == false
    end
  end

  describe "meeting selection" do
    test "an rtms_started for a different meeting is not ours to join" do
      source = start_source()

      assert_receive {:connected, :event, _url, ^source}

      other =
        "event_rtms_started.json"
        |> fixture()
        |> put_in(["payload", "object", "id"], "9999999999")

      send(source, {:rtms_ws, :event, {:message, other}})

      refute_receive {:meeting_phase, :joining, _meta}
      refute_receive {:connected, :signaling, _url, _owner}
    end

    test "a malformed rtms_started fails loud rather than half-joining" do
      source = start_source()

      assert_receive {:connected, :event, _url, ^source}

      truncated =
        "event_rtms_started.json"
        |> fixture()
        |> update_in(["payload", "object"], &Map.delete(&1, "rtms_stream_id"))

      send(source, {:rtms_ws, :event, {:message, truncated}})

      assert_receive {:meeting_source_error, {:rtms_protocol_error, :incomplete_rtms_started}}
    end
  end

  describe "teardown" do
    test "leave closes every leg and reports the meeting as left" do
      source = start_source()
      admit(source)

      push_audio(source, "audio_participant_one.json", 0)
      assert RtmsSource.leave(source) == :ok

      assert_receive {:meeting_audio, _frame}
      assert_receive {:leg_closed, :media}
      assert_receive {:meeting_ended, :left}
    end

    test "stop is idempotent, including against a source that is already gone" do
      source = start_source()

      assert RtmsSource.stop(source) == :ok
      refute Process.alive?(source)
      assert RtmsSource.stop(source) == :ok
    end
  end

  describe "self_count/0" do
    test "the RTMS app is not a participant, so nothing in the roster is us" do
      assert RtmsSource.self_count() == 0
    end
  end
end
