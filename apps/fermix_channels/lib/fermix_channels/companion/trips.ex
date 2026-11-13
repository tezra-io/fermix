defmodule FermixChannels.Companion.Trips do
  @moduledoc """
  The owner's trips as a kept kind on a companion connection (M89 §06, §07):
  the Registry calls a connection makes for them
  (`FermixCore.Trips.Registry.device_index/2`, `device_trip/4`,
  `device_edit/3`, and `device_share/3` for a share, which is neither a pull
  nor an edit), and the wire shapes of what it sends: `trips` (the index),
  `trip` (one whole trip) and `trip_shared` (its shared form). What a
  connection holds of them and owes is `Companion.Kept`, the same for every
  kind.

  A trip is the store's `trip` object (`FermixCore.Trips.Wire`) with what
  only a device's pull adds: `removed_at` on a trip that was itself removed,
  and with `removed?` the rows removed in the last 30 days, each with its
  `removed_at` and no `date` or `leg_m`, since it has no place among the
  days. An index entry's `ends_on` is its last day's date, from `starts_on`
  and `days`.
  """

  @behaviour FermixChannels.Companion.KeptKind

  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Registry, as: TripRegistry
  alias FermixCore.Trips.Wire

  @impl true
  def index(caller, opts), do: TripRegistry.device_index(caller, opts)

  @impl true
  def object(trip_id, removed?, caller, opts),
    do: TripRegistry.device_trip(trip_id, removed?, caller, opts)

  # The Registry names the trip by `trip_id`; a kept kind's edit by `id`.
  @impl true
  def edit(payload, caller, opts) do
    with {:ok, %{trip_id: id, made: made, duplicate: duplicate?}} <-
           TripRegistry.device_edit(payload, caller, opts),
         do: {:ok, %{id: id, made: made, duplicate: duplicate?}}
  end

  @doc "The trip `trip_id` names in its shared form, for a device's `trip_share`."
  @spec share(term(), atom() | nil, keyword()) ::
          {:ok, %{trip_id: String.t(), rev: non_neg_integer(), text: String.t()}}
          | {:error, term()}
  def share(trip_id, caller, opts) when is_binary(trip_id) and is_list(opts),
    do: TripRegistry.device_share(trip_id, caller, opts)

  @impl true
  def describe_error(reason), do: TripRegistry.describe_error(reason)

  # Swept away since it was pulled.
  @impl true
  def gone?(reason), do: match?({:no_such_trip, _id}, reason)

  @impl true
  def index_event, do: "trips"

  @impl true
  def object_event, do: "trip"

  @impl true
  def id_field, do: "trip_id"

  @impl true
  def flush_message, do: :trips_flush

  @impl true
  def drawn_kind, do: :trips

  @impl true
  def block_type, do: "trips"

  @impl true
  def draws_key, do: :draws_trips

  @impl true
  def draws_message, do: :trip_channel_draws

  # --- the wire's shapes --------------------------------------------------------------

  @doc "The `trips` payload: the index, in picker order."
  @impl true
  def index_payload(profile_id, trips) do
    %{"profile_id" => profile_id, "trips" => Enum.map(trips, &index_entry/1)}
  end

  defp index_entry(trip) do
    %{
      "trip_id" => trip.id,
      "title" => trip.title,
      "days" => trip.days,
      "stops" => trip.stops,
      "rev" => trip.rev
    }
    |> put_dates(trip.starts_on, trip.days)
  end

  # A trip keeps at least one day, so a trip with a start has a last day.
  defp put_dates(entry, nil, _days), do: entry

  defp put_dates(entry, %Date{} = starts_on, days) when is_integer(days) and days >= 1 do
    entry
    |> Map.put("starts_on", Date.to_iso8601(starts_on))
    |> Map.put("ends_on", Date.to_iso8601(Ops.day_date(starts_on, days)))
  end

  @doc """
  The `trip` payload: the whole trip in order, its removed rows when
  `removed?`, `removed_at` when the trip itself was removed, and `made` when a
  device's create, add or new day made something.
  """
  @impl true
  def object_payload(profile_id, %{trip: trip, rows: rows} = snapshot, removed?, made) do
    wire_trip =
      trip
      |> Wire.trip(rows)
      |> put_present("removed_at", stamp(trip.removed_at))
      |> put_removed(removed?, Map.get(snapshot, :removed_rows, []))

    %{"profile_id" => profile_id, "trip" => wire_trip}
    |> then(&if(made == %{}, do: &1, else: Map.put(&1, "made", made)))
  end

  @doc "The `trip_shared` payload answering the share `client_msg_id` names."
  @spec shared_payload(String.t(), String.t(), %{
          trip_id: String.t(),
          rev: non_neg_integer(),
          text: String.t()
        }) :: map()
  def shared_payload(profile_id, client_msg_id, %{trip_id: id, rev: rev, text: text})
      when is_binary(profile_id) and is_binary(client_msg_id) do
    %{
      "profile_id" => profile_id,
      "client_msg_id" => client_msg_id,
      "trip_id" => id,
      "rev" => rev,
      "text" => text
    }
  end

  defp put_removed(trip, false, _rows), do: trip
  defp put_removed(trip, true, rows), do: Map.put(trip, "removed", Enum.map(rows, &removed_row/1))

  # A removed row has no place among the days: no date, no leg.
  defp removed_row(%{kind: :day} = row) do
    %{"row_id" => row.id, "kind" => "day"}
    |> put_present("text", if(row.text != "", do: row.text))
    |> put_present("timezone", row.timezone)
    |> Map.put("removed_at", stamp(row.removed_at))
  end

  defp removed_row(%{kind: :stop} = row) do
    %{"row_id" => row.id, "kind" => "stop", "text" => row.text}
    |> put_present("time", row.time)
    |> put_present("duration", row.duration)
    |> put_present("fixed", if(row.fixed, do: true))
    |> put_present("note", row.note)
    |> put_present("place", row.place)
    |> Map.put("removed_at", stamp(row.removed_at))
  end

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
