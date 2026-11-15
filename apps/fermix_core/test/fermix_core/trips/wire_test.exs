defmodule FermixCore.Trips.WireTest do
  # M89 §06: the companion's `trip` object, pure: a day carries its date only
  # with a start and its name only when named, and its town once the near in
  # force is found; a stop carries only what it has, `fixed` only when true,
  # and `leg_m` from the placed stop before it.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Geo
  alias FermixCore.Trips.Place
  alias FermixCore.Trips.Wire

  # Every title, stop, place and id here is invented.
  @at ~U[2031-06-02 14:00:00Z]
  @inn %{"name" => "Marisco Inn", "location" => %{"latitude" => 41.2031, "longitude" => -8.4102}}
  @mill %{
    "name" => "Old Mill",
    "location" => %{"latitude" => 41.2075, "longitude" => -8.4021},
    "apple_place_id" => "I3K9M2Q7"
  }

  defp trip(fields) do
    Map.merge(
      %{
        id: "tr_4q8m2x7v1d",
        title: "Varonne",
        rev: 12,
        starts_on: ~D[2031-12-31],
        timezone: "Europe/Lisbon",
        position: 1_024,
        next_n: 9,
        created_at: @at,
        updated_at: @at,
        removed_at: nil,
        near: nil
      },
      fields
    )
  end

  defp row(id, n, kind, position, fields) do
    Map.merge(
      %{
        id: id,
        trip_id: "tr_4q8m2x7v1d",
        n: n,
        kind: kind,
        text: "",
        note: nil,
        time: nil,
        duration: nil,
        fixed: false,
        timezone: nil,
        place: nil,
        position: position,
        stamped: false,
        made_via: "chat",
        created_at: @at,
        updated_at: @at,
        removed_at: nil,
        removed_with: nil,
        near: nil,
        dirty: nil
      },
      fields
    )
  end

  defp rows do
    [
      row("ti_7h2k9m4p1c", 1, :day, 1_024, %{text: "Harbour"}),
      row("ti_0r2y8e6v3g", 2, :stop, 2_048, %{
        text: "Breakfast at the inn",
        time: "08:30",
        duration: 45,
        place: @inn
      }),
      row("ti_9a1b3c5d7e", 3, :stop, 3_072, %{text: "Picnic", note: "Bring the blanket"}),
      row("ti_5w7p0t4n6b", 4, :stop, 4_096, %{
        text: "Mill tour",
        fixed: true,
        place: @mill
      }),
      row("ti_3d8f1q6z2x", 5, :day, 5_120, %{timezone: "Atlantic/Azores"}),
      row("ti_8k2m4n6p8q", 6, :stop, 6_144, %{text: "Ferry", fixed: false, place: @mill})
    ]
  end

  test "the trip object names the trip and draws every row in order" do
    point = fn record -> Place.point(record) end
    leg = Geo.distance_m(point.(@inn), point.(@mill))

    assert Wire.trip(trip(%{}), rows(), %{}) == %{
             "trip_id" => "tr_4q8m2x7v1d",
             "title" => "Varonne",
             "rev" => 12,
             "starts_on" => "2031-12-31",
             "timezone" => "Europe/Lisbon",
             "rows" => [
               %{
                 "row_id" => "ti_7h2k9m4p1c",
                 "kind" => "day",
                 "text" => "Harbour",
                 "date" => "2031-12-31"
               },
               %{
                 "row_id" => "ti_0r2y8e6v3g",
                 "kind" => "stop",
                 "text" => "Breakfast at the inn",
                 "time" => "08:30",
                 "duration" => 45,
                 "place" => @inn
               },
               %{
                 "row_id" => "ti_9a1b3c5d7e",
                 "kind" => "stop",
                 "text" => "Picnic",
                 "note" => "Bring the blanket"
               },
               %{
                 "row_id" => "ti_5w7p0t4n6b",
                 "kind" => "stop",
                 "text" => "Mill tour",
                 "fixed" => true,
                 "leg_m" => leg,
                 "place" => @mill
               },
               %{
                 "row_id" => "ti_3d8f1q6z2x",
                 "kind" => "day",
                 "date" => "2032-01-01",
                 "timezone" => "Atlantic/Azores"
               },
               %{
                 "row_id" => "ti_8k2m4n6p8q",
                 "kind" => "stop",
                 "text" => "Ferry",
                 "place" => @mill
               }
             ]
           }
  end

  test "an undated trip with no zone carries neither, and no day a date" do
    object = Wire.trip(trip(%{starts_on: nil, timezone: nil}), rows(), %{})

    refute Map.has_key?(object, "starts_on")
    refute Map.has_key?(object, "timezone")
    assert Enum.all?(object["rows"], &(not Map.has_key?(&1, "date")))
  end

  # A removed row has no place among the days: no date and no leg.
  test "removed rows as a pull with them carries them, each with its removed_at" do
    gone = ~U[2031-06-03 09:15:00.000000Z]
    [day, stop | _rest] = rows()
    removed = [%{day | removed_at: gone}, %{stop | removed_at: gone, removed_with: day.id}]

    assert Wire.removed(removed) == [
             %{
               "row_id" => "ti_7h2k9m4p1c",
               "kind" => "day",
               "text" => "Harbour",
               "removed_at" => "2031-06-03T09:15:00.000000Z"
             },
             %{
               "row_id" => "ti_0r2y8e6v3g",
               "kind" => "stop",
               "text" => "Breakfast at the inn",
               "time" => "08:30",
               "duration" => 45,
               "place" => @inn,
               "removed_at" => "2031-06-03T09:15:00.000000Z"
             }
           ]
  end

  # M89: the town in force for the day, the day's own near if it has one,
  # else the trip's; a day whose own near has no town shows none, never the
  # trip's; a stop never carries one.
  @varonne %{
    name: "Varonne, Ostrel, Varonia",
    latitude: 41.2031,
    longitude: -8.4102,
    radius_meters: 5_210
  }
  @brisa %{name: "Brisa, Ostrel, Varonia", latitude: 41.3, longitude: -8.7, radius_meters: 3_100}

  test "a day carries the town in force once it is found, and only a day" do
    rows = [
      row("ti_7h2k9m4p1c", 1, :day, 1_024, %{}),
      row("ti_0r2y8e6v3g", 2, :stop, 2_048, %{text: "Breakfast", place: @inn}),
      row("ti_3d8f1q6z2x", 3, :day, 3_072, %{near: "Brisa"}),
      row("ti_9a1b3c5d7e", 4, :day, 4_096, %{near: "Kestrin"}),
      row("ti_5w7p0t4n6b", 5, :day, 5_120, %{near: "Varonne"})
    ]

    towns = %{"Varonne" => @varonne, "Brisa" => @brisa}
    object = Wire.trip(trip(%{near: "Varonne"}), rows, towns)
    by_id = Map.new(object["rows"], &{&1["row_id"], &1})

    wire_town = fn town ->
      %{
        "name" => town.name,
        "latitude" => town.latitude,
        "longitude" => town.longitude,
        "radius_meters" => town.radius_meters
      }
    end

    assert by_id["ti_7h2k9m4p1c"]["town"] == wire_town.(@varonne)
    assert by_id["ti_3d8f1q6z2x"]["town"] == wire_town.(@brisa)
    refute Map.has_key?(by_id["ti_9a1b3c5d7e"], "town")
    assert by_id["ti_5w7p0t4n6b"]["town"] == wire_town.(@varonne)
    refute Map.has_key?(by_id["ti_0r2y8e6v3g"], "town")

    # No near in force, or one not found: no town.
    refute Enum.any?(Wire.trip(trip(%{}), rows, %{})["rows"], &Map.has_key?(&1, "town"))
  end

  test "the most a day's town adds to the wire is what the guard reserves for it" do
    widest = %{
      name: String.duplicate("\"", 120),
      latitude: -1.2345678901234567e-5,
      longitude: -179.12345678901234,
      radius_meters: 20_037_509
    }

    rows = [row("ti_7h2k9m4p1c", 1, :day, 1_024, %{})]
    bare = byte_size(Jason.encode!(Wire.trip(trip(%{near: "W"}), rows, %{})))
    with_town = byte_size(Jason.encode!(Wire.trip(trip(%{near: "W"}), rows, %{"W" => widest})))

    assert with_town - bare <= Wire.town_bytes()
  end

  test "the bytes the guard measures are the largest pull's, as the encoder writes them" do
    gone = ~U[2031-06-03 09:15:00.000000Z]
    removed = for row <- Enum.take(rows(), 2), do: %{row | removed_at: gone}
    object = Wire.trip(trip(%{}), rows(), %{})

    assert Wire.bytes(trip(%{}), rows(), []) ==
             byte_size(Jason.encode!(Map.put(object, "removed", [])))

    assert Wire.bytes(trip(%{}), rows(), removed) ==
             byte_size(Jason.encode!(Map.put(object, "removed", Wire.removed(removed))))
  end
end
