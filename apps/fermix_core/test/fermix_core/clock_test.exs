defmodule FermixCore.ClockTest do
  # Every case passes `:personalization` in opts, so no application env is read
  # or written and the cases can run concurrently.
  use ExUnit.Case, async: true

  alias FermixCore.Clock

  @new_york [personalization: [timezone: "America/New_York"]]
  @unset [personalization: []]
  @unknown [personalization: [timezone: "Mars/Olympus_Mons"]]

  # 20:17 EDT on Saturday is 00:17 UTC on Sunday.
  @evening_utc ~U[2026-10-25 00:17:42Z]

  describe "zone/1" do
    test "returns the configured zone" do
      assert Clock.zone(@new_york) == {:ok, "America/New_York"}
    end

    test "refuses when no zone is configured" do
      assert Clock.zone(@unset) == {:error, :timezone_not_configured}
      assert Clock.zone(personalization: [timezone: ""]) == {:error, :timezone_not_configured}
    end

    test "refuses a name the time zone database does not know" do
      assert Clock.zone(@unknown) == {:error, {:invalid_timezone, "Mars/Olympus_Mons"}}
    end
  end

  describe "display_zone/1 and shown_zone/1" do
    test "show the owner's zone when it is usable" do
      assert Clock.display_zone(@new_york) == {:ok, "America/New_York"}
      assert Clock.shown_zone(@new_york) == "America/New_York"
    end

    test "show UTC and say why when the zone is missing or unknown" do
      assert Clock.display_zone(@unset) == {:utc, :timezone_not_configured}
      assert Clock.shown_zone(@unset) == "Etc/UTC"

      assert Clock.display_zone(@unknown) == {:utc, {:invalid_timezone, "Mars/Olympus_Mons"}}
      assert Clock.shown_zone(@unknown) == "Etc/UTC"
    end
  end

  describe "stating an instant in the owner's zone" do
    test "the day is the owner's local day, not the UTC day" do
      assert Clock.stated_day(@evening_utc, @new_york) == "Saturday, October 24, 2026"
      assert Clock.stated_day(@evening_utc, @unset) == "Sunday, October 25, 2026"
    end

    test "the instant carries the local time and the zone abbreviation" do
      assert Clock.stated_instant(@evening_utc, @new_york) ==
               "Saturday, October 24, 2026 at 8:17 PM EDT"

      assert Clock.stated_time(@evening_utc, @new_york) == "8:17 PM EDT"
    end

    test "standard time after the fall change carries its own abbreviation" do
      assert Clock.stated_instant(~U[2026-11-02 01:05:00Z], @new_york) ==
               "Sunday, November 1, 2026 at 8:05 PM EST"
    end

    test "ISO 8601 carries the owner's offset instead of Z" do
      assert Clock.iso(@evening_utc, @new_york) == "2026-10-24T20:17:42-04:00"
      assert Clock.iso(@evening_utc, @unset) == "2026-10-25T00:17:42Z"
    end

    test "the UTC offset is the owner's at that instant" do
      assert Clock.utc_offset(@evening_utc, @new_york) == "UTC-04:00"
      assert Clock.utc_offset(~U[2026-11-02 01:05:00Z], @new_york) == "UTC-05:00"

      assert Clock.utc_offset(@evening_utc, personalization: [timezone: "Asia/Kolkata"]) ==
               "UTC+05:30"

      assert Clock.utc_offset(@evening_utc, @unset) == "UTC+00:00"
    end

    test "the now line states the instant to the minute" do
      assert Clock.now_line(@evening_utc, @new_york) ==
               "Now: Saturday, October 24, 2026 at 8:17 PM EDT."
    end
  end

  describe "validate_zone/1" do
    test "accepts a known zone and refuses anything else" do
      assert Clock.validate_zone("Europe/London") == {:ok, "Europe/London"}
      assert Clock.validate_zone("Nowhere/Town") == {:error, {:invalid_timezone, "Nowhere/Town"}}
      assert Clock.validate_zone(nil) == {:error, {:invalid_timezone, nil}}
    end
  end
end
