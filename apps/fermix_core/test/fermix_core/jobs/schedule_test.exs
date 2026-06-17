defmodule FermixCore.Jobs.ScheduleTest do
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Schedule

  describe "parse/2 cron timezone evaluation" do
    test "cron fields are matched against the job's local wall-clock, not UTC" do
      # 2026-06-15 00:00:00Z; America/New_York is EDT (UTC-4) in June.
      now = ~U[2026-06-15 00:00:00Z]

      {:ok, parsed} = Schedule.parse("0 9 * * *", timezone: "America/New_York", now: now)

      # 09:00 EDT == 13:00 UTC. The stored instant is UTC; matching is local.
      assert parsed.next_run_at == ~U[2026-06-15 13:00:00Z]
      assert parsed.kind == "cron"
      assert parsed.timezone == "America/New_York"
    end

    test "UTC cron is unaffected" do
      now = ~U[2026-06-15 00:00:00Z]
      {:ok, parsed} = Schedule.parse("0 9 * * *", timezone: "UTC", now: now)
      assert parsed.next_run_at == ~U[2026-06-15 09:00:00Z]
    end

    test "the same wall-clock cron shifts across the DST boundary" do
      # Winter: EST (UTC-5) -> 09:00 local == 14:00 UTC.
      {:ok, winter} =
        Schedule.parse("0 9 * * *", timezone: "America/New_York", now: ~U[2026-01-15 00:00:00Z])

      assert winter.next_run_at == ~U[2026-01-15 14:00:00Z]

      # Summer: EDT (UTC-4) -> 09:00 local == 13:00 UTC.
      {:ok, summer} =
        Schedule.parse("0 9 * * *", timezone: "America/New_York", now: ~U[2026-06-15 00:00:00Z])

      assert summer.next_run_at == ~U[2026-06-15 13:00:00Z]
    end

    test "an unknown timezone is rejected loudly" do
      assert {:error, {:invalid_timezone, "Mars/Olympus_Mons"}} =
               Schedule.parse("0 9 * * *",
                 timezone: "Mars/Olympus_Mons",
                 now: ~U[2026-06-15 00:00:00Z]
               )
    end
  end

  describe "parse/2 cron field grammar" do
    @midnight ~U[2026-06-15 00:00:00Z]

    test "a step over the whole field still parses" do
      assert {:ok, %{kind: "cron"}} = Schedule.parse("*/15 * * * *", now: @midnight)
    end

    test "a range matches the first value inside it" do
      # Mon 2026-06-15 00:00Z; "30 9-17 * * *" first fires at 09:30 UTC.
      {:ok, parsed} = Schedule.parse("30 9-17 * * *", now: @midnight)
      assert parsed.next_run_at == ~U[2026-06-15 09:30:00Z]
    end

    test "a list matches its earliest member" do
      # minutes 5,20,40 of hour 0 — earliest future after 00:00 is 00:05.
      {:ok, parsed} = Schedule.parse("5,20,40 0 * * *", now: @midnight)
      assert parsed.next_run_at == ~U[2026-06-15 00:05:00Z]
    end

    test "a stepped range only matches values on the step" do
      # hours 8-18 step 4 => 8,12,16; minute 0. First future is 08:00 UTC.
      {:ok, parsed} = Schedule.parse("0 8-18/4 * * *", now: @midnight)
      assert parsed.next_run_at == ~U[2026-06-15 08:00:00Z]

      # 10:00 is NOT on the 8/12/16 step, so a 10:xx now skips to 12:00.
      {:ok, later} = Schedule.parse("0 8-18/4 * * *", now: ~U[2026-06-15 10:30:00Z])
      assert later.next_run_at == ~U[2026-06-15 12:00:00Z]
    end

    test "a comma list of ranges and singletons composes" do
      # day-of-month 1,15-17; here at 2026-06-15 it should match the 15th.
      {:ok, parsed} = Schedule.parse("0 0 1,15-17 * *", now: @midnight)
      assert parsed.next_run_at == ~U[2026-06-16 00:00:00Z]
    end

    test "weekday 7 and 0 both mean Sunday" do
      # 2026-06-15 is a Monday; next Sunday 00:00Z is 2026-06-21.
      {:ok, with_seven} = Schedule.parse("0 0 * * 7", now: @midnight)
      {:ok, with_zero} = Schedule.parse("0 0 * * 0", now: @midnight)
      assert with_seven.next_run_at == ~U[2026-06-21 00:00:00Z]
      assert with_zero.next_run_at == with_seven.next_run_at
    end

    test "malformed cron fields are rejected" do
      for expr <- [
            "60 * * * *",
            "1- * * * *",
            "5-1 * * * *",
            "1,, * * * *",
            "1-99 * * * *",
            "*/0 * * * *",
            "abc * * * *",
            "0 0 * * 8"
          ] do
        assert {:error, {:invalid_schedule, ^expr}} = Schedule.parse(expr, now: @midnight),
               "expected #{expr} to be rejected"
      end
    end
  end
end
