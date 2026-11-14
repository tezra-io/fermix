defmodule FermixCore.Trips.WaitingTest do
  # M89 D13 B: a stop given a place by words that could not be looked up for
  # a reason that heals by waiting keeps those words beside it, and the trip
  # placer looks it up again. Pure: which outcomes wait, which ops end a
  # wait, where a later lookup searches, and what each answer does to a wait.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Placing
  alias FermixCore.Trips.Shape
  alias FermixCore.Trips.Waiting

  # Every name, point and id here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @quay %{latitude: 41.1408, longitude: -8.6142}
  @record %{name: "Cais Velho", location: @quay, address: "2 Rua Inventada, Varonne"}

  @healing [:computer_away, :computer_timed_out, :computer_busy, :rate_limited, :deadline]
  @not_healing [
    :plan_excludes_place_search,
    :computer_off,
    :computer_refused,
    :not_found,
    :no_location,
    {:no_backend, "auth_failed: missing Brave API key"},
    {:failed, "network: unreachable"},
    {:unknown_near, "Varonne"}
  ]

  defp stop(id, n, fields \\ %{}) do
    Map.merge(
      %{
        id: id,
        trip_id: "tr_aaaaaaaaaa",
        n: n,
        kind: :stop,
        text: "Stop #{n}",
        note: nil,
        time: nil,
        duration: nil,
        fixed: false,
        timezone: nil,
        near: nil,
        place: nil,
        position: n * 1_024,
        stamped: false,
        made_via: "chat",
        created_at: @now,
        updated_at: @now,
        removed_at: nil,
        removed_with: nil,
        dirty: nil
      },
      fields
    )
  end

  defp day(id, n, near \\ nil), do: stop(id, n, %{kind: :day, text: "", near: near})

  defp placed(%{latitude: latitude, longitude: longitude}),
    do: %{
      "name" => "Somewhere",
      "location" => %{"latitude" => latitude, "longitude" => longitude}
    }

  defp wait(row_id, fields \\ %{}) do
    Map.merge(
      %{
        row_id: row_id,
        trip_id: "tr_aaaaaaaaaa",
        owner_id: "default",
        agent_id: "main",
        words: "Cais Velho",
        reason: :computer_away,
        since: @now,
        tries: 0
      },
      fields
    )
  end

  defp shaped(ops) do
    {:ok, call} = Shape.call(%{"trip" => "Varonne", "ops" => ops})
    call
  end

  test "only the reasons that heal by waiting wait" do
    assert Waiting.reasons() == @healing
    for why <- @healing, do: assert(Waiting.heals?(why), inspect(why))
    for why <- @not_healing, do: refute(Waiting.heals?(why), inspect(why))
  end

  test "a call leaves waiting only the stops its lookups could not look up for a healing reason" do
    requests = [
      %{ref: 2, place: "Cais Velho", day: 1},
      %{ref: 3, place: "Doca Seca", day: 1},
      %{ref: 4, place: "Ponte Nova", day: 2},
      %{ref: 5, place: "Torre", day: 2},
      %{ref: 6, place: "Mercado", day: 2}
    ]

    outcomes = [
      {2, {:none, :computer_away}},
      {3, {:none, :plan_excludes_place_search}},
      {4, {:offered, @record}},
      {5, {:placed, @record}},
      {6, {:none, :deadline}}
    ]

    assert Waiting.asked(requests, outcomes) == [
             %{ref: 2, words: "Cais Velho", reason: :computer_away},
             %{ref: 6, words: "Mercado", reason: :deadline}
           ]
  end

  describe "what ends a wait" do
    setup do
      rows = [day("ti_d1", 1), stop("ti_s2", 2), stop("ti_s3", 3), stop("ti_s4", 4)]
      %{rows: rows, result: %{trip: %{id: "tr_aaaaaaaaaa", removed_at: nil}, rows: rows}}
    end

    test "an edit that gives words or a place, from the model or a device; never time or a note",
         %{rows: rows, result: result} do
      call =
        shaped([
          %{"op" => "edit", "n" => 2, "text" => "Quay at noon"},
          %{"op" => "edit", "n" => 3, "place" => ""},
          %{"op" => "edit", "n" => 4, "time" => "10:00", "note" => "Early"}
        ])

      assert Enum.sort(Waiting.cleared(call, rows, result, [])) == ["ti_s2", "ti_s3"]

      device = %{trip: "tr_aaaaaaaaaa", ops: [edit_op({:id, "ti_s4"}, place: placed(@quay))]}
      assert Waiting.cleared(device, rows, result, []) == ["ti_s4"]

      moved = shaped([%{"op" => "move", "n" => 2, "day" => 1}])
      assert Waiting.cleared(moved, rows, result, []) == []
    end

    # The blocker: words that placed nothing leave the placed call's op at
    # `place: :keep`, so what ends the wait is read from the call as given.
    test "an edit that gave place words or a link ends the wait, even when they placed nothing",
         %{rows: rows, result: result} do
      given = shaped([%{"op" => "edit", "n" => 2, "place" => "Tasca do Zé"}])
      {placed, _outcomes} = Placing.placed_call(given, [{1, {:none, :not_found}}])
      assert [%{place: :keep}] = placed.ops

      assert Waiting.given(given) == [1]
      assert Waiting.cleared(placed, rows, result, Waiting.given(given)) == ["ti_s2"]

      link = shaped([%{"op" => "edit", "n" => 3, "place" => "https://maps.apple.com/place?x=1"}])
      assert Waiting.given(link) == [1]

      timed = shaped([%{"op" => "edit", "n" => 4, "time" => "10:00"}])
      assert Waiting.given(timed) == []
      assert Waiting.cleared(timed, rows, result, []) == []
    end

    test "a stop or a day removed, and every wait of a removed trip", %{rows: rows} do
      [d1, s2 | _rest] = rows
      left = %{trip: %{id: "tr_aaaaaaaaaa", removed_at: nil}, rows: [d1, s2]}
      call = shaped([%{"op" => "remove", "n" => 3}, %{"op" => "remove", "n" => 4}])
      assert Enum.sort(Waiting.cleared(call, rows, left, [])) == ["ti_s3", "ti_s4"]

      gone = %{trip: %{id: "tr_aaaaaaaaaa", removed_at: @now}, rows: rows}
      assert Waiting.cleared(shaped([%{"op" => "remove_trip"}]), rows, gone, []) == :all
    end
  end

  test "a removed trip saves no wait, whatever its call asked" do
    rows = [day("ti_d1", 1), stop("ti_s2", 2, %{dirty: :new})]
    call = shaped([%{"op" => "add", "text" => "Quay", "day" => 1}, %{"op" => "remove_trip"}])
    removed = %{trip: %{id: "tr_aaaaaaaaaa", removed_at: @now}, rows: rows, removed_rows: []}
    asked = [%{ref: 1, words: "Cais Velho", reason: :computer_away}]

    assert Waiting.saved(call, removed, asked) == []

    live = %{removed | trip: %{id: "tr_aaaaaaaaaa", removed_at: nil}}

    assert Waiting.saved(call, live, asked) == [
             %{row_id: "ti_s2", words: "Cais Velho", reason: :computer_away}
           ]
  end

  describe "where a later lookup searches" do
    test "each waiting stop on its day as the trip now stands; its own place anchors nothing" do
      trip = %{near: nil}

      rows = [
        day("ti_d1", 1),
        stop("ti_s2", 2, %{place: placed(@quay)}),
        stop("ti_s3", 3, %{place: placed(%{latitude: 41.2, longitude: -8.6})}),
        day("ti_d4", 4, "Porto, Portugal"),
        stop("ti_s5", 5)
      ]

      waits = [wait("ti_s5", %{words: "Ribeira"}), wait("ti_s3"), wait("ti_gone")]

      assert {requests, anchors} = Waiting.requests(trip, rows, waits)

      assert requests == [
               %{ref: "ti_s3", place: "Cais Velho", day: 1},
               %{ref: "ti_s5", place: "Ribeira", day: 2}
             ]

      assert anchors == %{
               placed: %{1 => [@quay]},
               day_near: %{2 => "Porto, Portugal"},
               trip_near: nil
             }
    end
  end

  describe "what an answer does to a wait" do
    defp settled(waits, outcomes, sent \\ :all) do
      sent = if sent == :all, do: Enum.map(outcomes, &elem(&1, 0)), else: sent
      Waiting.settle(waits, %{outcomes: outcomes, sent: sent}, @now)
    end

    test "placed by the name rule is placed; another name, none found or a refusal ends it" do
      waits = [wait("ti_s2"), wait("ti_s3"), wait("ti_s4"), wait("ti_s5"), wait("ti_s6")]

      outcomes = [
        {"ti_s2", {:placed, @record}},
        {"ti_s3", {:offered, %{@record | name: "Harbour Rooms"}}},
        {"ti_s4", {:none, :not_found}},
        {"ti_s5", {:none, :computer_off}},
        {"ti_s6", {:offered, @record, :no_anchor}}
      ]

      assert [placed | stopped] = settled(waits, outcomes)
      assert %{row_id: "ti_s2", action: {:place, %{"name" => "Cais Velho"}}} = placed
      assert Enum.map(stopped, & &1.action) == List.duplicate({:stop, :answered}, 4)
    end

    # Only a lookup that reached the place search and failed with a reason
    # that heals spends a try, and each retry waits longer: 30 min after the
    # first, 3 h after the second; the third ends the wait.
    test "a healing answer to a lookup that was sent spends a try and waits longer each time" do
      for {tries, action} <- [
            {0, {:wait, :rate_limited, 1, DateTime.add(@now, 30 * 60)}},
            {1, {:wait, :rate_limited, 2, DateTime.add(@now, 3 * 3_600)}},
            {2, {:stop, :gave_up}}
          ] do
        assert [%{action: ^action}] =
                 settled([wait("ti_s2", %{tries: tries})], [{"ti_s2", {:none, :rate_limited}}])
      end

      assert Waiting.max_tries() == 3
    end

    test "a healing answer to a lookup that was never sent spends nothing and stays due" do
      for tries <- [0, 2] do
        assert [%{action: {:wait, :computer_away, ^tries, nil}}] =
                 settled(
                   [wait("ti_s2", %{tries: tries})],
                   [{"ti_s2", {:none, :computer_away}}],
                   []
                 )
      end
    end

    test "a record too large to keep ends the wait; a stop not looked up is left alone" do
      big = Map.put(@record, :apple_place_id, String.duplicate("I", 300))

      assert [%{action: {:stop, :answered}}] =
               settled([wait("ti_s2"), wait("ti_s3")], [{"ti_s2", {:placed, big}}])
    end

    test "every result keeps the wait's words and since, which the store checks before it writes" do
      since = ~U[2031-06-01 09:00:00Z]
      waits = [wait("ti_s2", %{since: since, words: "Doca"})]

      assert [%{row_id: "ti_s2", words: "Doca", since: ^since}] =
               settled(waits, [{"ti_s2", {:none, :not_found}}])
    end
  end

  test "a wait older than seven days stops waiting" do
    assert Waiting.cutoff(@now) == ~U[2031-05-26 14:00:00Z]
  end

  defp edit_op(ref, fields) do
    Map.merge(
      %{
        op: :edit,
        n: ref,
        text: nil,
        time: :keep,
        duration: :keep,
        fixed: :keep,
        note: :keep,
        place: :keep
      },
      Map.new(fields)
    )
  end
end
