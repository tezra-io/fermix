defmodule FermixCore.Trips.Picker do
  @moduledoc """
  The one order the owner's trips are listed in (M89 D14), pure: a device's
  index, the line naming them to the model and `trip_read`'s index all take
  it from here (`Trips.Registry`), and the trips' day-turn process sends the
  index again when the date alone moves it (`Trips.DayTurn`).

  A trip is **now** from its first day through its last (`starts_on` plus its
  day count, less one), **upcoming** before its first day and **past** after
  its last, judged against today in the trip's own time zone, or in the
  home's (`FermixCore.Clock.shown_zone/1`, which the caller passes) when it
  names none. A trip's zone is checked when it is written (`Trips.Shape`), so
  one the time zone database does not know can only be one a later database
  dropped. Such a trip is judged in the home's zone, and nothing here logs
  it: this module is pure. A trip with no start is **undated**: never now and
  never past.

  The order: the trips happening now, then those to come, both by first day,
  soonest first; then the undated, newest made first; then the past, most
  recently ended first. A tie goes to the trip made first (`position`, then
  `id`), and among the undated (newest first) to the higher `position`, then
  the lower `id`. Each entry comes back with `past`, true only on a trip that
  is over: the one status the owner's devices are told.
  """

  @type status :: :now | :upcoming | :undated | :past

  @typedoc "A live trip as the store's index reads it: what the order needs."
  @type trip :: %{
          required(:id) => String.t(),
          required(:position) => integer(),
          required(:starts_on) => Date.t() | nil,
          required(:days) => non_neg_integer(),
          optional(:timezone) => String.t() | nil,
          optional(atom()) => term()
        }

  @midnight ~T[00:00:00]

  @doc "`trips` in picker order at `now`, each with `past`."
  @spec order([trip()], DateTime.t(), String.t()) :: [map()]
  def order(trips, %DateTime{} = now, home_zone) when is_list(trips) and is_binary(home_zone) do
    trips
    |> Enum.map(&{&1, status(&1, now, home_zone)})
    |> Enum.sort_by(fn {trip, status} -> key(trip, status) end)
    |> Enum.map(fn {trip, status} -> Map.put(trip, :past, status == :past) end)
  end

  @doc "Whether `trip` is happening `now`, still to come, undated or over."
  @spec status(trip(), DateTime.t(), String.t()) :: status()
  def status(%{starts_on: nil}, %DateTime{}, home_zone) when is_binary(home_zone), do: :undated

  def status(%{starts_on: %Date{} = first} = trip, %DateTime{} = now, home_zone)
      when is_binary(home_zone) do
    today = now |> DateTime.shift_zone!(zone(trip, now, home_zone)) |> DateTime.to_date()

    cond do
      Date.compare(today, first) == :lt -> :upcoming
      Date.compare(today, last_day(trip)) == :gt -> :past
      true -> :now
    end
  end

  @doc """
  The first instant after `now` at which any of `trips` changes its status,
  in UTC: the local midnight its first day begins at (upcoming to now) or the
  one after its last day (now to past), in its zone; nil when none will.
  """
  @spec next_change([trip()], DateTime.t(), String.t()) :: DateTime.t() | nil
  def next_change(trips, %DateTime{} = now, home_zone)
      when is_list(trips) and is_binary(home_zone) do
    trips
    |> Enum.flat_map(&change_at(&1, now, home_zone))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp change_at(trip, now, home_zone) do
    case status(trip, now, home_zone) do
      :upcoming -> midnight(trip.starts_on, zone(trip, now, home_zone))
      :now -> midnight(Date.add(last_day(trip), 1), zone(trip, now, home_zone))
      _undated_or_past -> []
    end
  end

  # A day that begins in a gap (a zone whose clocks jump at midnight) begins
  # when the gap ends; one that begins twice, at the first.
  defp midnight(date, zone) do
    case DateTime.new(date, @midnight, zone) do
      {:ok, at} -> [DateTime.shift_zone!(at, "Etc/UTC")]
      {:gap, _before, at} -> [DateTime.shift_zone!(at, "Etc/UTC")]
      {:ambiguous, at, _later} -> [DateTime.shift_zone!(at, "Etc/UTC")]
      {:error, _reason} -> []
    end
  end

  # A trip keeps at least one day, so its last is its first plus its count
  # less one.
  defp last_day(%{starts_on: first, days: days}), do: Date.add(first, max(days, 1) - 1)

  # The trip's zone when it names one the database knows, else the home's.
  defp zone(trip, now, home_zone) do
    case Map.get(trip, :timezone) do
      zone when is_binary(zone) and zone != "" -> known(zone, now, home_zone)
      _none -> home_zone
    end
  end

  defp known(zone, now, home_zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, _local} -> zone
      {:error, _unknown} -> home_zone
    end
  end

  # One shape of key for every group, so the tuples compare element by
  # element (a tuple's size comes first in the term order).
  defp key(trip, :now), do: {0, Date.to_gregorian_days(trip.starts_on), trip.position, trip.id}

  defp key(trip, :upcoming),
    do: {1, Date.to_gregorian_days(trip.starts_on), trip.position, trip.id}

  defp key(trip, :undated), do: {2, 0, -trip.position, trip.id}

  defp key(trip, :past),
    do: {3, -Date.to_gregorian_days(last_day(trip)), trip.position, trip.id}
end
