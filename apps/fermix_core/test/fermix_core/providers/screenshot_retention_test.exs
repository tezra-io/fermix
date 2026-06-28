defmodule FermixCore.Providers.ScreenshotRetentionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ScreenshotRetention

  # Units are tagged maps: a screenshot carrier holds `img: true`; `elide`
  # clears the bytes. This is the shape-agnostic core every adapter delegates to.
  defp shot(id), do: %{id: id, shot: true, img: true}
  defp text(id), do: %{id: id, shot: false}

  defp screenshot?(%{shot: true, img: true}), do: true
  defp screenshot?(_), do: false

  defp elide(unit), do: %{unit | img: false}

  defp keep(units, n),
    do: ScreenshotRetention.keep_last(units, n, &screenshot?/1, &elide/1)

  describe "keep_last/4" do
    test "nil keep disables retention — list returned unchanged" do
      units = [shot(1), text(2), shot(3)]
      assert keep(units, nil) == units
    end

    test "keep >= screenshot count leaves every screenshot's bytes intact" do
      units = [shot(1), text(2), shot(3)]
      assert keep(units, 3) == units
      assert keep(units, 2) == units
    end

    test "keeps the MOST RECENT N screenshots and elides the older ones" do
      units = [shot(1), text(:a), shot(2), shot(3), text(:b), shot(4)]

      # cap 2 → the two earliest of four screenshots (1, 2) are elided; 3 and 4 keep bytes
      result = keep(units, 2)

      assert Enum.map(result, &Map.get(&1, :img)) == [false, nil, false, true, nil, true]
      # non-screenshot units are untouched (no :img key gains/loses)
      assert Enum.at(result, 1) == text(:a)
      assert Enum.at(result, 4) == text(:b)
    end

    test "the newest screenshot is always retained (the inverted-prune regression)" do
      units = [shot(1), shot(2), shot(3), shot(4), shot(5)]
      result = keep(units, 1)

      # only the LAST keeps bytes; the first four are elided
      assert Enum.map(result, &Map.get(&1, :img)) == [false, false, false, false, true]
    end

    test "keep 0 elides every screenshot" do
      units = [shot(1), shot(2)]

      assert keep(units, 0) == [
               %{id: 1, shot: true, img: false},
               %{id: 2, shot: true, img: false}
             ]
    end

    test "non-screenshot units are never elided regardless of cap" do
      units = [text(1), text(2), text(3)]
      assert keep(units, 0) == units
    end

    test "order is preserved" do
      units = [shot(1), text(2), shot(3), text(4), shot(5)]
      assert Enum.map(keep(units, 1), & &1.id) == [1, 2, 3, 4, 5]
    end
  end
end
