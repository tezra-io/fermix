defmodule FermixCore.PhoneCalls.TelemetryTest do
  # The Trace route attaches a global handler under its own prefix and its own
  # Trace server, so the module runs alone; every metadata assertion pins its
  # own call id.
  use ExUnit.Case, async: false

  alias FermixCore.PhoneCalls.Telemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.TelemetryCapture

  @events [
    [:fermix, :phone_call, :run_start],
    [:fermix, :phone_call, :run_complete],
    [:fermix, :phone_call, :run_error]
  ]
  @today ~D[2031-03-04]

  # Invented ids and words.
  defp row(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        request_id: "main-77",
        origin_kind: "chat",
        model: "gpt-live-1",
        carrier_profile: "telnyx_credential_v1",
        authorization: "direct",
        status: "admitted",
        destination: "+14155550123",
        mandate: %{"goal" => "Ask for a table", "destination" => "+14155550123"},
        created_at: ~U[2031-03-04 15:00:00Z]
      },
      overrides
    )
  end

  setup do
    id = "pc_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    TelemetryCapture.attach(@events, call_id: id)
    %{id: id}
  end

  test "the call is its own session, the requesting turn its parent", %{id: id} do
    :ok = Telemetry.run_start(row(id), 660_000)

    assert_receive {:telemetry, [:fermix, :phone_call, :run_start], %{}, meta}
    assert meta.session_id == "phone_call_" <> id
    assert meta.session_id == Telemetry.session_id(id)
    assert meta.parent_session == "main-77"
    assert meta.agent == "phone_call:" <> id
    assert meta.max_duration_ms == 660_000
    assert meta.status == "admitted"
  end

  test "no number, mandate or transcript reaches ordinary metadata", %{id: id} do
    :ok = Telemetry.run_start(row(id), 1)

    assert_receive {:telemetry, _event, _measurements, meta}
    encoded = inspect(meta)
    refute encoded =~ "555"
    refute encoded =~ "table"
    refute Map.has_key?(meta, :destination)
    refute Map.has_key?(meta, :mandate)
  end

  test "an ended call closes as complete, whatever its outcome", %{id: id} do
    ended =
      row(id, %{
        status: "ended",
        outcome: "unavailable",
        usage_state: "voice_duration_confirmed",
        voice_seconds: 74,
        core_turns: 1,
        ended_at: ~U[2031-03-04 15:02:00Z]
      })

    :ok = Telemetry.run_end(ended)

    assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], measurements, meta}
    assert measurements.duration_ms == 120_000
    assert measurements.voice_seconds == 74
    assert meta.outcome == "unavailable"
    assert meta.status == "ended"
  end

  test "a failed or uncertain call closes as an error carrying the vendor's own words", %{id: id} do
    failed =
      row(id, %{
        status: "failed",
        outcome: "unknown",
        failure_reason: "provider_refused",
        vendor_message: "Destination +1 415 555 0123 is not reachable from this trunk."
      })

    :ok = Telemetry.run_end(failed)

    assert_receive {:telemetry, [:fermix, :phone_call, :run_error], %{count: 1}, meta}
    assert meta.error == "provider_refused"
    assert meta.vendor_message == "Destination [number] is not reachable from this trunk."

    :ok = Telemetry.run_end(row(id, %{status: "closure_unconfirmed", outcome: "unknown"}))
    assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, unconfirmed}
    assert unconfirmed.error == "closure_unconfirmed"
  end

  test "a row with no id fails loud" do
    assert_raise ArgumentError, fn -> Telemetry.run_start(%{status: "admitted"}, 1) end
  end

  test "the bookends reach the JSONL trace as agent_event rows", %{id: id} do
    tmp = Path.join(System.tmp_dir!(), "fermix_phone_tel_#{System.unique_integer([:positive])}")
    name = :"phone_trace_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: tmp, name: name, today: fn -> @today end})
    prefix = "phone-test-#{System.unique_integer([:positive])}"
    TelemetryHandler.attach(trace_server: name, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(tmp)
    end)

    :ok = Telemetry.run_start(row(id), 1)
    :ok = Telemetry.run_end(row(id, %{status: "ended", outcome: "options"}))
    :ok = Telemetry.run_end(row(id, %{status: "dispatch_unknown", outcome: "unknown"}))
    _state = :sys.get_state(name)

    rows =
      [tmp, Date.to_iso8601(@today), "agent_event.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["session_id"] == "phone_call_" <> id))

    assert Enum.map(rows, & &1["event"]) ==
             Enum.map(Telemetry.trace_event_definitions(), & &1.trace_event)

    assert Enum.all?(rows, &(&1["agent"] == "phone_call:" <> id))
  end
end
