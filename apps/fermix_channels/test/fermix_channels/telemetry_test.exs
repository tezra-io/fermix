defmodule FermixChannels.TelemetryTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Telemetry

  @pair_event [:fermix, :channel, :pair]
  @push_event [:fermix, :channel, :push]
  @transport_event [:fermix, :channel, :transport]

  setup do
    handler_id = "mobile-channel-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@pair_event, @push_event, @transport_event],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:mobile_channel_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "pair events expose only the bounded terminal status" do
    for status <- [:approved, :denied, :expired, :rate_limited] do
      assert :ok = Telemetry.emit_pair(:mobile, status, 17)

      assert_receive {:mobile_channel_telemetry, @pair_event, %{count: 1, duration_us: 17},
                      %{channel: :mobile, status: ^status}}
    end
  end

  test "push events expose only the bounded delivery status" do
    for status <- [:sent, :failed] do
      assert :ok = Telemetry.emit_push(:mobile, status, 23)

      assert_receive {:mobile_channel_telemetry, @push_event, %{count: 1, duration_us: 23},
                      %{channel: :mobile, status: ^status}}
    end
  end

  test "unsupported statuses and negative durations fail loud" do
    assert_raise FunctionClauseError, fn -> Telemetry.emit_pair(:mobile, :failed, 1) end
    assert_raise FunctionClauseError, fn -> Telemetry.emit_push(:mobile, :skipped, 1) end
    assert_raise FunctionClauseError, fn -> Telemetry.emit_pair(:mobile, :approved, -1) end
    assert_raise FunctionClauseError, fn -> Telemetry.emit_push(:mobile, :sent, -1) end
  end

  test "transport events expose only the bounded lifecycle status" do
    for status <- [:degraded, :recovered] do
      assert :ok = Telemetry.emit_transport(:telegram, status, 312, :timeout)

      assert_receive {:mobile_channel_telemetry, @transport_event,
                      %{count: 1, consecutive_failures: 312},
                      %{channel: :telegram, status: ^status, error_class: :timeout}}
    end
  end

  test "an unsupported transport status or an unbounded error class fails loud" do
    assert_raise FunctionClauseError, fn ->
      Telemetry.emit_transport(:telegram, :failed, 1, :timeout)
    end

    assert_raise FunctionClauseError, fn ->
      Telemetry.emit_transport(:telegram, :degraded, -1, :timeout)
    end

    # The guard is what keeps a response body, URL or bot token out of a trace
    # field: an unbounded term cannot reach telemetry at all.
    assert_raise FunctionClauseError, fn ->
      Telemetry.emit_transport(:telegram, :degraded, 1, "Telegram API error 401: secret-ish body")
    end
  end
end
