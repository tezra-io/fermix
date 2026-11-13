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

  defp resolve(requests, placed, search, opts \\ []) do
    Lookup.resolve(
      requests,
      placed,
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

  describe "the name rule" do
    test "a name is in the words or holds them, as whole words without case or accents" do
      assert Lookup.words_match?("Lunch at Café Lúmen", "CAFE LUMEN")
      assert Lookup.words_match?("Castelo da Águia", "castelo da aguia")
      assert Lookup.words_match?("Águia", "Castelo da Águia")
      assert Lookup.words_match?("Joe’s Bar", "Joe's Bar!")

      refute Lookup.words_match?("Dinner at Lúmen", "Rio Doce Grill")
      refute Lookup.words_match?("Torre Nacional", "National Tower")
      refute Lookup.words_match?("Lúmen", "Lumens Bakery")
      refute Lookup.words_match?("Café Lúmen", "Lúmen Café")
      refute Lookup.words_match?("Lúmen", "***")
      refute Lookup.words_match?("...", "Lúmen")
    end

    test "found: the first located result the rule matches is placed, scanned in order" do
      results = %{
        "Lunch at Café Lúmen" =>
          found([
            place("Lúmen Bakery", @market, 1),
            unlocated("Café Lúmen", 2),
            place("CAFE LUMEN", @tower, 3),
            place("Café Lúmen", @quay, 4)
          ])
      }

      assert {:ok, %{outcomes: [{7, {:placed, placed}}], records: [placed], lookups: 1}} =
               resolve([%{ref: 7, place: "Lunch at Café Lúmen", day: 1}], %{}, search_by(results))

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
                 %{},
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
               resolve([%{ref: 3, place: "Check in", day: 2}], %{}, search, opts)

      :ok = ReplyBlocks.put_places(server, @conversation, [offered])
      _taken = ReplyBlocks.take(server, @conversation)
      searched()

      link = Lookup.link(offered)
      assert link == "https://maps.apple.com/place?place-id=I9"

      assert {:ok, %{outcomes: [{3, {:placed, ^offered}}], records: [], lookups: 0}} =
               resolve([%{ref: 3, place: link, day: 2}], %{}, search, opts)

      assert searched() == []
    end

    test "not found is none, with no record" do
      search = search_by(%{"Doca Velha" => found([])})

      assert {:ok, %{outcomes: [{5, {:none, :not_found}}], records: [], lookups: 1}} =
               resolve([%{ref: 5, place: "Doca Velha", day: 1}], %{}, search)
    end

    test "a failed lookup is named in the place search's own words, and the rest go on" do
      results = %{
        "Torre Alta" => {:error, "network: Apple Maps could not be reached", %{}},
        "Mercado" => found([place("Mercado", @market, 2)])
      }

      assert {:ok, %{outcomes: outcomes, lookups: 2}} =
               resolve(
                 [%{ref: 1, place: "Torre Alta", day: 1}, %{ref: 2, place: "Mercado", day: 1}],
                 %{},
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
               resolve(requests, %{}, search_by(results))

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
               Lookup.resolve(requests, %{},
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
                 %{},
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

      assert resolve(requests, %{}, search) == {:error, {:unknown_place_link, 2}}
      assert searched() == []
    end

    test "a link to a place the search gave no location places nothing, and says so" do
      server = holder()
      kept = unlocated("Doca", 5)
      :ok = ReplyBlocks.put_places(server, @conversation, [kept])

      assert {:ok, %{outcomes: [{4, {:none, :no_location}}]}} =
               resolve([%{ref: 4, place: kept.source_url, day: 1}], %{}, search_by(%{}),
                 reply_blocks: server
               )
    end
  end

  describe "the anchor" do
    test "the day's placed stops, at least 2 km about their middle" do
      middle = Geo.centroid([@tower, @market])

      assert {:coordinates, latitude, longitude, 2_000} =
               Lookup.anchor(%{2 => [@tower, @market]}, 2)

      assert {latitude, longitude} == {middle.latitude, middle.longitude}
    end

    test "wider when the day's stops are, and never past the search's 50 km" do
      far = %{latitude: 41.1402, longitude: -8.5513}
      points = [@tower, far]
      middle = Geo.centroid(points)
      spread = Geo.spread_m(middle, points)
      assert spread > 2_000

      assert {:coordinates, _latitude, _longitude, ^spread} = Lookup.anchor(%{1 => points}, 1)

      across = [@tower, %{latitude: 38.7139, longitude: -9.1335}]
      assert {:coordinates, _latitude, _longitude, 50_000} = Lookup.anchor(%{1 => across}, 1)
    end

    test "a day with none anchors on the nearest day with some, the earlier on a tie, else none" do
      placed = %{2 => [@tower], 6 => [@market], 3 => []}

      assert {:coordinates, latitude, _longitude, 2_000} = Lookup.anchor(placed, 5)
      assert latitude == Geo.centroid([@market]).latitude

      assert {:coordinates, latitude, _longitude, 2_000} = Lookup.anchor(placed, 4)
      assert latitude == Geo.centroid([@tower]).latitude

      assert {:coordinates, latitude, _longitude, 2_000} = Lookup.anchor(placed, 3)
      assert latitude == Geo.centroid([@tower]).latitude

      assert Lookup.anchor(%{}, 1) == nil
      assert Lookup.anchor(%{1 => []}, 1) == nil
    end

    test "a lookup asks around the anchor, and with none asks the words alone" do
      search = search_by(%{"Mercado" => found([]), "Doca" => found([])})

      {:ok, _result} =
        resolve(
          [%{ref: 1, place: "Mercado", day: 2}],
          %{2 => [@tower, @market]},
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

      {:ok, _result} = resolve([%{ref: 1, place: "  Doca ", day: 1}], %{}, search)
      assert searched() == [%{query: "Doca", count: 5}]
    end

    test "a creating call anchors later lookups on what it placed, in waves" do
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

      assert {:ok, %{outcomes: outcomes, lookups: 3}} = resolve(requests, %{}, search_by(results))
      assert Enum.all?(outcomes, &match?({_ref, {:placed, _place}}, &1))

      [first | later] = searched()
      assert first == %{query: "Torre Alta", count: 5}

      for request <- later do
        assert {:coordinates, latitude, longitude} = request.anchor
        assert_in_delta latitude, @tower.latitude, 1.0e-9
        assert_in_delta longitude, @tower.longitude, 1.0e-9
        assert request.radius_meters == 2_000
      end
    end
  end

  describe "the bounds" do
    test "40 lookups a call, a repeated place once; a 41st refuses the call before any lookup" do
      search = fn %{query: query} -> found([place(query, @tower, 1)]) end

      unique = Enum.map(1..40, &%{ref: &1, place: "Spot #{&1}", day: 1})
      repeats = [%{ref: 41, place: "SPOT 1", day: 1}, %{ref: 42, place: "Spot 2!", day: 1}]

      assert {:ok, %{outcomes: outcomes, records: records, lookups: 40}} =
               resolve(unique ++ repeats, %{}, search)

      assert length(outcomes) == 42
      assert length(records) == 40
      assert {41, {:placed, %{name: "Spot 1"}}} = Enum.at(outcomes, 40)
      assert {42, {:placed, %{name: "Spot 2"}}} = Enum.at(outcomes, 41)

      another_day = [%{ref: 43, place: "Spot 1", day: 2}]
      assert resolve(unique ++ another_day, %{}, search) == {:error, :too_many_lookups}

      test_pid = self()
      refusing = fn _request -> send(test_pid, :unexpected_lookup) end
      assert resolve(unique ++ another_day, %{}, refusing) == {:error, :too_many_lookups}
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
               resolve(requests ++ [link], %{}, search, reply_blocks: server)
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
          Lookup.resolve(requests, %{},
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
               resolve(requests, %{}, search, now_ms: fn -> Agent.get(clock, & &1) end)

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
               resolve(requests, %{}, search, deadline_ms: 50)

      assert outcomes == [{1, {:none, :deadline}}, {2, {:none, :deadline}}]
    end

    test "a request that is not a stop's place and day is refused loudly" do
      search = search_by(%{})

      assert_raise FunctionClauseError, fn ->
        resolve([%{ref: 1, place: "", day: 1}], %{}, search)
      end

      assert_raise FunctionClauseError, fn ->
        resolve([%{ref: 1, place: "Doca", day: 0}], %{}, search)
      end

      assert_raise KeyError, fn ->
        Lookup.resolve([], %{}, conversation_key: @conversation)
      end
    end
  end

  describe "what the answer says" do
    test "a heading for each reason a stop was not placed" do
      assert Lookup.heading(:not_found) == "No place found"

      assert Lookup.heading(:no_location) ==
               "Not placed, the search gave that place no location"

      assert Lookup.heading(:rate_limited) == "Not looked up, the place search is rate limited"

      assert Lookup.heading(:deadline) ==
               "Not looked up, the call's 45 s for place lookups ran out"

      assert Lookup.heading({:failed, "network: Apple Maps could not be reached"}) ==
               "Not looked up, the place search failed (network: Apple Maps could not be reached)"

      assert Lookup.heading({:no_backend, @not_ready}) ==
               "Not looked up, no place search is set up here (#{@not_ready})"
    end

    test "a place's link is the search's page for it, else the place's own site" do
      assert Lookup.link(place("Mercado", @market, 4)) ==
               "https://maps.apple.com/place?place-id=I4"

      assert Lookup.link(%{name: "Mercado", canonical_url: "https://mercado.example/"}) ==
               "https://mercado.example/"
    end
  end
end
