defmodule FermixChannels.Companion.TripsTest do
  @moduledoc """
  M89 §06: what a companion connection sends of the owner's trips is the
  companion goldens, exactly: the index of a dated and an undated trip, a
  whole trip with its dates, its places, a leg past an unplaced stop and what
  a device's add made, the trip a create made, a removed trip with the rows
  removed from it, and the shared form, each built by `Companion.Trips` from
  what the store hands it. Pure.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Trips
  alias FermixCore.Trips.Render

  @server_fixtures Application.app_dir(
                     :fermix_core,
                     "priv/companion/fixtures/server_events.jsonl"
                   )
  @now ~U[2031-06-02 14:00:00.000000Z]

  # Every title, stop, place, address and id here is invented.
  @tower %{
    "name" => "Torre de Vale Escuro",
    "location" => %{"latitude" => 38.5412, "longitude" => -27.2105},
    "address" => "Rua da Torre 4, Varonne",
    "apple_place_id" => "I4B7D2E9A1C3F5",
    "source_url" => "https://maps.apple.com/place?place-id=I4B7D2E9A1C3F5",
    "categories" => ["Landmark"]
  }
  # Found by a search other than Apple's: no Apple id, no Apple link.
  @tavern %{
    "name" => "Tasca Pedra Negra",
    "location" => %{"latitude" => 38.544, "longitude" => -27.2071},
    "address" => "Largo do Peixe 2, Varonne",
    "canonical_url" => "https://pedranegra.example/"
  }
  @quay %{
    "name" => "Cais da Varonne",
    "location" => %{"latitude" => 38.5391, "longitude" => -27.215},
    "apple_place_id" => "I9K3M5N7P2Q4R6",
    "source_url" => "https://maps.apple.com/place?place-id=I9K3M5N7P2Q4R6"
  }

  test "the index is the golden's: a dated trip with its last day, an undated one, none" do
    entries = [
      Map.merge(varonne(), %{days: 2, stops: 4}),
      Map.merge(orvenne(), %{days: 1, stops: 0})
    ]

    assert Trips.index_payload("main", entries) == golden("trips", 0)
    assert Trips.index_payload("main", []) == golden("trips", 1)
  end

  test "a whole trip is the golden's, with what a device's add made" do
    snapshot = %{trip: varonne(), rows: varonne_rows(), removed_rows: []}
    made = %{"mac-61" => "ti_2k6n8q4s7w"}

    assert Trips.object_payload("main", snapshot, false, made) == golden("trip", 1)
  end

  test "the trip a create made is the golden's: one unnamed day, no start" do
    snapshot = %{trip: orvenne(), rows: [row(:day, "ti_8c4f2h6j0k", "")], removed_rows: []}
    made = %{"mac-60" => "tr_9t3k6w0p5h"}

    assert Trips.object_payload("main", snapshot, false, made) == golden("trip", 0)
  end

  test "a removed trip pulled with its removed rows is the golden's" do
    gone_at = ~U[2031-05-20 07:58:00.000000Z]

    trip = %{
      id: "tr_2b7n5r8c3j",
      title: "Spring in Salvé",
      rev: 6,
      starts_on: ~D[2031-04-11],
      timezone: nil,
      removed_at: ~U[2031-05-20 08:00:00.000000Z]
    }

    rows = [
      row(:day, "ti_1z3x5v7b9n", ""),
      row(:stop, "ti_4g6e8a2c0m", "Ferry to the island", %{time: "08:15"})
    ]

    removed = [
      row(:day, "ti_0r2y8e6v3g", "Hills", %{removed_at: gone_at}),
      row(:stop, "ti_7v2c9x4z1q", "Walk to the chapel", %{
        removed_at: gone_at,
        removed_with: "ti_0r2y8e6v3g"
      })
    ]

    snapshot = %{trip: trip, rows: rows, removed_rows: removed}
    assert Trips.object_payload("main", snapshot, true, %{}) == golden("trip", 2)

    # Pulled without them, the trip carries none, and says it was removed.
    plain = Trips.object_payload("main", snapshot, false, %{})["trip"]
    refute Map.has_key?(plain, "removed")
    assert plain["removed_at"] == "2031-05-20T08:00:00.000000Z"
  end

  test "the shared form is the engine's own, at the trip's rev" do
    shared = %{
      trip_id: "tr_4q8m2x7v1d",
      rev: 12,
      text: Render.share(varonne(), varonne_rows())
    }

    assert Trips.shared_payload("main", "mac-79", shared) == golden("trip_shared", 0)
  end

  test "the kind answers its own events, draws and window, and lets a swept trip go" do
    assert {Trips.index_event(), Trips.object_event(), Trips.id_field()} ==
             {"trips", "trip", "trip_id"}

    assert {Trips.drawn_kind(), Trips.block_type(), Trips.draws_key()} ==
             {:trips, "trips", :draws_trips}

    assert Trips.flush_message() == :trips_flush
    assert Trips.draws_message() == :trip_channel_draws
    assert Trips.gone?({:no_such_trip, "tr_4q8m2x7v1d"})
    refute Trips.gone?(:not_owner)
  end

  # --- the store's maps ---------------------------------------------------------------

  defp varonne do
    %{
      id: "tr_4q8m2x7v1d",
      title: "Varonne weekend",
      rev: 12,
      starts_on: ~D[2031-07-05],
      timezone: "Europe/Lisbon",
      removed_at: nil
    }
  end

  defp orvenne do
    %{
      id: "tr_9t3k6w0p5h",
      title: "Orvenne",
      rev: 1,
      starts_on: nil,
      timezone: nil,
      removed_at: nil
    }
  end

  defp varonne_rows do
    [
      row(:day, "ti_7h2k9m4p1c", "Old town"),
      row(:stop, "ti_5w7p0t4n6b", "Torre de Vale Escuro", %{
        time: "10:00",
        duration: 90,
        place: @tower
      }),
      row(:stop, "ti_2k6n8q4s7w", "Coffee by the walls"),
      row(:stop, "ti_3d8f1q6z2x", "Dinner at Pedra Negra", %{
        time: "20:00",
        fixed: true,
        note: "Table for two",
        place: @tavern
      }),
      row(:day, "ti_9a1b5c7d3e", "Harbour"),
      row(:stop, "ti_6m3p9r1t5y", "Boat to the lighthouse", %{
        time: "11:30",
        duration: 45,
        place: @quay
      })
    ]
  end

  defp row(kind, id, text, fields \\ %{}) do
    Map.merge(
      %{
        id: id,
        trip_id: "tr_4q8m2x7v1d",
        n: 1,
        kind: kind,
        text: text,
        note: nil,
        time: nil,
        duration: nil,
        fixed: false,
        timezone: nil,
        place: nil,
        position: 1_024,
        stamped: false,
        made_via: "mac",
        created_at: @now,
        updated_at: @now,
        removed_at: nil,
        removed_with: nil,
        dirty: nil
      },
      fields
    )
  end

  # The `n`th golden server frame of `type`, its payload as a builder makes it.
  defp golden(type, n) do
    @server_fixtures
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.at(n)
    |> Map.delete("type")
  end
end
