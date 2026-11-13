defmodule FermixCore.Trips.OpsTest do
  # M89 §04, §05: what each op of a trip_edit call, and each op a device
  # sends, does to a trip; pure, over the rows a transaction would load, the
  # store kept here as the test's own fold of each call's result.
  use ExUnit.Case, async: true

  alias FermixCore.Kept.Ids
  alias FermixCore.Trips.Geo
  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Place
  alias FermixCore.Trips.Shape
  alias FermixCore.Trips.Wire

  # Every title, stop, place and date here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @edit %{now: @now, outside?: false, made_via: "chat"}
  @device %{now: @now, outside?: false, made_via: "mac"}

  @inn %{"name" => "Marisco Inn", "location" => %{"latitude" => 41.2031, "longitude" => -8.4102}}
  @mill %{"name" => "Old Mill", "location" => %{"latitude" => 41.2075, "longitude" => -8.4021}}
  @quay %{"name" => "North Quay", "location" => %{"latitude" => 41.1702, "longitude" => -8.6203}}

  # --- the test's store ------------------------------------------------------

  defp empty, do: %{trips: [], rows: %{}, removed: %{}}

  defp call(store, trip, ops, edit \\ @edit) do
    {:ok, shaped} = Shape.call(%{"trip" => trip, "ops" => ops})
    run(store, shaped, edit)
  end

  defp call!(store, trip, ops, edit \\ @edit) do
    assert {:ok, result, store} = call(store, trip, ops, edit)
    {result, store}
  end

  defp device(store, params) do
    {:ok, shaped} = Shape.device_change(params)
    run(store, shaped, @device)
  end

  defp device!(store, params) do
    assert {:ok, result, store} = device(store, params)
    {result, store}
  end

  defp run(store, shaped, edit) do
    id = Ops.referenced(store.trips, shaped)

    loaded = %{
      trips: store.trips,
      rows: Map.get(store.rows, id, []),
      removed: Map.get(store.removed, id, []),
      kept_from: DateTime.add(edit.now, -30 * 86_400, :second)
    }

    case Ops.apply(loaded, shaped, edit) do
      {:ok, result} -> {:ok, result, fold(store, result)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The result written back as the store would write it.
  defp fold(store, %{trip: trip} = result) do
    restored = for %{dirty: :restored, id: id} <- result.rows, do: id
    gone = for row <- result.removed_rows, row.dirty != :new, do: %{row | dirty: nil}
    kept = store.removed |> Map.get(trip.id, []) |> Enum.reject(&(&1.id in restored))
    others = Enum.reject(store.trips, &(&1.id == trip.id))

    %{
      trips: [%{trip | created?: false, restored?: false} | others],
      rows: Map.put(store.rows, trip.id, Enum.map(result.rows, &%{&1 | dirty: nil})),
      removed: Map.put(store.removed, trip.id, kept ++ gone)
    }
  end

  defp trip(store, title), do: Enum.find(store.trips, &(&1.title == title and !&1.removed_at))
  defp rows(store, title), do: Map.fetch!(store.rows, trip(store, title).id)
  defp texts(rows), do: Enum.map(rows, & &1.text)
  defp day_rows(store, title), do: store |> rows(title) |> Enum.filter(&(&1.kind == :day))
  defp stop(store, title, text), do: store |> rows(title) |> Enum.find(&(&1.text == text))

  # Each day as its name, its date and its stops' words.
  defp outline(store, title) do
    starts_on = trip(store, title).starts_on

    for %{row: day, stops: stops, position: k} <- Ops.days(rows(store, title)),
        do: {day.text, Ops.day_date(starts_on, k), texts(stops)}
  end

  defp three_days(starts_on) do
    {_result, store} =
      call!(empty(), "Varonne", [
        %{"op" => "create", "days" => 3, "starts_on" => starts_on},
        %{"op" => "day", "day" => 1, "text" => "Harbour"},
        %{"op" => "add", "text" => "Fish market", "day" => 1},
        %{"op" => "add", "text" => "Ferry", "day" => 1},
        %{"op" => "day", "day" => 2, "text" => "Old town"},
        %{"op" => "add", "text" => "Clock tower", "day" => 2},
        %{"op" => "day", "day" => 3, "text" => "Hills"},
        %{"op" => "add", "text" => "Vineyard", "day" => 3}
      ])

    store
  end

  defp placed(store, trip_id, day_id, text, place) do
    op = %{"op" => "add", "text" => text, "day_id" => day_id}
    op = if place, do: Map.put(op, "place", place), else: op
    device!(store, %{"trip_id" => trip_id, "op" => op})
  end

  # --- days and stops --------------------------------------------------------

  test "a trip of one day: create makes one empty day and a stop lands in it" do
    {result, store} =
      call!(empty(), "Varonne", [
        %{"op" => "create"},
        %{"op" => "add", "text" => "Breakfast at Ostrel", "day" => 1, "time" => "08:30"}
      ])

    assert %{title: "Varonne", rev: 1, next_n: 3, starts_on: nil, id: id} = result.trip
    assert Ids.valid?(id, "tr_")

    assert [
             %{kind: :day, n: 1, text: "", id: day_id},
             %{kind: :stop, n: 2, text: "Breakfast at Ostrel", time: "08:30", id: stop_id}
           ] = result.rows

    assert Ids.valid?(day_id, "ti_") and Ids.valid?(stop_id, "ti_")
    assert outline(store, "Varonne") == [{"", nil, ["Breakfast at Ostrel"]}]
  end

  test "a trip of three days, and one of sixty made by an add that names day 60" do
    {_result, store} =
      call!(empty(), "Ostrel Coast", [
        %{"op" => "create", "days" => 3, "starts_on" => "2031-07-04"}
      ])

    assert outline(store, "Ostrel Coast") == [
             {"", ~D[2031-07-04], []},
             {"", ~D[2031-07-05], []},
             {"", ~D[2031-07-06], []}
           ]

    {result, store} =
      call!(store, "Long Way", [
        %{"op" => "create", "starts_on" => "2031-07-01"},
        %{"op" => "add", "text" => "Arrive at Pellmoor", "day" => 60}
      ])

    days = outline(store, "Long Way")
    assert length(days) == 60
    assert List.last(days) == {"", ~D[2031-08-29], ["Arrive at Pellmoor"]}
    assert days |> Enum.take(59) |> Enum.all?(fn {_name, _date, stops} -> stops == [] end)
    assert result.made == stop(store, "Long Way", "Arrive at Pellmoor").id
  end

  test "repeated visits to one place: two stops share one record, each its own number" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create", "days" => 2}])
    %{id: trip_id} = trip(store, "Varonne")
    [first, second] = day_rows(store, "Varonne")

    {_result, store} = placed(store, trip_id, first.id, "Back to the inn", @inn)
    {_result, store} = placed(store, trip_id, second.id, "Breakfast at the inn", @inn)

    [one, two] = store |> rows("Varonne") |> Enum.filter(&(&1.kind == :stop))
    assert {:ok, one.place} == Place.cut(@inn)
    assert one.place == two.place
    assert {one.n, two.n} == {3, 4}
    assert one.id != two.id
  end

  test "a day moved with its stops keeps their order, lands at its position, and every date follows" do
    store = three_days("2031-03-10")
    [harbour, old_town, _hills] = day_rows(store, "Varonne")
    assert harbour.n == 1

    {result, store} = call!(store, "Varonne", [%{"op" => "move", "n" => 1, "day" => 3}])

    assert outline(store, "Varonne") == [
             {"Old town", ~D[2031-03-10], ["Clock tower"]},
             {"Hills", ~D[2031-03-11], ["Vineyard"]},
             {"Harbour", ~D[2031-03-12], ["Fish market", "Ferry"]}
           ]

    assert result.touched_rows == [harbour.id]
    %{id: trip_id} = trip(store, "Varonne")

    # A device moves a day after another day's block, or first with neither.
    after_old_town = %{"op" => "move", "row_id" => harbour.id, "after_id" => old_town.id}
    {_result, store} = device!(store, %{"trip_id" => trip_id, "op" => after_old_town})

    assert store |> outline("Varonne") |> Enum.map(&elem(&1, 0)) == [
             "Old town",
             "Harbour",
             "Hills"
           ]

    # With day_id, before that day (PROTOCOL.md's move row, R2#9).
    [_old_town, _harbour, hills] = day_rows(store, "Varonne")
    before_hills = %{"op" => "move", "row_id" => old_town.id, "day_id" => hills.id}
    {_result, store} = device!(store, %{"trip_id" => trip_id, "op" => before_hills})

    assert store |> outline("Varonne") |> Enum.map(&elem(&1, 0)) == [
             "Harbour",
             "Old town",
             "Hills"
           ]

    first = %{"op" => "move", "row_id" => harbour.id}
    {_result, store} = device!(store, %{"trip_id" => trip_id, "op" => first})

    assert outline(store, "Varonne") == [
             {"Harbour", ~D[2031-03-10], ["Fish market", "Ferry"]},
             {"Old town", ~D[2031-03-11], ["Clock tower"]},
             {"Hills", ~D[2031-03-12], ["Vineyard"]}
           ]
  end

  test "a stop moves to the end of a day or after a stop, and never past the last day" do
    store = three_days("2031-03-10")
    ferry = stop(store, "Varonne", "Ferry")
    tower = stop(store, "Varonne", "Clock tower")

    {_result, store} = call!(store, "Varonne", [%{"op" => "move", "n" => ferry.n, "day" => 3}])
    {_result, store} = call!(store, "Varonne", [%{"op" => "move", "n" => tower.n, "after" => 1}])

    assert Enum.map(outline(store, "Varonne"), &elem(&1, 2)) == [
             ["Clock tower", "Fish market"],
             [],
             ["Vineyard", "Ferry"]
           ]

    assert {:error, {:op_failed, 1, {:no_day, 4, 3}}} =
             call(store, "Varonne", [%{"op" => "move", "n" => ferry.n, "day" => 4}])

    assert {:error, {:op_failed, 1, {:after_self, n}}} =
             call(store, "Varonne", [%{"op" => "move", "n" => ferry.n, "after" => ferry.n}])

    assert n == ferry.n
  end

  test "dates follow position across 31 Jan to 1 Feb, 28 Feb to 1 Mar in a leap year, and 31 Dec to 1 Jan" do
    cases = [
      {"2031-01-31", 2, [~D[2031-01-31], ~D[2031-02-01]]},
      {"2032-02-28", 3, [~D[2032-02-28], ~D[2032-02-29], ~D[2032-03-01]]},
      {"2031-12-31", 2, [~D[2031-12-31], ~D[2032-01-01]]}
    ]

    for {starts_on, days, dates} <- cases do
      {_result, store} =
        call!(empty(), "Varonne", [
          %{"op" => "create", "days" => days, "starts_on" => starts_on}
        ])

      assert Enum.map(outline(store, "Varonne"), &elem(&1, 1)) == dates
    end
  end

  test "a trip with no start has no dates; dates sets one and an empty one takes it away" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create", "days" => 2}])
    assert Enum.map(outline(store, "Varonne"), &elem(&1, 1)) == [nil, nil]

    {_result, store} = call!(store, "Varonne", [%{"op" => "dates", "starts_on" => "2031-05-01"}])
    assert Enum.map(outline(store, "Varonne"), &elem(&1, 1)) == [~D[2031-05-01], ~D[2031-05-02]]

    {_result, store} = call!(store, "Varonne", [%{"op" => "dates", "starts_on" => ""}])
    assert trip(store, "Varonne").starts_on == nil
    assert Enum.map(outline(store, "Varonne"), &elem(&1, 1)) == [nil, nil]
  end

  test "two zones: a day names its own, a stop keeps its wall clock" do
    {_result, store} =
      call!(empty(), "Varonne", [
        %{"op" => "create", "days" => 2, "timezone" => "Europe/Lisbon"},
        %{"op" => "day", "day" => 2, "timezone" => "Atlantic/Azores"},
        %{"op" => "add", "text" => "Whale watching", "day" => 2, "time" => "09:15"}
      ])

    assert trip(store, "Varonne").timezone == "Europe/Lisbon"
    assert [%{timezone: nil}, %{timezone: "Atlantic/Azores"}] = day_rows(store, "Varonne")
    assert %{time: "09:15", timezone: nil} = stop(store, "Varonne", "Whale watching")

    {_result, store} =
      call!(store, "Varonne", [%{"op" => "day", "day" => 2, "timezone" => ""}])

    assert [%{timezone: nil}, %{timezone: nil}] = day_rows(store, "Varonne")
    assert %{time: "09:15"} = stop(store, "Varonne", "Whale watching")
  end

  test "numbers only go up" do
    {_result, store} =
      call!(empty(), "Varonne", [
        %{"op" => "create"},
        %{"op" => "add", "text" => "Fish market", "day" => 1},
        %{"op" => "add", "text" => "Ferry", "day" => 1}
      ])

    {_result, store} = call!(store, "Varonne", [%{"op" => "remove", "n" => 3}])

    {result, store} =
      call!(store, "Varonne", [
        %{"op" => "add", "text" => "Clock tower", "day" => 1},
        %{"op" => "day", "day" => 2, "text" => "Hills"}
      ])

    assert Enum.map(rows(store, "Varonne"), &{&1.n, &1.text}) == [
             {1, ""},
             {2, "Fish market"},
             {4, "Clock tower"},
             {5, "Hills"}
           ]

    assert result.trip.next_n == 6
  end

  # --- caps ------------------------------------------------------------------

  test "the row cap: the 1,001st row is refused with the title and the call changes nothing" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create"}])
    add = fn i -> %{"op" => "add", "text" => "Stop #{i}", "day" => 1} end

    store =
      1..999
      |> Enum.chunk_every(100)
      |> Enum.reduce(store, fn chunk, acc ->
        {_result, acc} = call!(acc, "Varonne", Enum.map(chunk, add))
        acc
      end)

    assert length(rows(store, "Varonne")) == Ops.max_rows()

    assert call(store, "Varonne", [add.(1_000)]) ==
             {:error, {:op_failed, 1, {:trip_full, "Varonne"}}}

    assert {:error, {:op_failed, 2, {:trip_full, "Varonne"}}} =
             call(store, "Varonne", [
               %{"op" => "edit", "n" => 2, "text" => "Renamed"},
               %{"op" => "day", "day" => 2}
             ])
  end

  test "the 31st live trip is refused; a removed one frees its slot and title" do
    store =
      Enum.reduce(1..Ops.max_trips(), empty(), fn i, acc ->
        {_result, acc} = call!(acc, "Trip #{i}", [%{"op" => "create"}])
        acc
      end)

    assert call(store, "Trip 31", [%{"op" => "create"}]) ==
             {:error, {:op_failed, 1, :too_many_trips}}

    %{id: old_id} = trip(store, "Trip 7")
    {_result, store} = call!(store, "Trip 7", [%{"op" => "remove_trip"}])
    {result, _store} = call!(store, "Trip 7", [%{"op" => "create"}])
    assert result.trip.id != old_id
  end

  test "a live title is unique case-blind on create and rename" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create"}])
    {_result, store} = call!(store, "Élan Peaks", [%{"op" => "create"}])
    {_result, store} = call!(store, "Ostrel", [%{"op" => "create"}])

    assert call(store, " VARONNE ", [%{"op" => "create"}]) ==
             {:error, {:op_failed, 1, {:title_taken, "VARONNE"}}}

    # Folded as Unicode, where the store's index folds ASCII only (C17).
    assert call(store, "ÉLAN PEAKS", [%{"op" => "create"}]) ==
             {:error, {:op_failed, 1, {:title_taken, "ÉLAN PEAKS"}}}

    assert call(store, "Ostrel", [%{"op" => "rename", "text" => "varonne"}]) ==
             {:error, {:op_failed, 1, {:title_taken, "varonne"}}}

    {_result, store} = call!(store, "Varonne", [%{"op" => "rename", "text" => "VARONNE"}])
    assert trip(store, "VARONNE")
  end

  # R2#8: "Café" written as é or as e and a combining accent is one title.
  test "a title is kept in Unicode NFC, so two spellings of one title cannot both live" do
    nfc = "Café Varonne"
    nfd = "Café Varonne"

    {result, store} = call!(empty(), nfd, [%{"op" => "create"}])
    assert result.trip.title == nfc

    assert call(store, nfc, [%{"op" => "create"}]) ==
             {:error, {:op_failed, 1, {:title_taken, nfc}}}

    {_result, store} = call!(store, "Ostrel", [%{"op" => "create"}])

    assert call(store, "Ostrel", [%{"op" => "rename", "text" => "CAFÉ VARONNE"}]) ==
             {:error, {:op_failed, 1, {:title_taken, "CAFÉ VARONNE"}}}

    # Named either way, and a title kept before titles were NFC is one too.
    assert {:ok, %{trip: %{title: ^nfc}}, _store} =
             call(store, nfd, [%{"op" => "dates", "starts_on" => "2031-05-01"}])

    kept_before = %{
      store
      | trips: Enum.map(store.trips, &if(&1.title == nfc, do: %{&1 | title: nfd}, else: &1))
    }

    assert call(kept_before, nfc, [%{"op" => "create"}]) ==
             {:error, {:op_failed, 1, {:title_taken, nfc}}}

    {result, _store} = device!(store, %{"op" => %{"op" => "create", "title" => "Sé Nová"}})
    assert result.trip.title == "Sé Nová"
  end

  test "a refused op anywhere refuses the whole call, naming the op" do
    store = three_days(nil)

    assert call(store, "Varonne", [
             %{"op" => "add", "text" => "Night market", "day" => 2},
             %{"op" => "edit", "n" => 4, "text" => "Fish auction"},
             %{"op" => "remove", "n" => 99}
           ]) == {:error, {:op_failed, 3, {:no_row, 99}}}

    assert call(store, "Nowhere", [%{"op" => "rename", "text" => "Somewhere"}]) ==
             {:error, {:no_trip, "Nowhere", ["Varonne"]}}

    assert call(store, "Varonne", [%{"op" => "edit", "n" => 1, "text" => "Port"}]) ==
             {:error, {:op_failed, 1, {:not_a_stop, 1}}}

    assert call(store, "Varonne", [%{"op" => "remove_trip"}, %{"op" => "rename", "text" => "X"}]) ==
             {:error, {:op_failed, 2, :trip_removed}}
  end

  test "a trip whose wire form would pass 768 KiB is refused with its own sentence" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create"}])

    big = fn i ->
      %{
        "op" => "add",
        "text" => "#{i} " <> String.duplicate("w", 190),
        "note" => String.duplicate("n", 1_000),
        "day" => 1
      }
    end

    {refusal, store} =
      Enum.reduce_while(1..10, {nil, store}, fn batch, {nil, acc} ->
        ops = Enum.map((batch * 100 - 99)..(batch * 100), big)

        case call(acc, "Varonne", ops) do
          {:ok, _result, acc} -> {:cont, {nil, acc}}
          {:error, reason} -> {:halt, {reason, acc}}
        end
      end)

    assert refusal == {:trip_too_large, "Varonne"}
    assert length(rows(store, "Varonne")) < Ops.max_rows()
    assert Wire.bytes(trip(store, "Varonne"), rows(store, "Varonne"), []) <= Ops.max_wire_bytes()
  end

  # R2#3: a pull with the removed rows carries them for 30 days, so the guard
  # counts them; rows removed longer ago are swept by the call and do not.
  test "the 768 KiB guard counts the removed rows a pull carries while they are kept" do
    # A stop of about 3.7 KB: each character three bytes on the wire.
    big = fn i ->
      %{
        "op" => "add",
        "text" => "#{i} " <> String.duplicate("€", 190),
        "note" => String.duplicate("€", 1_000),
        "day" => 1
      }
    end

    add = fn store, from, edit ->
      call(store, "Varonne", Enum.map(from..(from + 19), big), edit)
    end

    earlier = %{@edit | now: DateTime.add(@now, -31 * 86_400, :second)}

    for {removed_on, refused?} <- [{@edit, true}, {earlier, false}] do
      {_result, store} = call!(empty(), "Varonne", [%{"op" => "create"}], removed_on)

      store =
        Enum.reduce(0..4, store, fn k, acc ->
          assert {:ok, _result, acc} = add.(acc, k * 20 + 1, removed_on)
          acc
        end)

      removes = for n <- 2..101, do: %{"op" => "remove", "n" => n}
      {_result, store} = call!(store, "Varonne", removes, removed_on)
      assert [%{kind: :day}] = rows(store, "Varonne")

      # About 370 KB removed: 120 more live stops pass the cap only with them.
      store =
        Enum.reduce(0..4, store, fn k, acc ->
          assert {:ok, _result, acc} = add.(acc, 200 + k * 20, @edit)
          acc
        end)

      sixth = add.(store, 300, @edit)
      assert match?({:error, {:trip_too_large, "Varonne"}}, sixth) == refused?

      # Live rows alone are far inside the cap: the old measure took the call.
      assert {:ok, _result, _store} = add.(%{store | removed: %{}}, 300, @edit)
    end
  end

  # A client reads a line of at most 1 MiB (M89 §06); the engine refuses past
  # 768 KiB so that what a call that never grows a trip adds stays inside it.
  @line_bytes 1_048_576
  # As the store stamps a row, to the microsecond.
  @stamped_now ~U[2031-06-02 14:00:00.000000Z]

  # A stop of about 900 bytes on the wire.
  defp big_stop(i),
    do: %{
      "op" => "add",
      "text" => "#{i} " <> String.duplicate("w", 190),
      "note" => String.duplicate("n", 650),
      "day" => 2
    }

  # A trip of two days, its stops on Day 2, filled until one more stop would
  # pass 768 KiB: a hundred at a time, then ten, then one, each until refused.
  defp at_cap do
    edit = %{@edit | now: @stamped_now}
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create", "days" => 2}], edit)
    {store, count} = Enum.reduce([100, 10, 1], {store, 0}, &fill(&2, &1, edit))
    assert count < Ops.max_rows() - 2
    {store, count, edit}
  end

  defp fill({store, count}, size, edit) do
    ops = for i <- (count + 1)..(count + size), do: big_stop(i)

    case call(store, "Varonne", ops, edit) do
      {:ok, _result, store} -> fill({store, count + size}, size, edit)
      {:error, {:trip_too_large, "Varonne"}} -> {store, count}
    end
  end

  # The `trip` push of a trip pulled with its removed rows, as a line.
  defp push_line(store) do
    trip = trip(store, "Varonne")
    object = Wire.trip(trip, rows(store, "Varonne"))
    removed = Wire.removed(Map.fetch!(store.removed, trip.id))

    payload = %{
      "type" => "trip",
      "profile_id" => "main",
      "trip" => Map.put(object, "removed", removed)
    }

    byte_size(Jason.encode!(payload)) + 1
  end

  # Follow-up to R2#3: only a call that can grow a trip is measured, so one at
  # the cap can always shrink.
  test "a trip at the cap refuses an add, and still takes a remove, a move and its removal" do
    {store, count, edit} = at_cap()

    assert {:error, {:trip_too_large, "Varonne"}} =
             call(store, "Varonne", [big_stop(count + 1)], edit)

    removes = for n <- 3..102, do: %{"op" => "remove", "n" => n}
    {_result, store} = call!(store, "Varonne", removes, edit)

    assert {:error, {:trip_too_large, "Varonne"}} =
             call(store, "Varonne", [big_stop(count + 1)], edit)

    {_result, store} = call!(store, "Varonne", [%{"op" => "move", "n" => 103, "day" => 1}], edit)
    {result, _store} = call!(store, "Varonne", [%{"op" => "remove_trip"}], edit)
    assert result.trip.removed_at == @stamped_now
  end

  test "removing every stop of a trip at the cap in one call keeps its push inside the line" do
    {store, count, edit} = at_cap()
    before = push_line(store)

    {result, store} = call!(store, "Varonne", [%{"op" => "remove", "n" => 2}], edit)
    assert length(result.removed_rows) == count + 1

    # The removed form's removed_at on every row is all the call added.
    after_removal = push_line(store)
    assert after_removal > Ops.max_wire_bytes()
    assert after_removal < @line_bytes
    assert after_removal - before < 50 * (count + 1)

    # A device brings the day back, with its stops, at the cap again.
    %{id: trip_id} = trip(store, "Varonne")
    day_id = hd(result.removed_rows).id
    restore = %{"trip_id" => trip_id, "op" => %{"op" => "restore", "row_id" => day_id}}
    {_result, store} = device!(store, restore)
    assert length(rows(store, "Varonne")) == count + 2
  end

  # --- trust -----------------------------------------------------------------

  test "after outside content only add runs, stamped" do
    store = three_days(nil)
    outside = %{@edit | outside?: true}

    {result, store} =
      call!(store, "Varonne", [%{"op" => "add", "text" => "Night market", "day" => 3}], outside)

    assert %{stamped: true} = stop(store, "Varonne", "Night market")
    assert [false, false, false] == Enum.map(day_rows(store, "Varonne"), & &1.stamped)
    assert result.made == stop(store, "Varonne", "Night market").id

    # R2#4: an add after outside content makes no day, so a page cannot
    # stretch the trip; one after a row the trip has still lands.
    assert call(store, "Varonne", [%{"op" => "add", "text" => "Far", "day" => 4}], outside) ==
             {:error, {:op_failed, 1, :outside_new_day}}

    {_result, store} =
      call!(store, "Varonne", [%{"op" => "add", "text" => "Late bar", "after" => 4}], outside)

    assert %{stamped: true} = stop(store, "Varonne", "Late bar")
    assert length(day_rows(store, "Varonne")) == 3

    refused = [
      %{"op" => "edit", "n" => 4, "text" => "Fish auction"},
      %{"op" => "move", "n" => 4, "day" => 2},
      %{"op" => "remove", "n" => 4},
      %{"op" => "day", "day" => 1, "text" => "Port"},
      %{"op" => "rename", "text" => "Elsewhere"},
      %{"op" => "dates", "starts_on" => "2031-05-01"},
      %{"op" => "remove_trip"}
    ]

    for op <- refused do
      assert call(store, "Varonne", [op], outside) == {:error, {:op_failed, 1, :outside_content}},
             inspect(op)
    end

    assert call(store, "Pellmoor", [%{"op" => "create"}], outside) ==
             {:error, {:op_failed, 1, :outside_content}}
  end

  # --- removal ---------------------------------------------------------------

  test "a day removed with its stops comes back with them" do
    store = three_days("2031-03-10")
    [_harbour, old_town, _hills] = day_rows(store, "Varonne")
    vineyard = stop(store, "Varonne", "Vineyard")

    {result, store} =
      call!(store, "Varonne", [
        %{"op" => "remove", "n" => old_town.n},
        %{"op" => "remove", "n" => vineyard.n}
      ])

    assert Enum.all?(result.removed_rows, &(&1.removed_at == @now))
    assert Enum.map(outline(store, "Varonne"), &elem(&1, 0)) == ["Harbour", "Hills"]

    %{id: trip_id} = trip(store, "Varonne")
    restore = %{"trip_id" => trip_id, "op" => %{"op" => "restore", "row_id" => old_town.id}}
    {result, store} = device!(store, restore)

    assert outline(store, "Varonne") == [
             {"Harbour", ~D[2031-03-10], ["Fish market", "Ferry"]},
             {"Old town", ~D[2031-03-11], ["Clock tower"]},
             {"Hills", ~D[2031-03-12], []}
           ]

    assert old_town.id in result.touched_rows
    assert [%{text: "Vineyard"}] = store.removed[trip_id]
  end

  test "the only day cannot be removed; a first day removed leaves a day first" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create"}])

    assert call(store, "Varonne", [%{"op" => "remove", "n" => 1}]) ==
             {:error, {:op_failed, 1, {:last_day, "Varonne"}}}

    store = three_days(nil)
    {_result, store} = call!(store, "Varonne", [%{"op" => "remove", "n" => 1}])
    assert [%{kind: :day, text: "Old town"} | _rest] = rows(store, "Varonne")
  end

  test "a removed trip is restored by a device under its title, or a new one when it is taken" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create"}])
    %{id: trip_id} = trip(store, "Varonne")
    {_result, store} = call!(store, "Varonne", [%{"op" => "remove_trip"}])
    {_result, store} = call!(store, "varonne", [%{"op" => "create"}])

    restore = %{"trip_id" => trip_id, "op" => %{"op" => "restore"}}
    assert device(store, restore) == {:error, {:op_failed, 1, {:title_in_use, "Varonne"}}}

    titled = put_in(restore, ["op", "title"], "Varonne again")
    {result, _store} = device!(store, titled)
    assert %{id: ^trip_id, title: "Varonne again", removed_at: nil, restored?: true} = result.trip
  end

  # --- made, legs and dates moved ---------------------------------------------

  test "made is the trip on create and the row on add, never a day made on the way" do
    {result, store} = call!(empty(), "Varonne", [%{"op" => "create", "days" => 3}])
    assert result.made == result.trip.id

    {result, store} =
      call!(store, "Varonne", [%{"op" => "add", "text" => "Lighthouse", "day" => 5}])

    assert result.made == stop(store, "Varonne", "Lighthouse").id

    %{id: trip_id} = trip(store, "Varonne")
    {result, store} = device!(store, %{"trip_id" => trip_id, "op" => %{"op" => "day"}})
    assert result.made == store |> day_rows("Varonne") |> List.last() |> Map.fetch!(:id)

    {result, _store} = device!(store, %{"op" => %{"op" => "create", "title" => "Pellmoor"}})
    assert result.made == result.trip.id
  end

  test "legs skip unplaced stops and never cross days" do
    {_result, store} = call!(empty(), "Varonne", [%{"op" => "create", "days" => 2}])
    %{id: trip_id} = trip(store, "Varonne")
    [first, second] = day_rows(store, "Varonne")

    {_result, store} = placed(store, trip_id, first.id, "Inn", @inn)
    {_result, store} = placed(store, trip_id, first.id, "Picnic", nil)
    {_result, store} = placed(store, trip_id, first.id, "Mill", @mill)
    {_result, store} = placed(store, trip_id, second.id, "Quay", @quay)
    {_result, store} = placed(store, trip_id, second.id, "Inn again", @inn)

    stop_id = fn text -> stop(store, "Varonne", text).id end
    point = fn record -> record |> Place.cut() |> elem(1) |> Place.point() end

    assert Ops.legs(rows(store, "Varonne")) == %{
             stop_id.("Mill") => Geo.distance_m(point.(@inn), point.(@mill)),
             stop_id.("Inn again") => Geo.distance_m(point.(@quay), point.(@inn))
           }
  end

  test "a fixed stop whose date moves is named, with its dates before and after" do
    store = three_days("2031-03-10")

    {_result, store} =
      call!(store, "Varonne", [
        %{
          "op" => "add",
          "text" => "Dinner at Corvo",
          "day" => 3,
          "time" => "20:00",
          "fixed" => true
        }
      ])

    dinner = stop(store, "Varonne", "Dinner at Corvo")
    [_harbour, old_town, _hills] = day_rows(store, "Varonne")

    {result, _store} = call!(store, "Varonne", [%{"op" => "remove", "n" => old_town.n}])

    assert result.dates_moved == [
             %{row: %{dinner | dirty: nil}, from: ~D[2031-03-12], to: ~D[2031-03-11]}
           ]

    {result, _store} = call!(store, "Varonne", [%{"op" => "dates", "starts_on" => ""}])
    assert [%{from: ~D[2031-03-12], to: nil}] = result.dates_moved
  end
end
