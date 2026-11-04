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

    # M85 §07: the lists a list tool read or changed are kept beside the places,
    # in the order the tools touched them, and taken with them.
    test "keeps the lists a tool touched beside the places, and builds a block of each" do
      {server, _clock} = holder()
      touch = %{list_id: "ck_3m9q2x7d1a", title: "Fermix", rows: ["ci_7k2m9d0q4a"]}

      :ok = ReplyBlocks.put_places(server, @chat, [record(1)])
      :ok = ReplyBlocks.put_checklists(server, @chat, [touch])

      assert [%{name: "Cafe 1"}, {:checklist, ^touch}] = records = ReplyBlocks.take(server, @chat)

      assert [%{"type" => "places"}, %{"type" => "checklists", "lists" => [list]}] =
               ReplyBlocks.build("[Cafe 1](https://cafe1.example/)", records)

      assert list == %{
               "list_id" => "ck_3m9q2x7d1a",
               "title" => "Fermix",
               "rows" => ["ci_7k2m9d0q4a"]
             }
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

    # M72 §14.1: a place Apple Maps found carries its identifier into the block,
    # which a Mac opens Apple's own place card by; its page is Apple's, so the
    # reply links it and the card attaches.
    test "an Apple Maps place carries its identifier, linked by Apple's page" do
      schema = @schema_path |> File.read!() |> Jason.decode!()
      page = "https://maps.apple.com/place?place-id=I15D3EC7F56AE8D5C"

      apple = %{
        name: "Tequila Mama Taqueria",
        canonical_url: "https://tequilamama.com",
        source_url: page,
        apple_place_id: "I15D3EC7F56AE8D5C",
        location: %{latitude: 34.0555026, longitude: -84.0647238},
        address: "340 Town Center Ave, Suwanee, GA 30024, United States",
        contact: %{telephone: "+1 (678) 456-3131"},
        categories: ["restaurant"]
      }

      blocks = ReplyBlocks.build("Try [Tequila Mama](#{page}) for the patio.", [apple, record(1)])

      assert [%{"type" => "places", "places" => [place]}] = blocks

      assert place == %{
               "name" => "Tequila Mama Taqueria",
               "canonical_url" => "https://tequilamama.com",
               "source_url" => page,
               "apple_place_id" => "I15D3EC7F56AE8D5C",
               "location" => %{"latitude" => 34.0555026, "longitude" => -84.0647238},
               "address" => "340 Town Center Ave, Suwanee, GA 30024, United States",
               "categories" => ["restaurant"]
             }

      assert WireSchema.errors(hd(blocks), WireSchema.ref("replyBlock"), schema) == []

      [%{"places" => [brave]}] = ReplyBlocks.build("https://cafe1.example/", [record(1)])
      refute Map.has_key?(brave, "apple_place_id")
    end
  end

  # M85 §07: the lists a turn's list tools read or changed, by id.
  describe "the checklists block" do
    defp touch(n, rows, title \\ nil),
      do: {:checklist, %{list_id: "ck_#{n}m9q2x7d1a", title: title || "List #{n}", rows: rows}}

    test "names each list once, in first-touch order, its newest title and every row it touched" do
      records = [
        touch(1, ["ci_7k2m9d0q4a"]),
        record(1),
        touch(2, []),
        touch(1, ["ci_2x8w1d5h3n", "ci_7k2m9d0q4a"], "Renamed")
      ]

      assert [%{"type" => "checklists", "lists" => [first, second]}] =
               ReplyBlocks.checklists(records)

      assert first == %{
               "list_id" => "ck_1m9q2x7d1a",
               "title" => "Renamed",
               "rows" => ["ci_7k2m9d0q4a", "ci_2x8w1d5h3n"]
             }

      assert second == %{"list_id" => "ck_2m9q2x7d1a", "title" => "List 2", "rows" => []}
    end

    test "names at most eight lists, and none without a touch" do
      lists = for n <- 0..9, do: touch(n, [])
      assert [%{"lists" => kept}] = ReplyBlocks.checklists(lists)
      assert length(kept) == ReplyBlocks.max_checklists()
      assert ReplyBlocks.checklists([record(1)]) == []
    end

    test "a built block is what the exported schema describes" do
      schema = @schema_path |> File.read!() |> Jason.decode!()
      [block] = ReplyBlocks.checklists([touch(1, ["ci_7k2m9d0q4a"]), touch(2, [])])

      assert WireSchema.errors(block, WireSchema.ref("replyBlock"), schema) == []

      drifted = put_in(block, ["lists", Access.at(0), "rows"], ["a row's words"])
      refute WireSchema.errors(drifted, WireSchema.ref("replyBlock"), schema) == []
    end
  end

  describe "the links a reply's previews are made from" do
    test "every link the text names, in order and once each, bold and bare ones read whole" do
      text =
        "**[Guide](https://guide.example/soho)** and <https://news.example/a>, then " <>
          "https://blog.example/post. Again: [Guide](https://guide.example/soho \"title\")."

      assert ReplyBlocks.links(text) ==
               ~w(https://guide.example/soho https://news.example/a https://blog.example/post)

      assert ReplyBlocks.links("no links here") == []
    end

    test "less the pages a block draws, matched as a place's links are" do
      text =
        "[Cafe 1](HTTPS://Cafe1.Example#hours) at https://search.brave.com/local/place/2/, " <>
          "with its [menu](https://cafe1.example/menu) and a [guide](https://guide.example/soho)."

      blocks = ReplyBlocks.build(text, [record(1), record(2)])
      assert names(blocks) == ["Cafe 1", "Cafe 2"]

      assert ReplyBlocks.links(text, blocks) ==
               ~w(https://cafe1.example/menu https://guide.example/soho)
    end
  end
end
