defmodule FermixCore.Realtime.LiveLedgerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.LiveLedger

  describe "observe_usage/3" do
    test "a cumulative snapshot replaces the previous one and is never summed" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(30, 30_000)
        |> LiveLedger.observe_usage(60, 60_000)

      assert LiveLedger.voice_seconds(ledger) == 60.0
      refute ledger.regressed?
    end

    test "a regressed snapshot is ignored and flagged" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(60, 60_000)
        |> LiveLedger.observe_usage(45, 70_000)

      assert LiveLedger.voice_seconds(ledger) == 60.0
      assert ledger.regressed?
    end
  end

  describe "tick/2" do
    test "local elapsed time accrues while the provider reports nothing" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.tick(45_000)

      assert LiveLedger.voice_seconds(ledger) == 45.0
    end

    test "a later tick recomputes from the last snapshot instead of accumulating" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(60, 60_000)
        |> LiveLedger.tick(90_000)
        |> LiveLedger.tick(120_000)

      assert LiveLedger.voice_seconds(ledger) == 120.0
    end
  end

  describe "voice_cost_millicents/1" do
    test "prices the billed second rounded up at the per-minute rate" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(30.2, 31_000)

      # ceil(30.2) = 31 billed seconds at 5_000 millicents per 60 seconds.
      assert LiveLedger.voice_cost_millicents(ledger) == 2_583
    end
  end

  describe "over_ceiling?/1" do
    test "trips when the priced duration reaches the configured ceiling" do
      ledger = LiveLedger.new(5, 0)

      refute LiveLedger.over_ceiling?(LiveLedger.tick(ledger, 59_000))
      assert LiveLedger.over_ceiling?(LiveLedger.tick(ledger, 60_000))
    end
  end

  describe "finalize/2" do
    test "a terminal duration completes the accounting and wins over the local estimate" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(60, 60_000)
        |> LiveLedger.tick(70_000)
        |> LiveLedger.finalize(75)

      assert LiveLedger.voice_seconds(ledger) == 75.0
      assert ledger.accounting == :complete
    end

    test "a missing terminal duration records incomplete accounting and keeps the spend" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(60, 60_000)
        |> LiveLedger.tick(90_000)
        |> LiveLedger.finalize(nil)

      assert LiveLedger.voice_seconds(ledger) == 90.0
      assert ledger.accounting == :incomplete
    end

    test "never overwrites a larger observed duration with a smaller terminal one" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(90, 90_000)
        |> LiveLedger.finalize(0)

      assert LiveLedger.voice_seconds(ledger) == 90.0
      assert ledger.accounting == :complete
    end
  end

  describe "record_backend_turn/2" do
    test "counts turns and token totals and never prices them" do
      ledger =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.record_backend_turn(%{input_tokens: 10, output_tokens: 4})
        |> LiveLedger.record_backend_turn(%{"input_tokens" => 6, "output_tokens" => 1})
        |> LiveLedger.record_backend_turn(%{})

      assert ledger.backend_turns == 3
      assert ledger.backend_input_tokens == 16
      assert ledger.backend_output_tokens == 5
      assert LiveLedger.usage_payload(ledger).backend_cost == "unknown"
    end
  end

  describe "usage_payload/1" do
    test "renders the live wire shape with three-decimal cents" do
      payload =
        100
        |> LiveLedger.new(0)
        |> LiveLedger.observe_usage(30.2, 31_000)
        |> LiveLedger.record_backend_turn(%{})
        |> LiveLedger.usage_payload()

      assert payload == %{
               status: "live",
               voice_seconds: 30.2,
               voice_cost_cents: 2.583,
               backend_turns: 1,
               backend_cost: "unknown",
               accounting: "running"
             }
    end

    test "reports the settled accounting word after finalize" do
      ledger = LiveLedger.new(100, 0)

      assert LiveLedger.usage_payload(LiveLedger.finalize(ledger, 12)).accounting == "complete"
      assert LiveLedger.usage_payload(LiveLedger.finalize(ledger, nil)).accounting == "incomplete"
    end
  end
end
