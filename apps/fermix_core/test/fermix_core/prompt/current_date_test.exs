defmodule FermixCore.Prompt.CurrentDateTest do
  # Mutates :personalization in Application env, so it must not run concurrently
  # with other reads of that key.
  use ExUnit.Case, async: false

  alias FermixCore.Prompt.CurrentDate

  # 20:17 on Saturday in New York is already Sunday in UTC: the evening window
  # where a UTC "today" and an owner-zone "said on" disagree by a day.
  @evening_utc ~U[2026-10-25 00:17:00Z]

  setup do
    previous = Application.get_env(:fermix_core, :personalization)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :personalization)
        value -> Application.put_env(:fermix_core, :personalization, value)
      end
    end)

    :ok
  end

  test "note states the owner's local date, not the UTC date, in the evening window" do
    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    note = CurrentDate.note(@evening_utc)

    assert note =~ "Current date: Saturday, October 24, 2026"
    assert note =~ "(America/New_York, UTC-04:00)"
    refute note =~ "Sunday"
    refute note =~ "(UTC)"
  end

  test "note says every date and time shown is in the owner's zone" do
    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    assert CurrentDate.note(@evening_utc) =~
             "Every date and time Fermix shows you is in this zone"
  end

  test "note carries no clock time" do
    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    # Date-only on purpose: the note sits ahead of history in every request,
    # so a minute-level stamp would bust provider prompt caches every turn.
    # The zone's UTC offset is a label, not a time of day.
    for note <- [CurrentDate.note(@evening_utc), CurrentDate.note()] do
      refute note
             |> String.replace(~r/UTC[+-]\d{2}:\d{2}/, "")
             |> String.match?(~r/\d{1,2}:\d{2}/)
    end
  end

  test "with no zone configured the note states the UTC date and says why" do
    Application.put_env(:fermix_core, :personalization, [])

    note = CurrentDate.note(@evening_utc)

    assert note =~ "Current date: Sunday, October 25, 2026 (UTC)"
    assert note =~ "No time zone is configured"
  end

  test "with an unknown zone configured the note states the UTC date and names the zone" do
    Application.put_env(:fermix_core, :personalization, timezone: "Mars/Olympus_Mons")

    note = CurrentDate.note(@evening_utc)

    assert note =~ "Current date: Sunday, October 25, 2026 (UTC)"
    assert note =~ "Mars/Olympus_Mons"
  end
end
