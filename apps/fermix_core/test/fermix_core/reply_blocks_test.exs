defmodule FermixCore.ReplyBlocksTest do
  use ExUnit.Case, async: true

  alias FermixCore.ReplyBlocks
  alias FermixTestSupport.WireSchema

  @schema_path Application.app_dir(:fermix_core, "priv/companion/protocol.schema.json")
  @chat {"companion", "main", :root}
  @other {"telegram", "42", :root}
  @minute_ms 60_000

  # A place as `PlaceSearch.Brave` normalizes it (M31 §10.2), every field set.
  defp record(n, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Cafe #{n}",
        canonical_url: "https://cafe#{n}.example/",
        source_url: "https://search.brave.com/local/place/#{n}",
        description: "A quiet room with long tables.",
        location: %{latitude: 40.7233, longitude: -74.003},
        address: "#{n} Example St, New York",
        opening_hours: %{current_day: "Thursday 07:00-19:00", days: ["Friday 07:00-19:00"]},
        contact: %{telephone: "+1 555 0100", email: "hi@cafe.example"},
        rating: %{value: 4.6, best: 5, count: 321},
        price_range: "$$",
        distance: %{value: 0.4, units: "km"},
        categories: ["coffee_shop"],
        cuisines: ["coffee"],
        media: [
          %{
            kind: "thumbnail",
            url: "https://imgs.example/#{n}.jpg",
            source_url: "https://search.brave.com/local/place/#{n}"
          }
        ]
      },
      overrides
    )
  end

  defp holder(now \\ 0) do
    clock = start_supervised!({Agent, fn -> now end})
    server = start_supervised!({ReplyBlocks, name: nil, clock: fn -> Agent.get(clock, & &1) end})
    {server, clock}
  end

  defp advance_to(clock, ms), do: Agent.update(clock, fn _now -> ms end)

  defp names([%{"type" => "places", "places" => places}]), do: Enum.map(places, & &1["name"])
  defp names([]), do: []

  describe "the holder" do
    test "keeps a conversation's places in order and forgets them once taken" do
      {server, _clock} = holder()

      :ok = ReplyBlocks.put_places(server, @chat, [record(1), record(2)])
      :ok = ReplyBlocks.put_places(server, @chat, [record(3)])
      :ok = ReplyBlocks.put_places(server, @other, [record(9)])

      assert Enum.map(ReplyBlocks.take(server, @chat), & &1.name) == [
               "Cafe 1",
               "Cafe 2",
               "Cafe 3"
             ]

      assert ReplyBlocks.take(server, @chat) == []
      assert [%{name: "Cafe 9"}] = ReplyBlocks.take(server, @other)
    end

    test "a conversation keeps its newest records, never more than the bound" do
      {server, _clock} = holder()
      bound = ReplyBlocks.max_records()

      :ok = ReplyBlocks.put_places(server, @chat, Enum.map(1..(bound - 5), &record/1))
      :ok = ReplyBlocks.put_places(server, @chat, Enum.map((bound - 4)..(bound + 7), &record/1))

      taken = ReplyBlocks.take(server, @chat)
      assert length(taken) == bound
      assert hd(taken).name == "Cafe 8"
      assert List.last(taken).name == "Cafe #{bound + 7}"
    end

    test "a record expires once the window has passed since it was put" do
      {server, clock} = holder(1_000)
      window = ReplyBlocks.ttl_ms()

      :ok = ReplyBlocks.put_places(server, @chat, [record(1)])
      advance_to(clock, 1_000 + @minute_ms)
      :ok = ReplyBlocks.put_places(server, @chat, [record(2)])

      advance_to(clock, 1_000 + window - 1)
      assert [%{name: "Cafe 1"}, %{name: "Cafe 2"}] = ReplyBlocks.take(server, @chat)

      :ok = ReplyBlocks.put_places(server, @chat, [record(3)])
      advance_to(clock, 1_000 + 2 * window - 1)
      assert ReplyBlocks.take(server, @chat) == []
    end

    test "a conversation that never takes holds nothing past the window" do
      {server, clock} = holder()

      :ok = ReplyBlocks.put_places(server, @other, [record(1)])
      advance_to(clock, ReplyBlocks.ttl_ms())
      :ok = ReplyBlocks.put_places(server, @chat, [record(2)])

      assert Map.keys(:sys.get_state(server).conversations) == [@chat]
    end
  end

  describe "building a reply's block" do
    test "keeps the places the text links, as the wire carries them" do
      text =
        "Two quiet ones: **[Cafe 1](https://cafe1.example/)** has long tables, and " <>
          "Cafe 2 (https://search.brave.com/local/place/2) opens early."

      assert [%{"type" => "places", "places" => [first, second]}] =
               ReplyBlocks.build(text, [record(1), record(2), record(3)])

      assert first == %{
               "name" => "Cafe 1",
               "canonical_url" => "https://cafe1.example/",
               "source_url" => "https://search.brave.com/local/place/1",
               "location" => %{"latitude" => 40.7233, "longitude" => -74.003},
               "address" => "1 Example St, New York",
               "rating" => %{"value" => 4.6, "best" => 5, "count" => 321},
               "price_range" => "$$",
               "categories" => ["coffee_shop"],
               "opening_hours" => %{"current_day" => "Thursday 07:00-19:00"},
               "distance" => %{"value" => 0.4, "units" => "km"}
             }

      assert second["name"] == "Cafe 2"
    end

    test "compares scheme and host in lower case, without fragment or trailing slash" do
      records = [record(1), record(2, %{canonical_url: "https://cafe2.example/menu/"})]

      text = "[One](HTTPS://Cafe1.Example#hours) and [Two](https://CAFE2.example/menu)."
      assert names(ReplyBlocks.build(text, records)) == ["Cafe 1", "Cafe 2"]

      # The path, the query and the scheme still tell pages apart.
      for other <-
            ~w(https://cafe2.example/Menu https://cafe2.example/menu?x=1 http://cafe1.example/) do
        assert ReplyBlocks.build("See #{other}", records) == [], "#{other} matched"
      end
    end

    test "places come in the order the text first links them, once each" do
      text =
        "Start at https://cafe3.example/, then [Cafe 1](https://cafe1.example/) " <>
          "([its page](https://search.brave.com/local/place/1)), then https://cafe3.example."

      assert names(ReplyBlocks.build(text, Enum.map(1..3, &record/1))) == ["Cafe 3", "Cafe 1"]
    end

    test "a block holds at most ten places" do
      records = Enum.map(1..12, &record(&1, %{location: %{latitude: &1, longitude: &1}}))
      text = Enum.map_join(1..12, "\n", &"- [Cafe #{&1}](https://cafe#{&1}.example/)")

      assert names(ReplyBlocks.build(text, records)) == Enum.map(1..10, &"Cafe #{&1}")
    end

    test "a place with no usable coordinates stays a link and takes no slot" do
      records = [
        record(1, %{location: nil}) |> Map.delete(:location),
        record(2, %{location: %{latitude: 95.0, longitude: 10.0}}),
        record(3, %{location: %{latitude: "40.7", longitude: "-74.0"}})
        | Enum.map(4..14, &record(&1, %{location: %{latitude: 1, longitude: &1}}))
      ]

      text = Enum.map_join(1..14, " ", &"https://cafe#{&1}.example/")

      assert names(ReplyBlocks.build(text, records)) == Enum.map(4..13, &"Cafe #{&1}")
    end

    test "links to pages no record names, or no links at all, make no block" do
      records = [record(1)]

      assert ReplyBlocks.build("No links here, just Cafe 1 by name.", records) == []
      assert ReplyBlocks.build("Read https://news.example/cafes first.", records) == []
      assert ReplyBlocks.build("[Cafe 1](https://cafe1.example/)", []) == []
    end

    test "each fact is carried only as the source gave it" do
      sparse =
        record(1, %{
          rating: %{count: 12},
          distance: %{value: 0.4},
          opening_hours: %{days: ["Friday 07:00-19:00"]},
          categories: Enum.map(1..7, &"kind_#{&1}")
        })
        |> Map.drop([:canonical_url, :address, :price_range])

      [%{"places" => [place]}] =
        ReplyBlocks.build("https://search.brave.com/local/place/1", [sparse])

      assert Map.keys(place) |> Enum.sort() ==
               ~w(categories location name rating source_url)

      assert place["rating"] == %{"count" => 12}
      assert place["categories"] == Enum.map(1..5, &"kind_#{&1}")
    end

    test "the newer search names a page two searches returned" do
      older = record(1, %{distance: %{value: 3.2, units: "km"}})
      newer = record(1, %{distance: %{value: 0.4, units: "km"}})

      [%{"places" => [place]}] = ReplyBlocks.build("https://cafe1.example/", [older, newer])
      assert place["distance"] == %{"value" => 0.4, "units" => "km"}
    end

    test "a built block is what the exported schema describes" do
      schema = @schema_path |> File.read!() |> Jason.decode!()
      text = Enum.map_join(1..3, " ", &"https://cafe#{&1}.example/")
      blocks = ReplyBlocks.build(text, Enum.map(1..3, &record/1))

      assert [_block] = blocks
      assert schema["$defs"]["placesBlock"]["properties"]["places"]["maxItems"] == 10

      for block <- blocks do
        assert WireSchema.errors(block, WireSchema.ref("replyBlock"), schema) == []
      end

      drifted = put_in(hd(blocks), ["places", Access.at(0), "location"], %{"latitude" => 1})
      refute WireSchema.errors(drifted, WireSchema.ref("replyBlock"), schema) == []
    end
  end
end
