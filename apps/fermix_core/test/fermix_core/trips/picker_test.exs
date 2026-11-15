defmodule FermixCore.Trips.PickerTest do
  # M89 D14: the one order the owner's trips are listed in, pure, with the
  # clock and the home's zone passed in. A trip happening now first; then
  # those to come, soonest first; then the undated, newest made first; then
  # the past, most recently ended first. "Now" and "past" are judged by the
  # trip's own days against today in its zone, else the home's. `past` is
  # true only on a past trip. Every title and id here is invented.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Picker

  @utc "Etc/UTC"
  # Midday in UTC, so no zone within twelve hours of it is on another date
  # than the one the edges below name.
  @now ~U[2027-06-20 12:00:00Z]

  defp trip(id, position, starts_on, days, timezone \\ nil) do
    %{
      id: id,
      title: "Trip #{id}",
      position: position,
      starts_on: starts_on,
      days: days,
      timezone: timezone,
      stops: 0,
      rev: 1
    }
  end

  defp ids(trips), do: Enum.map(trips, & &1.id)

  test "now, then to come soonest first, then undated newest made first, then past" do
    trips = [
      trip("tr_pastearly", 1024, ~D[2027-03-01], 3),
      trip("tr_undatedold", 2048, nil, 1),
      trip("tr_later", 3072, ~D[2027-09-10], 2),
      trip("tr_happening", 4096, ~D[2027-06-18], 5),
      trip("tr_pastlate", 5120, ~D[2027-06-10], 2),
      trip("tr_soon", 6144, ~D[2027-07-01], 4),
      trip("tr_undatednew", 7168, nil, 2)
    ]

    ordered = Picker.order(trips, @now, @utc)

    assert ids(ordered) == [
             "tr_happening",
             "tr_soon",
             "tr_later",
             "tr_undatednew",
             "tr_undatedold",
             "tr_pastlate",
             "tr_pastearly"
           ]

    assert for(%{id: id, past: true} <- ordered, do: id) == ["tr_pastlate", "tr_pastearly"]
    assert Enum.all?(ordered, &is_boolean(&1.past))
  end

  test "the edges: a last day today is now, yesterday past, a start tomorrow to come" do
    today_last = trip("tr_lasttoday", 1024, ~D[2027-06-18], 3)
    yesterday_last = trip("tr_lastyesterday", 2048, ~D[2027-06-18], 2)
    tomorrow = trip("tr_tomorrow", 3072, ~D[2027-06-21], 1)
    one_day_today = trip("tr_onlytoday", 4096, ~D[2027-06-20], 1)
    undated = trip("tr_undated", 5120, nil, 7)

    assert Picker.status(today_last, @now, @utc) == :now
    assert Picker.status(one_day_today, @now, @utc) == :now
    assert Picker.status(yesterday_last, @now, @utc) == :past
    assert Picker.status(tomorrow, @now, @utc) == :upcoming
    assert Picker.status(undated, @now, @utc) == :undated

    # An undated trip is never now and never past, whatever the clock says.
    for at <- [~U[1999-01-01 00:00:00Z], @now, ~U[2099-12-31 23:59:59Z]] do
      assert Picker.status(undated, at, @utc) == :undated
    end
  end

  test "today is the trip's own zone's when it names one, else the home's" do
    # 23:30 on 20 June in UTC is 11:30 on 21 June in Auckland (UTC+12 in June).
    late = ~U[2027-06-20 23:30:00Z]
    ends_20th = trip("tr_ends20", 1024, ~D[2027-06-19], 2)
    ends_20th_auckland = trip("tr_ends20nz", 2048, ~D[2027-06-19], 2, "Pacific/Auckland")
    ends_20th_utc = trip("tr_ends20utc", 3072, ~D[2027-06-19], 2, @utc)

    # The home in UTC: still the 20th for a trip with no zone, the 21st in its own.
    assert Picker.status(ends_20th, late, @utc) == :now
    assert Picker.status(ends_20th_auckland, late, @utc) == :past

    # The home in Auckland: the 21st for a trip with no zone, the 20th in UTC.
    assert Picker.status(ends_20th, late, "Pacific/Auckland") == :past
    assert Picker.status(ends_20th_utc, late, "Pacific/Auckland") == :now
  end

  test "a zone the database does not know is judged by the home's" do
    late = ~U[2027-06-20 23:30:00Z]
    unknown = trip("tr_nozone", 1024, ~D[2027-06-19], 2, "Mars/Olympus_Mons")

    assert Picker.status(unknown, late, @utc) == :now
    assert Picker.status(unknown, late, "Pacific/Auckland") == :past
  end

  test "ties go to the trip made first, and among the undated to the one made last" do
    trips = [
      trip("tr_b", 2048, ~D[2027-07-01], 2),
      trip("tr_a", 1024, ~D[2027-07-01], 3),
      trip("tr_c", 3072, ~D[2027-06-01], 2),
      trip("tr_d", 4096, ~D[2027-06-01], 1),
      trip("tr_e", 5120, nil, 1),
      trip("tr_f", 6144, nil, 1)
    ]

    # Ended on 2 June (tr_c) after 1 June (tr_d): the later end comes first.
    assert ids(Picker.order(trips, @now, @utc)) == ~w(tr_a tr_b tr_f tr_e tr_c tr_d)

    # The order is the input's whatever order the store read them in.
    assert Picker.order(Enum.reverse(trips), @now, @utc) == Picker.order(trips, @now, @utc)
  end

  test "the next change is the local midnight a trip starts or ends at, in its zone" do
    soon = trip("tr_soon", 1024, ~D[2027-06-23], 2)
    happening = trip("tr_happening", 2048, ~D[2027-06-19], 3)
    happening_nz = trip("tr_happeningnz", 3072, ~D[2027-06-19], 2, "Pacific/Auckland")
    past = trip("tr_past", 4096, ~D[2027-06-01], 2)
    undated = trip("tr_undated", 5120, nil, 1)

    # Its first day begins at midnight on the 23rd, home time.
    assert Picker.next_change([soon], @now, @utc) == ~U[2027-06-23 00:00:00Z]
    # It is over once the 22nd begins: midnight after its last day, the 21st.
    assert Picker.next_change([happening], @now, @utc) == ~U[2027-06-22 00:00:00Z]

    # Its last day is the 20th in Auckland: over at midnight there, 12:00 UTC
    # on the 20th, which is now, so its next change is due already.
    assert DateTime.compare(
             Picker.next_change([happening_nz], ~U[2027-06-20 11:00:00Z], @utc),
             ~U[2027-06-20 12:00:00Z]
           ) == :eq

    # The earliest of all of them, and none for a trip that will not change.
    assert Picker.next_change([soon, happening, past, undated], @now, @utc) ==
             ~U[2027-06-22 00:00:00Z]

    assert Picker.next_change([past, undated], @now, @utc) == nil
    assert Picker.next_change([], @now, @utc) == nil
  end

  # Santiago's clocks go from 00:00 to 01:00 on 5 Sep 2027, so that day has no
  # midnight: it begins when the gap ends, 01:00 local, 04:00 UTC.
  test "a day whose midnight a clock change skips begins when the gap ends" do
    trip = trip("tr_santiago", 1024, ~D[2027-09-05], 1, "America/Santiago")
    day_before = ~U[2027-09-04 12:00:00Z]

    assert {:gap, _before, _after} = DateTime.new(~D[2027-09-05], ~T[00:00:00], trip.timezone)
    assert Picker.next_change([trip], day_before, @utc) == ~U[2027-09-05 04:00:00Z]
    assert Picker.status(trip, ~U[2027-09-05 03:59:59Z], @utc) == :upcoming
    assert Picker.status(trip, ~U[2027-09-05 04:00:00Z], @utc) == :now
  end
end
