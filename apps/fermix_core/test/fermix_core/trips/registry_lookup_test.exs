defmodule FermixCore.Trips.RegistryLookupTest do
  # M89 §04: a trip_edit call's places resolved before its transaction opens,
  # through the Registry against a real store with the place search injected
  # (`context.place_lookup`): words looked up around the day each stop lands
  # in, the trip read first and the call run over it to learn that day; what
  # each lookup came to in the answer, by the stop's number; a link a search
  # returned placing its record, one none returned refusing the call; the
  # lookups' records joining the conversation before the store is asked; and
  # the counts on the edit's event.
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Trips.Registry
  alias FermixTestSupport.TelemetryCapture

  # Every title, stop, place, address and id here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @conversation {"telegram", "40017", :root}
  @owner %{
    agent_name: "main",
    conversation_key: @conversation,
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }

  @tower %{latitude: 41.1402, longitude: -8.6113}
  @quay %{latitude: 41.1408, longitude: -8.6142}
  @town "Varonne, Portugal"
  # The line an answer ends with when a place given was not placed.
  @report "Tell the owner which stops were placed, which were offered under another name " <>
            "with their links, and which were not placed and why, as this answer lists them."

  defp place(name, point, id) do
    %{
      name: name,
      location: point,
      address: "#{id} Rua Inventada, Varonne",
      apple_place_id: "I#{id}",
      source_url: "https://maps.apple.com/place?place-id=I#{id}"
    }
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trips-lookup-#{unique}.db")
    repo = :"trips_lookup_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: :holder))

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, holder: holder}
  end

  # A place search that answers each query from `results`, telling the test
  # every request it was asked.
  defp searching(results) do
    test = self()

    fn %{query: query} = request ->
      send(test, {:searched, request})
      Map.fetch!(results, query)
    end
  end

  defp found(places), do: {:ok, places, %{backend: "apple_maps"}}

  defp edit(ctx, trip, ops, results) do
    context = Map.put(@owner, :place_lookup, searching(results))
    opts = [repo: ctx.repo, now: @now, reply_blocks: ctx.holder, notifier: fn _c -> :ok end]
    Registry.edit(%{"trip" => trip, "ops" => ops}, context, opts)
  end

  defp rows!(ctx, trip) do
    assert {:ok, %{rows: rows}} =
             Repo.trips_call({:read_trip, "default", "main", trip}, server: ctx.repo)

    rows
  end

  defp searched do
    receive do
      {:searched, request} -> [request | searched()]
    after
      0 -> []
    end
  end

  test "a stop's words are looked up and placed, and the answer names what it placed", ctx do
    tower = place("Torre de Vale Escuro", @tower, 1)

    assert {:ok, answer} =
             edit(
               ctx,
               "Varonne",
               [
                 %{"op" => "create", "days" => 2, "near" => @town},
                 %{
                   "op" => "add",
                   "text" => "Morning at the tower",
                   "day" => 2,
                   "place" => "Torre de Vale Escuro"
                 }
               ],
               %{"Torre de Vale Escuro" => found([tower])}
             )

    assert answer.text ==
             "Varonne · rev 1 · created; 1 stop added · 2 days, 1 stop · 1 placed\n" <>
               ~s([3] "Morning at the tower": "Torre de Vale Escuro, 1 Rua Inventada, Varonne")

    assert searched() == [
             %{query: "Torre de Vale Escuro", count: 5, anchor: {:location, @town}}
           ]

    assert %{place: place} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 3))

    assert place == %{
             "name" => "Torre de Vale Escuro",
             "location" => %{"latitude" => 41.1402, "longitude" => -8.6113},
             "address" => "1 Rua Inventada, Varonne",
             "apple_place_id" => "I1",
             "source_url" => "https://maps.apple.com/place?place-id=I1"
           }
  end

  test "a stop placed earlier in the call, or already on its day, anchors the next lookup", ctx do
    results = %{
      "Torre de Vale Escuro" => found([place("Torre de Vale Escuro", @tower, 1)]),
      "Cais Velho" => found([place("Cais Velho", @quay, 2)]),
      "Doca Seca" => found([])
    }

    {:ok, _answer} =
      edit(
        ctx,
        "Varonne",
        [
          %{"op" => "create", "days" => 2, "near" => @town},
          %{"op" => "add", "text" => "Tower", "day" => 1, "place" => "Torre de Vale Escuro"},
          %{"op" => "add", "text" => "Quay", "after" => 3, "place" => "Cais Velho"}
        ],
        results
      )

    assert [first, second] = searched()
    assert first.anchor == {:location, @town}
    assert {:coordinates, 41.1402, -8.6113} = second.anchor
    assert second.radius_meters == 2_000

    # A later call reads the trip first: an edit of a stop on Day 1 is looked
    # up around Day 1's placed stops, and the row it names keeps its number.
    assert {:ok, answer} =
             edit(ctx, "Varonne", [%{"op" => "edit", "n" => 4, "place" => "Doca Seca"}], results)

    assert answer.text =~ ~s|No place found: [4] "Quay" (place unchanged).|
    assert [%{anchor: {:coordinates, _lat, _lon}, radius_meters: radius}] = searched()
    assert radius >= 2_000
    assert %{place: %{"name" => "Cais Velho"}} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 4))
  end

  # R2#1: a lookup that does not place, for whatever reason, never takes a
  # stop's place away; only an empty place clears it.
  test "an edit whose lookup does not place keeps the stop's place, and the rest of it lands",
       ctx do
    {:ok, _answer} =
      edit(
        ctx,
        "Varonne",
        [
          %{"op" => "create", "near" => @town},
          %{"op" => "add", "text" => "Quay", "day" => 1, "place" => "Cais Velho"}
        ],
        %{"Cais Velho" => found([place("Cais Velho", @quay, 2)])}
      )

    %{place: kept} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))
    assert %{"name" => "Cais Velho"} = kept

    cases = [
      {"Cais Velho, Ribeira", {:error, "rate_limited: slow down", %{}},
       "Not looked up, the place search is rate limited: "},
      {"Doca Seca", found([]), "No place found: "},
      {"Ponte Nova", {:error, "network: unreachable", %{}},
       "Not looked up, the place search failed (network: unreachable): "},
      {"Check in", found([place("Harbour Rooms", @tower, 9)]),
       "Not placed, nearest by another name:\n"}
    ]

    for {{words, result, heading}, i} <- Enum.with_index(cases, 1) do
      time = "1#{i}:00"
      op = %{"op" => "edit", "n" => 2, "time" => time, "place" => words}
      assert {:ok, answer} = edit(ctx, "Varonne", [op], %{words => result})

      assert answer.text =~ heading <> ~s|[2] "Quay" (place unchanged)|, words
      assert %{place: ^kept, time: ^time} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))
    end

    # An edit that gave only the place, and kept it, changes nothing at all.
    {:ok, %{trip: %{rev: rev}}} =
      Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: ctx.repo)

    only_place = [%{"op" => "edit", "n" => 2, "place" => "Doca Seca"}]
    assert {:ok, answer} = edit(ctx, "Varonne", only_place, %{"Doca Seca" => found([])})

    assert answer.text ==
             "Varonne · rev #{rev} · nothing changed · 1 day, 1 stop · 0 placed\n" <>
               ~s|No place found: [2] "Quay" (place unchanged).\n| <> @report

    assert [%{rows: []}] = answer.touched

    assert {:ok, %{trip: %{rev: ^rev}}} =
             Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: ctx.repo)

    assert {:ok, _answer} =
             edit(ctx, "Varonne", [%{"op" => "edit", "n" => 2, "place" => ""}], %{})

    assert %{place: nil} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))
  end

  test "another name is offered, saved unplaced, and its link places it in the next call", ctx do
    offered = place("Harbour Rooms", @quay, 9)

    assert {:ok, answer} =
             edit(
               ctx,
               "Varonne",
               [
                 %{"op" => "create", "near" => @town},
                 %{"op" => "add", "text" => "Check in", "day" => 1, "place" => "Check in"}
               ],
               %{"Check in" => found([offered])}
             )

    assert answer.text =~
             "Not placed, nearest by another name:\n" <>
               ~s([2] "Check in": "Harbour Rooms, 9 Rua Inventada, Varonne" · ) <>
               "https://maps.apple.com/place?place-id=I9"

    assert %{place: nil} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))
    assert [%{query: "Check in"}] = searched()

    assert {:ok, linked} =
             edit(
               ctx,
               "Varonne",
               [
                 %{
                   "op" => "edit",
                   "n" => 2,
                   "place" => "https://maps.apple.com/place?place-id=I9"
                 }
               ],
               %{}
             )

    assert linked.text =~ ~s([2] "Check in": "Harbour Rooms, 9 Rua Inventada, Varonne")
    assert searched() == []
    assert %{place: %{"name" => "Harbour Rooms"}} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))
  end

  test "a link no search returned refuses the whole call, before any lookup", ctx do
    {:ok, _answer} = edit(ctx, "Varonne", [%{"op" => "create"}], %{})

    assert {:error, reason} =
             edit(
               ctx,
               "Varonne",
               [
                 %{
                   "op" => "add",
                   "text" => "Tower",
                   "day" => 1,
                   "place" => "Torre de Vale Escuro"
                 },
                 %{
                   "op" => "add",
                   "text" => "Elsewhere",
                   "day" => 1,
                   "place" => "https://maps.apple.com/place?place-id=Inever"
                 }
               ],
               %{}
             )

    assert Registry.describe_error(reason) ==
             "No place search in this conversation returned that link; search again or give the " <>
               "place's name. Nothing in this call was changed (op 2)."

    assert searched() == []
    assert [%{kind: :day}] = rows!(ctx, "Varonne")
  end

  test "a call that would need a 41st lookup is refused before any runs", ctx do
    {:ok, _answer} = edit(ctx, "Varonne", [%{"op" => "create"}], %{})

    ops =
      for i <- 1..41,
          do: %{"op" => "add", "text" => "Stop #{i}", "day" => 1, "place" => "Place #{i}"}

    assert {:error, :too_many_lookups} = edit(ctx, "Varonne", ops, %{})

    assert Registry.describe_error(:too_many_lookups) ==
             "One call looks up at most 40 places; split the rest into another call."

    assert searched() == []
  end

  test "a call refused before its lookups spends none; one refused after keeps their records",
       ctx do
    {:ok, _answer} = edit(ctx, "Varonne", [%{"op" => "create"}], %{})
    {:ok, _answer} = edit(ctx, "Ostrel", [%{"op" => "create"}], %{})
    offered = place("Harbour Rooms", @quay, 9)

    assert {:error, {:op_failed, 1, {:no_row, 7}}} =
             edit(ctx, "Varonne", [%{"op" => "edit", "n" => 7, "place" => "Check in"}], %{})

    assert searched() == []

    # The dry run sees one trip, so a title the store refuses is refused there,
    # after the lookups: what they found still joins the conversation.
    assert {:error, {:op_failed, 2, {:title_taken, "Ostrel"}}} =
             edit(
               ctx,
               "Varonne",
               [
                 %{"op" => "add", "text" => "Check in", "day" => 1, "place" => "Check in"},
                 %{"op" => "rename", "text" => "Ostrel"}
               ],
               %{"Check in" => found([offered])}
             )

    assert {:ok, %{name: "Harbour Rooms"}} =
             ReplyBlocks.place_by_url(ctx.holder, @conversation, offered.source_url)
  end

  test "rate limited stops the lookups not started, each named, and the event counts them", ctx do
    session = "main-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :trip, :edit]], session_id: session)

    results = %{
      "Torre de Vale Escuro" => found([place("Torre de Vale Escuro", @tower, 1)]),
      "Cais Velho" => {:error, "rate_limited: slow down", %{backend: "brave"}},
      "Doca Seca" => found([]),
      "Ponte Nova" => found([])
    }

    ops =
      [%{"op" => "create", "near" => @town}] ++
        for {text, place} <- [
              {"Tower", "Torre de Vale Escuro"},
              {"Quay", "Cais Velho"},
              {"Dock", "Doca Seca"},
              {"Bridge", "Ponte Nova"}
            ],
            do: %{"op" => "add", "text" => text, "day" => 1, "place" => place}

    context = Map.merge(@owner, %{place_lookup: searching(results), session_id: session})
    opts = [repo: ctx.repo, now: @now, reply_blocks: ctx.holder, notifier: fn _c -> :ok end]

    assert {:ok, answer} = Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts)
    assert answer.text =~ " · 1 placed\n"
    assert answer.text =~ "Not looked up, the place search is rate limited: [3] \"Quay\""

    assert_receive {:telemetry, [:fermix, :trip, :edit], measurements, metadata}
    assert %{lookups: lookups, placed: 1, offered: 0, not_looked_up: not_looked_up} = measurements
    assert lookups >= 2 and measurements.not_found + not_looked_up == 3
    assert %{rate_limited: true, backend: nil, outcome: :ok} = metadata
  end

  # D10, from a live run: "Plan Saturday in Varonne: the fish market at 8:30"
  # made a trip with nowhere to search, and the fish market was placed in
  # another country. A lookup with no anchor offers, never places.
  describe "near" do
    @far %{
      name: "Atlanta Fish Market",
      location: %{latitude: 33.8404, longitude: -84.3797},
      address: "Pharr Road, Atlanta",
      apple_place_id: "I77",
      source_url: "https://maps.apple.com/place?place-id=I77"
    }

    test "a new trip with no near offers a far same-name place, places nothing, and says to give near",
         ctx do
      session = "main-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach([[:fermix, :trip, :edit]], session_id: session)

      ops = [
        %{"op" => "create", "starts_on" => "2031-06-07"},
        %{
          "op" => "add",
          "text" => "Fish market",
          "day" => 1,
          "time" => "08:30",
          "place" => "fish market"
        }
      ]

      context =
        Map.merge(@owner, %{
          place_lookup: searching(%{"fish market" => found([@far])}),
          session_id: session
        })

      opts = [repo: ctx.repo, now: @now, reply_blocks: ctx.holder, notifier: fn _c -> :ok end]
      assert {:ok, answer} = Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts)

      assert answer.text ==
               "Varonne · rev 1 · created; 1 stop added · 1 day, 1 stop · 0 placed\n" <>
                 "Not placed, this trip has no place to search near, so each is only the " <>
                 "first result anywhere: give its day a near (a town and its country) and the " <>
                 "place again, or its link if that is the place meant:\n" <>
                 ~s([2] "Fish market": "Atlanta Fish Market, Pharr Road, Atlanta" · ) <>
                 "https://maps.apple.com/place?place-id=I77\n" <> @report

      assert searched() == [%{query: "fish market", count: 5}]
      assert %{place: nil} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))

      assert {:ok, %{name: "Atlanta Fish Market"}} =
               ReplyBlocks.place_by_url(ctx.holder, @conversation, @far.source_url)

      assert_receive {:telemetry, [:fermix, :trip, :edit], %{placed: 0, offered: 1}, _metadata}
    end

    test "a two-city trip: a day's near wins over the trip's, so its stop is looked up and placed there",
         ctx do
      lisbon = "Lisbon, Portugal"
      porto = "Porto, Portugal"
      lift = place("Elevador do Largo", @quay, 4)
      bookshop = place("Livraria das Pedras", @tower, 5)

      ops = [
        %{"op" => "create", "days" => 3, "near" => lisbon},
        %{"op" => "day", "day" => 3, "near" => porto},
        %{"op" => "add", "text" => "Lift", "day" => 1, "place" => "Elevador do Largo"},
        %{"op" => "add", "text" => "Bookshop", "day" => 3, "place" => "Livraria das Pedras"}
      ]

      results = %{
        "Elevador do Largo" => found([lift]),
        "Livraria das Pedras" => found([bookshop])
      }

      assert {:ok, answer} = edit(ctx, "Two cities", ops, results)
      assert answer.text =~ " · 2 placed\n"

      assert searched() == [
               %{query: "Elevador do Largo", count: 5, anchor: {:location, lisbon}},
               %{query: "Livraria das Pedras", count: 5, anchor: {:location, porto}}
             ]

      assert {:ok, %{trip: trip, rows: rows}} =
               Repo.trips_call({:read_trip, "default", "main", "Two cities"}, server: ctx.repo)

      assert trip.near == lisbon
      assert [nil, nil, ^porto] = for(%{kind: :day} = day <- rows, do: day.near)

      assert %{place: %{"name" => "Livraria das Pedras"}} =
               Enum.find(rows, &(&1.text == "Bookshop"))
    end

    test "a near the place search does not find is no anchor: offered, not placed, and said",
         ctx do
      test = self()

      search = fn request ->
        send(test, {:searched, request})

        case request do
          %{anchor: {:location, "Varonne"}} ->
            {:error, "invalid_location: Apple Maps found no place by that name", %{}}

          %{query: "fish market"} ->
            found([@far])
        end
      end

      ops = [
        %{"op" => "create", "near" => "Varonne"},
        %{"op" => "add", "text" => "Fish market", "day" => 1, "place" => "fish market"}
      ]

      context = Map.put(@owner, :place_lookup, search)
      opts = [repo: ctx.repo, now: @now, reply_blocks: ctx.holder, notifier: fn _c -> :ok end]
      assert {:ok, answer} = Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts)

      assert answer.text =~
               ~s(Not placed, the place search found no place "Varonne" to search near, so ) <>
                 "each is only the first result anywhere: give its day a near it can find (a " <>
                 "town and its country) and the place again, or its link if that is the place " <>
                 "meant:\n" <>
                 ~s([2] "Fish market": "Atlanta Fish Market, Pharr Road, Atlanta" · )

      assert searched() == [
               %{query: "fish market", count: 5, anchor: {:location, "Varonne"}},
               %{query: "fish market", count: 5}
             ]

      assert %{place: nil} = Enum.find(rows!(ctx, "Varonne"), &(&1.n == 2))
    end
  end
end
