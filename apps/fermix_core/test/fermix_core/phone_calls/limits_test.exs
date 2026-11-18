defmodule FermixCore.PhoneCalls.LimitsTest do
  # Pure module: constants only, no app env, no settings.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Limits

  # launchd's default `ExitTimeOut`, which applies under the Mac app, whose
  # launch agent sets none: the smallest window the engine gets to stop.
  @launchd_exit_timeout_ms 20 * 1000
  # What an orderly stop stops before the drain begins (nothing), and after.
  @stops_before_drain_ms 0
  @trees_after_drain_ms 10 * 1000

  test "external calls and attempts" do
    assert Limits.max_outstanding_calls() == 1
    assert Limits.max_attempts_per_day() == 5
    assert Limits.attempt_window_ms() == 24 * 60 * 60 * 1000
  end

  test "call, ringing and inactivity deadlines" do
    assert Limits.call_deadline_ms() == 10 * 60 * 1000
    assert Limits.ringing_timeout_ms() == 60 * 1000
    assert Limits.recipient_silence_timeout_ms() == 120 * 1000
    assert Limits.opening_wait_ms() == 2 * 1000
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
    assert Limits.dtmf_ack_timeout_ms() == 3 * 1000
  end

  test "cleanup and report" do
    assert Limits.max_immediate_termination_requests() == 1
    assert Limits.max_cleanup_retries() == 2
    assert Limits.cleanup_window_ms() == 30 * 1000
    assert Limits.terminal_drain_ms() == 5 * 1000
    assert Limits.result_extraction_timeout_ms() == 60 * 1000
    assert Limits.max_report_delivery_attempts() == 3
    assert Limits.max_terminal_write_attempts() == 5
    assert Limits.terminal_write_retry_ms() == 1_000
  end

  test "the slot is measured from the latest moment a session could have started" do
    assert Limits.max_create_wait_ms() == 90 * 1000

    assert Limits.slot_hold_ms() ==
             Limits.max_create_wait_ms() + Limits.provider_lifetime_bound_ms()
  end

  # The engine gets a fixed window to stop before SIGKILL: what the CLI's own
  # service units ask (`Fermix.CLI.Service.Templates`: ExitTimeOut,
  # TimeoutStopSec), or launchd's default under the Mac app, whose launch
  # agent sets none (`@launchd_exit_timeout_ms`). Nothing stops before the
  # drain: the first application an orderly stop stops (web, else channels,
  # else the core) drains in its own `prep_stop/1`, before its tree goes
  # (`FermixChannels.ApplicationStopTest`, `FermixWeb.ApplicationStopTest`).
  # Every tree stops after it, the channels application's own children taking
  # up to 10 s. So the drain, and then the trees, fit the smallest window, and
  # the drain holds the shutdown path's hangup wait, the terminal drain and a
  # second for the end report.
  test "the orderly stop's drain fits the smallest stop window the engine runs under" do
    templates =
      File.read!(Path.expand("../../../lib/fermix/cli/service/templates.ex", __DIR__))

    windows =
      Regex.scan(~r/ExitTimeOut<\/key><integer>(\d+)<|TimeoutStopSec=(\d+)/, templates)
      |> Enum.map(fn captures -> captures |> Enum.drop(1) |> Enum.join() end)
      |> Enum.map(&(String.to_integer(&1) * 1000))

    assert windows != []
    window_ms = Enum.min([@launchd_exit_timeout_ms | windows])
    assert window_ms == @launchd_exit_timeout_ms

    assert Limits.shutdown_drain_ms() == 10 * 1000

    assert @stops_before_drain_ms + Limits.shutdown_drain_ms() + @trees_after_drain_ms <=
             window_ms

    assert Limits.shutdown_hangup_wait_ms() == 3 * 1000

    assert Limits.shutdown_hangup_wait_ms() + Limits.terminal_drain_ms() + 1_000 <=
             Limits.shutdown_drain_ms()
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
