defmodule FermixCore.Trips.PlacingTest do
  # M89 §04, R2#1: what a lookup's outcome does to the op that gave the place.
  # Pure: a call as `Trips.Shape` makes it, and outcomes as `Trips.Lookup`
  # answers them.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Placing
  alias FermixCore.Trips.Shape

  # Every name and point here is invented.
  @record %{
    name: "Cais Velho",
    location: %{latitude: 41.1408, longitude: -8.6142},
    address: "2 Rua Inventada, Varonne"
  }

  @not_placed [
    {:none, :not_found},
    {:none, :no_location},
    {:none, :rate_limited},
    {:none, :deadline},
    {:none, {:failed, "network: unreachable"}},
    {:none, {:no_backend, "auth_failed: missing Brave API key"}},
    {:offered, %{@record | name: "Harbour Rooms"}},
    # A record too large to keep is not placed either.
    {:placed, Map.put(@record, :apple_place_id, String.duplicate("I", 300))}
  ]

  defp shaped(op) do
    {:ok, call} = Shape.call(%{"trip" => "Varonne", "ops" => [op]})
    call
  end

  test "an edit's lookup that does not place keeps the stop's place; the rest still lands" do
    call = shaped(%{"op" => "edit", "n" => 4, "time" => "11:00", "place" => "Cais Velho"})

    for outcome <- @not_placed do
      assert {%{ops: [op]}, [{1, _outcome}]} = Placing.placed_call(call, [{1, outcome}])
      assert match?(%{place: :keep, time: "11:00"}, op), inspect({outcome, op})
    end
  end

  test "an add's lookup that does not place saves the stop without one" do
    call = shaped(%{"op" => "add", "text" => "Quay", "day" => 1, "place" => "Cais Velho"})

    for outcome <- @not_placed do
      assert {%{ops: [%{place: nil}]}, [{1, _outcome}]} =
               Placing.placed_call(call, [{1, outcome}])
    end
  end

  test "a placed record is what the stop keeps, on an add or an edit" do
    for op <- [
          %{"op" => "add", "text" => "Quay", "day" => 1, "place" => "Cais Velho"},
          %{"op" => "edit", "n" => 4, "place" => "Cais Velho"}
        ] do
      assert {%{ops: [%{place: %{"name" => "Cais Velho"}}]}, [{1, {:placed, _place}}]} =
               Placing.placed_call(shaped(op), [{1, {:placed, @record}}])
    end
  end
end
