defmodule FermixCore.Trips.Ops do
  @moduledoc """
  What each op of a `trip_edit` call, or a device's op, does to a trip (M89
  §04, §05, §06): pure functions over the rows one transaction loaded, run by
  `Memory.Repo.TripsSql` inside that transaction, so the whole call lands or
  none of it does. One call is one trip; the ops after a `create` address the
  trip it made.

  `apply/3` takes the owner's trips (the live ones, and a removed one a
  device's `restore` names), the live rows of the trip the call names
  (`referenced/2`) and its removed rows, with the first moment a removed row
  is still kept once the call is written (`kept_from`), and the call as
  `Trips.Shape` made it, and answers the trip and its rows as they now
  stand: the rows to write, the rows removed, what happened in a few words,
  which rows the call added or changed, the id the last create or add made,
  and each fixed stop whose date moved (C14). A trip the call changed moves
  its `rev` once.

  Rows are in one order by `position` (`Kept.Positions`). A day is a row and
  the stops after it are its stops (`days/1`); the first live row is always a
  day, and the only day cannot be removed. A day has no date of its own: its
  date is the trip's `starts_on` plus its position (`day_date/2`), so moving a
  day never leaves a date behind. A row's `n` comes from the trip's `next_n`,
  shared by days and stops, which only goes up. `day` past the last (on `add`
  and `day`) makes the empty days up to it. A day moved takes its stops with
  it as one run.

  After outside content a call may only add (`@outside_ops`): every other op,
  `create` included, is refused, and the stop it adds is stamped. Such an add
  makes no day: a `day` past the last is refused (`:outside_new_day`).

  Removal is soft, as a list's: a removed row keeps its `removed_at`, and the
  stops removed with their day keep the day's id (`removed_with`), so a day a
  device restores comes back with exactly those stops (C34). A removed trip's
  title is free at once; a restored trip comes back under its title only while
  no live trip holds it, compared case-blind.

  `made` is the id the last `create` (the trip), `add` (the stop) or a
  device's new `day` made; the days a create or an add makes on the way never
  overwrite it (C19). The caps are 30 live trips, 1,000 live rows a trip, and
  a call that can grow a trip (`@growing_ops`) refused when its `trip` object
  (`Trips.Wire`), with the removed rows a pull carries while the store keeps
  them, would pass 768 KiB (C10); a remove, move or restore is never refused,
  so a trip at the cap can always shrink, and every push fits a line.

  Refusals are `{:error, {:op_failed, op_index, reason}}`, the op counted from
  1, and a trip no live trip answers to is `{:error, {:no_trip, ref, titles}}`;
  `Trips.Registry.describe_error/1` turns each into a sentence.
  """

  alias FermixCore.Kept.Access, as: KeptAccess
  alias FermixCore.Kept.Ids
  alias FermixCore.Kept.Positions
  alias FermixCore.Trips.Geo
  alias FermixCore.Trips.Place
  alias FermixCore.Trips.Wire

  @max_trips 30
  @max_rows 1_000
  @max_wire_bytes 768 * 1_024
  # The only ops a call that read outside content may run (§14): an
  # allow-list, so an op added later is refused there until it is ruled on.
  @outside_ops [:add]
  # The ops that can grow a trip's wire form, the only ones the size guard
  # measures (`fits/2`). Remove, move and restore only take a row between its
  # live and removed forms or move it: the removed form adds a `removed_at`
  # (42 bytes) and a move at most a `leg_m`, so from the last measured call, at
  # most 768 KiB, a trip of 1,000 live rows gains under 70 KB however it is
  # removed, moved or brought back, inside the 1 MiB line; and a trip at the
  # cap can always shrink.
  @growing_ops [:create, :add, :edit, :day, :rename, :dates]
  @stop_fields [:time, :duration, :fixed, :note, :place]

  @typedoc "One trip as the store holds it, with what this call did to it."
  @type trip_meta :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:starts_on) => Date.t() | nil,
          required(:timezone) => String.t() | nil,
          required(:position) => integer(),
          required(:rev) => non_neg_integer(),
          required(:next_n) => pos_integer(),
          required(:removed_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  One day or stop (`Memory.Repo.TripsSql.decode_row/1`). A day's `text` is
  its name or "", and it carries only a `timezone`; a stop's `place` is a
  `Trips.Place` record or nil. `dirty` is what this call did to the row.
  """
  @type row :: %{
          required(:id) => String.t(),
          required(:trip_id) => String.t(),
          required(:n) => pos_integer(),
          required(:kind) => :day | :stop,
          required(:text) => String.t(),
          required(:note) => String.t() | nil,
          required(:time) => String.t() | nil,
          required(:duration) => pos_integer() | nil,
          required(:fixed) => boolean(),
          required(:timezone) => String.t() | nil,
          required(:place) => Place.t() | nil,
          required(:position) => integer(),
          required(:stamped) => boolean(),
          required(:made_via) => String.t(),
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t(),
          required(:removed_at) => DateTime.t() | nil,
          required(:removed_with) => String.t() | nil,
          required(:dirty) => nil | :new | :changed | :restored
        }

  @typedoc "What `apply/3` hands back: the trip's next state and the call's summary."
  @type result :: %{
          trip: trip_meta(),
          rows: [row()],
          removed_rows: [row()],
          changed?: boolean(),
          made: String.t() | nil,
          events: [String.t()],
          touched_rows: [String.t()],
          dates_moved: [%{row: row(), from: Date.t() | nil, to: Date.t() | nil}]
        }

  @doc "The most live trips an owner keeps."
  @spec max_trips() :: pos_integer()
  def max_trips, do: @max_trips

  @doc "The most live rows, days and stops together, a trip holds."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @doc "The most bytes a trip's `trip` object may take on the wire."
  @spec max_wire_bytes() :: pos_integer()
  def max_wire_bytes, do: @max_wire_bytes

  # --- what a call names -----------------------------------------------------

  @doc """
  The live trip `ref` names: its id, or its title compared case-blind (as the
  lists fold it, Unicode and trimmed), which names one trip because titles are
  unique that way.
  """
  @spec resolve([trip_meta()], String.t()) :: {:ok, trip_meta()} | {:error, term()}
  def resolve(trips, ref) when is_list(trips) and is_binary(ref) do
    live = live(trips)

    case Enum.find(live, &names?(&1, ref)) do
      nil -> {:error, {:no_trip, ref, Enum.map(live, & &1.title)}}
      trip -> {:ok, trip}
    end
  end

  defp names?(trip, ref) do
    if Ids.valid?(ref, "tr_"), do: trip.id == ref, else: same_words?(trip.title, ref)
  end

  @doc "The id of the existing trip whose rows a call needs, nil for a create or one no trip answers to."
  @spec referenced([trip_meta()], map()) :: String.t() | nil
  def referenced(trips, %{trip: ref, ops: ops}) when is_list(trips) and is_list(ops) do
    case ops do
      [%{op: :create} | _rest] -> nil
      [%{op: :restore, row: nil}] -> ref
      _ops -> trips |> resolve(ref) |> found_id()
    end
  end

  defp found_id({:ok, trip}), do: trip.id
  defp found_id({:error, _reason}), do: nil

  @doc "The removed trip a device's `restore` brings back, which the store loads beside the live ones."
  @spec restored_trip(map()) :: String.t() | nil
  def restored_trip(%{trip: id, ops: [%{op: :restore, row: nil}]}), do: id
  def restored_trip(%{ops: ops}) when is_list(ops), do: nil

  # --- reading a trip --------------------------------------------------------

  @doc "The trip's days in order: each day's row, its stops, and its position from 1."
  @spec days([row()]) :: [%{row: row(), stops: [row()], position: pos_integer()}]
  def days(rows) when is_list(rows) do
    rows
    |> Enum.reduce([], fn
      %{kind: :day} = day, acc -> [{day, []} | acc]
      %{kind: :stop} = stop, [{day, stops} | rest] -> [{day, [stop | stops]} | rest]
    end)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {{day, stops}, k} -> %{row: day, stops: Enum.reverse(stops), position: k} end)
  end

  @doc "The date of the day at position `k` of a trip that starts on `starts_on`; nil with no start."
  @spec day_date(Date.t() | nil, pos_integer()) :: Date.t() | nil
  def day_date(nil, k) when is_integer(k) and k >= 1, do: nil

  def day_date(%Date{} = starts_on, k) when is_integer(k) and k >= 1,
    do: Date.add(starts_on, k - 1)

  @doc """
  Each placed stop's straight line in metres from the placed stop before it in
  its day, passing over any unplaced stop between (C7); the day's first placed
  stop and an unplaced stop have none.
  """
  @spec legs([row()]) :: %{String.t() => non_neg_integer()}
  def legs(rows) when is_list(rows) do
    rows |> days() |> Enum.flat_map(&day_legs(&1.stops)) |> Map.new()
  end

  defp day_legs(stops) do
    {legs, _last} = Enum.reduce(stops, {[], nil}, &leg/2)
    legs
  end

  defp leg(%{place: nil}, {legs, last}), do: {legs, last}
  defp leg(stop, {legs, nil}), do: {legs, Place.point(stop.place)}

  defp leg(stop, {legs, last}) do
    point = Place.point(stop.place)
    {[{stop.id, Geo.distance_m(last, point)} | legs], point}
  end

  @doc "How many days and stops `rows` hold."
  @spec counts([row()]) :: {non_neg_integer(), non_neg_integer()}
  def counts(rows) when is_list(rows) do
    days = Enum.count(rows, &(&1.kind == :day))
    {days, length(rows) - days}
  end

  # --- the call --------------------------------------------------------------

  @doc """
  Applies `call` (`%{trip: ref, ops: [op]}`) to `loaded` (`%{trips:, rows:}`,
  and the trip's removed rows as `removed:` with `kept_from:` when the store
  holds some) under `edit` (`now`, `outside?`, `made_via`), all of it or none.
  """
  @spec apply(map(), %{trip: String.t() | nil, ops: [map()]}, map()) ::
          {:ok, result()} | {:error, term()}
  def apply(%{trips: trips, rows: rows} = loaded, %{trip: ref, ops: [_ | _] = ops}, edit)
      when is_list(trips) and is_list(rows) and is_map_key(edit, :now) do
    initial = %{
      trips: trips,
      trip: nil,
      rows: rows,
      removed: Map.get(loaded, :removed, []),
      kept_from: Map.get(loaded, :kept_from),
      removed_rows: [],
      made: nil,
      events: [],
      added: %{stops: 0, days: 0},
      touched: [],
      changed?: false
    }

    with {:ok, state, rest, offset} <- target(initial, ref, ops, edit),
         {:ok, state} <- run_ops(state, rest, offset, edit) do
      finish(state, before(trips, rows, ops, ref), edit, ops)
    end
  end

  # The trip a call changes: one its first op creates, a removed one a
  # device's `restore` brings back, or an existing live one.
  defp target(state, ref, [%{op: :create} = create | rest], edit) do
    with :ok <- outside_allows(edit, create),
         {:ok, state} <- create(state, create.title || ref, create, edit) do
      {:ok, state, rest, 2}
    else
      {:error, reason} -> {:error, {:op_failed, 1, reason}}
    end
  end

  defp target(state, id, [%{op: :restore, row: nil} = restore], edit) do
    with :ok <- outside_allows(edit, restore),
         {:ok, state} <- restore_trip(state, id, restore) do
      {:ok, state, [], 2}
    else
      {:error, {:no_trip, _id, _titles} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:op_failed, 1, reason}}
    end
  end

  defp target(state, ref, ops, _edit) do
    with {:ok, trip} <- resolve(state.trips, ref), do: {:ok, %{state | trip: trip}, ops, 1}
  end

  defp run_ops(state, ops, offset, edit) do
    ops
    |> Enum.with_index(offset)
    |> Enum.reduce_while({:ok, state}, fn {op, index}, {:ok, acc} ->
      case op(acc, op, edit) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:op_failed, index, reason}}}
      end
    end)
  end

  # Nothing reaches a trip a call removed, and after outside content nothing
  # but an add.
  defp op(state, op, edit) do
    cond do
      op.op == :create -> {:error, :create_not_first}
      outside_allows(edit, op) != :ok -> {:error, :outside_content}
      state.trip.removed_at -> {:error, :trip_removed}
      op.op in [:rename, :dates, :remove_trip] -> trip_op(state, op, edit)
      true -> row_op(state, op, edit)
    end
  end

  defp outside_allows(%{outside?: true}, %{op: op}) when op not in @outside_ops,
    do: {:error, :outside_content}

  defp outside_allows(_edit, _op), do: :ok

  # --- trips -----------------------------------------------------------------

  defp create(state, title, op, edit) do
    live = live(state.trips)

    cond do
      length(live) >= @max_trips -> {:error, :too_many_trips}
      title_taken?(live, title, nil) -> {:error, {:title_taken, title}}
      true -> state |> new_trip(title, op, edit) |> make_days(op.days, edit)
    end
  end

  defp new_trip(state, title, op, edit) do
    trip = %{
      id: Ids.new("tr_"),
      title: title,
      starts_on: op.starts_on,
      timezone: op.timezone,
      position: Positions.after_last(Enum.map(state.trips, & &1.position)),
      rev: 0,
      next_n: 1,
      created_at: edit.now,
      updated_at: edit.now,
      removed_at: nil,
      created?: true,
      restored?: false
    }

    %{state | trip: trip, rows: [], made: trip.id} |> changed() |> event("created")
  end

  defp restore_trip(state, id, restore) do
    live = live(state.trips)

    case Enum.find(state.trips, &(&1.id == id)) do
      nil -> {:error, {:no_trip, id, Enum.map(live, & &1.title)}}
      %{removed_at: nil} -> {:error, :not_removed}
      trip -> revive(state, live, trip, restore.title || trip.title)
    end
  end

  defp revive(state, live, trip, title) do
    words = if title == trip.title, do: "restored", else: "restored as " <> quoted(title)

    cond do
      length(live) >= @max_trips -> {:error, :too_many_trips}
      title_taken?(live, title, trip.id) -> {:error, {:title_in_use, title}}
      true -> {:ok, %{state | trip: revived(trip, title)} |> changed() |> event(words)}
    end
  end

  defp revived(trip, title),
    do: %{trip | removed_at: nil, title: title} |> Map.put(:restored?, true)

  defp trip_op(state, %{op: :rename, text: title}, _edit) do
    trip = state.trip

    cond do
      trip.title == title ->
        {:ok, event(state, "already named " <> quoted(title))}

      title_taken?(live(state.trips), title, trip.id) ->
        {:error, {:title_taken, title}}

      true ->
        {:ok, state |> put_trip(title: title) |> event("renamed from " <> quoted(trip.title))}
    end
  end

  defp trip_op(state, %{op: :dates, starts_on: starts_on, timezone: zone}, _edit) do
    zone = if zone == :keep, do: state.trip.timezone, else: zone
    words = if starts_on, do: "starts on " <> Date.to_iso8601(starts_on), else: "has no dates"
    {:ok, state |> put_trip(starts_on: starts_on, timezone: zone) |> event(words)}
  end

  defp trip_op(state, %{op: :remove_trip}, edit),
    do: {:ok, state |> put_trip(removed_at: edit.now) |> event("removed")}

  defp put_trip(state, fields),
    do: %{state | trip: Map.merge(state.trip, Map.new(fields))} |> changed()

  defp title_taken?(trips, title, except_id),
    do: Enum.any?(trips, &(&1.id != except_id and same_words?(&1.title, title)))

  # --- adding ----------------------------------------------------------------

  defp row_op(state, %{op: :add} = op, edit) do
    with :ok <- outside_day(state.rows, op, edit),
         {:ok, state, made_days} <- ensure_day(state, op.day, edit),
         {:ok, index} <- add_index(state.rows, op),
         :ok <- room(state, 1) do
      {row, state} = new_row(state, :stop, op, edit)

      state
      |> insert(index, row, edit.now)
      |> Map.put(:made, row.id)
      |> count_added(:days, made_days)
      |> count_added(:stops, 1)
      |> touch(row.id)
      |> changed()
      |> ok()
    end
  end

  # An edit left with nothing to give changes nothing: one whose only field was
  # a place the lookup did not place keeps it (`Trips.Placing`), and the
  # answer says so by itself.
  defp row_op(state, %{op: :edit, n: ref, text: nil} = op, _edit)
       when op.time == :keep and op.duration == :keep and op.fixed == :keep and
              op.note == :keep and op.place == :keep do
    with {:ok, _index, _row} <- stop_at(state.rows, ref), do: {:ok, state}
  end

  defp row_op(state, %{op: :edit, n: ref} = op, edit) do
    with {:ok, index, row} <- stop_at(state.rows, ref) do
      updated = row |> edited(op) |> dirty(edit.now)

      state
      |> replace(index, updated)
      |> event("edited " <> handle(updated))
      |> touch(updated.id)
      |> changed()
      |> ok()
    end
  end

  defp row_op(state, %{op: :move, n: ref} = op, edit) do
    with {:ok, index, row} <- find(state.rows, ref) do
      if row.kind == :day,
        do: move_day(state, {index, row}, op, edit),
        else: move_stop(state, {index, row}, op, edit)
    end
  end

  defp row_op(state, %{op: :day, day: {:new, after_ref}} = op, edit) do
    with {:ok, index} <- new_day_index(state.rows, after_ref),
         :ok <- room(state, 1) do
      {row, state} = new_row(state, :day, %{text: ""}, edit)
      state = state |> insert(index, row, edit.now) |> Map.put(:made, row.id)
      state |> count_added(:days, 1) |> name_day(row.id, op, edit)
    end
  end

  defp row_op(state, %{op: :day, day: k} = op, edit) when is_integer(k) do
    with {:ok, state, made_days} <- ensure_day(state, k, edit) do
      %{row: day} = state.rows |> days() |> Enum.at(k - 1)
      state |> count_added(:days, made_days) |> name_day(day.id, op, edit)
    end
  end

  defp row_op(state, %{op: :day, day: ref} = op, edit) do
    with {:ok, _index, day} <- day_at(state.rows, ref), do: name_day(state, day.id, op, edit)
  end

  defp row_op(state, %{op: :remove, n: ref}, edit) do
    with {:ok, index, row} <- find(state.rows, ref) do
      if row.kind == :day,
        do: remove_day(state, {index, row}, edit),
        else: remove_stop(state, {index, row}, edit)
    end
  end

  defp row_op(state, %{op: :restore, row: {:id, id} = ref}, edit) do
    case Enum.find(state.removed, &(&1.id == id)) do
      %{kind: :day} = day ->
        restore_day(state, day, edit)

      %{kind: :stop} = stop ->
        restore_stop(state, stop, edit)

      nil ->
        if live_row?(state.rows, id), do: {:error, :not_removed}, else: {:error, {:no_row, ref}}
    end
  end

  # After outside content an add makes no day: its stop goes on a day the trip
  # has, or after a row it has, so no page stretches the trip (§14).
  defp outside_day(rows, %{day: k}, %{outside?: true}) when is_integer(k) do
    {count, _stops} = counts(rows)
    if k > count, do: {:error, :outside_new_day}, else: :ok
  end

  defp outside_day(_rows, _op, _edit), do: :ok

  # A day past the last is made, with every empty day before it.
  defp ensure_day(state, k, edit) when is_integer(k) do
    {count, _stops} = counts(state.rows)

    if k > count,
      do: with({:ok, state} <- make_days(state, k - count, edit), do: {:ok, state, k - count}),
      else: {:ok, state, 0}
  end

  defp ensure_day(state, _ref, _edit), do: {:ok, state, 0}

  # Empty days at the end, one at a time while the trip has room: at most the
  # row cap, the bound on every loop here.
  defp make_days(state, 0, _edit), do: {:ok, state}

  defp make_days(state, count, edit) when count > 0 do
    with :ok <- room(state, 1) do
      {row, state} = new_row(state, :day, %{text: ""}, edit)
      state |> insert(length(state.rows), row, edit.now) |> make_days(count - 1, edit)
    end
  end

  # A stop lands at the end of its day, or right after the row `after` names:
  # after a day's own row it is that day's first stop.
  defp add_index(rows, %{day: day}) when not is_nil(day) do
    with {:ok, index, _day} <- day_at(rows, day), do: {:ok, block_end(rows, index)}
  end

  defp add_index(rows, %{after: ref}) do
    with {:ok, index, _row} <- find(rows, ref), do: {:ok, index + 1}
  end

  defp new_day_index(rows, nil), do: {:ok, length(rows)}

  defp new_day_index(rows, ref) do
    with {:ok, index, _day} <- day_at(rows, ref), do: {:ok, block_end(rows, index)}
  end

  defp new_row(state, kind, fields, edit) do
    trip = state.trip

    row =
      Map.merge(
        %{
          id: Ids.new("ti_"),
          trip_id: trip.id,
          n: trip.next_n,
          kind: kind,
          note: nil,
          time: nil,
          duration: nil,
          fixed: false,
          timezone: nil,
          place: nil,
          position: 0,
          stamped: kind == :stop and edit.outside?,
          made_via: edit.made_via,
          created_at: edit.now,
          updated_at: edit.now,
          removed_at: nil,
          removed_with: nil,
          dirty: :new
        },
        row_fields(kind, fields)
      )

    {row, %{state | trip: %{trip | next_n: trip.next_n + 1}}}
  end

  defp row_fields(:day, %{text: text}), do: %{text: text}

  defp row_fields(:stop, op) do
    op
    |> Map.take([:text | @stop_fields])
    |> Map.update!(:place, &record/1)
  end

  # A place reaches here resolved: a record, or none. The place lookup turns a
  # model's words or link into one before the store is asked.
  defp record(nil), do: nil
  defp record(%{"name" => _name, "location" => _location} = place), do: place

  # --- changing --------------------------------------------------------------

  defp edited(row, op) do
    row = if op.text, do: %{row | text: op.text}, else: row

    Enum.reduce(@stop_fields, row, fn field, acc ->
      case Map.fetch!(op, field) do
        :keep -> acc
        value when field == :place -> Map.put(acc, :place, record(value))
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp move_stop(state, {index, row}, op, edit) do
    rest = List.delete_at(state.rows, index)

    with :ok <- stop_place(op, row),
         {:ok, target} <- stop_target(rest, op) do
      moved = dirty(row, edit.now)
      state = %{state | rows: Positions.insert(rest, target, moved, edit.now)}

      state
      |> event("moved #{handle(moved)} to Day #{day_of(state.rows, moved.id)}")
      |> touch(moved.id)
      |> changed()
      |> ok()
    end
  end

  defp stop_place(%{after: :start}, _row), do: {:error, {:device, :move_needs_place}}

  defp stop_place(%{after: ref}, row) when not is_nil(ref) do
    if names_row?(row, ref), do: {:error, {:after_self, ref}}, else: :ok
  end

  defp stop_place(_op, _row), do: :ok

  defp stop_target(rows, %{day: k}) when is_integer(k) do
    {count, _stops} = counts(rows)

    if k > count,
      do: {:error, {:no_day, k, count}},
      else: {:ok, rows |> day_indexes() |> Enum.at(k - 1) |> then(&block_end(rows, &1))}
  end

  defp stop_target(rows, op), do: add_index(rows, op)

  # A day moves with its stops as one run: before the day now at position
  # `day` (the end past the last), after `after`'s day, or a device's first.
  defp move_day(state, {index, day}, op, edit) do
    stop = block_end(state.rows, index)
    {block, rest} = split_run(state.rows, index, stop)
    from = day_of(state.rows, day.id)

    with {:ok, target} <- day_target(rest, day, op) do
      moved = Enum.map(block, &dirty(&1, edit.now))
      rows = Positions.insert_run(rest, target, moved, edit.now)

      %{state | rows: rows}
      |> event("moved Day #{from} to Day #{day_of(rows, day.id)}")
      |> touch(day.id)
      |> changed()
      |> ok()
    end
  end

  defp day_target(_rows, _day, %{after: :start}), do: {:ok, 0}

  defp day_target(rows, _day, %{day: k}) when is_integer(k),
    do: {:ok, rows |> day_indexes() |> Enum.at(k - 1) |> at_or_end(rows)}

  defp day_target(rows, day, %{day: ref}) when not is_nil(ref) do
    with :ok <- not_self(day, ref),
         {:ok, index, _day} <- day_at(rows, ref),
         do: {:ok, index}
  end

  defp day_target(rows, day, %{after: ref}) do
    with :ok <- not_self(day, ref),
         {:ok, index, _day} <- day_at(rows, ref),
         do: {:ok, block_end(rows, index)}
  end

  defp not_self(day, ref),
    do: if(names_row?(day, ref), do: {:error, {:after_self, ref}}, else: :ok)

  # A day's name and zone as the op gives them; a day just made is counted
  # among the days added, so it needs no words of its own.
  defp name_day(state, day_id, op, edit) do
    index = Enum.find_index(state.rows, &(&1.id == day_id))
    day = Enum.at(state.rows, index)
    named = %{day | text: keep(op.text, day.text), timezone: keep(op.timezone, day.timezone)}
    k = day_of(state.rows, day_id)

    cond do
      named != day ->
        state
        |> replace(index, dirty(named, edit.now))
        |> event(day_words(k, day, named))
        |> touch(day_id)
        |> changed()
        |> ok()

      day.dirty == :new ->
        state |> touch(day_id) |> changed() |> ok()

      true ->
        {:ok, event(state, "Day #{k} unchanged")}
    end
  end

  defp keep(:keep, current), do: current
  defp keep(value, _current), do: value

  defp day_words(k, day, named) do
    [
      if(named.text != day.text, do: name_words(k, named.text)),
      if(named.timezone != day.timezone, do: zone_words(k, named.timezone))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp name_words(k, ""), do: "Day #{k} unnamed"
  defp name_words(k, text), do: "named Day #{k} " <> quoted(text)
  defp zone_words(k, nil), do: "Day #{k} in the trip's zone"
  defp zone_words(k, zone), do: "Day #{k} in #{zone}"

  # --- removing and restoring ------------------------------------------------

  defp remove_stop(state, {index, row}, edit) do
    state
    |> Map.put(:rows, List.delete_at(state.rows, index))
    |> Map.update!(:removed_rows, &[gone(row, edit.now, nil) | &1])
    |> event("removed " <> handle(row))
    |> changed()
    |> ok()
  end

  # A day goes with its stops, all at one `removed_at`, the stops marked as
  # removed with it; the only day stays.
  defp remove_day(state, {index, day}, edit) do
    {count, _stops} = counts(state.rows)

    if count == 1 do
      {:error, {:last_day, state.trip.title}}
    else
      {[_day | stops], rest} = split_run(state.rows, index, block_end(state.rows, index))
      gone = [gone(day, edit.now, nil) | Enum.map(stops, &gone(&1, edit.now, day.id))]
      words = "removed Day #{day_of(state.rows, day.id)} and its #{plural(length(stops), "stop")}"

      %{state | rows: rest, removed_rows: gone ++ state.removed_rows}
      |> event(words)
      |> changed()
      |> ok()
    end
  end

  defp gone(row, now, with_day),
    do: %{row | updated_at: now, removed_at: now, removed_with: with_day}

  # A stop comes back where its position puts it, never ahead of the first day.
  defp restore_stop(state, row, edit) do
    with :ok <- room(state, 1) do
      at = state.rows |> Enum.find_index(&(&1.position > row.position)) |> at_or_end(state.rows)
      back = restored(row, edit.now)

      %{state | rows: Positions.insert(state.rows, max(at, 1), back, edit.now)}
      |> Map.update!(:removed, &List.delete(&1, row))
      |> event("restored " <> handle(back))
      |> touch(back.id)
      |> changed()
      |> ok()
    end
  end

  # A day comes back with the stops removed with it, before the first live day
  # whose position is past its own.
  defp restore_day(state, day, edit) do
    stops =
      state.removed |> Enum.filter(&(&1.removed_with == day.id)) |> Enum.sort_by(& &1.position)

    with :ok <- room(state, 1 + length(stops)) do
      at = Enum.find_index(state.rows, &(&1.kind == :day and &1.position > day.position))
      run = Enum.map([day | stops], &restored(&1, edit.now))
      rows = Positions.insert_run(state.rows, at_or_end(at, state.rows), run, edit.now)
      back = MapSet.new(run, & &1.id)

      %{state | rows: rows, removed: Enum.reject(state.removed, &MapSet.member?(back, &1.id))}
      |> event("restored Day #{day_of(rows, day.id)} and its #{plural(length(stops), "stop")}")
      |> touch(day.id)
      |> changed()
      |> ok()
    end
  end

  defp restored(row, now),
    do: %{row | removed_at: nil, removed_with: nil, updated_at: now, dirty: :restored}

  defp at_or_end(nil, rows), do: length(rows)
  defp at_or_end(index, _rows), do: index

  defp live_row?(rows, id), do: Enum.any?(rows, &(&1.id == id))

  # --- rows ------------------------------------------------------------------

  # A row by its number (the model's) or by `{:id, row_id}` (a device's).
  defp find(rows, ref) do
    case Enum.find_index(rows, &names_row?(&1, ref)) do
      nil -> {:error, {:no_row, ref}}
      index -> {:ok, index, Enum.at(rows, index)}
    end
  end

  defp names_row?(row, {:id, id}), do: row.id == id
  defp names_row?(row, n), do: row.n == n

  defp stop_at(rows, ref) do
    case find(rows, ref) do
      {:ok, _index, %{kind: :day}} -> {:error, {:not_a_stop, ref}}
      found -> found
    end
  end

  # A day by its position (the model's) or by its row's id (a device's).
  defp day_at(rows, k) when is_integer(k) do
    {count, _stops} = counts(rows)

    case rows |> day_indexes() |> Enum.at(k - 1) do
      nil -> {:error, {:no_day, k, count}}
      index -> {:ok, index, Enum.at(rows, index)}
    end
  end

  defp day_at(rows, ref) do
    case find(rows, ref) do
      {:ok, _index, %{kind: :stop}} -> {:error, {:not_a_day, ref}}
      found -> found
    end
  end

  defp day_indexes(rows), do: for({%{kind: :day}, index} <- Enum.with_index(rows), do: index)

  # The index after the last stop of the day at `index`.
  defp block_end(rows, index) do
    case rows |> Enum.drop(index + 1) |> Enum.find_index(&(&1.kind == :day)) do
      nil -> length(rows)
      offset -> index + 1 + offset
    end
  end

  defp split_run(rows, from, to) do
    {before, rest} = Enum.split(rows, from)
    {run, after_run} = Enum.split(rest, to - from)
    {run, before ++ after_run}
  end

  # The position of the day a row is in, from 1.
  defp day_of(rows, id) do
    rows
    |> Enum.take_while(&(&1.id != id))
    |> Enum.count(&(&1.kind == :day))
    |> then(fn before -> if day?(rows, id), do: before + 1, else: before end)
  end

  defp day?(rows, id), do: Enum.any?(rows, &(&1.id == id and &1.kind == :day))

  defp room(state, count) do
    if length(state.rows) + count <= @max_rows,
      do: :ok,
      else: {:error, {:trip_full, state.trip.title}}
  end

  defp insert(state, index, row, now),
    do: %{state | rows: Positions.insert(state.rows, index, row, now)}

  defp replace(state, index, row), do: %{state | rows: List.replace_at(state.rows, index, row)}

  defp dirty(row, now), do: %{row | updated_at: now, dirty: row.dirty || :changed}

  # --- bookkeeping -----------------------------------------------------------

  defp changed(state), do: %{state | changed?: true}
  defp ok(state), do: {:ok, state}
  defp event(state, words), do: %{state | events: state.events ++ [words]}

  defp touch(state, id) do
    if id in state.touched, do: state, else: %{state | touched: state.touched ++ [id]}
  end

  # Adds are told as counts, at the place in the answer of the first one.
  defp count_added(state, _kind, 0), do: state

  defp count_added(state, kind, count) do
    marker = {:added, kind}
    events = if marker in state.events, do: state.events, else: state.events ++ [marker]
    %{state | events: events, added: Map.update!(state.added, kind, &(&1 + count))}
  end

  @doc """
  A stop as a call's answer names it: its number and its words, JSON-quoted,
  framed when they were written after outside content (§14), as a read frames
  them, so every answer that repeats them marks the turn as the read does.
  """
  @spec handle(row()) :: String.t()
  def handle(%{n: n, stamped: true, text: text}) when is_integer(n),
    do: "[#{n}] " <> KeptAccess.outside_frame() <> " " <> quoted(text)

  def handle(%{n: n, stamped: false, text: text}) when is_integer(n),
    do: "[#{n}] " <> quoted(text)

  defp quoted(text), do: Jason.encode!(text)

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp live(trips),
    do: trips |> Enum.filter(&is_nil(&1.removed_at)) |> Enum.sort_by(&{&1.position, &1.id})

  # Titles compare as one spelling: trimmed, in Unicode NFC (a title kept
  # before titles were stored so is folded here too) and case-blind. Every
  # title and ref here is whole Unicode (`Trips.Shape`).
  defp same_words?(a, b), do: title_key(a) == title_key(b)

  defp title_key(title),
    do: title |> String.trim() |> :unicode.characters_to_nfc_binary() |> String.downcase()

  # --- the end of the call ---------------------------------------------------

  # The fixed stops' dates as the call found them, to name the ones it moved.
  defp before(_trips, _rows, [%{op: :create} | _rest], _ref), do: %{}

  defp before(trips, rows, _ops, ref) do
    case resolve(trips, ref) do
      {:ok, trip} -> fixed_dates(trip.starts_on, rows)
      {:error, _reason} -> %{}
    end
  end

  defp fixed_dates(starts_on, rows) do
    for %{stops: stops, position: k} <- days(rows),
        %{fixed: true} = stop <- stops,
        into: %{},
        do: {stop.id, day_date(starts_on, k)}
  end

  # The trip a call changed moves its rev once and must still fit the wire.
  defp finish(state, before, edit, ops) do
    trip = state.trip
    trip = if state.changed?, do: %{trip | rev: trip.rev + 1, updated_at: edit.now}, else: trip
    state = %{state | trip: trip}

    with :ok <- fits(state, ops) do
      {:ok,
       %{
         trip: trip,
         rows: state.rows,
         removed_rows: state.removed_rows,
         changed?: state.changed?,
         made: state.made,
         events: Enum.map(state.events, &event_words(&1, state.added)),
         touched_rows: Enum.filter(state.touched, &live_row?(state.rows, &1)),
         dates_moved: dates_moved(before, state)
       }}
    end
  end

  defp fits(%{changed?: false}, _ops), do: :ok
  defp fits(%{trip: %{removed_at: %DateTime{}}}, _ops), do: :ok

  defp fits(%{trip: trip, rows: rows} = state, ops) do
    cond do
      not Enum.any?(ops, &(&1.op in @growing_ops)) -> :ok
      Wire.bytes(trip, rows, kept_removed(state)) <= @max_wire_bytes -> :ok
      true -> {:error, {:trip_too_large, trip.title}}
    end
  end

  # The removed rows a pull with them carries once the call is written: those
  # the store held and the call did not bring back, and those it removed, less
  # any it also added; each while the store keeps it (`kept_from`, when the
  # caller names one: the store sweeps every row removed before it).
  defp kept_removed(state) do
    stored = Enum.reject(state.removed_rows, &(&1.dirty == :new))
    Enum.filter(state.removed ++ stored, &kept?(&1, state.kept_from))
  end

  defp kept?(_row, nil), do: true
  defp kept?(row, kept_from), do: DateTime.compare(row.removed_at, kept_from) != :lt

  defp event_words({:added, :stops}, added), do: plural(added.stops, "stop") <> " added"
  defp event_words({:added, :days}, added), do: plural(added.days, "day") <> " added"
  defp event_words(words, _added), do: words

  defp dates_moved(_before, %{trip: %{removed_at: %DateTime{}}}), do: []

  defp dates_moved(before, %{trip: trip, rows: rows}) do
    after_call = fixed_dates(trip.starts_on, rows)
    by_id = Map.new(rows, &{&1.id, &1})

    Enum.flat_map(before, fn {id, from} ->
      case Map.fetch(after_call, id) do
        {:ok, ^from} -> []
        {:ok, to} -> [%{row: Map.fetch!(by_id, id), from: from, to: to}]
        :error -> []
      end
    end)
  end
end
