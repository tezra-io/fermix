defmodule FermixCore.Temporal.DefaultsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Temporal.Defaults

  describe "plan_for/2" do
    test "birthdays and anniversaries get week-before plus day-of at 9am local" do
      for kind <- ["birthday", "anniversary"] do
        assert {:ok, rules} = Defaults.plan_for(kind, "date")

        assert [
                 %{rule_id: "week_before", kind: :days_before, days: 7, at: ~T[09:00:00]},
                 %{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]}
               ] = rules
      end
    end

    test "timed appointments and events get 24-hour and 1-hour absolute leads" do
      for kind <- ["appointment", "event", "deadline"] do
        assert {:ok, rules} = Defaults.plan_for(kind, "datetime")

        assert [
                 %{rule_id: "hours_24_before", kind: :duration_before, seconds: 86_400},
                 %{rule_id: "hour_1_before", kind: :duration_before, seconds: 3_600}
               ] = rules
      end
    end

    test "date-only deadlines and generic events get three date-only leads" do
      assert {:ok, rules} = Defaults.plan_for("deadline", "date")
      assert Enum.map(rules, & &1.rule_id) == ["week_before", "day_before", "day_of"]
      assert Enum.all?(rules, &(&1.kind == :days_before))
      assert Enum.map(rules, & &1.days) == [7, 1, 0]
    end

    test "follow-ups and explicit reminders fire once at the stored time" do
      for kind <- ["follow_up", "explicit_reminder"] do
        assert {:ok, [%{rule_id: "at_time", kind: :at_occurrence}]} =
                 Defaults.plan_for(kind, "datetime")
      end
    end

    test "date-only explicit reminders fire once on the morning of the day" do
      assert {:ok, [%{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]}]} =
               Defaults.plan_for("explicit_reminder", "date")
    end

    test "a timed birthday has no default plan and says so" do
      assert {:error, {:no_default_plan, "birthday", "datetime"}} =
               Defaults.plan_for("birthday", "datetime")
    end

    test "an unknown kind has no default plan" do
      assert {:error, {:no_default_plan, "wedding", "date"}} =
               Defaults.plan_for("wedding", "date")
    end

    test "every default plan is within the caps and has unique stable rule ids" do
      shapes = [
        {"birthday", "date"},
        {"anniversary", "date"},
        {"appointment", "datetime"},
        {"event", "datetime"},
        {"deadline", "datetime"},
        {"appointment", "date"},
        {"deadline", "date"},
        {"event", "date"},
        {"follow_up", "datetime"},
        {"explicit_reminder", "datetime"},
        {"follow_up", "date"},
        {"explicit_reminder", "date"}
      ]

      for {kind, time_kind} <- shapes do
        assert {:ok, rules} = Defaults.plan_for(kind, time_kind)
        assert {:ok, ^rules} = Defaults.validate_plan(rules)
        ids = Enum.map(rules, & &1.rule_id)
        assert ids == Enum.uniq(ids)
      end
    end
  end

  describe "validate_plan/2" do
    test "rejects more than ten rules" do
      rules =
        for index <- 1..11 do
          %{rule_id: "rule_#{index}", kind: :days_before, days: index, at: ~T[09:00:00]}
        end

      assert Defaults.max_rules() == 10
      assert {:error, {:too_many_rules, 11}} = Defaults.validate_plan(rules)
    end

    test "rejects duplicate rule ids" do
      rules = [
        %{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]},
        %{rule_id: "day_of", kind: :days_before, days: 1, at: ~T[09:00:00]}
      ]

      assert {:error, {:duplicate_rule_id, "day_of"}} = Defaults.validate_plan(rules)
    end

    test "rejects an empty plan unless the caller explicitly allows it" do
      assert {:error, :empty_plan_not_allowed} = Defaults.validate_plan([])
      assert {:ok, []} = Defaults.validate_plan([], allow_empty: true)
    end

    test "rejects malformed rules" do
      assert {:error, {:invalid_rule, _}} =
               Defaults.validate_plan([%{rule_id: "x", kind: :days_before}])

      assert {:error, {:invalid_rule, _}} =
               Defaults.validate_plan([%{rule_id: "", kind: :at_occurrence}])

      assert {:error, {:invalid_rule, _}} =
               Defaults.validate_plan([%{rule_id: "x", kind: :duration_before, seconds: 0}])

      assert {:error, {:invalid_rule, _}} =
               Defaults.validate_plan([%{rule_id: "x", kind: :later}])
    end
  end

  describe "encode_plan/1 and decode_plan/1" do
    test "round-trips every rule kind through JSON-safe maps" do
      rules = [
        %{rule_id: "week_before", kind: :days_before, days: 7, at: ~T[09:00:00]},
        %{rule_id: "hours_24_before", kind: :duration_before, seconds: 86_400},
        %{rule_id: "at_time", kind: :at_occurrence}
      ]

      encoded = Defaults.encode_plan(rules)

      assert encoded == [
               %{
                 "rule_id" => "week_before",
                 "kind" => "days_before",
                 "days" => 7,
                 "at" => "09:00:00"
               },
               %{
                 "rule_id" => "hours_24_before",
                 "kind" => "duration_before",
                 "seconds" => 86_400
               },
               %{"rule_id" => "at_time", "kind" => "at_occurrence"}
             ]

      assert encoded == encoded |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^rules} = Defaults.decode_plan(encoded)
    end

    test "decode rejects unknown rule shapes rather than guessing" do
      assert {:error, {:invalid_rule, _}} = Defaults.decode_plan([%{"rule_id" => "x"}])
      assert {:error, {:invalid_rule, _}} = Defaults.decode_plan([%{"kind" => "days_before"}])
      assert {:error, :invalid_plan} = Defaults.decode_plan(%{"rule_id" => "x"})
    end
  end
end
