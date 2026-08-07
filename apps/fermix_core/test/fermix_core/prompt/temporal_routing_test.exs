defmodule FermixCore.Prompt.TemporalRoutingTest do
  use ExUnit.Case, async: true

  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Tools.ScheduleJob

  # MILESTONE_30 §12.3: the prompt and the tool catalog move together. Changing
  # only one of them leaves the catalog contradicting the system prompt.

  describe "runtime prompt routing" do
    setup do
      %{contract: RuntimeSections.build([], capabilities: [])}
    end

    test "no longer routes reminders at schedule_job", %{contract: contract} do
      refute contract =~ "For reminders, recurring work"

      reminder_lines =
        contract
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "reminder"))

      assert reminder_lines != []
      refute Enum.any?(reminder_lines, &(&1 =~ "schedule_job"))
    end

    test "states the event/job boundary as its own block", %{contract: contract} do
      assert contract =~ "event_store"
      assert contract =~ "deterministic personal reminders"
      assert contract =~ "birthdays"
      assert contract =~ "reason, call a provider, use tools"
      assert contract =~ "Ask before storing ambiguous"
    end

    test "keeps the adjacent jobs delivery guidance intact", %{contract: contract} do
      assert contract =~ "delivery_mode"
      assert contract =~ "expires_at"
    end
  end

  describe "schedule_job catalog text" do
    test "no longer claims reminders" do
      refute ScheduleJob.description() =~ "reminder"
      refute ScheduleJob.when_to_use() =~ "reminder"
    end

    test "still owns recurring work, digests, watchers, and cron" do
      description = ScheduleJob.description()

      assert description =~ "cron"
      assert description =~ "digest"
      assert description =~ "watcher"
      assert ScheduleJob.when_to_use() =~ "recurring"
    end

    test "points deterministic personal dates at event_store" do
      assert ScheduleJob.description() =~ "event_store" or
               ScheduleJob.when_to_use() =~ "event_store"
    end
  end
end
