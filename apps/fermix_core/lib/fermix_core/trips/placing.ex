defmodule FermixCore.Trips.Placing do
  @moduledoc """
  The places a `trip_edit` call gives (M89 §04), around the place lookup: the
  part of the call `Trips.Registry` runs before its transaction opens, and
  after it. Pure; the lookup itself is `Trips.Lookup`.

  **Before.** A model's `place` is words or a link (`Trips.Shape`), and the
  lookup needs the day each stop lands in and the trip's placed stops by day
  (`Lookup.anchor/2`). `requests/3` learns both by running the call over the
  trip as it was read (`Trips.Ops.apply/3`, which is pure), each place given
  replaced by a mark naming its op: the day of a stop an `after` puts in a
  day, a stop the call adds to a day it makes, and a stop an earlier op moved
  are all where the call puts them. A call `Ops` refuses there is refused
  before any lookup is spent (the store would refuse it the same way: it sees
  the same rows, and every trip where this saw one). A place a later op of the
  call replaces, or on a stop the call removes, is not looked up.

  **Between.** `placed_call/2` puts each lookup's outcome in its op: a placed
  record as the stop keeps it (`Trips.Place.from_search/1`). Anything else
  places nothing: an add's stop is saved without a place (C28), and an edit's
  stop keeps the place it had, since only a place given empty takes one away;
  the edit's other fields still land.

  **After.** `placements/3` names, for the answer, each stop the call gave a
  place to as the store now holds it, by the op that gave it: the `k`th add of
  the call made the `k`th new stop by number (`Ops` numbers rows in the order
  it makes them, and only an add makes a stop), and an edit names its stop by
  number, `kept` when the stop kept its place. A stop given a place twice is
  named once, with the later.
  """

  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Place

  # A mark no place's name can hold: `Trips.Place` takes control characters
  # out of every word it keeps. Its point is never read as a place: no
  # request anchors on a marked stop.
  @mark <<0>>
  @mark_point %{"latitude" => 0, "longitude" => 0}

  @typedoc "What a lookup came to, by the op (counted from 1) that gave the place."
  @type outcomes :: [{pos_integer(), Lookup.outcome() | {:none, :unstorable}}]

  @doc "Whether any op of `call` gives a place by words or by a link."
  @spec needed?(map()) :: boolean()
  def needed?(%{ops: ops}) when is_list(ops), do: Enum.any?(ops, &given?/1)

  defp given?(%{place: {kind, value}}) when kind in [:words, :link] and is_binary(value), do: true
  defp given?(_op), do: false

  @doc "Whether any op of `call` gives a place by words, which is a lookup of the place search."
  @spec words?(map()) :: boolean()
  def words?(%{ops: ops}) when is_list(ops),
    do: Enum.any?(ops, &match?(%{place: {:words, _}}, &1))

  @doc """
  The lookups `call` needs over `loaded` (`%{trips:, rows:}`, as `Ops.apply/3`
  takes it) under `edit`: one request a place given, with the day its stop
  lands in, and the placed stops by day that anchor them.
  """
  @spec requests(map(), map(), map()) ::
          {:ok, [Lookup.request()], Lookup.placed()} | {:error, term()}
  def requests(loaded, %{ops: ops} = call, edit) when is_map(loaded) and is_map(edit) do
    marked = %{call | ops: ops |> Enum.with_index(1) |> Enum.map(&marked/1)}

    with {:ok, %{rows: rows}} <- Ops.apply(loaded, marked, edit) do
      days = Ops.days(rows)
      {:ok, Enum.sort_by(Enum.flat_map(days, &day_requests(&1, ops)), & &1.ref), placed(days)}
    end
  end

  defp marked({%{place: {kind, _value}} = op, index}) when kind in [:words, :link],
    do: %{op | place: %{"name" => @mark <> Integer.to_string(index), "location" => @mark_point}}

  defp marked({op, _index}), do: op

  defp day_requests(%{stops: stops, position: k}, ops) do
    for %{place: %{"name" => @mark <> index}} <- stops do
      index = String.to_integer(index)
      %{place: {_kind, value}} = Enum.at(ops, index - 1)
      %{ref: index, place: value, day: k}
    end
  end

  defp placed(days) do
    for %{stops: stops, position: k} <- days,
        points = for(stop <- stops, not marked?(stop.place), do: Place.point(stop.place)),
        points != [],
        into: %{},
        do: {k, points}
  end

  defp marked?(nil), do: true
  defp marked?(%{"name" => @mark <> _index}), do: true
  defp marked?(_place), do: false

  @doc """
  `call` with each place given resolved by `outcomes` (`Lookup.resolve/3`'s,
  by op): a placed record as a stop keeps it, else no place on an add and the
  place it had on an edit; and the outcomes as they now stand, a record too
  large to keep being `{:none, :unstorable}`.
  """
  @spec placed_call(map(), [{pos_integer(), Lookup.outcome()}]) :: {map(), outcomes()}
  def placed_call(%{ops: ops} = call, outcomes) when is_list(outcomes) do
    by_op = Map.new(outcomes)

    {placed, kept} =
      ops
      |> Enum.with_index(1)
      |> Enum.map(fn {op, index} -> resolved(op, index, Map.get(by_op, index)) end)
      |> Enum.unzip()

    {%{call | ops: placed}, Enum.reject(kept, &is_nil/1)}
  end

  defp resolved(%{place: {kind, _value}} = op, index, outcome) when kind in [:words, :link] do
    case outcome do
      nil -> {%{op | place: unplaced(op)}, nil}
      {:placed, record} -> stored(op, index, Place.from_search(record))
      other -> {%{op | place: unplaced(op)}, {index, other}}
    end
  end

  defp resolved(op, _index, _outcome), do: {op, nil}

  defp stored(op, index, {:ok, place}), do: {%{op | place: place}, {index, {:placed, place}}}

  defp stored(op, index, {:error, {:invalid_place, _field}}),
    do: {%{op | place: unplaced(op)}, {index, {:none, :unstorable}}}

  # A place the lookup did not place: an add's stop has none, an edit's stop
  # keeps the one it had.
  defp unplaced(%{op: :add}), do: nil
  defp unplaced(%{op: :edit}), do: :keep

  @doc """
  Each stop `call` gave a place to, as `applied` (the store's answer) holds
  it, with what its place came to: `Trips.Render.answer/2`'s placements.
  """
  @spec placements(map(), map(), outcomes()) :: [
          %{row: map(), outcome: term(), kept: boolean()}
        ]
  def placements(%{ops: ops}, %{rows: rows} = applied, outcomes) when is_list(outcomes) do
    made = made_by_add(ops, rows ++ Map.get(applied, :removed_rows, []))
    live = Map.new(rows, &{&1.id, &1})

    # A stop removed later in the call, or by another edit since, has no line.
    placed =
      for {index, outcome} <- outcomes,
          op <- [Enum.at(ops, index - 1)],
          %{id: id} <- [stop_of(op, index, made, rows)],
          Map.has_key?(live, id),
          do: %{row: Map.fetch!(live, id), outcome: outcome, kept: kept?(op, outcome)}

    placed |> Enum.reverse() |> Enum.uniq_by(& &1.row.id) |> Enum.reverse()
  end

  defp kept?(%{op: :edit}, {:placed, _place}), do: false
  defp kept?(%{op: :edit}, _outcome), do: true
  defp kept?(%{op: :add}, _outcome), do: false

  defp made_by_add(ops, rows) do
    adds = for {%{op: :add}, index} <- Enum.with_index(ops, 1), do: index

    new_stops =
      rows |> Enum.filter(&(&1.kind == :stop and &1.dirty == :new)) |> Enum.sort_by(& &1.n)

    adds |> Enum.zip(new_stops) |> Map.new()
  end

  defp stop_of(%{op: :add}, index, made, _rows), do: Map.get(made, index)
  defp stop_of(%{op: :edit, n: n}, _index, _made, rows), do: Enum.find(rows, &(&1.n == n))
end
