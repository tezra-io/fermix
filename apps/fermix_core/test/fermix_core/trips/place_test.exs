defmodule FermixCore.Trips.PlaceTest do
  # M89 §05: a stop's place is the wire's `place` cut to what identifies it and
  # where it is, never a rating, a price, hours or a distance (`place_json`).
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Place

  # Every name, address and id here is invented.
  @record %{
    "name" => "Pell Café",
    "location" => %{"latitude" => 41.2031, "longitude" => -8.4102},
    "address" => "Rua das Ostras 12, Varonne",
    "apple_place_id" => "I3K9M2Q7",
    "source_url" => "https://maps.apple.com/place?place-id=I3K9M2Q7",
    "canonical_url" => "https://pellcafe.example/",
    "categories" => ["cafe", "bakery"]
  }

  describe "a device's record" do
    test "keeps its name, location and facts, and drops what is a moment's" do
      extra =
        Map.merge(@record, %{
          "rating" => %{"value" => 4.5},
          "price_range" => "$$",
          "opening_hours" => %{"current_day" => "8-18"},
          "distance" => %{"value" => 3, "units" => "km"}
        })

      assert Place.cut(extra) == {:ok, @record}
    end

    test "needs a name and a location in range" do
      assert Place.cut(Map.delete(@record, "name")) == {:error, {:invalid_place, :name}}
      assert Place.cut(%{@record | "name" => "  "}) == {:error, {:invalid_place, :name}}

      far = %{@record | "location" => %{"latitude" => 91, "longitude" => 0}}
      assert Place.cut(far) == {:error, {:invalid_place, :location}}
      assert Place.cut(Map.delete(@record, "location")) == {:error, {:invalid_place, :location}}
    end

    test "names over their bounds, a link that is not https and six categories are refused" do
      long = String.duplicate("é", 201)
      assert Place.cut(%{@record | "name" => long}) == {:error, {:invalid_place, :name}}

      address = String.duplicate("a", 301)
      assert Place.cut(%{@record | "address" => address}) == {:error, {:invalid_place, :address}}

      plain = %{@record | "source_url" => "http://maps.apple.com/place?place-id=I3K9M2Q7"}
      assert Place.cut(plain) == {:error, {:invalid_place, :source_url}}

      six = %{@record | "categories" => ~w(a b c d e f)}
      assert Place.cut(six) == {:error, {:invalid_place, :categories}}
    end

    test "control characters are taken out of its words" do
      assert {:ok, %{"name" => "Pell Café", "address" => "Rua das Ostras 12"}} =
               Place.cut(%{
                 @record
                 | "name" => "Pell\u0007 Café\n",
                   "address" => "Rua das Ostras 12"
               })
    end

    test "only what is given rides" do
      bare = Map.take(@record, ["name", "location"])
      assert Place.cut(bare) == {:ok, bare}
    end
  end

  describe "a search's record" do
    test "takes the place search's fields and cuts what is long" do
      record = %{
        name: String.duplicate("n", 250),
        location: %{latitude: 41.2031, longitude: -8.4102},
        address: String.duplicate("a", 350),
        apple_place_id: "I3K9M2Q7",
        source_url: "https://maps.apple.com/place?place-id=I3K9M2Q7",
        canonical_url: "http://pellcafe.example/",
        categories: ~w(a b c d e f g),
        rating: %{value: 4.5, best: 5}
      }

      assert {:ok, cut} = Place.from_search(record)
      assert String.length(cut["name"]) == 200
      assert String.length(cut["address"]) == 300
      assert cut["categories"] == ~w(a b c d e)
      assert cut["location"] == %{"latitude" => 41.2031, "longitude" => -8.4102}
      refute Map.has_key?(cut, "canonical_url")
      refute Map.has_key?(cut, "rating")
    end

    test "a search's record with no usable location is no place" do
      assert Place.from_search(%{name: "Pell Café", location: nil}) ==
               {:error, {:invalid_place, :location}}
    end
  end

  test "the point of a record, as the globe's arithmetic takes it" do
    assert Place.point(@record) == %{latitude: 41.2031, longitude: -8.4102}
    assert Place.point(nil) == nil
  end
end
