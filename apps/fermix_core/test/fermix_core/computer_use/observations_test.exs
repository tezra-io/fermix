defmodule FermixCore.ComputerUse.ObservationsTest do
  @moduledoc """
  The observation table (M42 slice 3 §4.1): the three images a conversation may
  still address, and the three checks over them.

  It replaces the region guard, whose whole job was to notice that the model had
  forgotten to copy a rectangle onto its click. There is no rectangle to forget
  any more — an action names the image its coordinates were read in — so the
  guard becomes an addressing check, the mark table becomes a property of the
  image it was badged on, and the M28 wrong-grid tripwire keeps its thresholds
  and its arithmetic exactly.
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Observations

  doctest Observations

  # The live M28 incident geometry: region {23,11,482,341} in full-sent space came
  # back as a 1355x959 crop (kz_eff = 1355/482 = 2.811).
  @region %{"x" => 23, "y" => 11, "w" => 482, "h" => 341}

  defp image(id, opts) do
    %{
      "observation_id" => id,
      "observation_kind" => "image",
      "width" => Keyword.get(opts, :w, 1355),
      "height" => Keyword.get(opts, :h, 959),
      "marks" => Keyword.get(opts, :marks)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The helper resolves whatever rectangle it was asked for into FULL-DISPLAY image
  # pixels and echoes it, so `:region` here is what the request asked for (in
  # whatever space) and `:echo` is what the helper answered with. They differ only
  # for a crop of a crop, which is exactly the case that used to be recorded wrong.
  defp record(table, id, opts \\ []) do
    asked = Keyword.get(opts, :region)

    request =
      %{"action" => "screenshot", "region" => asked}
      |> put_unless_nil("observation_id", Keyword.get(opts, :of))

    response = put_unless_nil(image(id, opts), "region", Keyword.get(opts, :echo, asked))
    Observations.record(table, request, response, Keyword.get(opts, :at, 0))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  describe "the table" do
    test "a reply that names an observation is recorded under its id" do
      table = record(Observations.new(), "7c1e-12", region: @region)

      assert {:ok, entry} = Observations.fetch(table, "7c1e-12")
      assert entry.kind == "image"
      assert entry.region == @region
      assert entry.dims == {1355, 959}
      assert entry.recorded_at_ms == 0
    end

    test "a reply that names none leaves the table alone" do
      table = record(Observations.new(), "7c1e-12", region: @region)

      assert Observations.record(table, %{"action" => "wait"}, %{"ok" => true}, 1) == table
    end

    # The rectangle a crop-of-a-crop request carries is in its PARENT image's
    # pixels; the tripwire and the check both read the recorded rectangle as a
    # position on the full-display image. Recording the request's copy verbatim
    # made a correct click on a nested crop look wrong on both counts.
    #
    # Reviewer's scenario, 5120x2880 @1x: full screenshot region {0,0,700,400}
    # comes back as B (1366x780); a screenshot naming B with region
    # {100,50,400,300} — 400x300 of B's OWN pixels — comes back as C (768x576).
    # In full-display image pixels that rectangle is {51,26,205,154}.
    test "a crop of a crop records the rectangle the helper resolved, not the one asked for" do
      table =
        Observations.new()
        |> record("B", region: %{"x" => 0, "y" => 0, "w" => 700, "h" => 400}, w: 1366, h: 780)
        |> record("C",
          of: "B",
          region: %{"x" => 100, "y" => 50, "w" => 400, "h" => 300},
          echo: %{"x" => 51, "y" => 26, "w" => 205, "h" => 154},
          w: 768,
          h: 576
        )

      assert {:ok, %{region: %{"x" => 51, "y" => 26, "w" => 205, "h" => 154}}} =
               Observations.fetch(table, "C")

      # A correct click read in C: (300,200) is nowhere near the resolved rect, so
      # it is admitted. Against the rectangle as ASKED FOR it sat inside
      # {100,50,400,300} at kz 1.92 and was refused with a "conversion" to
      # (384,288) — a point in the very image the model had already read.
      click = %{"action" => "left_click", "x" => 300, "y" => 200, "observation_id" => "C"}
      assert Observations.ambiguity(table, click) == :ok
    end

    # The twin: the tripwire must still FIRE on a nested crop when the wrong-grid
    # signature genuinely holds — the point sits inside the resolved rectangle on
    # the full-display image while C magnifies it more than 1.5x (768/205 = 3.75).
    # Keying on the request's rectangle also broke this direction: a parent sent at
    # native scale gives a ratio near 1 and the guard silently stopped guarding.
    test "a crop of a crop still trips when the wrong-grid signature holds" do
      table =
        record(Observations.new(), "C",
          of: "B",
          region: %{"x" => 100, "y" => 50, "w" => 400, "h" => 300},
          echo: %{"x" => 51, "y" => 26, "w" => 205, "h" => 154},
          w: 768,
          h: 576
        )

      assert {:error, {:ambiguous_coordinates, info}} =
               Observations.ambiguity(table, %{
                 "action" => "left_click",
                 "x" => 150,
                 "y" => 100,
                 "observation_id" => "C"
               })

      assert info.region == %{"x" => 51, "y" => 26, "w" => 205, "h" => 154}
      assert_in_delta info.kz, 768 / 205, 0.001
    end

    test "a full-screen capture records no region, so nothing reads as a crop" do
      table = record(Observations.new(), "7c1e-12", w: 1366, h: 384)

      assert {:ok, %{region: nil}} = Observations.fetch(table, "7c1e-12")
    end

    test "at most three are kept, oldest out" do
      table =
        Observations.new()
        |> record("a", at: 1)
        |> record("b", at: 2)
        |> record("c", at: 3)
        |> record("d", at: 4)

      assert Observations.fetch(table, "a") == :error
      assert {:ok, _} = Observations.fetch(table, "b")
      assert {:ok, _} = Observations.fetch(table, "d")
    end

    test "re-recording an id refreshes it in place rather than filling a slot" do
      table =
        Observations.new()
        |> record("a", at: 1)
        |> record("b", at: 2)
        |> record("a", at: 3)
        |> record("c", at: 4)

      assert {:ok, %{recorded_at_ms: 3}} = Observations.fetch(table, "a")
      assert {:ok, _} = Observations.fetch(table, "b")
    end

    # The helper is the authority on which ids still resolve; when it refuses one
    # this side forgets it too, so the next turn cannot name an image that is
    # gone on both sides.
    test "an id the helper refused is dropped" do
      table = Observations.new() |> record("a") |> Observations.drop("a")

      assert Observations.fetch(table, "a") == :error
    end

    test "an unknown id simply is not there" do
      assert Observations.fetch(Observations.new(), "nope") == :error
      assert Observations.fetch(Observations.new(), nil) == :error
    end
  end

  describe "check_addressing/2" do
    setup do
      %{table: record(Observations.new(), "7c1e-12", region: @region)}
    end

    test "a pointer action without an observation_id is refused", %{table: table} do
      for action <-
            ~w(left_click right_click double_click mouse_move left_click_drag scroll inspect) do
        assert Observations.check_addressing(table, %{"action" => action, "x" => 1, "y" => 2}) ==
                 {:error, :observation_required},
               "#{action} must name the image its coordinates came from"
      end
    end

    test "the same action WITH one is admitted", %{table: table} do
      request = %{"action" => "left_click", "x" => 1, "y" => 2, "observation_id" => "7c1e-12"}

      assert Observations.check_addressing(table, request) == :ok
    end

    # The helper owns liveness: an id this side no longer holds is still sent, and
    # the helper answers `unknown_observation` for it. Two authorities for one fact
    # is how a healthy click gets refused by the wrong half.
    test "an id this side does not hold is still admitted", %{table: table} do
      request = %{"action" => "left_click", "x" => 1, "y" => 2, "observation_id" => "gone-1"}

      assert Observations.check_addressing(table, request) == :ok
    end

    test "keyboard and look actions are never addressed", %{table: table} do
      for request <- [
            %{"action" => "type", "text" => "e4"},
            %{"action" => "key", "chord" => "enter"},
            %{"action" => "screenshot"},
            %{"action" => "elements"},
            %{"action" => "windows"},
            %{"action" => "wait", "ms" => 10}
          ] do
        assert Observations.check_addressing(table, request) == :ok
      end
    end
  end

  describe "resolve_mark/2" do
    @marks [
      %{"id" => 1, "role" => "AXButton", "title" => "Start game", "x" => 200, "y" => 300},
      %{"id" => 2, "role" => "AXLink", "title" => "Chess", "x" => 1100, "y" => 700}
    ]

    setup do
      table =
        Observations.new()
        |> record("marked", region: @region, marks: @marks)
        |> record("plain", region: @region)

      %{table: table}
    end

    test "a mark resolves to its badge's point in the image it names", %{table: table} do
      request = %{"action" => "left_click", "mark" => 2, "observation_id" => "marked"}

      assert {:ok, resolved, true} = Observations.resolve_mark(table, request)
      assert resolved["x"] == 1100
      assert resolved["y"] == 700
      assert resolved["observation_id"] == "marked"
      refute Map.has_key?(resolved, "mark"), "the helper must never see a mark id"
    end

    test "an image with no marks answers no_marks", %{table: table} do
      request = %{"action" => "left_click", "mark" => 1, "observation_id" => "plain"}

      assert Observations.resolve_mark(table, request) == {:error, :no_marks}
    end

    test "an image this side does not hold answers no_marks", %{table: table} do
      request = %{"action" => "left_click", "mark" => 1, "observation_id" => "gone"}

      assert Observations.resolve_mark(table, request) == {:error, :no_marks}
    end

    test "an unknown mark is refused with that image's live count", %{table: table} do
      request = %{"action" => "left_click", "mark" => 9, "observation_id" => "marked"}

      assert Observations.resolve_mark(table, request) == {:error, {:unknown_mark, 9, 2}}
    end

    test "a malformed mark is refused rather than guessed", %{table: table} do
      request = %{"action" => "left_click", "mark" => "two", "observation_id" => "marked"}

      assert Observations.resolve_mark(table, request) == {:error, :no_marks}
    end

    test "an action with no mark passes through untouched", %{table: table} do
      request = %{"action" => "left_click", "x" => 1, "y" => 2, "observation_id" => "marked"}

      assert Observations.resolve_mark(table, request) == {:ok, request, false}
    end
  end

  describe "ambiguity/2 — the M28 wrong-grid tripwire" do
    setup do
      %{table: record(Observations.new(), "crop", region: @region)}
    end

    defp click(id, x, y),
      do: %{"action" => "left_click", "x" => x, "y" => y, "observation_id" => id}

    test "the live incident click is refused with the exact conversion", %{table: table} do
      assert {:error, {:ambiguous_coordinates, info}} =
               Observations.ambiguity(table, click("crop", 400, 265))

      assert info.id == "crop"
      assert info.region == @region
      assert info.view == %{"w" => 1355, "h" => 959}
      # (400-23)x2.811, (265-11)x2.811 — the point the model meant, in crop pixels.
      assert info.crop_equivalents == [{1060, 714}]
    end

    test "the corrected crop-space point is admitted", %{table: table} do
      assert Observations.ambiguity(table, click("crop", 1060, 714)) == :ok
    end

    test "the rect is POSITIONED, so a point left of it is unambiguous" do
      offcenter = %{"x" => 700, "y" => 40, "w" => 482, "h" => 341}
      table = record(Observations.new(), "crop", region: offcenter)

      assert {:error, {:ambiguous_coordinates, _}} =
               Observations.ambiguity(table, click("crop", 750, 200))

      assert Observations.ambiguity(table, click("crop", 400, 265)) == :ok
    end

    test "magnification at or below the threshold never trips" do
      mild = %{"x" => 0, "y" => 0, "w" => 1000, "h" => 341}
      table = record(Observations.new(), "crop", region: mild, w: 1366, h: 466)

      assert Observations.ambiguity(table, click("crop", 400, 265)) == :ok
    end

    test "a full-screen image is never ambiguous" do
      table = record(Observations.new(), "full", w: 1366, h: 384)

      assert Observations.ambiguity(table, click("full", 400, 265)) == :ok
    end

    test "an image with no dimensions (a semantic list) never trips" do
      table =
        Observations.record(
          Observations.new(),
          %{"action" => "elements", "region" => @region},
          %{"observation_id" => "list", "observation_kind" => "semantic"},
          0
        )

      assert Observations.ambiguity(table, click("list", 400, 265)) == :ok
    end

    test "a drag is ambiguous only when BOTH endpoints are inside the rect", %{table: table} do
      both = %{
        "action" => "left_click_drag",
        "observation_id" => "crop",
        "from" => %{"x" => 148, "y" => 279},
        "to" => %{"x" => 148, "y" => 214}
      }

      assert {:error, {:ambiguous_coordinates, info}} = Observations.ambiguity(table, both)
      assert length(info.crop_equivalents) == 2

      one_outside = put_in(both["to"], %{"x" => 900, "y" => 500})
      assert Observations.ambiguity(table, one_outside) == :ok
    end

    test "an action with no coordinates never trips", %{table: table} do
      assert Observations.ambiguity(table, %{"action" => "type", "text" => "e4"}) == :ok
    end

    test "an unknown observation never trips — the helper refuses it first", %{table: table} do
      assert Observations.ambiguity(table, click("gone", 400, 265)) == :ok
    end

    # Exhaustive sweep of the predicate: a point refuses iff it lies inside the
    # positioned rect, never outside it.
    test "refusal iff the point is inside the positioned region rect", %{table: table} do
      %{"x" => rx, "y" => ry, "w" => rw, "h" => rh} = @region

      for x <- [0, rx - 1, rx, rx + div(rw, 2), rx + rw, rx + rw + 1, 1300],
          y <- [0, ry - 1, ry, ry + div(rh, 2), ry + rh, ry + rh + 1, 900] do
        inside = x >= rx and x <= rx + rw and y >= ry and y <= ry + rh
        result = Observations.ambiguity(table, click("crop", x, y))

        if inside do
          assert {:error, {:ambiguous_coordinates, _}} = result, "(#{x},#{y}) must refuse"
        else
          assert result == :ok, "(#{x},#{y}) must be admitted"
        end
      end
    end
  end
end
