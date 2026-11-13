defmodule FermixCore.Trips.Shape do
  @moduledoc """
  The shape of a change to a trip (M89 §04, §06), checked in the caller before
  the store is asked: a `trip_edit` call (`call/1`), one trip and at most 100
  ops, the ops after a `create` addressing the new trip; and one op a device
  sent (`device_change/1`), its rows named by id. Pure.

  Every op comes out as `Trips.Ops` takes it: its name an atom, rows named by
  number (`n`, `after`) from the model or `{:id, row_id}` from a device, a day
  by its position (`day: 2`) or a device's `{:id, day_row_id}`. A field an
  edit does not give is `:keep`; one given empty (or `duration: 0`) clears it.

  Bounds: a title 1..80, a day's name 0..80, a stop's words 1..200, a note at
  most 1,000 code points, each on one line (a note's lines each one); a time
  `HH:MM`; a duration 1..1440 minutes; a zone IANA (`Clock.validate_zone/1`);
  a date `YYYY-MM-DD`. A model's `place` is a link a place search returned or
  a place's own name (`{:link, url}`, `{:words, words}`), which the place
  lookup resolves before the store; a device's is a whole record
  (`Trips.Place.cut/1`).
  """

  alias FermixCore.Clock
  alias FermixCore.Kept.Ids
  alias FermixCore.Trips.Place

  @max_ops 100
  @max_days 1_000
  @title_max 80
  @day_max 80
  @text_max 200
  @note_max 1_000
  @minutes 1..1440
  @ops ~w(create add edit move day remove rename dates remove_trip)
  @device_ops ~w(create add edit move day remove restore rename dates remove_trip)
  @trip_prefix "tr_"
  @row_prefix "ti_"
  # The id fields a device's op carries, by the name each is refused under.
  @id_fields %{
    "trip_id" => :trip_id,
    "row_id" => :row_id,
    "day_id" => :day_id,
    "after_id" => :after_id
  }
  @time ~r/\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/
  @date ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  # A line break, another control character, a line or paragraph separator,
  # or a bidi override: none belongs in one line of a trip (the lists' rule).
  @forbidden ~r/[\p{Cc}\p{Zl}\p{Zp}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @doc "Every op a `trip_edit` call takes, by name."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc "Every op a device's `trip_edit` takes, by name."
  @spec device_ops() :: [String.t()]
  def device_ops, do: @device_ops

  @doc "The most ops one `trip_edit` call carries."
  @spec max_ops() :: pos_integer()
  def max_ops, do: @max_ops

  # --- a model's call --------------------------------------------------------

  @doc """
  A `trip_edit` call (`"trip"`: a title or id, a created trip's title;
  `"ops"`: 1..100) as `Trips.Ops` takes it. An op's refusal is
  `{:invalid_op, op_index, reason}`, counted from 1.
  """
  @spec call(map()) :: {:ok, %{trip: String.t(), ops: [map()]}} | {:error, term()}
  def call(params) when is_map(params) do
    with {:ok, ops} <- op_list(Map.get(params, "ops")),
         {:ok, trip} <- trip_ref(Map.get(params, "trip"), ops),
         {:ok, shaped} <- ops |> Enum.with_index(1) |> collect(&model_op/1) do
      {:ok, %{trip: trip, ops: shaped}}
    end
  end

  defp op_list(ops) when is_list(ops) and ops != [] do
    if length(ops) > @max_ops, do: {:error, :too_many_ops}, else: {:ok, ops}
  end

  defp op_list(_absent), do: {:error, {:invalid_param, :ops}}

  # A call that creates its trip with no title of its own names it by `trip`,
  # so that is held to a title's bounds.
  defp trip_ref(ref, [%{"op" => "create"} = create | _rest]) when is_binary(ref) do
    case Map.get(create, "title") do
      nil -> located(text(ref, :title, @title_max), 1)
      _title -> plain_ref(ref)
    end
  end

  defp trip_ref(ref, _ops) when is_binary(ref), do: plain_ref(ref)
  defp trip_ref(_ref, _ops), do: {:error, {:invalid_param, :trip}}

  defp plain_ref(ref) do
    case String.trim(ref) do
      "" -> {:error, {:invalid_param, :trip}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp model_op({%{"op" => name} = op, index}) when name in @ops,
    do: located(op_fields(String.to_existing_atom(name), op), index)

  defp model_op({%{"op" => name}, index}), do: {:error, {:invalid_op, index, {:unknown_op, name}}}
  defp model_op({_op, index}), do: {:error, {:invalid_op, index, {:missing, :op}}}

  defp located({:ok, value}, _index), do: {:ok, value}
  defp located({:error, reason}, index), do: {:error, {:invalid_op, index, reason}}

  defp op_fields(:create, op) do
    with {:ok, title} <- optional_text(op, "title", :title, @title_max),
         {:ok, starts_on} <- date(op, :absent_is_nil),
         {:ok, days} <- days(op),
         {:ok, zone} <- zone(op, :absent_is_nil) do
      {:ok, %{op: :create, title: title, starts_on: starts_on, days: days, timezone: zone}}
    end
  end

  defp op_fields(:add, op) do
    with {:ok, text} <- required_text(op, "text", :text, @text_max),
         {:ok, where} <- add_place(number(op, "day"), number(op, "after")),
         {:ok, stop} <- stop_fields(op, :absent_is_nil),
         {:ok, place} <- model_place(op, :absent_is_nil) do
      {:ok, %{op: :add, text: text, place: place} |> Map.merge(where) |> Map.merge(stop)}
    end
  end

  defp op_fields(:edit, op) do
    with {:ok, n} <- row_number(op, "n"),
         {:ok, text} <- optional_text(op, "text", :text, @text_max),
         {:ok, stop} <- stop_fields(op, :absent_is_keep),
         {:ok, place} <- model_place(op, :absent_is_keep) do
      something_to_edit(Map.merge(%{op: :edit, n: n, text: text, place: place}, stop))
    end
  end

  defp op_fields(:move, op) do
    with {:ok, n} <- row_number(op, "n"),
         {:ok, day} <- number(op, "day"),
         {:ok, after_n} <- number(op, "after") do
      case {day, after_n} do
        {nil, nil} -> {:error, :move_needs_place}
        {day, nil} -> {:ok, %{op: :move, n: n, day: day, after: nil}}
        {nil, after_n} -> {:ok, %{op: :move, n: n, day: nil, after: after_n}}
        _both -> {:error, :place_conflict}
      end
    end
  end

  defp op_fields(:day, op) do
    with {:ok, day} <- row_number(op, "day"),
         {:ok, text} <- day_text(op),
         {:ok, zone} <- zone(op, :absent_is_keep),
         do: {:ok, %{op: :day, day: day, text: text, timezone: zone}}
  end

  defp op_fields(:remove, op) do
    with {:ok, n} <- row_number(op, "n"), do: {:ok, %{op: :remove, n: n}}
  end

  defp op_fields(:rename, op) do
    with {:ok, title} <- required_text(op, "text", :title, @title_max),
         do: {:ok, %{op: :rename, text: title}}
  end

  defp op_fields(:dates, op) do
    with {:ok, starts_on} <- date(op, :required),
         {:ok, zone} <- zone(op, :absent_is_keep),
         do: {:ok, %{op: :dates, starts_on: starts_on, timezone: zone}}
  end

  defp op_fields(:remove_trip, _op), do: {:ok, %{op: :remove_trip}}

  defp add_place({:ok, nil}, {:ok, nil}), do: {:error, :add_needs_place}
  defp add_place({:ok, day}, {:ok, nil}), do: {:ok, %{day: day, after: nil}}
  defp add_place({:ok, nil}, {:ok, after_n}), do: {:ok, %{day: nil, after: after_n}}
  defp add_place({:ok, _day}, {:ok, _after}), do: {:error, :place_conflict}
  defp add_place({:error, reason}, _after), do: {:error, reason}
  defp add_place(_day, {:error, reason}), do: {:error, reason}

  defp something_to_edit(%{text: nil} = edit) do
    if Enum.all?([:time, :duration, :fixed, :note, :place], &(Map.fetch!(edit, &1) == :keep)),
      do: {:error, :nothing_to_edit},
      else: {:ok, edit}
  end

  defp something_to_edit(edit), do: {:ok, edit}

  # A model's place: a link a search returned, or a place's own name.
  defp model_place(op, absent) do
    case {Map.fetch(op, "place"), absent} do
      {:error, :absent_is_keep} -> {:ok, :keep}
      {:error, :absent_is_nil} -> {:ok, nil}
      {{:ok, nil}, _absent} -> {:ok, nil}
      {{:ok, value}, _absent} when is_binary(value) -> place_words(String.trim(value))
      {{:ok, _value}, _absent} -> {:error, {:invalid_param, :place}}
    end
  end

  defp place_words(""), do: {:ok, nil}

  defp place_words(value) do
    if String.starts_with?(value, ["https://", "http://"]),
      do: {:ok, {:link, value}},
      else: with({:ok, words} <- text(value, :place, @text_max), do: {:ok, {:words, words}})
  end

  # --- a device's op ---------------------------------------------------------

  @doc """
  One op a device sent (`"op"` and, for every op but `create`, `"trip_id"`),
  its rows named by id, as `Trips.Ops` takes it.
  """
  @spec device_change(map()) ::
          {:ok, %{trip: String.t() | nil, ops: [map()]}} | {:error, term()}
  def device_change(%{"op" => %{"op" => "create"} = op}) do
    with {:ok, title} <- required_text(op, "title", :title, @title_max) do
      create = %{op: :create, title: title, starts_on: nil, days: 1, timezone: nil}
      {:ok, %{trip: nil, ops: [create]}}
    end
  end

  def device_change(%{"op" => %{"op" => name} = op} = params) when name in @device_ops do
    with {:ok, trip_id} <- required_id(params, "trip_id", @trip_prefix),
         {:ok, shaped} <- device_op(String.to_existing_atom(name), op),
         do: {:ok, %{trip: trip_id, ops: [shaped]}}
  end

  def device_change(%{"op" => %{"op" => name}}), do: {:error, {:unknown_device_op, name}}
  def device_change(params) when is_map(params), do: {:error, {:missing, :op}}

  defp device_op(:add, op) do
    with {:ok, text} <- required_text(op, "text", :text, @text_max),
         {:ok, day} <- optional_id(op, "day_id", @row_prefix),
         {:ok, after_row} <- optional_id(op, "after_id", @row_prefix),
         {:ok, where} <- add_place({:ok, row_ref(day)}, {:ok, row_ref(after_row)}),
         {:ok, stop} <- stop_fields(op, :absent_is_nil),
         {:ok, place} <- device_place(op, :absent_is_nil) do
      {:ok, %{op: :add, text: text, place: place} |> Map.merge(where) |> Map.merge(stop)}
    end
  end

  defp device_op(:edit, op) do
    with {:ok, row} <- required_id(op, "row_id", @row_prefix),
         {:ok, text} <- optional_text(op, "text", :text, @text_max),
         {:ok, stop} <- stop_fields(op, :absent_is_keep),
         {:ok, place} <- device_edit_place(op) do
      something_to_edit(Map.merge(%{op: :edit, n: {:id, row}, text: text, place: place}, stop))
    end
  end

  # A day's row moves its block after `after_id`'s day, or first with neither;
  # a stop needs one of the two, which `Trips.Ops` says when it sees the row.
  defp device_op(:move, op) do
    with {:ok, row} <- required_id(op, "row_id", @row_prefix),
         {:ok, day} <- optional_id(op, "day_id", @row_prefix),
         {:ok, after_row} <- optional_id(op, "after_id", @row_prefix) do
      case {day, after_row} do
        {nil, nil} -> {:ok, %{op: :move, n: {:id, row}, day: nil, after: :start}}
        {day, nil} -> {:ok, %{op: :move, n: {:id, row}, day: {:id, day}, after: nil}}
        {nil, after_row} -> {:ok, %{op: :move, n: {:id, row}, day: nil, after: {:id, after_row}}}
        _both -> {:error, {:device, :place_conflict}}
      end
    end
  end

  # With a row id a day is named; with none a new day is made, after
  # `after_id`'s day or at the end. A device gives no zone (C15).
  defp device_op(:day, op) do
    with {:ok, row} <- optional_id(op, "row_id", @row_prefix),
         {:ok, after_row} <- optional_id(op, "after_id", @row_prefix),
         {:ok, text} <- day_text(op) do
      case {row, after_row} do
        {nil, after_row} ->
          {:ok, %{op: :day, day: {:new, row_ref(after_row)}, text: text, timezone: :keep}}

        {row, nil} ->
          {:ok, %{op: :day, day: {:id, row}, text: text, timezone: :keep}}

        _both ->
          {:error, {:device, :day_conflict}}
      end
    end
  end

  defp device_op(:remove, op) do
    with {:ok, row} <- required_id(op, "row_id", @row_prefix),
         do: {:ok, %{op: :remove, n: {:id, row}}}
  end

  defp device_op(:restore, op) do
    with {:ok, row} <- optional_id(op, "row_id", @row_prefix),
         {:ok, title} <- optional_text(op, "title", :title, @title_max),
         do: {:ok, %{op: :restore, row: row_ref(row), title: title}}
  end

  defp device_op(:dates, op) do
    with {:ok, starts_on} <- date(op, :required),
         do: {:ok, %{op: :dates, starts_on: starts_on, timezone: :keep}}
  end

  defp device_op(name, op) when name in [:rename, :remove_trip], do: op_fields(name, op)

  defp device_place(op, absent) do
    case {Map.fetch(op, "place"), absent} do
      {:error, :absent_is_keep} -> {:ok, :keep}
      {:error, :absent_is_nil} -> {:ok, nil}
      {{:ok, record}, _absent} when is_map(record) -> Place.cut(record)
      {{:ok, _value}, _absent} -> {:error, {:invalid_param, :place}}
    end
  end

  defp device_edit_place(op) do
    case {Map.get(op, "unplace"), Map.has_key?(op, "place")} do
      {true, true} -> {:error, {:device, :place_and_unplace}}
      {true, false} -> {:ok, nil}
      {unplace, _place} when unplace in [nil, false] -> device_place(op, :absent_is_keep)
      _other -> {:error, {:invalid_param, :unplace}}
    end
  end

  defp required_id(map, key, prefix) do
    case Map.get(map, key) do
      nil -> {:error, {:missing, Map.fetch!(@id_fields, key)}}
      id -> with :ok <- matches(id, prefix, key), do: {:ok, id}
    end
  end

  defp optional_id(map, key, prefix) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      id -> with :ok <- matches(id, prefix, key), do: {:ok, id}
    end
  end

  # A trip is named by its bare id, a row by `{:id, row_id}`.
  defp row_ref(nil), do: nil
  defp row_ref(id), do: {:id, id}

  defp matches(id, prefix, key) do
    if Ids.valid?(id, prefix),
      do: :ok,
      else: {:error, {:invalid_param, Map.fetch!(@id_fields, key)}}
  end

  # --- a stop's fields -------------------------------------------------------

  # `time`, `duration`, `fixed` and `note`: absent is nil on an add and keeps
  # what is there on an edit; empty, or no minutes, clears it.
  defp stop_fields(op, absent) do
    with {:ok, time} <- field(op, "time", absent, &time/1),
         {:ok, duration} <- field(op, "duration", absent, &duration/1),
         {:ok, fixed} <- fixed(op, absent),
         {:ok, note} <- field(op, "note", absent, &note_text/1) do
      {:ok, %{time: time, duration: duration, fixed: fixed, note: note}}
    end
  end

  defp field(op, key, absent, check) do
    case {Map.fetch(op, key), absent} do
      {:error, :absent_is_keep} -> {:ok, :keep}
      {:error, :absent_is_nil} -> {:ok, nil}
      {{:ok, nil}, _absent} -> {:ok, nil}
      {{:ok, value}, _absent} -> check.(value)
    end
  end

  defp time(""), do: {:ok, nil}

  defp time(value) when is_binary(value) do
    if Regex.match?(@time, value), do: {:ok, value}, else: {:error, {:not_time, :time}}
  end

  defp time(_value), do: {:error, {:not_time, :time}}

  defp duration(0), do: {:ok, nil}
  defp duration(minutes) when is_integer(minutes) and minutes in @minutes, do: {:ok, minutes}
  defp duration(_value), do: {:error, {:not_minutes, :duration}}

  defp fixed(op, absent) do
    case {Map.fetch(op, "fixed"), absent} do
      {:error, :absent_is_keep} -> {:ok, :keep}
      {:error, :absent_is_nil} -> {:ok, false}
      {{:ok, value}, _absent} when is_boolean(value) -> {:ok, value}
      {{:ok, _value}, _absent} -> {:error, {:not_boolean, :fixed}}
    end
  end

  # Its lines trimmed and the empty ones dropped; nil when nothing is left.
  defp note_text(value) when is_binary(value) do
    note =
      value
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    joined = Enum.join(note, "\n")

    cond do
      note == [] -> {:ok, nil}
      Enum.any?(note, &Regex.match?(@forbidden, &1)) -> {:error, {:not_one_line, :note}}
      code_points(joined) > @note_max -> {:error, {:too_long, :note, @note_max}}
      true -> {:ok, joined}
    end
  end

  defp note_text(_value), do: {:error, {:invalid_param, :note}}

  # A day's name: absent keeps it, empty takes it away (stored "", C27).
  defp day_text(op) do
    case Map.get(op, "text", :keep) do
      :keep -> {:ok, :keep}
      nil -> {:ok, ""}
      "" -> {:ok, ""}
      value -> text(value, :text, @day_max)
    end
  end

  # --- dates, zones, numbers -------------------------------------------------

  defp date(op, presence) do
    case {Map.fetch(op, "starts_on"), presence} do
      {:error, :required} -> {:error, {:missing, :starts_on}}
      {:error, :absent_is_nil} -> {:ok, nil}
      {{:ok, value}, _presence} when value in [nil, ""] -> {:ok, nil}
      {{:ok, value}, _presence} -> parse_date(value)
    end
  end

  defp parse_date(value) when is_binary(value) do
    with true <- Regex.match?(@date, value),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _invalid -> {:error, {:not_date, :starts_on}}
    end
  end

  defp parse_date(_value), do: {:error, {:not_date, :starts_on}}

  defp zone(op, absent) do
    case {Map.fetch(op, "timezone"), absent} do
      {:error, :absent_is_keep} ->
        {:ok, :keep}

      {:error, :absent_is_nil} ->
        {:ok, nil}

      {{:ok, value}, _absent} when value in [nil, ""] ->
        {:ok, nil}

      {{:ok, value}, _absent} when is_binary(value) and byte_size(value) <= 64 ->
        valid_zone(value)

      {{:ok, value}, _absent} ->
        {:error, {:invalid_timezone, value}}
    end
  end

  defp valid_zone(value) do
    with {:error, {:invalid_timezone, _zone}} <- Clock.validate_zone(value),
         do: {:error, {:invalid_timezone, value}}
  end

  defp days(op) do
    case Map.get(op, "days") do
      nil -> {:ok, 1}
      days when is_integer(days) and days in 1..@max_days -> {:ok, days}
      _other -> {:error, {:not_days, :days}}
    end
  end

  defp row_number(op, key) do
    case Map.get(op, key) do
      n when is_integer(n) and n >= 1 -> {:ok, n}
      nil -> {:error, {:missing, String.to_existing_atom(key)}}
      _other -> {:error, {:not_a_number, String.to_existing_atom(key)}}
    end
  end

  defp number(op, key) do
    case Map.get(op, key) do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= 1 -> {:ok, n}
      _other -> {:error, {:not_a_number, String.to_existing_atom(key)}}
    end
  end

  # --- words -----------------------------------------------------------------

  defp required_text(op, key, field, max) do
    case Map.get(op, key) do
      nil -> {:error, {:missing, field}}
      value -> text(value, field, max)
    end
  end

  defp optional_text(op, key, field, max) do
    case Map.get(op, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value -> text(value, field, max)
    end
  end

  # One line of words: trimmed, never empty, nothing that breaks a line, and
  # within `max` characters as the store counts them (code points).
  defp text(value, field, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {:missing, field}}
      Regex.match?(@forbidden, trimmed) -> {:error, {:not_one_line, field}}
      code_points(trimmed) > max -> {:error, {:too_long, field, max}}
      true -> {:ok, trimmed}
    end
  end

  defp text(_value, field, _max), do: {:error, {:invalid_param, field}}

  defp code_points(text), do: text |> String.codepoints() |> length()

  defp collect(indexed, fun) do
    indexed
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end
end
