defmodule FermixCore.Trips.Wire do
  @moduledoc """
  A trip as the owner's devices draw it (M89 §06): the companion's `trip`
  object, pure, which the connection's push carries, and the `removed[]` a
  pull with the removed rows adds to it (`removed/1`). The 768 KiB guard
  measures the largest of them, the object with every removed row a pull
  would carry (`bytes/3`, with the wire's own encoder, C10).

  `trip_id`, `title`, `rev` and the rows in their order; `starts_on` and
  `timezone` only when the trip has them. A day is `row_id`, `kind`, its name
  only when named (C27), its `date` only when the trip has a start (the start
  plus its position, so no app adds days to a date) and its own `timezone`
  only when it names one. A stop is `row_id`, `kind`, `text`, and only what it
  has of `time`, `duration`, `fixed` (only when true), `note`, `leg_m` (the
  straight line in metres from the placed stop before it in its day, C7) and
  `place`. A removed row has no place among the days, so no `date` or
  `leg_m`, and carries its `removed_at`.
  """

  alias FermixCore.Trips.Ops

  @doc "The `trip` object for `trip` and its live rows, in their order."
  @spec trip(map(), [map()]) :: map()
  def trip(%{id: id, title: title, rev: rev} = trip, rows) when is_list(rows) do
    legs = Ops.legs(rows)

    %{"trip_id" => id, "title" => title, "rev" => rev, "rows" => wire_rows(trip, rows, legs)}
    |> put("starts_on", trip.starts_on && Date.to_iso8601(trip.starts_on))
    |> put("timezone", trip.timezone)
  end

  @doc "The `removed[]` a pull with the removed rows carries, in the order given."
  @spec removed([map()]) :: [map()]
  def removed(rows) when is_list(rows), do: Enum.map(rows, &removed_row/1)

  @doc """
  How many bytes the `trip` object is, with `removed_rows` as a pull with the
  removed rows carries them, as the wire's encoder writes it.
  """
  @spec bytes(map(), [map()], [map()]) :: non_neg_integer()
  def bytes(trip, rows, removed_rows)
      when is_map(trip) and is_list(rows) and is_list(removed_rows) do
    trip
    |> trip(rows)
    |> Map.put("removed", removed(removed_rows))
    |> Jason.encode!()
    |> byte_size()
  end

  defp wire_rows(trip, rows, legs) do
    rows
    |> Ops.days()
    |> Enum.flat_map(fn %{row: day, stops: stops, position: k} ->
      [day(day, Ops.day_date(trip.starts_on, k)) | Enum.map(stops, &stop(&1, legs))]
    end)
  end

  defp day(row, date) do
    %{"row_id" => row.id, "kind" => "day"}
    |> put("text", if(row.text != "", do: row.text))
    |> put("date", date && Date.to_iso8601(date))
    |> put("timezone", row.timezone)
  end

  defp stop(row, legs) do
    %{"row_id" => row.id, "kind" => "stop", "text" => row.text}
    |> put("time", row.time)
    |> put("duration", row.duration)
    |> put("fixed", if(row.fixed, do: true))
    |> put("note", row.note)
    |> put("leg_m", Map.get(legs, row.id))
    |> put("place", row.place)
  end

  defp removed_row(%{kind: :day, removed_at: %DateTime{} = at} = row) do
    %{"row_id" => row.id, "kind" => "day"}
    |> put("text", if(row.text != "", do: row.text))
    |> put("timezone", row.timezone)
    |> Map.put("removed_at", DateTime.to_iso8601(at))
  end

  defp removed_row(%{kind: :stop, removed_at: %DateTime{} = at} = row) do
    %{"row_id" => row.id, "kind" => "stop", "text" => row.text}
    |> put("time", row.time)
    |> put("duration", row.duration)
    |> put("fixed", if(row.fixed, do: true))
    |> put("note", row.note)
    |> put("place", row.place)
    |> Map.put("removed_at", DateTime.to_iso8601(at))
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
