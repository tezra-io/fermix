defmodule FermixCore.OpenLoops.DefaultsTest do
  use ExUnit.Case, async: true

  alias FermixCore.OpenLoops.Defaults

  @tz "America/New_York"
  # Monday 2031-06-02, 10:00 EDT. Every date in this file is invented.
  @said_at ~U[2031-06-02 14:00:00Z]

  # The UTC instant a date-only loop has passed: the start of the next local day.
  defp date_passed_at(%Date{} = date) do
    date |> Date.add(1) |> DateTime.new!(~T[00:00:00], @tz) |> DateTime.shift_zone!("Etc/UTC")
  end

  describe "caps and bounds" do
    test "the touch, loop and window constants are the spec's numbers" do
      assert Defaults.max_touches() == 3
      assert Defaults.max_live_loops() == 20
      assert Defaults.rung1_window_ms() == 3 * 60 * 60 * 1000
      assert Defaults.expiry_grace_ms() == 24 * 60 * 60 * 1000
      assert Defaults.fault_floor_ms() == 5_000
    end

    test "active hours derive from 28 days and at least 40 messages, else 09:00 to 21:00" do
      assert Defaults.active_hours_default() == {~T[09:00:00], ~T[21:00:00]}
      assert Defaults.active_hours_lookback_days() == 28
      assert Defaults.active_hours_min_messages() == 40
      assert Defaults.active_hours_percentiles() == {15, 85}
      assert Defaults.active_hours_min_span_hours() == 6
    end

    test "the check-in run keeps the follow-up run's bounds" do
      assert Defaults.checkin_max_iterations() == 6
      assert Defaults.checkin_watchdog_ms() == 120_000
      assert Defaults.send_timeout_ms() == 60_000
    end

    test "every text the model passes has its bound" do
      assert Defaults.message_max_bytes() == 1_800
      assert Defaults.intention_max() == 500
      assert Defaults.why_it_matters_max() == 300
      assert Defaults.owner_words_max() == 240
      assert Defaults.reason_max() == 240
      assert Defaults.dedupe_key_max() == 240
      assert Defaults.closed_list_limit() == 25
    end

    test "loops waited on and their replies keep M83's bounds" do
      assert Defaults.after_max_touches() == 2
      assert Defaults.conversation_window_ms() == 14 * 24 * 60 * 60 * 1000
      assert Defaults.ask_after_min_ms() == 3 * 60 * 60 * 1000
      assert Defaults.ask_after_max_ms() == 365 * 24 * 60 * 60 * 1000
      assert Defaults.reactions_kept() == 50
      assert Defaults.note_replies() == %{this_loop: 1, others: 2}
      assert Defaults.checkin_replies() == %{this_loop: 1, others: 4}
      assert Defaults.reply_window_ms() == 24 * 60 * 60 * 1000
      assert Defaults.reply_text_max() == 280
      assert Defaults.raised_with_max() == 280
      assert Defaults.reaches() == ~w(conversation message)
    end
  end

  describe "horizon_class/3" do
    test "fourteen local days or more is long" do
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-06-16]), @tz) == "long"
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-07-30]), @tz) == "long"
    end

    test "four to thirteen local days is medium" do
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-06-15]), @tz) == "medium"
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-06-06]), @tz) == "medium"
    end

    test "two to three local days is short" do
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-06-05]), @tz) == "short"
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-06-04]), @tz) == "short"
    end

    test "under 48 hours to the instant the date has passed is imminent" do
      assert Defaults.horizon_class(@said_at, date_passed_at(~D[2031-06-03]), @tz) == "imminent"

      # A datetime 47 hours out is imminent although it is two local days away.
      assert Defaults.horizon_class(@said_at, ~U[2031-06-04 13:00:00Z], @tz) == "imminent"
    end

    test "exactly 48 hours is not imminent, and one local day of it is short" do
      said_at = ~U[2031-06-02 04:00:00Z]
      assert Defaults.horizon_class(said_at, date_passed_at(~D[2031-06-03]), @tz) == "short"
    end

    test "the local dates are read in the loop's zone, not in UTC" do
      # 23:30 EDT on June 1 is already June 2 in UTC; the local date said is June 1.
      late = ~U[2031-06-02 03:30:00Z]
      assert Defaults.horizon_class(late, date_passed_at(~D[2031-06-15]), @tz) == "long"
    end
  end

  describe "slots/1" do
    test "each class has its slot table, and its last slot is the hand-back" do
      assert Defaults.slots("long") == [{:days_before, 7}, {:days_before, 1}, {:days_after, 1}]
      assert Defaults.slots("medium") == [{:days_before, 3}, {:days_before, 1}, {:days_after, 1}]
      assert Defaults.slots("short") == [{:before_hours_min, 24}, {:days_after, 1}]
      assert Defaults.slots("imminent") == [{:after_hours, 3}]
      assert Defaults.slots("after") == [{:at_anchor}]
    end

    test "no class has more slots than a loop has touches" do
      for class <- ~w(long medium short imminent after) do
        assert length(Defaults.slots(class)) <= Defaults.max_touches()
      end

      assert length(Defaults.slots("after")) < Defaults.after_max_touches()
    end

    test "an unknown class is refused loudly" do
      assert_raise FunctionClauseError, fn -> Defaults.slots("weekly") end
    end
  end

  describe "slots/2" do
    test "a message loop keeps its class's table" do
      for class <- ~w(long medium short imminent after) do
        assert Defaults.slots(class, "message") == Defaults.slots(class)
      end
    end

    test "a conversation loop has no hand-back" do
      assert Defaults.slots("long", "conversation") == [{:days_before, 7}, {:days_before, 1}]
      assert Defaults.slots("medium", "conversation") == [{:days_before, 3}, {:days_before, 1}]
      assert Defaults.slots("short", "conversation") == [{:before_hours_min, 24}]
      assert Defaults.slots("imminent", "conversation") == [{:after_hours, 3}]
      assert Defaults.slots("after", "conversation") == [{:at_anchor}]

      for class <- ~w(long medium short imminent after) do
        refute Defaults.handback?(class, "conversation")
      end

      for class <- ~w(long medium short), do: assert(Defaults.handback?(class, "message"))
      refute Defaults.handback?("imminent", "message")
      refute Defaults.handback?("after", "message")
    end

    test "an unknown reach is refused loudly" do
      assert_raise FunctionClauseError, fn -> Defaults.slots("long", "email") end
    end
  end
end
