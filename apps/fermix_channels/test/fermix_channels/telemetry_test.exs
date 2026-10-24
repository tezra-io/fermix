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

  # M51 §14: the pair event carries the platform, the attestation's outcome
  # and the signer role, all atoms, and never a chain, a key or a name.
  test "pair events expose only the bounded terminal status and attestation facts" do
    facts = %{platform: :android, attestation: :verified, signer_role: :development}

    for status <- [:approved, :denied, :expired, :cancelled, :device_disconnected] do
      assert :ok = Telemetry.emit_pair(:mobile, status, 17, facts)

      assert_receive {:mobile_channel_telemetry, @pair_event, %{count: 1, duration_us: 17},
                      metadata}

      assert metadata == Map.merge(%{channel: :mobile, status: status}, facts)
    end

    for {status, attestation} <- [
          attestation: :refused,
          platform_unsupported: :refused,
          attestation_unavailable: :unavailable
        ] do
      refused = %{platform: :ios, attestation: attestation, signer_role: nil}
      assert :ok = Telemetry.emit_pair(:mobile, status, 3, refused)

      assert_receive {:mobile_channel_telemetry, @pair_event, %{count: 1, duration_us: 3},
                      %{status: ^status, attestation: ^attestation, signer_role: nil}}
    end

    nobody = %{platform: nil, attestation: nil, signer_role: nil}
    assert :ok = Telemetry.emit_pair(:mobile, :expired, 5, nobody)
    assert_receive {:mobile_channel_telemetry, @pair_event, _measurements, %{platform: nil}}
  end

  test "push events expose only the bounded delivery status and the push service" do
    for status <- [:sent, :failed], platform <- [:apns, :fcm] do
      assert :ok = Telemetry.emit_push(:mobile, status, 23, platform)

      assert_receive {:mobile_channel_telemetry, @push_event, %{count: 1, duration_us: 23},
                      metadata}

      assert metadata == %{channel: :mobile, status: status, platform: platform}
    end
  end

  test "unsupported statuses and negative durations fail loud" do
    facts = %{platform: :android, attestation: :verified, signer_role: :release}
    assert_raise FunctionClauseError, fn -> Telemetry.emit_pair(:mobile, :failed, 1, facts) end

    assert_raise FunctionClauseError, fn ->
      Telemetry.emit_pair(:mobile, :rate_limited, 1, facts)
    end

    for bad <- [
          %{facts | platform: "android"},
          %{facts | attestation: :maybe},
          %{facts | signer_role: "release"},
          Map.put(facts, :chain, <<1, 2>>)
        ] do
      assert_raise FunctionClauseError, fn -> Telemetry.emit_pair(:mobile, :approved, 1, bad) end
    end

    assert_raise FunctionClauseError, fn -> Telemetry.emit_push(:mobile, :skipped, 1, :fcm) end
    assert_raise FunctionClauseError, fn -> Telemetry.emit_push(:mobile, :sent, 1, :gcm) end
    assert_raise FunctionClauseError, fn -> Telemetry.emit_pair(:mobile, :approved, -1, facts) end
    assert_raise FunctionClauseError, fn -> Telemetry.emit_push(:mobile, :sent, -1, :apns) end
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
