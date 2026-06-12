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
end
