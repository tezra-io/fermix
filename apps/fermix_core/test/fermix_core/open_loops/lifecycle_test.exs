defmodule FermixCore.OpenLoops.LifecycleTest do
  use ExUnit.Case, async: true

  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Lifecycle

  @tz "America/New_York"
  # Monday 2031-06-02, 10:00 EDT. June 2031 is EDT (UTC-4) throughout, and every
  # date in this file is invented. 09:00 EDT is 13:00 UTC.
  @now ~U[2031-06-02 14:00:00Z]
  @hours %{start: ~T[09:00:00], finish: ~T[21:00:00], source: :default, sample: 0}
  @late_hours %{start: ~T[11:00:00], finish: ~T[22:00:00], source: :derived, sample: 60}

  defp date_passed_at(%Date{} = date) do
    date |> Date.add(1) |> DateTime.new!(~T[00:00:00], @tz) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp loop(class, date, overrides) do
    Map.merge(
      %{
        id: "loop_AbCdEfGhIjK",
        horizon_class: class,
        matters_by_kind: "date",
        matters_by_date: date,
        matters_by_time: nil,
        matters_by_at: date_passed_at(date),
        timezone: @tz,
        state: "open",
        touches: 0,
        next_touch_at: @now,
        claimed_at: nil,
        last_touch_at: nil,
        last_touch_rung: nil,
        last_answer: nil,
        plan_at: nil,
        last_outcome: nil,
        last_outcome_at: nil,
        last_message: nil
      },
      overrides
    )
  end

  # The walked loops: medium (June 10; slots June 7, 9, 11), long (June 20;
  # slots June 13, 19, 21), short (June 4; slots June 3 and 5), imminent (June 3).
  defp medium(overrides \\ %{}), do: loop("medium", ~D[2031-06-10], overrides)
  defp long(overrides \\ %{}), do: loop("long", ~D[2031-06-20], overrides)
  defp short(overrides \\ %{}), do: loop("short", ~D[2031-06-04], overrides)
  defp imminent(overrides \\ %{}), do: loop("imminent", ~D[2031-06-03], overrides)

  describe "slot_time/4: the horizon-to-touch table" do
    test "long: 7 days before, the day before, the day after, each at the active-hours start" do
      assert Lifecycle.slot_time(long(), 0, @hours, @now) == {:ok, ~U[2031-06-13 13:00:00Z]}
      assert Lifecycle.slot_time(long(), 1, @hours, @now) == {:ok, ~U[2031-06-19 13:00:00Z]}
      assert Lifecycle.slot_time(long(), 2, @hours, @now) == {:ok, ~U[2031-06-21 13:00:00Z]}
      assert Lifecycle.slot_time(long(), 3, @hours, @now) == :none
    end

    test "medium: 3 days before, the day before, the day after" do
      assert Lifecycle.slot_time(medium(), 0, @hours, @now) == {:ok, ~U[2031-06-07 13:00:00Z]}
      assert Lifecycle.slot_time(medium(), 1, @hours, @now) == {:ok, ~U[2031-06-09 13:00:00Z]}
      assert Lifecycle.slot_time(medium(), 2, @hours, @now) == {:ok, ~U[2031-06-11 13:00:00Z]}
    end

    test "short: the next active-hours start at least 24 h before the date, then the day after" do
      assert Lifecycle.slot_time(short(), 0, @hours, @now) == {:ok, ~U[2031-06-03 13:00:00Z]}
      assert Lifecycle.slot_time(short(), 1, @hours, @now) == {:ok, ~U[2031-06-05 13:00:00Z]}
      assert Lifecycle.slot_time(short(), 2, @hours, @now) == :none

      # 06:00 EDT on June 4: the next start is inside the last 24 hours.
      assert Lifecycle.slot_time(short(), 0, @hours, ~U[2031-06-04 10:00:00Z]) == :past
    end

    test "imminent: now, until the date has passed" do
      assert Lifecycle.slot_time(imminent(), 0, @hours, @now) == {:ok, @now}
      assert Lifecycle.slot_time(imminent(), 0, @hours, ~U[2031-06-04 04:00:00Z]) == :past
      assert Lifecycle.slot_time(imminent(), 1, @hours, @now) == :none
    end

    test "a slot already behind now is past" do
      assert Lifecycle.slot_time(medium(), 0, @hours, ~U[2031-06-07 13:00:00Z]) == :past
      assert Lifecycle.slot_time(medium(), 0, @hours, ~U[2031-06-08 13:00:00Z]) == :past
    end

    test "a slot follows the owner's derived start, not 09:00 by fiat" do
      assert Lifecycle.slot_time(medium(), 0, @late_hours, @now) ==
               {:ok, ~U[2031-06-07 15:00:00Z]}
    end

    test "a datetime loop's slots are read off its local date" do
      at = ~U[2031-06-10 19:00:00Z]

      timed =
        medium(%{matters_by_kind: "datetime", matters_by_time: ~T[15:00:00], matters_by_at: at})

      assert Lifecycle.slot_time(timed, 1, @hours, @now) == {:ok, ~U[2031-06-09 13:00:00Z]}
      assert Lifecycle.slot_time(timed, 2, @hours, @now) == {:ok, ~U[2031-06-11 13:00:00Z]}
    end
  end

  describe "first_touch_at/3" do
    test "every class arms its first slot; imminent arms now" do
      assert Lifecycle.first_touch_at(long(), @hours, @now) == {:ok, ~U[2031-06-13 13:00:00Z]}
      assert Lifecycle.first_touch_at(medium(), @hours, @now) == {:ok, ~U[2031-06-07 13:00:00Z]}
      assert Lifecycle.first_touch_at(short(), @hours, @now) == {:ok, ~U[2031-06-03 13:00:00Z]}
      assert Lifecycle.first_touch_at(imminent(), @hours, @now) == {:ok, @now}
    end

    test "an imminent loop with no time left before its date has no window" do
      assert Lifecycle.first_touch_at(imminent(), @hours, ~U[2031-06-04 05:00:00Z]) ==
               {:error, :imminent_without_window}
    end
  end

  describe "due_decision/2: the due scan" do
    test "an open loop whose touch is still ahead is not yet due" do
      assert Lifecycle.due_decision(medium(%{next_touch_at: ~U[2031-06-07 13:00:00Z]}), @now) ==
               :not_yet
    end

    test "an open or asked loop whose touch has arrived becomes due" do
      open = medium(%{next_touch_at: ~U[2031-06-07 13:00:00Z]})
      assert Lifecycle.due_decision(open, ~U[2031-06-07 13:00:00Z]) == :due

      asked = medium(%{state: "asked", touches: 1, next_touch_at: ~U[2031-06-09 13:00:00Z]})
      assert Lifecycle.due_decision(asked, ~U[2031-06-09 13:30:00Z]) == :due
    end

    test "a row already due, or held by a check-in, stays as it is" do
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-07 13:00:00Z]})
      assert Lifecycle.due_decision(due, ~U[2031-06-07 20:00:00Z]) == :not_yet

      claimed = %{due | claimed_at: ~U[2031-06-07 17:00:00Z]}
      assert Lifecycle.due_decision(claimed, ~U[2031-06-11 20:00:00Z]) == :not_yet
    end

    test "daemon asleep: a passed before-the-date slot skips to the hand-back once asked" do
      asked = medium(%{state: "asked", touches: 1, next_touch_at: ~U[2031-06-09 13:00:00Z]})

      assert Lifecycle.due_decision(asked, ~U[2031-06-11 10:00:00Z]) ==
               {:skip_to_handback, ~U[2031-06-11 13:00:00Z]}

      stuck_due = medium(%{state: "due", touches: 1, next_touch_at: ~U[2031-06-09 13:00:00Z]})

      assert Lifecycle.due_decision(stuck_due, ~U[2031-06-11 04:00:00Z]) ==
               {:skip_to_handback, ~U[2031-06-11 13:00:00Z]}
    end

    test "daemon asleep: a passed before-the-date slot never asked expires" do
      never_asked = medium(%{next_touch_at: ~U[2031-06-07 13:00:00Z]})
      assert Lifecycle.due_decision(never_asked, ~U[2031-06-12 13:00:00Z]) == :expire

      due_never_asked = medium(%{state: "due", next_touch_at: ~U[2031-06-09 13:00:00Z]})
      assert Lifecycle.due_decision(due_never_asked, ~U[2031-06-11 04:00:00Z]) == :expire
    end

    test "the hand-back slot comes due like any other" do
      skipped = medium(%{touches: 1, next_touch_at: ~U[2031-06-11 13:00:00Z]})

      skipped =
        Map.merge(skipped, %{last_touch_at: ~U[2031-06-07 13:30:00Z], last_touch_rung: 1})

      assert Lifecycle.due_decision(skipped, ~U[2031-06-11 13:00:00Z]) == :due
    end

    test "a hand-back not delivered within a day of its slot expires" do
      handback = medium(%{state: "due", touches: 2, next_touch_at: ~U[2031-06-11 13:00:00Z]})
      handback = %{handback | last_touch_at: ~U[2031-06-09 13:30:00Z]}

      assert Lifecycle.due_decision(handback, ~U[2031-06-12 12:59:59Z]) == :not_yet
      assert Lifecycle.due_decision(handback, ~U[2031-06-12 13:00:00Z]) == :expire

      slept = %{handback | state: "asked"}
      assert Lifecycle.due_decision(slept, ~U[2031-06-13 13:00:00Z]) == :expire
    end

    test "an asked row whose hand-back is spent expires when its answer day ends" do
      spent =
        medium(%{
          state: "asked",
          touches: 3,
          last_touch_at: ~U[2031-06-11 16:00:00Z],
          last_touch_rung: 2,
          next_touch_at: ~U[2031-06-12 16:00:00Z]
        })

      assert Lifecycle.due_decision(spent, ~U[2031-06-12 15:59:59Z]) == :not_yet
      assert Lifecycle.due_decision(spent, ~U[2031-06-12 16:00:00Z]) == :expire

      skipped_then_handed_back = %{spent | touches: 2}
      assert Lifecycle.due_decision(skipped_then_handed_back, ~U[2031-06-12 16:00:00Z]) == :expire
    end

    test "under 48 hours: due at once, and expired once the date passes" do
      assert Lifecycle.due_decision(imminent(), @now) == :due

      due = imminent(%{state: "due"})
      assert Lifecycle.due_decision(due, ~U[2031-06-04 03:59:59Z]) == :not_yet
      assert Lifecycle.due_decision(due, ~U[2031-06-04 04:00:00Z]) == :expire
    end
  end

  describe "rung2_eligible?/4: the rung 2 claim rule" do
    setup do
      %{due: medium(%{state: "due", next_touch_at: ~U[2031-06-07 13:00:00Z]})}
    end

    test "an imminent loop never gets an unprompted check-in" do
      assert Lifecycle.rung2_eligible?(imminent(%{state: "due"}), @now, @hours, false) ==
               {:skip, :imminent}
    end

    test "rung 2 waits for the rung 1 window to close", %{due: due} do
      assert Lifecycle.rung2_eligible?(due, ~U[2031-06-07 15:59:59Z], @hours, false) ==
               {:skip, :window_open}
    end

    test "rung 2 waits for active hours", %{due: due} do
      assert Lifecycle.rung2_eligible?(due, ~U[2031-06-08 02:00:00Z], @hours, false) ==
               {:skip, :active_hours}
    end

    test "rung 2 waits a day once the day's budget is spent", %{due: due} do
      assert Lifecycle.rung2_eligible?(due, ~U[2031-06-07 17:00:00Z], @hours, true) ==
               {:skip, :budget}
    end

    test "a due loop past its window, in active hours, inside the budget is eligible",
         %{due: due} do
      assert Lifecycle.rung2_eligible?(due, ~U[2031-06-07 16:00:00Z], @hours, false) == true
    end
  end

  describe "after_touch/4: the touch ledger" do
    test "a touch counts, marks asked and arms the following slot" do
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-07 13:00:00Z]})
      now = ~U[2031-06-07 17:00:00Z]

      assert Lifecycle.after_touch(due, 2, now, @hours) == %{
               touches: 1,
               state: "asked",
               next_touch_at: ~U[2031-06-09 13:00:00Z],
               last_touch_at: now,
               last_touch_rung: 2
             }
    end

    test "the second touch arms the hand-back, and the hand-back arms the answer day" do
      second = medium(%{state: "due", touches: 1, next_touch_at: ~U[2031-06-09 13:00:00Z]})

      assert %{touches: 2, next_touch_at: ~U[2031-06-11 13:00:00Z]} =
               Lifecycle.after_touch(second, 1, ~U[2031-06-09 15:00:00Z], @hours)

      handback = medium(%{state: "due", touches: 2, next_touch_at: ~U[2031-06-11 13:00:00Z]})

      assert %{touches: 3, next_touch_at: ~U[2031-06-12 17:00:00Z]} =
               Lifecycle.after_touch(handback, 2, ~U[2031-06-11 17:00:00Z], @hours)
    end

    test "short loops go from their one before-the-date touch to the hand-back" do
      due = short(%{state: "due", next_touch_at: ~U[2031-06-03 13:00:00Z]})

      assert %{touches: 1, next_touch_at: ~U[2031-06-05 13:00:00Z]} =
               Lifecycle.after_touch(due, 1, ~U[2031-06-03 13:30:00Z], @hours)
    end

    test "an imminent loop raised once waits a day for the answer, then expires" do
      assert %{touches: 1, state: "asked", next_touch_at: ~U[2031-06-03 14:00:00Z]} =
               Lifecycle.after_touch(imminent(%{state: "due"}), 1, @now, @hours)
    end

    test "a fourth touch cannot exist" do
      spent = medium(%{state: "due", touches: 3})
      assert_raise FunctionClauseError, fn -> Lifecycle.after_touch(spent, 2, @now, @hours) end
    end

    test "only rungs 1 and 2 touch" do
      assert_raise FunctionClauseError, fn -> Lifecycle.after_touch(medium(), 3, @now, @hours) end
    end
  end

  describe "after_answer/5: every transition the owner's answer makes" do
    setup do
      asked =
        medium(%{
          state: "asked",
          touches: 1,
          next_touch_at: ~U[2031-06-09 13:00:00Z],
          last_touch_at: ~U[2031-06-07 13:30:00Z],
          last_touch_rung: 1
        })

      %{asked: asked, now: ~U[2031-06-07 17:00:00Z]}
    end

    test "done, stop and drop close the loop for good", %{asked: asked, now: now} do
      for {answer, reason} <- [{"done", "done"}, {"stop", "stop"}, {"drop", "dropped"}] do
        assert Lifecycle.after_answer(asked, answer, nil, now, @hours) ==
                 {:ok,
                  %{
                    state: "closed",
                    close_reason: reason,
                    closed_at: now,
                    next_touch_at: nil,
                    last_answer: answer
                  }}
      end
    end

    test "every answer is accepted on every live state", %{asked: asked, now: now} do
      for state <- ~w(open due asked) do
        assert {:ok, %{state: "closed"}} =
                 Lifecycle.after_answer(%{asked | state: state}, "done", nil, now, @hours)
      end
    end

    test "a plan re-arms at the plan's date and no earlier", %{asked: asked, now: now} do
      plan_at = ~U[2031-06-08 22:00:00Z]

      assert {:ok, changes} = Lifecycle.after_answer(asked, "plan", plan_at, now, @hours)

      assert changes == %{
               state: "open",
               last_answer: "plan",
               plan_at: plan_at,
               next_touch_at: plan_at
             }

      planned = Map.merge(asked, changes)
      assert Lifecycle.due_decision(planned, ~U[2031-06-08 21:59:59Z]) == :not_yet
      assert Lifecycle.due_decision(planned, plan_at) == :due
    end

    test "the plan stands in for the pending slot and leaves the later ones alone",
         %{asked: asked, now: now} do
      plan_at = ~U[2031-06-08 22:00:00Z]
      {:ok, changes} = Lifecycle.after_answer(asked, "plan", plan_at, now, @hours)
      planned = Map.merge(asked, %{changes | state: "due"})

      # The plan replaced the day-before slot, so the next one is the hand-back.
      assert %{touches: 2, next_touch_at: ~U[2031-06-11 13:00:00Z]} =
               Lifecycle.after_touch(planned, 1, ~U[2031-06-08 22:30:00Z], @hours)
    end

    test "a plan needs a date no later than the loop's own", %{asked: asked, now: now} do
      assert Lifecycle.after_answer(asked, "plan", nil, now, @hours) ==
               {:error, :plan_requires_date}

      assert Lifecycle.after_answer(asked, "plan", ~U[2031-06-11 04:00:01Z], now, @hours) ==
               {:error, :plan_after_date}

      assert Lifecycle.after_answer(asked, "plan", now, now, @hours) == {:error, :plan_passed}

      assert {:ok, %{next_touch_at: ~U[2031-06-11 04:00:00Z]}} =
               Lifecycle.after_answer(asked, "plan", ~U[2031-06-11 04:00:00Z], now, @hours)
    end

    test "only a plan carries a plan date", %{asked: asked, now: now} do
      assert Lifecycle.after_answer(asked, "done", ~U[2031-06-08 22:00:00Z], now, @hours) ==
               {:error, :plan_at_without_plan}
    end

    test "not yet keeps the loop open for one more touch nearer the date",
         %{asked: asked, now: now} do
      assert Lifecycle.after_answer(asked, "not_yet", nil, now, @hours) ==
               {:ok,
                %{state: "open", last_answer: "not_yet", next_touch_at: ~U[2031-06-09 13:00:00Z]}}

      # Volunteered while due and never asked: the passed slot is not re-armed.
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-07 13:00:00Z]})

      assert {:ok, %{next_touch_at: ~U[2031-06-09 13:00:00Z]}} =
               Lifecycle.after_answer(due, "not_yet", nil, ~U[2031-06-07 15:00:00Z], @hours)
    end

    test "not yet after the hand-back keeps the expiry", %{asked: asked} do
      spent = %{asked | touches: 3, next_touch_at: ~U[2031-06-12 16:00:00Z]}
      spent = %{spent | last_touch_at: ~U[2031-06-11 16:00:00Z]}

      assert Lifecycle.after_answer(spent, "not_yet", nil, ~U[2031-06-11 18:00:00Z], @hours) ==
               {:ok,
                %{state: "open", last_answer: "not_yet", next_touch_at: ~U[2031-06-12 16:00:00Z]}}
    end

    test "asked records a rung 1 raise as a touch", %{now: now} do
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-07 13:00:00Z]})

      assert {:ok, %{touches: 1, state: "asked", last_touch_rung: 1, last_touch_at: ^now}} =
               Lifecycle.after_answer(due, "asked", nil, now, @hours)
    end

    test "asked is refused on an asked row and once the touches are spent",
         %{asked: asked, now: now} do
      assert Lifecycle.after_answer(asked, "asked", nil, now, @hours) == {:error, :already_asked}

      spent =
        Map.merge(asked, %{
          state: "open",
          touches: 3,
          last_touch_at: ~U[2031-06-11 16:00:00Z],
          next_touch_at: ~U[2031-06-12 16:00:00Z]
        })

      assert Lifecycle.after_answer(spent, "asked", nil, ~U[2031-06-11 18:00:00Z], @hours) ==
               {:error, :already_asked}
    end

    test "touches advance only through a touch", %{asked: asked, now: now} do
      for answer <- ~w(done stop drop not_yet) do
        {:ok, changes} = Lifecycle.after_answer(asked, answer, nil, now, @hours)
        refute Map.has_key?(changes, :touches), "#{answer} moved the touch count"
      end

      {:ok, changes} =
        Lifecycle.after_answer(asked, "plan", ~U[2031-06-08 22:00:00Z], now, @hours)

      refute Map.has_key?(changes, :touches)

      due = %{asked | state: "due"}

      for outcome <- ~w(silent empty delivery_failed timeout error closed) do
        changes = Lifecycle.after_outcome(due, outcome, now, @hours)
        refute Map.has_key?(changes, :touches), "#{outcome} moved the touch count"
      end
    end
  end

  describe "after_outcome/4: a check-in that did not speak" do
    setup do
      %{
        due: medium(%{state: "due", next_touch_at: ~U[2031-06-07 13:00:00Z]}),
        now: ~U[2031-06-07 17:00:00Z]
      }
    end

    test "silent and empty advance to the following slot", %{due: due, now: now} do
      for outcome <- ~w(silent empty) do
        assert Lifecycle.after_outcome(due, outcome, now, @hours) == %{
                 state: "open",
                 next_touch_at: ~U[2031-06-09 13:00:00Z],
                 last_outcome: outcome,
                 last_outcome_at: now
               }
      end
    end

    test "silence on the last before-the-date slot of a loop never asked expires it" do
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-09 13:00:00Z]})
      now = ~U[2031-06-09 17:00:00Z]

      assert %{state: "expired", close_reason: "expired", closed_at: ^now, next_touch_at: nil} =
               Lifecycle.after_outcome(due, "silent", now, @hours)
    end

    test "silence on the hand-back ends the loop" do
      handback = medium(%{state: "due", touches: 1, next_touch_at: ~U[2031-06-11 13:00:00Z]})
      handback = %{handback | last_touch_at: ~U[2031-06-07 13:30:00Z]}
      now = ~U[2031-06-11 17:00:00Z]

      assert %{state: "expired", close_reason: "expired", last_outcome: "silent"} =
               Lifecycle.after_outcome(handback, "silent", now, @hours)
    end

    test "a failed run retries at the next active-hours start", %{due: due, now: now} do
      for outcome <- ~w(delivery_failed timeout error) do
        assert Lifecycle.after_outcome(due, outcome, now, @hours) == %{
                 state: "open",
                 next_touch_at: ~U[2031-06-08 13:00:00Z],
                 last_outcome: outcome,
                 last_outcome_at: now
               }
      end
    end

    test "a retry is never armed sooner than the five-second floor", %{due: due} do
      now = ~U[2031-06-08 12:59:58Z]

      assert %{next_touch_at: ~U[2031-06-08 13:00:03Z]} =
               Lifecycle.after_outcome(due, "timeout", now, @hours)
    end

    test "a retry that would land after the date goes to the hand-back, or ends a loop never asked" do
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-09 13:00:00Z]})
      now = ~U[2031-06-10 17:00:00Z]

      assert %{state: "expired"} = Lifecycle.after_outcome(due, "error", now, @hours)

      asked_once = %{due | touches: 1, last_touch_at: ~U[2031-06-07 13:30:00Z]}

      assert %{state: "open", next_touch_at: ~U[2031-06-11 15:00:00Z]} =
               Lifecycle.after_outcome(asked_once, "error", now, @late_hours)
    end

    test "the hand-back retries once, then expires" do
      handback = medium(%{state: "due", touches: 1, next_touch_at: ~U[2031-06-11 13:00:00Z]})
      handback = %{handback | last_touch_at: ~U[2031-06-07 13:30:00Z]}
      first = ~U[2031-06-11 17:00:00Z]

      assert %{state: "open", next_touch_at: ~U[2031-06-12 13:00:00Z]} =
               changes = Lifecycle.after_outcome(handback, "delivery_failed", first, @hours)

      retried = Map.merge(handback, %{changes | state: "due"})

      assert %{state: "expired", last_outcome: "timeout"} =
               Lifecycle.after_outcome(retried, "timeout", ~U[2031-06-12 17:00:00Z], @hours)
    end

    test "closed reports the loop settled elsewhere", %{due: due, now: now} do
      assert Lifecycle.after_outcome(due, "closed", now, @hours) == %{
               state: "closed",
               close_reason: "reported_elsewhere",
               closed_at: now,
               next_touch_at: nil,
               last_outcome: "closed",
               last_outcome_at: now
             }
    end

    test "a spoken message is a touch, not an outcome", %{due: due, now: now} do
      assert_raise FunctionClauseError, fn ->
        Lifecycle.after_outcome(due, "spoke", now, @hours)
      end
    end
  end

  describe "next_wake/2: when the scheduler must look again" do
    test "an open or asked loop wakes at its next touch" do
      assert Lifecycle.next_wake(medium(%{next_touch_at: ~U[2031-06-07 13:00:00Z]}), @now) ==
               ~U[2031-06-07 13:00:00Z]
    end

    test "a due loop wakes when its rung 1 window closes, then when its date passes" do
      due = medium(%{state: "due", next_touch_at: ~U[2031-06-09 13:00:00Z]})

      assert Lifecycle.next_wake(due, ~U[2031-06-09 14:00:00Z]) == ~U[2031-06-09 16:00:00Z]
      assert Lifecycle.next_wake(due, ~U[2031-06-09 17:00:00Z]) == ~U[2031-06-11 04:00:00Z]
    end

    test "an imminent due loop wakes when its date passes" do
      assert Lifecycle.next_wake(imminent(%{state: "due"}), @now) == ~U[2031-06-04 04:00:00Z]
    end

    test "a due hand-back wakes when its day of grace ends" do
      handback = medium(%{state: "due", touches: 2, next_touch_at: ~U[2031-06-11 13:00:00Z]})
      handback = %{handback | last_touch_at: ~U[2031-06-09 13:30:00Z]}

      assert Lifecycle.next_wake(handback, ~U[2031-06-11 17:00:00Z]) == ~U[2031-06-12 13:00:00Z]
    end

    test "a claimed or closed loop has nothing for the scheduler" do
      claimed = medium(%{state: "due", claimed_at: @now})
      assert Lifecycle.next_wake(claimed, @now) == nil

      closed = medium(%{state: "closed", next_touch_at: nil})
      assert Lifecycle.next_wake(closed, @now) == nil
    end
  end

  describe "final_touch?/1" do
    test "the hand-back and the last touch a class allows are final" do
      refute Lifecycle.final_touch?(
               medium(%{touches: 0, next_touch_at: ~U[2031-06-07 13:00:00Z]})
             )

      refute Lifecycle.final_touch?(
               medium(%{touches: 1, next_touch_at: ~U[2031-06-09 13:00:00Z]})
             )

      assert Lifecycle.final_touch?(
               medium(%{touches: 2, next_touch_at: ~U[2031-06-11 13:00:00Z]})
             )

      assert Lifecycle.final_touch?(
               medium(%{touches: 1, next_touch_at: ~U[2031-06-11 13:00:00Z]})
             )

      assert Lifecycle.final_touch?(short(%{touches: 1, next_touch_at: ~U[2031-06-04 13:00:00Z]}))
    end
  end

  test "every class's table fits under the touch cap" do
    for class <- ~w(long medium short imminent) do
      assert length(Defaults.slots(class)) <= Defaults.max_touches()
    end
  end
end
