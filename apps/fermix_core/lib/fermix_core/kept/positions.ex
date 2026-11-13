defmodule FermixCore.Kept.Positions do
  @moduledoc """
  Where a kept thing's rows sit (M89 §07): integer positions with gaps of
  1,024. A row put between two neighbours takes the midpoint, and when no gap
  is left the whole run is numbered again, each row whose position moved
  marked changed at `now`. Shared by every kept kind. Pure.
  """

  @gap 1_024

  @typedoc "A row as a kind's ops hold it: its position and what an edit did to it."
  @type row :: %{
          required(:position) => integer(),
          required(:dirty) => atom() | nil,
          required(:updated_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @doc "The gap between two neighbours a renumbering leaves."
  @spec gap() :: pos_integer()
  def gap, do: @gap

  @doc "The position after the last of `positions`, or the first one when there is none."
  @spec after_last([integer()]) :: integer()
  def after_last(positions) when is_list(positions),
    do: Enum.max(positions, fn -> 0 end) + @gap

  @doc """
  `rows` with `row` put at `index`: at the midpoint of its neighbours, or with
  every row numbered again when they leave no room.
  """
  @spec insert([row()], non_neg_integer(), row(), DateTime.t()) :: [row()]
  def insert(rows, index, %{position: _position} = row, %DateTime{} = now)
      when is_list(rows) and is_integer(index) and index >= 0 do
    previous = if index == 0, do: 0, else: Enum.at(rows, index - 1).position
    next = rows |> Enum.at(index) |> next_position(previous)

    if next - previous >= 2,
      do: List.insert_at(rows, index, %{row | position: previous + div(next - previous, 2)}),
      else: rows |> List.insert_at(index, row) |> renumber(now)
  end

  defp next_position(nil, previous), do: previous + 2 * @gap
  defp next_position(row, _previous), do: row.position

  @doc "`rows` numbered again in their order, `gap/0` apart, the ones that moved marked changed."
  @spec renumber([row()], DateTime.t()) :: [row()]
  def renumber(rows, %DateTime{} = now) when is_list(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, i} -> renumbered(row, i * @gap, now) end)
  end

  defp renumbered(%{position: position} = row, position, _now), do: row

  defp renumbered(row, position, now),
    do: %{row | position: position, updated_at: now, dirty: row.dirty || :changed}
end
