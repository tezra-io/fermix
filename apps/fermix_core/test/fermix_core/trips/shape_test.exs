defmodule FermixCore.Trips.ShapeTest do
  # M89 §04, §06: a trip_edit call and a device's op are checked in the caller,
  # before the store is asked: bounds, one line, HH:MM, minutes, IANA zones and
  # dates, and at most 100 ops a call.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Shape

  # Every title, stop and id here is invented.
  @trip_id "tr_4q8m2x7v1d"
  @day_id "ti_7h2k9m4p1c"
  @stop_id "ti_5w7p0t4n6b"
  @inn %{"name" => "Marisco Inn", "location" => %{"latitude" => 41.2031, "longitude" => -8.4102}}

  defp call(ops, trip \\ "Varonne"), do: Shape.call(%{"trip" => trip, "ops" => ops})
  defp one(op), do: call([op])

  defp shaped!(op) do
    assert {:ok, %{ops: [shaped]}} = one(op)
    shaped
  end

  describe "a model's call" do
    test "over 100 ops is refused, and so is none" do
      ops = for i <- 1..101, do: %{"op" => "add", "text" => "Stop #{i}", "day" => 1}
      assert call(ops) == {:error, :too_many_ops}
      assert {:ok, %{ops: ops}} = call(Enum.take(ops, 100))
      assert length(ops) == 100
      assert call([]) == {:error, {:invalid_param, :ops}}
      assert Shape.call(%{"trip" => "Varonne"}) == {:error, {:invalid_param, :ops}}
      assert call([%{"op" => "remove_trip"}], "  ") == {:error, {:invalid_param, :trip}}
    end

    test "a create takes its title from the trip, or its own, within 80 characters" do
      assert {:ok, %{trip: "Varonne", ops: [%{op: :create, title: nil, days: 1}]}} =
               call([%{"op" => "create"}], " Varonne ")

      assert %{op: :create, title: "Ostrel", days: 3, starts_on: ~D[2031-07-04]} =
               shaped!(%{
                 "op" => "create",
                 "title" => "Ostrel",
                 "days" => 3,
                 "starts_on" => "2031-07-04"
               })

      long = String.duplicate("t", 81)

      assert call([%{"op" => "create"}], long) ==
               {:error, {:invalid_op, 1, {:too_long, :title, 80}}}

      assert one(%{"op" => "create", "days" => 0}) ==
               {:error, {:invalid_op, 1, {:not_days, :days}}}

      assert one(%{"op" => "create", "days" => 1_001}) ==
               {:error, {:invalid_op, 1, {:not_days, :days}}}
    end

    test "texts are words on one line within their bounds" do
      assert one(%{"op" => "add", "text" => String.duplicate("w", 201), "day" => 1}) ==
               {:error, {:invalid_op, 1, {:too_long, :text, 200}}}

      assert one(%{"op" => "add", "text" => "Fish\nmarket", "day" => 1}) ==
               {:error, {:invalid_op, 1, {:not_one_line, :text}}}

      assert one(%{"op" => "day", "day" => 1, "text" => String.duplicate("d", 81)}) ==
               {:error, {:invalid_op, 1, {:too_long, :text, 80}}}

      assert one(%{
               "op" => "add",
               "text" => "Dinner",
               "day" => 1,
               "note" => String.duplicate("n", 1_001)
             }) ==
               {:error, {:invalid_op, 1, {:too_long, :note, 1_000}}}

      assert one(%{"op" => "rename", "text" => String.duplicate("t", 81)}) ==
               {:error, {:invalid_op, 1, {:too_long, :title, 80}}}

      assert %{op: :day, day: 2, text: ""} = shaped!(%{"op" => "day", "day" => 2, "text" => ""})

      assert %{note: "Table for two\nBooked"} =
               shaped!(%{
                 "op" => "add",
                 "text" => "Dinner",
                 "day" => 1,
                 "note" => " Table for two \n\n Booked "
               })
    end

    test "HH:MM, minutes and IANA zones are checked" do
      for time <- ["25:00", "9:00", "12:60", "noon", 900] do
        assert one(%{"op" => "add", "text" => "Ferry", "day" => 1, "time" => time}) ==
                 {:error, {:invalid_op, 1, {:not_time, :time}}},
               inspect(time)
      end

      assert %{time: "09:05"} =
               shaped!(%{"op" => "add", "text" => "Ferry", "day" => 1, "time" => "09:05"})

      for duration <- [-1, 1_441, 1.5, "90"] do
        assert one(%{"op" => "add", "text" => "Ferry", "day" => 1, "duration" => duration}) ==
                 {:error, {:invalid_op, 1, {:not_minutes, :duration}}},
               inspect(duration)
      end

      assert %{duration: 90} =
               shaped!(%{"op" => "add", "text" => "Ferry", "day" => 1, "duration" => 90})

      assert one(%{"op" => "day", "day" => 1, "timezone" => "Mars/Olympus"}) ==
               {:error, {:invalid_op, 1, {:invalid_timezone, "Mars/Olympus"}}}

      assert %{timezone: "Atlantic/Azores"} =
               shaped!(%{"op" => "day", "day" => 1, "timezone" => "Atlantic/Azores"})

      assert %{timezone: nil} = shaped!(%{"op" => "day", "day" => 1, "timezone" => ""})

      assert one(%{"op" => "dates", "starts_on" => "2031-02-30"}) ==
               {:error, {:invalid_op, 1, {:not_date, :starts_on}}}

      assert one(%{"op" => "dates"}) == {:error, {:invalid_op, 1, {:missing, :starts_on}}}
      assert %{starts_on: nil} = shaped!(%{"op" => "dates", "starts_on" => ""})
    end

    test "an edit changes what it is given, and an empty value or no minutes clears it" do
      assert %{
               op: :edit,
               n: 4,
               text: nil,
               time: nil,
               duration: nil,
               note: nil,
               place: nil,
               fixed: :keep
             } =
               shaped!(%{
                 "op" => "edit",
                 "n" => 4,
                 "time" => "",
                 "duration" => 0,
                 "note" => "",
                 "place" => ""
               })

      assert %{time: :keep, duration: :keep, note: :keep, place: :keep, fixed: true} =
               shaped!(%{"op" => "edit", "n" => 4, "fixed" => true})

      assert one(%{"op" => "edit", "n" => 4}) == {:error, {:invalid_op, 1, :nothing_to_edit}}

      assert one(%{"op" => "edit", "n" => 0, "text" => "x"}) ==
               {:error, {:invalid_op, 1, {:not_a_number, :n}}}
    end

    test "a place is a link a search returned or a place's own name" do
      link = "https://maps.apple.com/place?place-id=I3K9M2Q7"

      assert %{place: {:link, ^link}} =
               shaped!(%{"op" => "add", "text" => "Lunch", "day" => 1, "place" => link})

      assert %{place: {:words, "Pell Café"}} =
               shaped!(%{"op" => "add", "text" => "Lunch", "day" => 1, "place" => " Pell Café "})

      assert %{place: nil} = shaped!(%{"op" => "add", "text" => "Lunch", "day" => 1})
    end

    # Both a day and an after pass here: only the trip's rows say whether they
    # name one day, so `Trips.Ops` holds them to it.
    test "an add and a move name where to go, by day, after or both, and an unknown op is refused" do
      assert %{op: :add, day: 1, after: 3} =
               shaped!(%{"op" => "add", "text" => "Ferry", "day" => 1, "after" => 3})

      assert %{op: :move, n: 4, day: 3, after: 7} =
               shaped!(%{"op" => "move", "n" => 4, "day" => 3, "after" => 7})

      assert %{op: :move, n: 4, day: nil, after: 7} =
               shaped!(%{"op" => "move", "n" => 4, "after" => 7})

      assert one(%{"op" => "add", "text" => "Ferry", "day" => 1, "after" => 0}) ==
               {:error, {:invalid_op, 1, {:not_a_number, :after}}}

      assert one(%{"op" => "add", "text" => "Ferry"}) ==
               {:error, {:invalid_op, 1, :add_needs_place}}

      assert one(%{"op" => "move", "n" => 4}) == {:error, {:invalid_op, 1, :move_needs_place}}

      assert one(%{"op" => "replace"}) == {:error, {:invalid_op, 1, {:unknown_op, "replace"}}}
      assert one(%{"text" => "x"}) == {:error, {:invalid_op, 1, {:missing, :op}}}
    end

    # D10: near names where a trip, or one of its days, is; the model's words.
    test "near is a place's name on create and on day; on day empty clears it, absent keeps it" do
      assert %{op: :create, near: "Lisbon, Portugal"} =
               shaped!(%{"op" => "create", "near" => " Lisbon, Portugal "})

      assert %{op: :create, near: nil} = shaped!(%{"op" => "create"})
      assert %{op: :create, near: nil} = shaped!(%{"op" => "create", "near" => ""})

      assert %{op: :day, day: 8, near: "Porto, Portugal", text: :keep} =
               shaped!(%{"op" => "day", "day" => 8, "near" => "Porto, Portugal"})

      assert %{op: :day, near: nil} = shaped!(%{"op" => "day", "day" => 8, "near" => ""})
      assert %{op: :day, near: :keep} = shaped!(%{"op" => "day", "day" => 8, "text" => "Ribeira"})

      assert one(%{"op" => "day", "day" => 8, "near" => String.duplicate("p", 201)}) ==
               {:error, {:invalid_op, 1, {:too_long, :near, 200}}}

      assert one(%{"op" => "create", "near" => "Porto\nPortugal"}) ==
               {:error, {:invalid_op, 1, {:not_one_line, :near}}}

      assert one(%{"op" => "day", "day" => 8, "near" => 8}) ==
               {:error, {:invalid_op, 1, {:invalid_param, :near}}}
    end
  end

  describe "a device's op" do
    defp device(op, trip_id \\ @trip_id) do
      params = %{"op" => op}
      params = if trip_id, do: Map.put(params, "trip_id", trip_id), else: params
      Shape.device_change(params)
    end

    test "every op by row id, the trip named by its id but for a create" do
      assert {:ok, %{trip: nil, ops: [%{op: :create, title: "Kyoto Hills", days: 1}]}} =
               device(%{"op" => "create", "title" => "Kyoto Hills"}, nil)

      assert {:ok, %{trip: @trip_id, ops: [%{op: :add, day: {:id, @day_id}, after: nil}]}} =
               device(%{"op" => "add", "text" => "Ferry", "day_id" => @day_id})

      assert {:ok, %{ops: [%{op: :remove, n: {:id, @stop_id}}]}} =
               device(%{"op" => "remove", "row_id" => @stop_id})

      assert {:ok, %{ops: [%{op: :move, n: {:id, @day_id}, day: nil, after: :start}]}} =
               device(%{"op" => "move", "row_id" => @day_id})

      assert {:ok, %{ops: [%{op: :day, day: {:new, nil}, text: :keep}]}} =
               device(%{"op" => "day"})

      assert {:ok, %{ops: [%{op: :day, day: {:id, @day_id}, text: "Harbour"}]}} =
               device(%{"op" => "day", "row_id" => @day_id, "text" => "Harbour"})

      assert {:ok, %{ops: [%{op: :restore, row: nil, title: "Again"}]}} =
               device(%{"op" => "restore", "title" => "Again"})

      assert device(%{"op" => "add", "text" => "Ferry", "day_id" => @day_id}, nil) ==
               {:error, {:missing, :trip_id}}

      assert device(%{"op" => "remove", "row_id" => "ci_5w7p0t4n6b"}) ==
               {:error, {:invalid_param, :row_id}}

      assert device(%{"op" => "replace"}) == {:error, {:unknown_device_op, "replace"}}
      assert Shape.device_change(%{"trip_id" => @trip_id}) == {:error, {:missing, :op}}
    end

    # The Mac's drafts follow this rule, so a device still names one place to go.
    test "a device's add or move gives day_id or after_id, not both" do
      both = %{"day_id" => @day_id, "after_id" => @stop_id}

      assert device(Map.merge(%{"op" => "add", "text" => "Ferry"}, both)) ==
               {:error, :place_conflict}

      assert device(Map.merge(%{"op" => "move", "row_id" => @stop_id}, both)) ==
               {:error, {:device, :place_conflict}}
    end

    # D10: near is the model's alone; no device wire carries it.
    test "a device's create and day take no near" do
      assert {:ok, %{ops: [%{op: :create, near: nil}]}} =
               device(%{"op" => "create", "title" => "Kyoto Hills", "near" => "Kyoto"}, nil)

      assert {:ok, %{ops: [%{op: :day, near: :keep}]}} =
               device(%{"op" => "day", "row_id" => @day_id, "near" => "Kyoto"})
    end

    test "a device's place is a whole record, cut; unplace takes it away" do
      assert {:ok, %{ops: [%{place: place}]}} =
               device(%{"op" => "add", "text" => "Inn", "day_id" => @day_id, "place" => @inn})

      assert place == @inn

      assert {:ok, %{ops: [%{op: :edit, place: nil}]}} =
               device(%{"op" => "edit", "row_id" => @stop_id, "unplace" => true})

      assert device(%{"op" => "edit", "row_id" => @stop_id, "unplace" => true, "place" => @inn}) ==
               {:error, {:device, :place_and_unplace}}

      assert device(%{
               "op" => "add",
               "text" => "Inn",
               "day_id" => @day_id,
               "place" => %{"name" => "Inn"}
             }) ==
               {:error, {:invalid_place, :location}}
    end
  end
end
