defmodule FermixCore.Cues.RecentDropsTest do
  # async: false: the table is a named one, as `Cues.LiveFilters` makes it.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Item
  alias FermixCore.Cues.RecentDrops

  @at ~U[2026-10-10 12:00:00Z]

  defp item(n) do
    {:ok, item} =
      Item.new(%{item_id: "i-#{n}", type: "create", data: %{"text" => "post #{n}"}}, @at)

    item
  end

  test "keeps the newest 50 per watcher; a read with no table is empty; fetch and forget" do
    assert RecentDrops.list("w") == []

    task =
      Task.async(fn ->
        RecentDrops.new_table()
        for n <- 1..55, do: RecentDrops.put("w", item(n), "s", "Not news.", @at)
        drop = RecentDrops.put("other", item(0), "s", "Off topic.", @at)

        drops = RecentDrops.list("w")
        assert length(drops) == 50
        assert hd(drops).item.item_id == "i-55"
        assert List.last(drops).item.item_id == "i-6"
        assert {:ok, %{reason: "Off topic."}} = RecentDrops.fetch("other", drop.key)
        assert :error = RecentDrops.fetch("w", drop.key)

        RecentDrops.forget("w")
        assert RecentDrops.list("w") == []
      end)

    Task.await(task)
    # The table went with its owner.
    assert RecentDrops.list("other") == []
  end
end
