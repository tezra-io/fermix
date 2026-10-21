defmodule FermixCore.Realtime.GrokLedgerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.GrokLedger

  @minute 60_000

  describe "the spending ceiling" do
    test "a $1 ceiling allows 12.5 connected minutes with no text items" do
      ledger = GrokLedger.new(100, 0)

      assert GrokLedger.ms_until_ceiling(ledger) == 750_000
      refute GrokLedger.over_ceiling?(GrokLedger.tick(ledger, 749_000))
      assert GrokLedger.over_ceiling?(GrokLedger.tick(ledger, 750_000))
      assert GrokLedger.ms_until_ceiling(GrokLedger.tick(ledger, 750_000)) == 0
    end

    test "twenty text items bring a $1 ceiling down to 11.5 minutes" do
      ledger = sent(GrokLedger.new(100, 0), 20)

      assert GrokLedger.ms_until_ceiling(ledger) == 690_000
      refute GrokLedger.over_ceiling?(GrokLedger.tick(ledger, 689_000))
      assert GrokLedger.over_ceiling?(GrokLedger.tick(ledger, 690_000))
    end

    # A timer set for `ms_until_ceiling/1` must find the ceiling reached when
    # it fires, or the session would have to re-arm it.
    test "the ceiling has been reached when a timer for the remaining span fires" do
      for ceiling <- [1, 7, 33, 100, 999], items <- [0, 1, 2], start <- [0, 12_345] do
        ledger = sent(GrokLedger.new(ceiling, start), items)
        remaining = GrokLedger.ms_until_ceiling(ledger)

        assert GrokLedger.over_ceiling?(GrokLedger.tick(ledger, start + remaining)),
               "ceiling #{ceiling}, #{items} items, #{remaining} ms"
      end
    end

    test "text items alone past the ceiling leave no time at all" do
      ledger = sent(GrokLedger.new(1, 0), 3)

      assert GrokLedger.ms_until_ceiling(ledger) == 0
      assert GrokLedger.over_ceiling?(ledger)
    end

    test "a text item is afforded only if it fits under the ceiling before it is sent" do
      ledger = GrokLedger.new(2, 0)

      assert GrokLedger.affords_text_item?(sent(ledger, 4))
      refute GrokLedger.over_ceiling?(sent(ledger, 4))
      refute GrokLedger.affords_text_item?(sent(ledger, 5))
      assert GrokLedger.over_ceiling?(sent(ledger, 5))

      # Duration counts against the same ceiling.
      refute GrokLedger.affords_text_item?(ledger |> sent(4) |> GrokLedger.tick(1))
    end

    test "a ceiling must be a positive number of cents" do
      assert_raise FunctionClauseError, fn -> GrokLedger.new(0, 0) end
    end
  end

  describe "duration" do
    # The meter is the connection: nothing happening is still a billed minute.
    test "silence counts: connected time accrues with no events at all" do
      ledger = GrokLedger.tick(GrokLedger.new(100, 1_000), 1_000 + @minute)

      assert GrokLedger.connected_ms(ledger) == @minute
      assert GrokLedger.voice_cost_millicents(ledger) == 8_000
    end

    test "the clock never moves backwards" do
      ledger =
        100
        |> GrokLedger.new(0)
        |> GrokLedger.tick(10_000)
        |> GrokLedger.tick(5_000)

      assert GrokLedger.connected_ms(ledger) == 10_000
    end

    # 15 ms is exactly 2 millicents; fifteen 1 ms ticks rounded one by one
    # would bill 15.
    test "the duration charge is rounded up once over the whole span" do
      ledger = Enum.reduce(1..15, GrokLedger.new(100, 0), &GrokLedger.tick(&2, &1))

      assert GrokLedger.voice_cost_millicents(ledger) == 2
      assert GrokLedger.voice_cost_millicents(GrokLedger.tick(GrokLedger.new(100, 0), 1)) == 1
      assert GrokLedger.voice_cost_millicents(GrokLedger.new(100, 0)) == 0
    end
  end

  describe "text items" do
    test "an item is charged when sent, and its acknowledgement never lowers the cost" do
      ledger = sent(GrokLedger.new(100, 0), 2)
      acked = ledger |> GrokLedger.text_item_acked() |> GrokLedger.text_item_acked()

      assert GrokLedger.voice_cost_millicents(ledger) == 800
      assert GrokLedger.voice_cost_millicents(acked) == 800
      assert acked.text_items_acked == 2
    end

    test "an acknowledgement with no sent item behind it is refused" do
      ledger = GrokLedger.text_item_acked(sent(GrokLedger.new(100, 0), 1))

      assert_raise FunctionClauseError, fn -> GrokLedger.text_item_acked(ledger) end
    end

    # Function outputs are not billable text, so the ledger has no way to count
    # one, and a backend turn has no price.
    test "function outputs and backend turns are never charged" do
      exported = GrokLedger.__info__(:functions)

      refute Enum.any?(exported, fn {name, _arity} -> Atom.to_string(name) =~ "function" end)

      ledger = GrokLedger.tick(GrokLedger.new(100, 0), 30_000)
      turned = ledger |> GrokLedger.record_backend_turn() |> GrokLedger.record_backend_turn()

      assert GrokLedger.voice_cost_millicents(turned) == GrokLedger.voice_cost_millicents(ledger)
      assert GrokLedger.usage_payload(turned).backend_turns == 2
    end
  end

  describe "finalize/2" do
    test "settles as incomplete at the final reading, with the spend kept" do
      ledger =
        100
        |> GrokLedger.new(0)
        |> GrokLedger.tick(30_000)
        |> GrokLedger.finalize(45_000)

      assert ledger.accounting == :incomplete
      assert GrokLedger.connected_ms(ledger) == 45_000
      assert GrokLedger.voice_cost_millicents(ledger) == 6_000
    end

    test "a final reading earlier than the last tick does not lower the spend" do
      ledger =
        100
        |> GrokLedger.new(0)
        |> GrokLedger.tick(45_000)
        |> GrokLedger.finalize(30_000)

      assert GrokLedger.connected_ms(ledger) == 45_000
    end
  end

  describe "usage_payload/1" do
    test "renders seconds and cents with three decimals, and backend cost as unknown" do
      ledger =
        100
        |> GrokLedger.new(0)
        |> GrokLedger.tick(30_200)
        |> sent(2)
        |> GrokLedger.record_backend_turn()

      # ceil(30_200 * 8_000 / 60_000) = 4_027 millicents, plus two items at 400.
      assert GrokLedger.usage_payload(ledger) == %{
               status: "live",
               voice_seconds: 30.2,
               voice_cost_cents: 4.827,
               voice_text_items: 2,
               backend_turns: 1,
               backend_cost: "unknown",
               accounting: "running"
             }

      assert GrokLedger.usage_payload(GrokLedger.finalize(ledger, 30_200)).accounting ==
               "incomplete"
    end
  end

  defp sent(ledger, count) when count >= 0 do
    Enum.reduce(List.duplicate(:item, count), ledger, fn :item, acc ->
      GrokLedger.text_item_sent(acc)
    end)
  end
end
