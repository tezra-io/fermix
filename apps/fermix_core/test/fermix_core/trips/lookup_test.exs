defmodule FermixCore.Trips.LookupTest do
  use ExUnit.Case, async: true

  alias FermixCore.ReplyBlocks
  alias FermixCore.Trips.Geo
  alias FermixCore.Trips.Lookup

  @conversation {"companion", "main", :root}
  @not_ready "auth_failed: missing Brave API key"

  # Invented places around one invented old town, a short walk apart.
  @tower %{latitude: 41.1402, longitude: -8.6113}
  @market %{latitude: 41.1446, longitude: -8.6071}
  @quay %{latitude: 41.1408, longitude: -8.6142}
  @town "Vila Nova, Portugal"

  defp place(name, point, id) do
    %{
      name: name,
      location: point,
      address: "#{id} Rua Inventada, Vila Nova",
      apple_place_id: "I#{id}",
      source_url: "https://maps.apple.com/place?place-id=I#{id}"
    }
  end

  defp unlocated(name, id), do: name |> place(@tower, id) |> Map.delete(:location)

  # Where a call's lookups search (`Lookup.anchors()`): the trip's placed stops
  # by day, each day's own `near` and the trip's.
  defp anchors(placed \\ %{}, day_near \\ %{}, trip_near \\ nil),
    do: %{placed: placed, day_near: day_near, trip_near: trip_near}

  # A trip whose `near` is the invented town, so a lookup has somewhere to search.
  defp near_town, do: anchors(%{}, %{}, @town)

  defp holder do
    start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: make_ref()))
  end

  # A backend that answers each query from `results`, telling the test every
  # request it was asked.
  defp search_by(results) do
    test_pid = self()

    fn %{query: query} = request ->
      send(test_pid, {:searched, request})
      Map.fetch!(results, query)
    end
  end

  defp found(places), do: {:ok, places, %{backend: "apple_maps"}}

  defp resolve(requests, anchors, search, opts \\ []) do
    Lookup.resolve(
      requests,
      anchors,
      Keyword.merge(
        [backend: {:ok, search}, reply_blocks: holder(), conversation_key: @conversation],
        opts
      )
    )
  end

  defp searched do
    receive do
      {:searched, request} -> [request | searched()]
    after
      0 -> []
    end
  end

  # A request searched 2 km about one placed stop at `point`.
  defp assert_around(request, point) do
    assert {:coordinates, latitude, longitude} = request.anchor
    assert_in_delta latitude, point.latitude, 1.0e-9
    assert_in_delta longitude, point.longitude, 1.0e-9
    assert request.radius_meters == 2_000
  end

  describe "the name rule" do
    test "a name holds the words or begins them, as whole words without case or accents" do
      assert Lookup.words_match?("Castelo da Águia", "castelo da aguia")
      assert Lookup.words_match?("Águia", "Castelo da Águia")
      assert Lookup.words_match?("Joe’s Bar", "Joe's Bar!")
      assert Lookup.words_match?("Castelo de São Jorge, Lisbon", "Castelo de São Jorge")
      assert Lookup.words_match?("Prado, Lisbon", "Prado")

      # A name that is only some later words of them is another place.
      refute Lookup.words_match?("Pois Café", "Café")
      refute Lookup.words_match?("Sé de Lisboa", "Lisboa")
      refute Lookup.words_match?("Dinner at Prado", "Prado")
      refute Lookup.words_match?("Lunch at Café Lúmen", "CAFE LUMEN")
      refute Lookup.words_match?("Dinner at Lúmen", "Rio Doce Grill")
      refute Lookup.words_match?("Torre Nacional", "National Tower")
      refute Lookup.words_match?("Lúmen", "Lumens Bakery")
      refute Lookup.words_match?("Café Lúmen", "Lúmen Café")
      refute Lookup.words_match?("Lúmen", "***")
      refute Lookup.words_match?("...", "Lúmen")
    end

    test "found: the first located result the rule matches is placed, scanned in order" do
      results = %{
        "Café Lúmen, Vila Nova" =>
          found([
            place("Lúmen Bakery", @market, 1),
            unlocated("Café Lúmen", 2),
            place("CAFE LUMEN", @tower, 3),
            place("Café Lúmen", @quay, 4)
          ])
      }

      assert {:ok, %{outcomes: [{7, {:placed, placed}}], records: [placed], lookups: 1}} =
               resolve(
                 [%{ref: 7, place: "Café Lúmen, Vila Nova", day: 1}],
                 near_town(),
                 search_by(results)
               )

      assert placed.name == "CAFE LUMEN"
    end

    test "a result with no location is skipped, matching or not" do
      results = %{
        "Torre Alta" => found([unlocated("Torre Alta", 1), place("Harbour Rooms", @quay, 2)]),
        "Doca" => found([unlocated("Doca", 3)])
      }

      assert {:ok, %{outcomes: outcomes, records: records}} =
               resolve(
                 [%{ref: 1, place: "Torre Alta", day: 1}, %{ref: 2, place: "Doca", day: 1}],
                 near_town(),
                 search_by(results)
               )

      assert [{1, {:offered, %{name: "Harbour Rooms"}}}, {2, {:none, :not_found}}] = outcomes
      assert Enum.map(records, & &1.name) == ["Harbour Rooms"]
    end
  end

  describe "what a lookup does" do
    test "another name is offered, never applied, and its link places it in a later call" do
      server = holder()
      offered = place("Harbour Rooms", @quay, 9)
      search = search_by(%{"Check in" => found([offered])})
      opts = [reply_blocks: server]

      assert {:ok, %{outcomes: [{3, {:offered, ^offered}}], records: [^offered]}} =
               resolve([%{ref: 3, place: "Check in", day: 2}], near_town(), search, opts)

      :ok = ReplyBlocks.put_places(server, @conversation, [offered])
      _taken = ReplyBlocks.take(server, @conversation)
      searched()

      link = Lookup.link(offered)
      assert link == "https://maps.apple.com/place?place-id=I9"

      assert {:ok, %{outcomes: [{3, {:placed, ^offered}}], records: [], lookups: 0}} =
               resolve([%{ref: 3, place: link, day: 2}], anchors(), search, opts)

      assert searched() == []
    end

    test "not found is none, with no record" do
      search = search_by(%{"Doca Velha" => found([])})

      assert {:ok, %{outcomes: [{5, {:none, :not_found}}], records: [], lookups: 1}} =
               resolve([%{ref: 5, place: "Doca Velha", day: 1}], near_town(), search)
    end

    test "a failed lookup is named in the place search's own words, and the rest go on" do
      results = %{
        "Torre Alta" => {:error, "network: Apple Maps could not be reached", %{}},
        "Mercado" => found([place("Mercado", @market, 2)])
      }

      assert {:ok, %{outcomes: outcomes, lookups: 2}} =
               resolve(
                 [%{ref: 1, place: "Torre Alta", day: 1}, %{ref: 2, place: "Mercado", day: 1}],
                 near_town(),
                 search_by(results)
               )

      assert outcomes == [
               {1, {:none, {:failed, "network: Apple Maps could not be reached"}}},
               {2, {:placed, place("Mercado", @market, 2)}}
             ]
    end

    test "rate limited stops every lookup not started, each named; the started ones finish" do
      results =
        1..9
        |> Map.new(&{"Spot #{&1}", found([place("Spot #{&1}", @tower, &1)])})
        |> Map.put("Spot 3", {:error, "rate_limited: Apple Maps is throttling searches", %{}})

      requests = Enum.map(1..9, &%{ref: &1, place: "Spot #{&1}", day: 1})

      assert {:ok, %{outcomes: outcomes, records: records, lookups: 5}} =
               resolve(requests, near_town(), search_by(results))

      assert Enum.map(outcomes, fn {ref, {kind, detail}} ->
               {ref, if(kind == :none, do: detail, else: kind)}
             end) == [
               {1, :placed},
               {2, :placed},
               {3, :rate_limited},
               {4, :placed},
               {5, :placed},
               {6, :rate_limited},
               {7, :rate_limited},
               {8, :rate_limited},
               {9, :rate_limited}
             ]

      assert Enum.map(records, & &1.name) == ["Spot 1", "Spot 2", "Spot 4", "Spot 5"]
      assert length(searched()) == 5
    end

    test "no place search set up here: every stop by words is none with why, a link still places" do
      server = holder()
      kept = place("Mercado", @market, 4)
      :ok = ReplyBlocks.put_places(server, @conversation, [kept])

      requests = [
        %{ref: 1, place: "Torre Alta", day: 1},
        %{ref: 2, place: kept.source_url, day: 1}
      ]

      assert {:ok, %{outcomes: outcomes, records: [], lookups: 0}} =
               Lookup.resolve(requests, near_town(),
                 backend: {:error, @not_ready},
                 reply_blocks: server,
                 conversation_key: @conversation
               )

      assert outcomes == [{1, {:none, {:no_backend, @not_ready}}}, {2, {:placed, kept}}]
    end
  end

  describe "the link form" do
    test "a link a search in the conversation returned places that record, after a take" do
      server = holder()
      kept = place("Mercado", @market, 4)
      :ok = ReplyBlocks.put_places(server, @conversation, [kept])
      _taken = ReplyBlocks.take(server, @conversation)
      search = search_by(%{})

      assert {:ok, %{outcomes: [{2, {:placed, ^kept}}], records: [], lookups: 0}} =
               resolve(
                 [%{ref: 2, place: " HTTPS://Maps.Apple.com/place?place-id=I4 ", day: 1}],
                 anchors(),
                 search,
                 reply_blocks: server
               )
    end

    test "a link none returned refuses the whole call before any lookup" do
      search = search_by(%{"Torre Alta" => found([place("Torre Alta", @tower, 1)])})

      requests = [
        %{ref: 1, place: "Torre Alta", day: 1},
        %{ref: 2, place: "https://maps.apple.com/place?place-id=I404", day: 1}
      ]

      assert resolve(requests, near_town(), search) == {:error, {:unknown_place_link, 2}}
      assert searched() == []
    end

    test "a link to a place the search gave no location places nothing, and says so" do
      server = holder()
      kept = unlocated("Doca", 5)
      :ok = ReplyBlocks.put_places(server, @conversation, [kept])

      assert {:ok, %{outcomes: [{4, {:none, :no_location}}]}} =
               resolve([%{ref: 4, place: kept.source_url, day: 1}], anchors(), search_by(%{}),
                 reply_blocks: server
               )
    end
  end

  describe "the anchor" do
    test "the day's placed stops, at least 2 km about their middle" do
      middle = Geo.centroid([@tower, @market])

      assert {:coordinates, latitude, longitude, 2_000} =
               Lookup.anchor(anchors(%{2 => [@tower, @market]}), 2)

      assert {latitude, longitude} == {middle.latitude, middle.longitude}
    end

    test "wider when the day's stops are, and never past the search's 50 km" do
      far = %{latitude: 41.1402, longitude: -8.5513}
      points = [@tower, far]
      middle = Geo.centroid(points)
      spread = Geo.spread_m(middle, points)
      assert spread > 2_000

      assert {:coordinates, _latitude, _longitude, ^spread} =
               Lookup.anchor(anchors(%{1 => points}), 1)

      across = [@tower, %{latitude: 38.7139, longitude: -9.1335}]

      assert {:coordinates, _latitude, _longitude, 50_000} =
               Lookup.anchor(anchors(%{1 => across}), 1)
    end

    test "a day with none anchors on the nearest day with some, the earlier on a tie, else none" do
      placed = anchors(%{2 => [@tower], 6 => [@market], 3 => []})

      assert {:coordinates, latitude, _longitude, 2_000} = Lookup.anchor(placed, 5)
      assert latitude == Geo.centroid([@market]).latitude

      assert {:coordinates, latitude, _longitude, 2_000} = Lookup.anchor(placed, 4)
      assert latitude == Geo.centroid([@tower]).latitude

      assert {:coordinates, latitude, _longitude, 2_000} = Lookup.anchor(placed, 3)
      assert latitude == Geo.centroid([@tower]).latitude

      assert Lookup.anchor(anchors(), 1) == nil
      assert Lookup.anchor(anchors(%{1 => []}), 1) == nil
    end

    # D11: a near wins, the day's, else the trip's; the placed stops anchor
    # only a trip with neither, the day's own, else the nearest placed day.
    test "with a near: the day's, else the trip's, over every placed stop" do
      porto = "Porto, Portugal"
      lisbon = "Lisbon, Portugal"

      # The day's near wins over its own placed stops and the trip's near.
      assert Lookup.anchor(anchors(%{3 => [@tower]}, %{3 => porto}, lisbon), 3) ==
               {:location, porto}

      # A day with no near of its own takes the trip's, over its own placed
      # stops and a placed day beside it.
      assert Lookup.anchor(anchors(%{3 => [@tower], 2 => [@market]}, %{}, lisbon), 3) ==
               {:location, lisbon}

      assert Lookup.anchor(anchors(%{2 => [@tower]}, %{3 => porto}, lisbon), 4) ==
               {:location, lisbon}

      # Another day's near is not this one's.
      assert Lookup.anchor(anchors(%{}, %{3 => porto}, lisbon), 4) == {:location, lisbon}
    end

    test "with no near: the day's placed stops, else the nearest placed day, else none" do
      porto = "Porto, Portugal"

      assert {:coordinates, latitude, _longitude, 2_000} =
               Lookup.anchor(anchors(%{3 => [@tower], 2 => [@market]}), 3)

      assert latitude == Geo.centroid([@tower]).latitude

      # Another day's near is not this one's: the nearest placed day anchors.
      assert {:coordinates, latitude, _longitude, 2_000} =
               Lookup.anchor(anchors(%{2 => [@market]}, %{5 => porto}), 3)

      assert latitude == Geo.centroid([@market]).latitude

      assert Lookup.anchor(anchors(%{}, %{5 => porto}), 3) == nil
    end

    test "a lookup asks around the anchor, near a place by its name, and with none the words alone" do
      search = search_by(%{"Mercado" => found([]), "Doca" => found([])})

      {:ok, _result} =
        resolve(
          [%{ref: 1, place: "Mercado", day: 2}],
          anchors(%{2 => [@tower, @market]}),
          search
        )

      assert [
               %{
                 query: "Mercado",
                 count: 5,
                 anchor: {:coordinates, _lat, _lon},
                 radius_meters: 2_000
               }
             ] =
               searched()

      # A near is the place search's own named anchor: it finds the place and
      # searches its region, so the request names no radius.
      {:ok, _result} = resolve([%{ref: 1, place: "Mercado", day: 2}], near_town(), search)
      assert searched() == [%{query: "Mercado", count: 5, anchor: {:location, @town}}]

      {:ok, _result} = resolve([%{ref: 1, place: "  Doca ", day: 1}], anchors(), search)
      assert searched() == [%{query: "Doca", count: 5}]
    end

    # With no near, a stop placed in an earlier wave anchors the later ones.
    test "a call with no near anchors later lookups on what it placed, in waves" do
      results = %{
        "Torre Alta" => found([place("Torre Alta", @tower, 1)]),
        "Mercado" => found([place("Mercado", @market, 2)]),
        "Harbour Rooms" => found([place("Harbour Rooms", @quay, 3)])
      }

      requests = [
        %{ref: 1, place: "Torre Alta", day: 1},
        %{ref: 2, place: "Mercado", day: 1},
        %{ref: 3, place: "Harbour Rooms", day: 2}
      ]

      assert {:ok, %{outcomes: outcomes, lookups: 3}} =
               resolve(requests, anchors(%{2 => [@quay]}), search_by(results))

      assert Enum.all?(outcomes, &match?({_ref, {:placed, _place}}, &1))

      [first | later] = searched()
      assert first.query == "Torre Alta"
      assert_around(first, @quay)
      assert_around(Enum.find(later, &(&1.query == "Mercado")), @tower)
      assert_around(Enum.find(later, &(&1.query == "Harbour Rooms")), @quay)
    end

    # With a near, what an earlier wave placed moves no later lookup's anchor.
    test "a call with a near searches it in every wave" do
      results = %{
        "Torre Alta" => found([place("Torre Alta", @tower, 1)]),
        "Mercado" => found([place("Mercado", @market, 2)])
      }

      requests = [%{ref: 1, place: "Torre Alta", day: 1}, %{ref: 2, place: "Mercado", day: 1}]

      assert {:ok, %{outcomes: [{1, {:placed, _tower}}, {2, {:placed, _market}}]}} =
               resolve(requests, near_town(), search_by(results))

      assert searched() == [
               %{query: "Torre Alta", count: 5, anchor: {:location, @town}},
               %{query: "Mercado", count: 5, anchor: {:location, @town}}
             ]
    end
  end

  # D11, from a live run in Lisbon: a day whose first placed stop was in
  # Alfama searched every later stop within a few km of it, so the tower in
  # Belém, 7 km off, was placed at a business of its name in Alfama. A near
  # wins over the placed stops, so a city's stops are each searched in the city.
  describe "a near wins" do
    @lisbon "Lisbon, Portugal"
    @alfama %{latitude: 38.7098, longitude: -9.1332}
    @alfama_bar %{latitude: 38.7163, longitude: -9.1342}
    @belem %{latitude: 38.6916, longitude: -9.2160}

    test "a day with a near: its stops in two districts are each searched near it" do
      cathedral = place("Sé de Lisboa", @alfama, 11)
      tower = place("Torre de Belém", @belem, 12)

      search =
        search_by(%{"Sé de Lisboa" => found([cathedral]), "Torre de Belém" => found([tower])})

      requests = [
        %{ref: 1, place: "Sé de Lisboa", day: 1},
        %{ref: 2, place: "Torre de Belém", day: 1}
      ]

      assert {:ok, %{outcomes: [{1, {:placed, ^cathedral}}, {2, {:placed, ^tower}}]}} =
               resolve(requests, anchors(%{1 => [@alfama]}, %{1 => @lisbon}), search)

      assert searched() == [
               %{query: "Sé de Lisboa", count: 5, anchor: {:location, @lisbon}},
               %{query: "Torre de Belém", count: 5, anchor: {:location, @lisbon}}
             ]
    end

    test "a business of a landmark's name beside a placed stop does not win: the near is searched" do
      bar = place("Torre de Belém", @alfama_bar, 13)
      tower = place("Torre de Belém", @belem, 12)
      test_pid = self()

      # Around the placed stop the search finds the bar; in the city, the tower.
      search = fn request ->
        send(test_pid, {:searched, request})

        case request.anchor do
          {:coordinates, _latitude, _longitude} -> found([bar])
          {:location, @lisbon} -> found([tower])
        end
      end

      assert {:ok, %{outcomes: [{1, {:placed, ^tower}}], records: [^tower]}} =
               resolve(
                 [%{ref: 1, place: "Torre de Belém", day: 1}],
                 anchors(%{1 => [@alfama]}, %{}, @lisbon),
                 search
               )

      assert searched() == [%{query: "Torre de Belém", count: 5, anchor: {:location, @lisbon}}]
    end

    # A near's search stays in the near: the Apple Maps helper geocodes it and
    # searches its region as required, never as a hint MapKit may leave, so no
    # result outside it comes back and Lookup checks no distance of its own.
    test "the place search's named anchor is a required region" do
      source =
        "../../../../fermix_nif/swift_src/fermix_maps.swift"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> String.replace(~r/\s+/, " ")

      assert source =~
               "case .location(let location): " <>
                 "geocode(location) { region in run(request.query, region: region) }"

      assert source =~
               "if let region { request.region = region request.regionPriority = .required }"
    end
  end

  # D10: a generic name with nowhere to search lands wherever the search is
  # (a "fish market" for a trip to Varonne found in another country), so a
  # lookup with no anchor never places.
  describe "no anchor" do
    @far_market %{latitude: 33.8404, longitude: -84.3797}

    test "a lookup with nowhere to search offers its first located result and places nothing" do
      far = place("Atlanta Fish Market", @far_market, 7)
      search = search_by(%{"fish market" => found([unlocated("Fish Market", 6), far])})

      assert {:ok, %{outcomes: [{1, {:offered, ^far, :no_anchor}}], records: [^far]}} =
               resolve([%{ref: 1, place: "fish market", day: 1}], anchors(), search)

      assert searched() == [%{query: "fish market", count: 5}]

      search = search_by(%{"fish market" => found([unlocated("Fish Market", 6)])})

      assert {:ok, %{outcomes: [{1, {:none, :not_found}}], records: []}} =
               resolve([%{ref: 1, place: "fish market", day: 1}], anchors(), search)
    end

    test "a two-city trip: a day's near wins over the trip's, and its lookup places there" do
      sinos = place("Torre dos Sinos", @tower, 3)
      search = search_by(%{"Torre dos Sinos" => found([sinos])})
      two_cities = anchors(%{1 => [@market]}, %{3 => "Porto, Portugal"}, "Lisbon, Portugal")

      assert {:ok, %{outcomes: [{1, {:placed, ^sinos}}]}} =
               resolve([%{ref: 1, place: "Torre dos Sinos", day: 3}], two_cities, search)

      assert searched() == [
               %{query: "Torre dos Sinos", count: 5, anchor: {:location, "Porto, Portugal"}}
             ]
    end

    # The place search's named anchor answers invalid_location for a name it
    # finds no place by; that near is no anchor, looked up once a call.
    test "a near that does not geocode is no anchor: offered, never placed, and said" do
      far = place("Fish market", @far_market, 7)
      test_pid = self()

      search = fn request ->
        send(test_pid, {:searched, request})

        case request do
          %{anchor: {:location, "Varonne"}} ->
            {:error, "invalid_location: Apple Maps found no place by that name", %{}}

          %{query: "Fish market"} ->
            found([far])

          %{query: "Ferry"} ->
            found([])
        end
      end

      requests = [
        %{ref: 1, place: "Fish market", day: 1},
        %{ref: 2, place: "Ferry", day: 1}
      ]

      assert {:ok, %{outcomes: outcomes, records: [^far], lookups: 2}} =
               resolve(requests, anchors(%{}, %{}, "Varonne"), search)

      assert outcomes == [
               {1, {:offered, far, {:unknown_near, "Varonne"}}},
               {2, {:none, {:unknown_near, "Varonne"}}}
             ]

      assert searched() == [
               %{query: "Fish market", count: 5, anchor: {:location, "Varonne"}},
               %{query: "Fish market", count: 5},
               %{query: "Ferry", count: 5}
             ]
    end
  end

  describe "the bounds" do
    test "40 lookups a call, a repeated place once; a 41st refuses the call before any lookup" do
      search = fn %{query: query} -> found([place(query, @tower, 1)]) end

      unique = Enum.map(1..40, &%{ref: &1, place: "Spot #{&1}", day: 1})
      repeats = [%{ref: 41, place: "SPOT 1", day: 1}, %{ref: 42, place: "Spot 2!", day: 1}]

      assert {:ok, %{outcomes: outcomes, records: records, lookups: 40}} =
               resolve(unique ++ repeats, near_town(), search)

      assert length(outcomes) == 42
      assert length(records) == 40
      assert {41, {:placed, %{name: "Spot 1"}}} = Enum.at(outcomes, 40)
      assert {42, {:placed, %{name: "Spot 2"}}} = Enum.at(outcomes, 41)

      another_day = [%{ref: 43, place: "Spot 1", day: 2}]
      assert resolve(unique ++ another_day, near_town(), search) == {:error, :too_many_lookups}

      test_pid = self()
      refusing = fn _request -> send(test_pid, :unexpected_lookup) end
      assert resolve(unique ++ another_day, near_town(), refusing) == {:error, :too_many_lookups}
      refute_received :unexpected_lookup
      assert Lookup.max_lookups() == 40
    end

    test "links do not count against the lookups" do
      server = holder()
      kept = place("Mercado", @market, 4)
      :ok = ReplyBlocks.put_places(server, @conversation, [kept])
      search = fn %{query: query} -> found([place(query, @tower, 1)]) end
      requests = Enum.map(1..40, &%{ref: &1, place: "Spot #{&1}", day: 1})
      link = %{ref: 41, place: kept.source_url, day: 1}

      assert {:ok, %{lookups: 40}} =
               resolve(requests ++ [link], near_town(), search, reply_blocks: server)
    end

    test "four at a time: the first alone, then waves of four" do
      test_pid = self()
      gauge = start_supervised!({Agent, fn -> %{running: 0, most: 0} end})

      search = fn %{query: query} ->
        Agent.update(gauge, fn %{running: running, most: most} ->
          %{running: running + 1, most: max(most, running + 1)}
        end)

        send(test_pid, {:started, self()})

        receive do
          :go -> :ok
        end

        Agent.update(gauge, &%{&1 | running: &1.running - 1})
        found([place(query, @tower, 1)])
      end

      requests = Enum.map(1..9, &%{ref: &1, place: "Spot #{&1}", day: 1})
      server = holder()

      task =
        Task.async(fn ->
          Lookup.resolve(requests, near_town(),
            backend: {:ok, search},
            reply_blocks: server,
            conversation_key: @conversation
          )
        end)

      for wave <- [1, 4, 4] do
        started =
          for _lookup <- 1..wave do
            assert_receive {:started, pid}
            pid
          end

        assert Agent.get(gauge, & &1.running) == wave
        Enum.each(started, &send(&1, :go))
      end

      assert {:ok, %{lookups: 9}} = Task.await(task, 10_000)
      assert Agent.get(gauge, & &1.most) == 4
    end

    test "the lookups not started by the 45 s deadline are none, each named" do
      clock = start_supervised!({Agent, fn -> 0 end})

      search = fn %{query: query} ->
        Agent.update(clock, &(&1 + Lookup.deadline_ms()))
        found([place(query, @tower, 1)])
      end

      requests = Enum.map(1..3, &%{ref: &1, place: "Spot #{&1}", day: 1})

      assert {:ok, %{outcomes: outcomes, lookups: 1}} =
               resolve(requests, near_town(), search, now_ms: fn -> Agent.get(clock, & &1) end)

      assert [{1, {:placed, _place}}, {2, {:none, :deadline}}, {3, {:none, :deadline}}] = outcomes
      assert Lookup.deadline_ms() == 45_000
    end

    test "a lookup still running at the deadline is stopped and named" do
      search = fn _request ->
        receive do
          :never -> found([])
        end
      end

      requests = [%{ref: 1, place: "Spot 1", day: 1}, %{ref: 2, place: "Spot 2", day: 1}]

      assert {:ok, %{outcomes: outcomes, records: [], lookups: 1}} =
               resolve(requests, near_town(), search, deadline_ms: 50)

      assert outcomes == [{1, {:none, :deadline}}, {2, {:none, :deadline}}]
    end

    # M89 D13: a home that looks places up on a Mac stops the call's lookups
    # on the first answer that no such Mac is online, as on a rate limit.
    # M89 D13: on a Mac of the home, what cannot heal within the call stops
    # the lookups not started, each by its own kind; a busy Mac stops nothing.
    test "a Mac away, switched off, refusing or not answering stops the call; busy does not" do
      for why <- [:computer_away, :computer_off, :computer_refused, :computer_timed_out] do
        stop = {:error, "#{why}: words", %{attempt: 1, provider_code: "code"}}
        search = search_by(%{"Spot 1" => stop, "Spot 2" => found([]), "Spot 3" => found([])})
        requests = Enum.map(1..3, &%{ref: &1, place: "Spot #{&1}", day: &1})

        assert {:ok, %{outcomes: outcomes, stop_reason: ^why, stop_code: "code"}} =
                 resolve(requests, near_town(), search)

        assert Enum.map(outcomes, &elem(&1, 1)) == List.duplicate({:none, why}, 3)
        assert [%{query: "Spot 1"}] = searched()
      end

      busy = {:error, "computer_busy: words", %{attempt: 1}}
      search = search_by(%{"Spot 1" => busy, "Spot 2" => found([])})
      requests = Enum.map(1..2, &%{ref: &1, place: "Spot #{&1}", day: &1})

      assert {:ok, %{outcomes: [{1, {:none, :computer_busy}}, {2, {:none, :not_found}}]} = result} =
               resolve(requests, near_town(), search)

      assert result.stop_reason == nil
    end

    # M89 D13 B: the trip placer spends a try only on a lookup that reached
    # the place search; one a stop left unsent, or one that said it sent
    # nothing, is not among them.
    test "the refs whose lookup was sent: never one a stop left unsent or one that sent nothing" do
      limited = {:error, "rate_limited: slow down", %{attempt: 1}}
      away = {:error, "computer_away: words", %{attempt: 0}}

      search =
        search_by(%{"Spot 1" => limited, "Spot 2" => found([]), "Spot 3" => found([])})

      requests = Enum.map(1..3, &%{ref: &1, place: "Spot #{&1}", day: &1})

      assert {:ok, %{sent: [1], stop_reason: :rate_limited}} =
               resolve(requests, near_town(), search)

      search = search_by(%{"Spot 1" => away, "Spot 2" => found([])})
      requests = Enum.map(1..2, &%{ref: &1, place: "Spot #{&1}", day: &1})
      assert {:ok, %{sent: []}} = resolve(requests, near_town(), search)

      # Two stops by the same words on one day are one lookup, sent for both.
      search = search_by(%{"Spot 1" => found([])})
      twice = [%{ref: 1, place: "Spot 1", day: 1}, %{ref: 2, place: "Spot 1", day: 1}]
      assert {:ok, %{sent: [1, 2]}} = resolve(twice, near_town(), search)
    end

    # Only a stop a lookup placed is credited to what searched; one its link
    # placed is no lookup's.
    test "what placed each stop a lookup placed is kept by its ref, never a link's" do
      server = holder()
      kept = place("Mercado", @market, 4)
      :ok = ReplyBlocks.put_places(server, @conversation, [kept])

      mac = fn %{query: query} ->
        {:ok, [place(query, @tower, 1)], %{searched_with: "Apple Maps on studio Mac"}}
      end

      requests = [
        %{ref: 1, place: "Spot 1", day: 1},
        %{ref: 2, place: kept.source_url, day: 1},
        %{ref: 3, place: "Spot 1", day: 1}
      ]

      assert {:ok, %{placed_by: placed_by, outcomes: outcomes}} =
               resolve(requests, near_town(), mac, reply_blocks: server)

      assert [{1, {:placed, _}}, {2, {:placed, ^kept}}, {3, {:placed, _}}] = outcomes
      assert placed_by == %{1 => "Apple Maps on studio Mac", 3 => "Apple Maps on studio Mac"}

      # A result by another name, offered, placed nothing.
      offered = fn _request ->
        {:ok, [place("Elsewhere", @tower, 1)], %{searched_with: "Brave"}}
      end

      assert {:ok, %{placed_by: %{}}} = resolve(Enum.take(requests, 1), near_town(), offered)
    end

    test "a request that is not a stop's place and day is refused loudly" do
      search = search_by(%{})

      assert_raise FunctionClauseError, fn ->
        resolve([%{ref: 1, place: "", day: 1}], anchors(), search)
      end

      assert_raise FunctionClauseError, fn ->
        resolve([%{ref: 1, place: "Doca", day: 0}], anchors(), search)
      end

      assert_raise KeyError, fn ->
        Lookup.resolve([], anchors(), conversation_key: @conversation)
      end
    end
  end

  describe "what the answer says" do
    test "a heading for each reason a stop was not placed" do
      assert Lookup.heading(:not_found) == "No place found"

      assert Lookup.heading(:no_location) ==
               "Not placed, the search gave that place no location"

      # M89 D13 B: what heals by waiting is saved and placed later, if its
      # condition clears within the week a stop waits.
      assert Lookup.heading(:rate_limited) ==
               "Not looked up yet, the place search is rate limited; these stops are saved " <>
                 "and will be placed if it allows more searches within a week"

      assert Lookup.heading(:deadline) ==
               "Not looked up yet, the call's 45 s for place lookups ran out; these stops are " <>
                 "saved and will be placed if they can be looked up within a week"

      assert Lookup.heading(:computer_away) ==
               "Not looked up yet, no Mac that looks places up in Apple Maps is online; these " <>
                 "stops are saved and will be placed if one comes online within a week"

      assert Lookup.heading(:computer_off) ==
               "Not looked up, Apple Maps is switched off on the Mac that looks places up, so " <>
                 "these stops are saved without a place; only someone at that Mac can switch it on"

      assert Lookup.heading(:computer_refused) ==
               "Not looked up, the Mac that looks places up in Apple Maps refused the search, so " <>
                 "these stops are saved without a place"

      assert Lookup.heading(:computer_timed_out) ==
               "Not looked up yet, the Mac that looks places up in Apple Maps did not answer " <>
                 "in time; these stops are saved and will be placed if it answers within a week"

      assert Lookup.heading(:computer_busy) ==
               "Not looked up yet, the Mac that looks places up in Apple Maps was busy; these " <>
                 "stops are saved and will be placed if it frees up within a week"

      # No heading of a reason that cannot heal by waiting says to ask again.
      for why <- [:computer_off, :computer_refused, :plan_excludes_place_search] do
        refute Lookup.heading(why) =~ "ask again"
      end

      assert Lookup.heading({:failed, "network: Apple Maps could not be reached"}) ==
               "Not looked up, the place search failed (network: Apple Maps could not be reached)"

      assert Lookup.heading({:no_backend, @not_ready}) ==
               "Not looked up, no place search is set up here (#{@not_ready})"

      assert Lookup.heading({:unknown_near, "Varonne"}) ==
               ~s(No place found, and the place search found no place "Varonne" to search ) <>
                 "near; give its day a near it can find (a town and its country)"
    end

    test "a heading for what a lookup with no anchor offered, saying to give near" do
      assert Lookup.offered_heading(:no_anchor) ==
               "Not placed, this trip has no place to search near, so each is only the first " <>
                 "result anywhere: give its day a near (a town and its country) and the place " <>
                 "again, or its link if that is the place meant"

      assert Lookup.offered_heading({:unknown_near, "Varonne"}) ==
               ~s(Not placed, the place search found no place "Varonne" to search near, so ) <>
                 "each is only the first result anywhere: give its day a near it can find (a " <>
                 "town and its country) and the place again, or its link if that is the place " <>
                 "meant"
    end

    test "a place's link is the search's page for it, else the place's own site" do
      assert Lookup.link(place("Mercado", @market, 4)) ==
               "https://maps.apple.com/place?place-id=I4"

      assert Lookup.link(%{name: "Mercado", canonical_url: "https://mercado.example/"}) ==
               "https://mercado.example/"
    end
  end
end
