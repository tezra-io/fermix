defmodule FermixCore.Trips.GeoTest do
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Geo

  # Invented spots, a short walk apart, and two cities a flight apart.
  @castle %{latitude: 38.7139, longitude: -9.1335}
  @cathedral %{latitude: 38.7097, longitude: -9.1325}
  @north %{latitude: 48.8566, longitude: 2.3522}
  @west %{latitude: 51.5074, longitude: -0.1278}

  describe "distance_m/2" do
    test "is the great-circle distance in whole metres" do
      assert Geo.distance_m(%{latitude: 0, longitude: 0}, %{latitude: 1, longitude: 0}) == 111_195

      assert Geo.distance_m(%{latitude: 0, longitude: 0}, %{latitude: 0, longitude: 90}) ==
               10_007_543

      assert Geo.distance_m(@north, @west) == 343_556
      assert Geo.distance_m(@castle, @cathedral) == 475
    end

    test "is zero for one point, the same both ways, and whole across the antimeridian" do
      assert Geo.distance_m(@castle, @castle) == 0
      assert Geo.distance_m(@castle, @cathedral) == Geo.distance_m(@cathedral, @castle)

      assert Geo.distance_m(%{latitude: 0, longitude: 179.5}, %{latitude: 0, longitude: -179.5}) ==
               111_195
    end

    test "holds at the antipode, where rounding can push the haversine past one" do
      assert Geo.distance_m(%{latitude: 0, longitude: 0}, %{latitude: 0, longitude: 180}) ==
               20_015_087

      assert Geo.distance_m(%{latitude: 90, longitude: 0}, %{latitude: -90, longitude: 0}) ==
               20_015_087
    end

    test "reads a place record's location, whatever else the map holds" do
      located = Map.put(@castle, :name, "Castle")
      assert Geo.distance_m(located, @cathedral) == 475
    end

    test "refuses a point that is not a latitude and a longitude in range" do
      assert_raise FunctionClauseError, fn ->
        Geo.distance_m(%{latitude: 91, longitude: 0}, @castle)
      end

      assert_raise FunctionClauseError, fn ->
        Geo.distance_m(@castle, %{latitude: 0, longitude: 180.5})
      end

      assert_raise FunctionClauseError, fn ->
        Geo.distance_m(%{"latitude" => 1, "longitude" => 2}, @castle)
      end

      assert_raise FunctionClauseError, fn ->
        Geo.distance_m(%{latitude: "38.7", longitude: -9.1}, @castle)
      end
    end
  end

  describe "centroid/1" do
    test "is nil for no points and the point itself for one" do
      assert Geo.centroid([]) == nil

      assert %{latitude: latitude, longitude: longitude} = Geo.centroid([@castle])
      assert_in_delta latitude, @castle.latitude, 1.0e-9
      assert_in_delta longitude, @castle.longitude, 1.0e-9
    end

    test "is the middle of the points, equally far from two" do
      middle = Geo.centroid([@castle, @cathedral])

      assert abs(Geo.distance_m(middle, @castle) - Geo.distance_m(middle, @cathedral)) <= 1
      assert Geo.distance_m(middle, @castle) in 237..238
    end

    test "is the middle across the antimeridian, not the other side of the world" do
      middle = Geo.centroid([%{latitude: 10, longitude: 179}, %{latitude: 10, longitude: -179}])

      assert_in_delta middle.latitude, 10.0, 0.01
      assert_in_delta abs(middle.longitude), 180.0, 1.0e-9
      assert Map.keys(middle) |> Enum.sort() == [:latitude, :longitude]
    end

    test "refuses a list holding something that is not a point" do
      assert_raise FunctionClauseError, fn -> Geo.centroid([@castle, %{latitude: 1}]) end
      assert_raise FunctionClauseError, fn -> Geo.centroid(@castle) end
    end
  end

  describe "spread_m/2" do
    test "is the largest distance from the point, and zero for no points" do
      assert Geo.spread_m(@castle, []) == 0
      assert Geo.spread_m(@castle, [@castle]) == 0
      assert Geo.spread_m(@castle, [@cathedral, @castle]) == 475

      assert Geo.spread_m(@north, [@castle, @west, @cathedral]) ==
               Geo.distance_m(@north, @cathedral)
    end

    test "refuses a point or a list that is not points" do
      # Through apply/3: a literal the type checker sees is a compile warning.
      assert_raise FunctionClauseError, fn ->
        apply(Geo, :spread_m, [%{latitude: 1}, [@castle]])
      end

      assert_raise FunctionClauseError, fn -> Geo.spread_m(@castle, [nil]) end
      assert_raise FunctionClauseError, fn -> Geo.spread_m(@castle, @cathedral) end
    end
  end
end
