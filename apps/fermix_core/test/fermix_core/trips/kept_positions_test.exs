defmodule FermixCore.Trips.KeptPositionsTest do
  # M89 §05: a trip moves a day with its stops as one run of rows, put between
  # two neighbours when the gap holds the run and numbered again when not
  # (`Kept.Positions.insert_run/4`).
  use ExUnit.Case, async: true

  alias FermixCore.Kept.Positions

  @now ~U[2031-06-02 14:00:00Z]
  @before ~U[2031-06-01 09:00:00Z]

  defp row(id, position), do: %{id: id, position: position, dirty: nil, updated_at: @before}

  defp ids(rows), do: Enum.map(rows, & &1.id)

  test "a run between two neighbours with room takes positions between them, in its order" do
    rows = [row("a", 1_024), row("b", 2_048)]
    run = [row("x", 0), row("y", 0), row("z", 0)]

    placed = Positions.insert_run(rows, 1, run, @now)

    assert ids(placed) == ["a", "x", "y", "z", "b"]
    assert Enum.map(placed, & &1.position) == [1_024, 1_280, 1_536, 1_792, 2_048]
    assert Enum.all?([hd(placed), List.last(placed)], &(&1.dirty == nil))
  end

  test "a run at the end goes a gap apart after the last row" do
    placed = Positions.insert_run([row("a", 1_024)], 1, [row("x", 0), row("y", 0)], @now)

    assert ids(placed) == ["a", "x", "y"]
    assert Enum.map(placed, & &1.position) == [1_024, 2_048, 3_072]
  end

  test "a run at the start of an empty list starts a gap in" do
    placed = Positions.insert_run([], 0, [row("x", 0), row("y", 0)], @now)
    assert Enum.map(placed, & &1.position) == [1_024, 2_048]
  end

  test "a run the gap cannot hold numbers every row again, the ones that moved marked changed" do
    rows = [row("a", 1_024), row("b", 1_026)]
    run = [row("x", 0), row("y", 0)]

    placed = Positions.insert_run(rows, 1, run, @now)

    assert ids(placed) == ["a", "x", "y", "b"]
    assert Enum.map(placed, & &1.position) == [1_024, 2_048, 3_072, 4_096]
    assert [%{dirty: nil}, %{dirty: :changed}, %{dirty: :changed}, %{dirty: :changed}] = placed
    assert Enum.at(placed, 3).updated_at == @now
  end

  test "one row in a run lands where insert/4 puts it" do
    rows = [row("a", 1_024), row("b", 2_048)]

    assert Positions.insert_run(rows, 1, [row("x", 0)], @now) ==
             Positions.insert(rows, 1, row("x", 0), @now)
  end
end
