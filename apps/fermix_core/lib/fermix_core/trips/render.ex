defmodule FermixCore.Trips.Render do
  @moduledoc """
  The owner's trips as the model reads them, as they are shared, and the
  answer to a `trip_edit` call (M89 §04, §13): text, never rows. Pure. A
  stop that waits for its place (D13 B, `Trips.Waiting`) ends its line in a
  read with `(place waiting)`; the shared form and a device's wire never
  say so.

  **A read** (`read/4`) is a header line (the title, id, dates, zone, the
  trip's `near`, rev and counts), the line that says the rows are the owner's
  data, then each day asked: `## [n] Day k` with its date, its name, the zone
  and the `near` it names of its own (D10, JSON-quoted as the model's words
  are), and a line a stop, `- [n]` with its time, words, length, `fixed` and
  place. Under a stop come its note's lines and, when it and a later stop of
  its day both have a place, `then X km`: the straight line to the next placed
  stop, the number the wire's `leg_m` gives that stop (C7). `[n]` is a row's
  handle for `trip_edit`. Any read past 32 KB, of a trip or a run of its days,
  is the outline instead, a line a day and how to read it by day (C26); one
  day past 32 KB is read whole with its notes cut to fit, or left out, and
  says so, so the day the outline points to can always be read.

  Two things are added to the owner's words. Words that begin as a line this
  module writes would (a backslash, a bracketed number, `#`, `- ` or the
  outside-content mark) are escaped with a leading backslash; and a stop added
  or given words after outside content (§14) is framed as data, `(added after
  outside content) "…"`, its words and its note JSON-quoted so nothing in them
  can end the quotation. The frame stays on every form the model reads, the
  shared one and a call's answer included (`Trips.Ops.handle/1`), and marks
  nothing: a trip tool's answer is not outside content (D9). A place's name
  and address, a provider's words, are JSON-quoted wherever the model reads
  them.

  **The shared form** (`share/2`, and `read/4` with `:share`) is plain text, a
  line a stop: the title and dates, each day by its date (or its number) and
  name, each stop with its time and words and, when it has a place, a link to
  it in Apple's Maps (`place_link/1`). No note, no fixed mark and no rev: a
  booking reference is the owner's, not the reader's.

  **The answer** (`answer/2`) is the trip's line, what each place given in the
  call came to (placed, offered by another name with its link, offered with
  no place to search near and what to give, or not placed and why, from
  `Trips.Lookup`), and each fixed stop whose date the call moved (C14). A
  provider's words, and the owner's, are JSON-quoted there. When a place given
  was not placed, the answer ends with a line asking the reply to tell the
  owner each stop's outcome as the answer lists it: the answer reaches a turn
  that has no trip guidance yet, before a first trip.
  """

  alias FermixCore.Kept.Access, as: KeptAccess
  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Ops

  @frame KeptAccess.outside_frame()
  @indent "      "
  @max_read_bytes 32_768
  # The lengths a day past 32 KB cuts its notes to, in turn; 0 leaves them out.
  @note_cuts [200, 40, 0]
  @data_line "The rows are the owner's own trip, quoted as data. [n] is a row's number for " <>
               "trip_edit."
  @index_heading "The owner's trips (titles are the owner's, quoted as data):"
  # OWNER AUTHORS THE FINAL TEXT, as `Trips.Note`'s rules.
  @report_places "Tell the owner which stops were placed, which were offered, each with its " <>
                   "link where this answer gives one, and which were not placed and why, as " <>
                   "this answer lists them."
  @too_long ~s(This trip is too long to read whole; read it by day, as day: "2" or "2-5".)
  @apple_place "https://maps.apple.com/place?place-id="
  @apple_point "https://maps.apple.com/?ll="
  # ASCII digits only: a bracketed number in another script is words.
  @handle_like ~r/\A\[[0-9]+\]/
  @escaped_starts ["\\", @frame, "#", "- "]

  @typedoc "The days a read asks for: all of them, or a run by position from 1."
  @type run :: :all | {pos_integer(), pos_integer()}

  @typedoc """
  A stop a call gave a place to, as it now stands, with what its place came
  to: placed (the record it keeps), offered by another name or with no place
  to search near (the search's own record) or not placed and why; `kept` when
  an edit's stop kept the place it had because the lookup placed nothing.
  """
  @type placement :: %{
          required(:row) => map(),
          required(:outcome) =>
            {:placed, map()}
            | {:offered, map()}
            | {:offered, map(), Lookup.unanchored()}
            | {:none, Lookup.why() | :unstorable},
          required(:kept) => boolean(),
          optional(:ref) => pos_integer()
        }

  @doc "The most bytes one read returns whole; past it, the outline."
  @spec max_read_bytes() :: pos_integer()
  def max_read_bytes, do: @max_read_bytes

  @doc """
  The model's read of `trip` and its live `rows`: the days `run` names, as
  text (`:text`) or in the shared form (`:share`), `{:whole, text}`, or
  `{:outline, text}` when that would pass 32 KB.
  """
  @spec read(map(), [map()], run(), :text | :share, MapSet.t(String.t())) ::
          {:whole | :outline, String.t()}
  def read(trip, rows, run, form, waiting \\ MapSet.new())
      when is_map(trip) and is_list(rows) and form in [:text, :share] and
             is_struct(waiting, MapSet) do
    days = rows |> Ops.days() |> asked(run)
    text = whole(trip, {rows, waiting}, days, form)

    cond do
      byte_size(text) <= @max_read_bytes -> {:whole, text}
      form == :text and length(days) == 1 -> {:whole, cut_notes(trip, {rows, waiting}, days)}
      true -> {:outline, outline(trip, rows, days)}
    end
  end

  defp asked(days, :all), do: days

  defp asked(days, {from, to}) when from >= 1 and to >= from,
    do: Enum.filter(days, &(&1.position in from..to))

  defp whole(trip, rows_waiting, days, :text), do: text(trip, rows_waiting, days, :all)
  defp whole(trip, {rows, _waiting}, days, :share), do: shared(trip, rows, days, :framed)

  defp text(trip, {rows, waiting}, days, notes) do
    lines = {Ops.legs(rows), notes, waiting}
    year? = crosses_year?(trip, rows)
    body = Enum.flat_map(days, &["" | day_lines(&1, trip, year?, lines)])
    Enum.join([header(trip, rows), @data_line | body], "\n")
  end

  # The outline says to read by day, so one day past 32 KB is still read
  # whole: its notes cut shorter at each step until it fits, and at the last
  # left out, whatever its size then.
  defp cut_notes(trip, rows_waiting, days) do
    Enum.reduce_while(@note_cuts, nil, fn cap, _longer ->
      text = text(trip, rows_waiting, days, cap) <> "\n\n" <> cut_line(cap)
      if byte_size(text) <= @max_read_bytes, do: {:halt, text}, else: {:cont, text}
    end)
  end

  defp cut_line(0), do: "This day is too long to read whole, so its notes are left out."

  defp cut_line(cap),
    do: "This day is too long to read whole, so each note is cut to its first #{cap} characters."

  defp outline(trip, rows, days) do
    year? = crosses_year?(trip, rows)

    lines =
      Enum.map(days, &(heading(&1, trip, year?) <> " · " <> plural(length(&1.stops), "stop")))

    Enum.join([header(trip, rows), @data_line, "" | lines] ++ ["", @too_long], "\n")
  end

  @doc """
  A trip's header line: `Trip "Title" (tr_…)`, its dates, zone and `near`
  when it has them, then `rev N · D days, S stops`.
  """
  @spec header(map(), [map()]) :: String.t()
  def header(trip, rows) when is_map(trip) and is_list(rows) do
    {days, stops} = Ops.counts(rows)

    joined([
      "Trip #{quoted(trip.title)} (#{trip.id})",
      span(trip.starts_on, max(days, 1), true),
      trip.timezone,
      near_part(trip.near),
      "rev #{trip.rev}",
      "#{plural(days, "day")}, #{plural(stops, "stop")}"
    ])
  end

  # --- days and stops ----------------------------------------------------------

  defp day_lines(%{stops: stops} = day, trip, year?, lines),
    do: [heading(day, trip, year?) | stop_lines(stops, lines)]

  defp heading(%{row: day, position: k}, trip, year?) do
    date = Ops.day_date(trip.starts_on, k)
    name = if day.text != "", do: escape(day.text)

    joined([
      "## [#{day.n}] Day #{k}",
      date && day_date(date, year?),
      name,
      day.timezone,
      near_part(day.near)
    ])
  end

  # Where a trip or a day is searched near, the model's words, quoted.
  defp near_part(nil), do: nil
  defp near_part(near), do: "near " <> quoted(near)

  defp stop_lines(stops, {legs, notes, waiting}) do
    stops
    |> Enum.with_index()
    |> Enum.flat_map(fn {stop, index} ->
      [stop_line(stop) <> waiting_part(stop, waiting) | note_lines(cut(stop, notes))] ++
        then_line(stops, index, legs)
    end)
  end

  # A stop whose place words wait to be looked up (`Trips.Waiting`), so a
  # later turn knows it will be placed.
  defp waiting_part(%{id: id}, waiting),
    do: if(MapSet.member?(waiting, id), do: " (place waiting)", else: "")

  # A stop's note as a read takes it: whole, cut to its first `cap`
  # characters and marked as cut, or with none.
  defp cut(stop, :all), do: stop
  defp cut(stop, 0), do: %{stop | note: nil}
  defp cut(%{note: nil} = stop, _cap), do: stop

  defp cut(%{note: note} = stop, cap) do
    if String.length(note) > cap,
      do: %{stop | note: String.slice(note, 0, cap) <> "…"},
      else: stop
  end

  defp stop_line(stop) do
    "- [#{stop.n}] " <>
      if(stop.time, do: stop.time <> " ", else: "") <>
      words(stop) <>
      duration_part(stop.duration) <>
      if(stop.fixed, do: " · fixed", else: "") <>
      place_part(stop.place)
  end

  defp duration_part(nil), do: ""
  defp duration_part(minutes) when minutes < 60, do: " · #{minutes} min"
  defp duration_part(minutes) when rem(minutes, 60) == 0, do: " · #{div(minutes, 60)} h"

  defp duration_part(minutes),
    do: " · #{div(minutes, 60)} h #{String.pad_leading("#{rem(minutes, 60)}", 2, "0")}"

  # A place's name and address are a provider's words, quoted as the answer
  # quotes them.
  defp place_part(nil), do: ""
  defp place_part(place), do: " · at " <> quoted(place_words(place))

  defp place_words(%{"name" => name, "address" => address}), do: name <> ", " <> address
  defp place_words(%{"name" => name}), do: name

  # Under a placed stop, the line to the next placed stop of its day (C7).
  defp then_line(stops, index, legs) do
    with %{place: place} when place != nil <- Enum.at(stops, index),
         %{id: next} <- stops |> Enum.drop(index + 1) |> Enum.find(&(&1.place != nil)),
         {:ok, metres} <- Map.fetch(legs, next) do
      [@indent <> "then " <> km(metres)]
    else
      _none -> []
    end
  end

  defp km(metres) do
    tenths = round(metres / 100)

    cond do
      tenths == 0 -> "under 0.1 km"
      tenths < 100 -> "#{div(tenths, 10)}.#{rem(tenths, 10)} km"
      true -> "#{round(metres / 1_000)} km"
    end
  end

  defp words(%{stamped: true, text: text}), do: framed(text)
  defp words(%{text: text}), do: escape(text)

  defp note_lines(%{note: nil}), do: []
  defp note_lines(%{stamped: true, note: note}), do: [@indent <> framed(note)]

  defp note_lines(%{note: note}),
    do: note |> String.split("\n") |> Enum.map(&(@indent <> escape(&1)))

  defp framed(text), do: @frame <> " " <> Jason.encode!(text)

  defp escape(text) do
    if String.starts_with?(text, @escaped_starts) or Regex.match?(@handle_like, text),
      do: "\\" <> text,
      else: text
  end

  # --- the index -----------------------------------------------------------------

  @doc """
  The index: every live trip with its dates, day and stop counts and rev, in
  the order given (the picker's).
  """
  @spec index([map()]) :: String.t()
  def index([]), do: "The owner keeps no trips yet."

  def index(trips) when is_list(trips),
    do: Enum.join([@index_heading | Enum.map(trips, &index_line/1)], "\n")

  defp index_line(trip) do
    joined([
      "- #{quoted(trip.title)} (#{trip.id})",
      span(trip.starts_on, max(trip.days, 1), true),
      "#{plural(trip.days, "day")}, #{plural(trip.stops, "stop")}",
      "rev #{trip.rev}"
    ])
  end

  # --- the shared form -----------------------------------------------------------

  @doc """
  A trip in its shared form, whole, as a device's Share hands it on: plain
  text, nothing framed (the owner's own surface shows every row as it is).
  """
  @spec share(map(), [map()]) :: String.t()
  def share(trip, rows) when is_map(trip) and is_list(rows),
    do: shared(trip, rows, Ops.days(rows), :plain)

  defp shared(trip, rows, days, mode) do
    {count, _stops} = Ops.counts(rows)
    year? = crosses_year?(trip, rows)

    title =
      Enum.join(
        Enum.reject([trip.title, span(trip.starts_on, max(count, 1), true)], &is_nil/1),
        ", "
      )

    Enum.join([title | Enum.map(days, &shared_day(&1, trip, year?, mode))], "\n\n")
  end

  defp shared_day(%{row: day, stops: stops, position: k}, trip, year?, mode) do
    label =
      case Ops.day_date(trip.starts_on, k) do
        nil -> "Day #{k}"
        date -> day_date(date, year?)
      end

    heading = if day.text != "", do: label <> ", " <> day.text, else: label
    Enum.join([heading | Enum.map(stops, &shared_stop(&1, mode))], "\n")
  end

  defp shared_stop(stop, mode) do
    [stop.time, shared_words(stop, mode), stop.place && place_link(stop.place)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp shared_words(%{stamped: true, text: text}, :framed), do: framed(text)
  defp shared_words(%{text: text}, _mode), do: text

  @doc """
  A place's link in Apple's Maps: the search's own Apple Maps page, else the
  page of its Apple id, else Apple Maps at its point, named (C24).
  """
  @spec place_link(map()) :: String.t()
  def place_link(%{"name" => name, "location" => location} = place)
      when is_binary(name) and is_map(location) do
    cond do
      apple_page?(Map.get(place, "source_url")) ->
        place["source_url"]

      is_binary(place["apple_place_id"]) ->
        @apple_place <> URI.encode_www_form(place["apple_place_id"])

      true ->
        point_link(name, location)
    end
  end

  defp apple_page?(url) when is_binary(url),
    do: match?(%URI{scheme: "https", host: "maps.apple.com"}, URI.parse(url))

  defp apple_page?(_url), do: false

  defp point_link(name, %{"latitude" => latitude, "longitude" => longitude}),
    do: @apple_point <> "#{number(latitude)},#{number(longitude)}&q=" <> URI.encode_www_form(name)

  # Plain decimals, never an exponent a map may not read, to ten places (well
  # under a millimetre).
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value),
    do: :erlang.float_to_binary(value, [{:decimals, 10}, :compact])

  # --- the trip_edit answer ------------------------------------------------------

  @doc """
  The answer to a `trip_edit` call that `applied` (`Trips.Ops.apply/3`'s
  result): the trip's line, ` · P placed` when the call gave places, then what
  each place came to (`placements`, in the call's order), what placed the
  stops a lookup placed (`placed_by`, `Trips.Lookup`'s, by each placement's
  `ref`: "Placed with Apple Maps on studio Mac: [9], [11]."; a stop its link
  placed is no lookup's, and is not named), and the fixed stops whose date
  moved.
  """
  @spec answer(map(), [placement()], %{optional(term()) => String.t()}) :: String.t()
  def answer(applied, placements, placed_by \\ %{})

  # The model has no restore: the owner's app brings a removed trip back.
  def answer(%{trip: %{removed_at: %DateTime{}, title: title}}, placements, placed_by)
      when is_list(placements) and is_map(placed_by),
      do: "#{title} · removed; it can be restored from the Fermix app for 30 days"

  def answer(%{trip: trip, rows: rows, events: events} = applied, placements, placed_by)
      when is_list(placements) and is_map(placed_by) do
    {days, stops} = Ops.counts(rows)
    words = if events == [], do: "nothing changed", else: Enum.join(events, "; ")

    line =
      "#{trip.title} · rev #{trip.rev} · #{words} · #{plural(days, "day")}, #{plural(stops, "stop")}"

    [line <> placed_count(placements)]
    |> Kernel.++(placed_lines(placements))
    |> Kernel.++(placed_by_lines(placements, placed_by))
    |> Kernel.++(offered_lines(placements))
    |> Kernel.++(unanchored_lines(placements))
    |> Kernel.++(unplaced_lines(placements))
    |> Kernel.++(moved_lines(applied.dates_moved))
    |> Kernel.++(report_line(placements))
    |> Enum.join("\n")
  end

  # A call whose places all landed needs no line; one that placed some and
  # offered or missed others has the reply tell them apart.
  defp report_line(placements) do
    if Enum.all?(placements, &match?(%{outcome: {:placed, _place}}, &1)),
      do: [],
      else: [@report_places]
  end

  defp placed_count([]), do: ""

  defp placed_count(placements),
    do: " · #{Enum.count(placements, &match?(%{outcome: {:placed, _place}}, &1))} placed"

  defp placed_lines(placements) do
    for %{row: row, outcome: {:placed, place}} <- placements,
        do: "#{stop_ref(row)}: #{quoted(place_words(place))}"
  end

  # What searched each stop a lookup placed, by what searched, in the order
  # each first comes up; a stop its link placed is named by none.
  defp placed_by_lines(placements, placed_by) do
    placements
    |> Enum.flat_map(fn
      %{outcome: {:placed, _place}, row: row} = placement ->
        case Map.fetch(placed_by, Map.get(placement, :ref)) do
          {:ok, words} -> [{words, "[#{row.n}]"}]
          :error -> []
        end

      _placement ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {words, _refs} -> first_placed_by(placements, placed_by, words) end)
    |> Enum.map(fn {words, refs} -> "Placed with #{words}: #{Enum.join(refs, ", ")}." end)
  end

  defp first_placed_by(placements, placed_by, words),
    do: Enum.find_index(placements, &(Map.get(placed_by, Map.get(&1, :ref)) == words))

  defp offered_lines(placements) do
    case for %{outcome: {:offered, place}} = placement <- placements,
             do: offered_line(placement, place) do
      [] -> []
      lines -> ["Not placed, nearest by another name:" | lines]
    end
  end

  defp offered_line(placement, place) do
    words = joined_comma([place.name, Map.get(place, :address)])
    link = if linked?(place), do: " · " <> Lookup.link(place), else: ""
    "#{placement_ref(placement)}: #{quoted(words)}#{link}"
  end

  defp linked?(place),
    do: Enum.any?([:source_url, :canonical_url], &(Map.get(place, &1) not in [nil, ""]))

  # Offered with no place to search near (D10), by why, in the order each
  # first comes up.
  defp unanchored_lines(placements) do
    placements
    |> Enum.flat_map(fn
      %{outcome: {:offered, place, why}} = placement -> [{why, offered_line(placement, place)}]
      _placement -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {why, _lines} -> unanchored_index(placements, why) end)
    |> Enum.flat_map(fn {why, lines} -> [Lookup.offered_heading(why) <> ":" | lines] end)
  end

  defp unanchored_index(placements, why),
    do: Enum.find_index(placements, &match?(%{outcome: {:offered, _place, ^why}}, &1))

  # Not placed, by why, in the order each first comes up.
  defp unplaced_lines(placements) do
    placements
    |> Enum.flat_map(fn
      %{outcome: {:none, why}} = placement -> [{why, placement}]
      _placement -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {why, _placed} -> first_index(placements, why) end)
    |> Enum.map(fn {why, placed} ->
      "#{why_heading(why)}: #{Enum.map_join(placed, ", ", &placement_ref/1)}."
    end)
  end

  # A stop an edit gave a place the lookup did not place keeps the one it had.
  defp placement_ref(%{row: row, kept: true}), do: stop_ref(row) <> " (place unchanged)"
  defp placement_ref(%{row: row, kept: false}), do: stop_ref(row)

  defp first_index(placements, why),
    do: Enum.find_index(placements, &match?(%{outcome: {:none, ^why}}, &1))

  defp why_heading(:unstorable),
    do: "Not placed, the search's record of that place is too large to keep"

  defp why_heading(why), do: Lookup.heading(why)

  defp moved_lines([]), do: []

  defp moved_lines(moved),
    do: ["Dates moved: " <> Enum.map_join(moved, "; ", &moved_words/1) <> "."]

  defp moved_words(%{row: row, to: to}), do: "#{stop_ref(row)} (fixed) is now #{stated_date(to)}"

  defp stated_date(nil), do: "undated"
  defp stated_date(%Date{} = date), do: Calendar.strftime(date, "%a %-d %b %Y")

  # A stop as the answer names it, as the call's events do (`Ops.handle/1`).
  defp stop_ref(row), do: Ops.handle(row)

  # --- dates and words -----------------------------------------------------------

  @doc """
  The dates of a trip that starts on `first` and lasts `days`: `8 to 14 May
  2031`, `28 May to 3 Jun 2031`, `30 Dec 2031 to 3 Jan 2032`, one day `9 May
  2031`, each day with its weekday when `weekday?`; nil with no start.
  """
  @spec span(Date.t() | nil, pos_integer(), boolean()) :: String.t() | nil
  def span(nil, days, weekday?) when is_integer(days) and is_boolean(weekday?), do: nil

  def span(%Date{} = first, days, weekday?) when is_integer(days) and days >= 1 do
    last = Date.add(first, days - 1)

    cond do
      days == 1 ->
        "#{day_month(first, weekday?)} #{first.year}"

      first.year != last.year ->
        "#{day_month(first, weekday?)} #{first.year} to #{day_month(last, weekday?)} #{last.year}"

      first.month != last.month ->
        "#{day_month(first, weekday?)} to #{day_month(last, weekday?)} #{last.year}"

      true ->
        "#{day_only(first, weekday?)} to #{day_month(last, weekday?)} #{last.year}"
    end
  end

  defp day_only(date, true), do: Calendar.strftime(date, "%a %-d")
  defp day_only(date, false), do: Calendar.strftime(date, "%-d")
  defp day_month(date, weekday?), do: day_only(date, weekday?) <> Calendar.strftime(date, " %b")

  # A day's heading date: with its year only in a trip that crosses one.
  defp day_date(date, true), do: Calendar.strftime(date, "%a %-d %b %Y")
  defp day_date(date, false), do: Calendar.strftime(date, "%a %-d %b")

  defp crosses_year?(%{starts_on: nil}, _rows), do: false

  defp crosses_year?(%{starts_on: first}, rows) do
    {days, _stops} = Ops.counts(rows)
    Date.add(first, max(days, 1) - 1).year != first.year
  end

  @doc "A title, or another's words, JSON-quoted."
  @spec quoted(String.t()) :: String.t()
  def quoted(text) when is_binary(text), do: Jason.encode!(text)

  defp joined(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  defp joined_comma(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"
end
