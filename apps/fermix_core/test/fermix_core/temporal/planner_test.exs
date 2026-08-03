defmodule FermixCore.Temporal.PlannerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.Planner

  @tz "America/New_York"

  defp birthday(overrides \\ %{}) do
    {:ok, plan} = Defaults.plan_for("birthday", "date")

    Map.merge(
      %{
        title: "Sarah's birthday",
        description: nil,
        kind: "birthday",
        time_kind: "date",
        local_date: nil,
        local_time: nil,
        timezone: @tz,
        occurrence_at: nil,
        recurrence_kind: "yearly",
        recurrence_month: 9,
        recurrence_day: 14,
        leap_day_policy: nil,
        reminder_plan: plan
      },
      overrides
    )
  end

  defp appointment(overrides \\ %{}) do
    {:ok, plan} = Defaults.plan_for("appointment", "datetime")

    Map.merge(
      %{
        title: "Dentist appointment",
        description: nil,
        kind: "appointment",
        time_kind: "datetime",
        local_date: ~D[2026-08-16],
        local_time: ~T[15:00:00],
        timezone: @tz,
        occurrence_at: ~U[2026-08-16 19:00:00Z],
        recurrence_kind: "once",
        recurrence_month: nil,
        recurrence_day: nil,
        leap_day_policy: nil,
        reminder_plan: plan
      },
      overrides
    )
  end

  defp by_key(occurrences) do
    Map.new(occurrences, &{{&1.occurrence_key, &1.reminder_rule_id}, &1})
  end

  describe "materialize/2 for yearly events" do
    test "a September birthday created in August plans this year and next" do
      assert {:ok, plan} = Planner.materialize(birthday(), ~U[2026-08-02 12:00:00Z])

      assert plan.next_occurrence_on == ~D[2026-09-14]
      assert plan.materialized_through_on == ~D[2027-09-14]

      assert Enum.map(plan.occurrences, &{&1.occurrence_key, &1.reminder_rule_id}) == [
               {"2026-09-14", "week_before"},
               {"2026-09-14", "day_of"},
               {"2027-09-14", "week_before"},
               {"2027-09-14", "day_of"}
             ]
    end

    test "the same birthday created after the date starts with next year" do
      assert {:ok, plan} = Planner.materialize(birthday(), ~U[2026-09-20 12:00:00Z])

      assert plan.next_occurrence_on == ~D[2027-09-14]
      assert plan.materialized_through_on == ~D[2028-09-14]

      assert Enum.map(plan.occurrences, & &1.occurrence_key) |> Enum.uniq() == [
               "2027-09-14",
               "2028-09-14"
             ]
    end

    test "on the day itself the current occurrence is still planned" do
      # 2026-09-14 08:00 local (12:00Z) — the 9am day-of reminder is still ahead.
      assert {:ok, plan} = Planner.materialize(birthday(), ~U[2026-09-14 12:00:00Z])

      assert plan.next_occurrence_on == ~D[2026-09-14]

      assert [{"2026-09-14", "day_of"} | _] =
               Enum.map(plan.occurrences, &{&1.occurrence_key, &1.reminder_rule_id})
    end

    test "resolves local 9am wall time to UTC through the event timezone" do
      assert {:ok, plan} = Planner.materialize(birthday(), ~U[2026-08-02 12:00:00Z])
      indexed = by_key(plan.occurrences)

      assert indexed[{"2026-09-14", "week_before"}].scheduled_for == ~U[2026-09-07 13:00:00Z]
      assert indexed[{"2026-09-14", "day_of"}].scheduled_for == ~U[2026-09-14 13:00:00Z]
    end

    test "an early rule is valid until the next rule is due and the day-of rule until end of local day" do
      assert {:ok, plan} = Planner.materialize(birthday(), ~U[2026-08-02 12:00:00Z])
      indexed = by_key(plan.occurrences)

      assert indexed[{"2026-09-14", "week_before"}].valid_until == ~U[2026-09-14 13:00:00Z]
      assert indexed[{"2026-09-14", "day_of"}].valid_until == ~U[2026-09-15 04:00:00Z]
    end

    test "every occurrence carries the resolved event boundary and a bounded payload" do
      assert {:ok, plan} = Planner.materialize(birthday(), ~U[2026-08-02 12:00:00Z])
      occurrence = hd(plan.occurrences)

      assert occurrence.event_occurrence_at == ~U[2026-09-14 04:00:00Z]

      assert occurrence.payload == %{
               "title" => "Sarah's birthday",
               "kind" => "birthday",
               "rule_id" => "week_before",
               "occurrence_key" => "2026-09-14",
               "event_local_date" => "2026-09-14",
               "event_local_time" => nil,
               "timezone" => @tz
             }
    end

    test "annual rollover uses local calendar arithmetic across a leap year" do
      event = birthday(%{recurrence_month: 3, recurrence_day: 1})

      assert {:ok, plan} = Planner.materialize(event, ~U[2027-06-01 12:00:00Z])

      assert plan.next_occurrence_on == ~D[2028-03-01]
      assert plan.materialized_through_on == ~D[2029-03-01]
    end

    test "february 29 requires an explicit leap-day policy" do
      event = birthday(%{recurrence_month: 2, recurrence_day: 29})

      assert {:error, :leap_day_policy_required} =
               Planner.materialize(event, ~U[2026-01-02 12:00:00Z])

      assert {:ok, feb} =
               Planner.materialize(
                 Map.put(event, :leap_day_policy, "feb_28"),
                 ~U[2026-01-02 12:00:00Z]
               )

      assert feb.next_occurrence_on == ~D[2026-02-28]
      assert feb.materialized_through_on == ~D[2027-02-28]

      assert {:ok, mar} =
               Planner.materialize(
                 Map.put(event, :leap_day_policy, "mar_1"),
                 ~U[2026-01-02 12:00:00Z]
               )

      assert mar.next_occurrence_on == ~D[2026-03-01]
    end

    test "a leap year keeps february 29 itself" do
      event = birthday(%{recurrence_month: 2, recurrence_day: 29, leap_day_policy: "feb_28"})

      assert {:ok, plan} = Planner.materialize(event, ~U[2028-01-02 12:00:00Z])
      assert plan.next_occurrence_on == ~D[2028-02-29]
      assert plan.materialized_through_on == ~D[2029-02-28]
    end
  end

  describe "materialize/2 for one-time events" do
    test "timed leads subtract an absolute duration from the resolved instant" do
      assert {:ok, plan} = Planner.materialize(appointment(), ~U[2026-08-02 12:00:00Z])

      assert plan.next_occurrence_on == ~D[2026-08-16]
      assert plan.materialized_through_on == ~D[2026-08-16]

      indexed = by_key(plan.occurrences)
      assert indexed[{"2026-08-16", "hours_24_before"}].scheduled_for == ~U[2026-08-15 19:00:00Z]
      assert indexed[{"2026-08-16", "hour_1_before"}].scheduled_for == ~U[2026-08-16 18:00:00Z]
    end

    test "the last pre-event rule is valid until the event begins" do
      assert {:ok, plan} = Planner.materialize(appointment(), ~U[2026-08-02 12:00:00Z])
      indexed = by_key(plan.occurrences)

      assert indexed[{"2026-08-16", "hours_24_before"}].valid_until == ~U[2026-08-16 18:00:00Z]
      assert indexed[{"2026-08-16", "hour_1_before"}].valid_until == ~U[2026-08-16 19:00:00Z]
    end

    test "an exact-time reminder at the event boundary stays valid for two hours" do
      {:ok, rules} = Defaults.plan_for("explicit_reminder", "datetime")

      event =
        appointment(%{
          kind: "explicit_reminder",
          title: "Submit the report",
          reminder_plan: rules
        })

      assert {:ok, plan} = Planner.materialize(event, ~U[2026-08-02 12:00:00Z])
      assert [occurrence] = plan.occurrences
      assert occurrence.scheduled_for == ~U[2026-08-16 19:00:00Z]
      assert occurrence.valid_until == ~U[2026-08-16 21:00:00Z]
    end

    test "past lead rules are skipped at creation" do
      # Three days before the appointment: the 24-hour lead is still ahead, the
      # 1-hour lead too, but a week-before rule would already have passed.
      rules = [
        %{rule_id: "week_before", kind: :days_before, days: 7, at: ~T[09:00:00]},
        %{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]}
      ]

      event = appointment(%{reminder_plan: rules})

      assert {:ok, plan} = Planner.materialize(event, ~U[2026-08-13 12:00:00Z])
      assert Enum.map(plan.occurrences, & &1.reminder_rule_id) == ["day_of"]
      assert plan.next_occurrence_on == ~D[2026-08-16]
    end

    test "an event whose rules have all passed still reports its occurrence horizon" do
      assert {:ok, plan} = Planner.materialize(appointment(), ~U[2026-08-16 18:30:00Z])
      assert plan.occurrences == []
      assert plan.next_occurrence_on == ~D[2026-08-16]
      assert plan.materialized_through_on == ~D[2026-08-16]
    end

    test "an explicitly empty plan materializes no reminders" do
      assert {:ok, plan} =
               Planner.materialize(appointment(%{reminder_plan: []}), ~U[2026-08-02 12:00:00Z])

      assert plan.occurrences == []
      assert plan.next_occurrence_on == ~D[2026-08-16]
    end

    test "a date-only one-time event plans date-only leads and ends with the local day" do
      {:ok, rules} = Defaults.plan_for("deadline", "date")

      event =
        appointment(%{
          kind: "deadline",
          title: "Tax filing",
          time_kind: "date",
          local_date: ~D[2026-08-16],
          local_time: nil,
          occurrence_at: nil,
          reminder_plan: rules
        })

      assert {:ok, plan} = Planner.materialize(event, ~U[2026-08-02 12:00:00Z])
      indexed = by_key(plan.occurrences)

      assert indexed[{"2026-08-16", "week_before"}].scheduled_for == ~U[2026-08-09 13:00:00Z]
      assert indexed[{"2026-08-16", "day_before"}].scheduled_for == ~U[2026-08-15 13:00:00Z]
      assert indexed[{"2026-08-16", "day_of"}].scheduled_for == ~U[2026-08-16 13:00:00Z]
      assert indexed[{"2026-08-16", "day_of"}].valid_until == ~U[2026-08-17 04:00:00Z]
    end
  end

  describe "DST correctness" do
    test "a nonexistent local datetime is refused with a tagged gap error" do
      assert {:error, {:dst_gap, @tz, ~D[2026-03-08], ~T[02:30:00]}} =
               Planner.resolve_local_datetime(~D[2026-03-08], ~T[02:30:00], @tz, nil)
    end

    test "an ambiguous local datetime is refused unless an offset picks one instant" do
      assert {:error, {:dst_ambiguous, ["-04:00", "-05:00"]}} =
               Planner.resolve_local_datetime(~D[2026-11-01], ~T[01:30:00], @tz, nil)

      assert {:ok, ~U[2026-11-01 05:30:00Z]} =
               Planner.resolve_local_datetime(~D[2026-11-01], ~T[01:30:00], @tz, "-04:00")

      assert {:ok, ~U[2026-11-01 06:30:00Z]} =
               Planner.resolve_local_datetime(~D[2026-11-01], ~T[01:30:00], @tz, "-05:00")

      assert {:error, {:dst_ambiguous, ["-04:00", "-05:00"]}} =
               Planner.resolve_local_datetime(~D[2026-11-01], ~T[01:30:00], @tz, "+02:00")
    end

    test "an unambiguous local datetime resolves to UTC" do
      assert {:ok, ~U[2026-08-16 19:00:00Z]} =
               Planner.resolve_local_datetime(~D[2026-08-16], ~T[15:00:00], @tz, nil)
    end

    test "an unknown timezone is refused" do
      assert {:error, {:invalid_timezone, "Mars/Olympus"}} =
               Planner.resolve_local_datetime(~D[2026-08-16], ~T[15:00:00], "Mars/Olympus", nil)
    end

    test "a custom reminder wall time inside a DST gap fails materialization" do
      rules = [%{rule_id: "gap_rule", kind: :days_before, days: 0, at: ~T[02:30:00]}]

      event =
        appointment(%{
          time_kind: "date",
          local_date: ~D[2026-03-08],
          local_time: nil,
          occurrence_at: nil,
          reminder_plan: rules
        })

      assert {:error, {:dst_gap, @tz, ~D[2026-03-08], ~T[02:30:00]}} =
               Planner.materialize(event, ~U[2026-02-01 12:00:00Z])
    end
  end

  describe "validation" do
    test "a duration rule requires a timed event" do
      rules = [%{rule_id: "hour_1_before", kind: :duration_before, seconds: 3_600}]

      assert {:error, {:rule_requires_datetime, "hour_1_before"}} =
               Planner.materialize(birthday(%{reminder_plan: rules}), ~U[2026-08-02 12:00:00Z])
    end

    test "an at-occurrence rule requires a timed event" do
      rules = [%{rule_id: "at_time", kind: :at_occurrence}]

      assert {:error, {:rule_requires_datetime, "at_time"}} =
               Planner.materialize(birthday(%{reminder_plan: rules}), ~U[2026-08-02 12:00:00Z])
    end

    test "two rules resolving to the same instant are refused" do
      rules = [
        %{rule_id: "a", kind: :days_before, days: 0, at: ~T[09:00:00]},
        %{rule_id: "b", kind: :days_before, days: 0, at: ~T[09:00:00]}
      ]

      assert {:error, {:invalid_rule_time, "a"}} =
               Planner.materialize(birthday(%{reminder_plan: rules}), ~U[2026-08-02 12:00:00Z])
    end

    test "a rule resolving past the validity boundary is refused" do
      rules = [%{rule_id: "too_late", kind: :days_before, days: -2, at: ~T[09:00:00]}]

      assert {:error, {:invalid_rule, _}} =
               Planner.materialize(birthday(%{reminder_plan: rules}), ~U[2026-08-02 12:00:00Z])
    end

    test "a yearly event requires month and day" do
      assert {:error, {:invalid_event, :recurrence_month}} =
               Planner.materialize(
                 birthday(%{recurrence_month: nil}),
                 ~U[2026-08-02 12:00:00Z]
               )
    end

    test "a one-time event requires a local date" do
      assert {:error, {:invalid_event, :local_date}} =
               Planner.materialize(appointment(%{local_date: nil}), ~U[2026-08-02 12:00:00Z])
    end

    test "a one-time datetime requires a resolved occurrence instant" do
      assert {:error, {:invalid_event, :occurrence_at}} =
               Planner.materialize(appointment(%{occurrence_at: nil}), ~U[2026-08-02 12:00:00Z])
    end

    test "an invalid timezone fails materialization" do
      assert {:error, {:invalid_timezone, "Mars/Olympus"}} =
               Planner.materialize(
                 birthday(%{timezone: "Mars/Olympus"}),
                 ~U[2026-08-02 12:00:00Z]
               )
    end

    test "a plan over the rule cap fails materialization" do
      rules =
        for index <- 1..11 do
          %{rule_id: "rule_#{index}", kind: :days_before, days: index, at: ~T[09:00:00]}
        end

      assert {:error, {:too_many_rules, 11}} =
               Planner.materialize(birthday(%{reminder_plan: rules}), ~U[2026-08-02 12:00:00Z])
    end
  end

  describe "event boundaries" do
    test "a timed event ends at its resolved instant" do
      assert {:ok, ~U[2026-08-16 19:00:00Z]} = Planner.event_boundary_at(appointment())
    end

    test "a date-only event ends at the start of the next local day" do
      event =
        appointment(%{time_kind: "date", local_time: nil, occurrence_at: nil})

      assert {:ok, ~U[2026-08-17 04:00:00Z]} = Planner.event_boundary_at(event)
    end

    test "a yearly event uses its cached next occurrence date" do
      event = birthday(%{next_occurrence_on: ~D[2026-09-14]})
      assert {:ok, ~U[2026-09-15 04:00:00Z]} = Planner.event_boundary_at(event)
    end

    test "the annual horizon is two occurrences" do
      assert Planner.annual_horizon() == 2
    end
  end
end
