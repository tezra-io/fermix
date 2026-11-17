defmodule FermixCore.PhoneCalls.LimitsTest do
  # Pure module: constants only, no app env, no settings.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Limits

  test "external calls and attempts" do
    assert Limits.max_outstanding_calls() == 1
    assert Limits.max_create_requests_per_mandate() == 1
    assert Limits.max_attempts_per_day() == 5
    assert Limits.attempt_window_ms() == 24 * 60 * 60 * 1000
  end

  test "call, ringing and inactivity deadlines" do
    assert Limits.call_deadline_ms() == 10 * 60 * 1000
    assert Limits.ringing_timeout_ms() == 60 * 1000
    assert Limits.recipient_silence_timeout_ms() == 120 * 1000
  end

  test "delegation" do
    assert Limits.max_active_delegations() == 1
    assert Limits.max_pending_delegations() == 1
    assert Limits.max_core_turns_per_call() == 8
    assert Limits.core_turn_timeout_ms() == 30 * 1000
    assert Limits.max_agent_steps_per_core_turn() == 12
  end

  test "transcript and keypad" do
    assert Limits.max_transcript_bytes() == 64 * 1024
    assert Limits.max_dtmf_keys() == 32
    assert Limits.max_outstanding_dtmf_acks() == 1
    assert Limits.dtmf_ack_timeout_ms() == 3 * 1000
  end

  test "cleanup and report" do
    assert Limits.max_immediate_termination_requests() == 1
    assert Limits.max_cleanup_retries() == 2
    assert Limits.cleanup_window_ms() == 30 * 1000
    assert Limits.terminal_drain_ms() == 5 * 1000
    assert Limits.max_result_extractions() == 1
    assert Limits.result_extraction_timeout_ms() == 30 * 1000
    assert Limits.max_report_delivery_attempts() == 3
  end

  # What bounds a call once Fermix is gone (design D2): the provider's
  # documented limits, which the slot release waits out for an unresolved call.
  test "the provider's documented remote bounds" do
    assert Limits.provider_ringing_limit_ms() == 3 * 60 * 1000
    assert Limits.provider_connected_limit_ms() == 2 * 60 * 60 * 1000

    assert Limits.provider_lifetime_bound_ms() ==
             Limits.provider_ringing_limit_ms() + Limits.provider_connected_limit_ms()
  end

  test "retention" do
    assert Limits.outcome_retention_days() == 90
    assert Limits.excerpt_retention_days() == 7
  end

  test "no bound is read from application environment" do
    source = File.read!(Path.expand("../../../lib/fermix_core/phone_calls/limits.ex", __DIR__))

    refute source =~ "Application."
    refute source =~ "System.get_env"
  end
end
