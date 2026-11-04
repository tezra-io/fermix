defmodule FermixCore.Temporal.Renderer do
  @moduledoc """
  Deterministic reminder text (M30 §13).

  Pure: no model, no provider, no database, no configuration. The message is
  built from the reminder row's bounded semantic payload — the snapshot taken
  when the row was materialized, so a later event edit never rewrites sent
  history — plus the render-time clock.

  The moment leads, in the words a person would use, then the title:
  "Tonight at 7:00 PM EDT, in 3 hours: Dinner with Sam." A birthday or an
  anniversary, whose title is a name and an occasion, reads as a sentence
  instead: "Sarah's birthday is this Monday, September 14." Leading with the
  moment keeps every other title grammatical, an instruction included.

  Rules the templates enforce:

    * the absolute event date is always present, with its weekday, and with the
      wall time and its zone whenever the event carries one;
    * how far away it is comes from the local calendar at render time: today
      (tonight for a timed event from 6 PM), tomorrow, this weekday for two to
      six days, a week from today, then the day count; a timed event later today
      adds the hours left, dropped whenever they would mislead — a retry that
      lands under half an hour before the event, or after it has begun, omits
      them;
    * no ids, attempt counts, rule names, platforms, or other machinery appears
      in an owner-facing reminder;
    * one message of at most 1,800 UTF-8 bytes, truncated only at a grapheme
      boundary and never at the cost of the absolute date/time. This stays under
      the smallest supported channel text limit, so a reminder can never be
      chunked into several messages by an adapter.
  """

  # One message, below the smallest adapter text limit (Discord, 2,000).
  @max_bytes 1_800
  @ellipsis "…"

  @months {"January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December"}

  @weekdays {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}

  # Kinds whose title is a name and an occasion, so "<title> is <moment>." reads
  # right; any other title may be an instruction and follows the moment instead.
  @sentence_kinds ~w(birthday anniversary)

  # A timed event at or after this local time, later today, is tonight.
  @tonight_from ~T[18:00:00]

  @doc """
  Renders one reminder row for delivery at `now`.

  The row needs its `:payload` (string-keyed snapshot) and `:event_occurrence_at`
  instant. A payload that cannot produce a truthful absolute date is an error,
  never a blank or UTC-substituted message.
  """
  @spec render(map(), DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def render(
        %{payload: payload, event_occurrence_at: %DateTime{} = occurrence_at},
        %DateTime{} = now
      )
      when is_map(payload) do
    with {:ok, title} <- fetch_title(payload),
         {:ok, date} <- fetch_date(payload),
         {:ok, time} <- fetch_time(payload),
         {:ok, timezone} <- fetch_timezone(payload),
         {:ok, local_now} <- shift(now, timezone),
         {:ok, clock} <- clock_with_zone(date, time, timezone) do
      moment = moment(date, time, clock, occurrence_at, local_now)
      {:ok, compose(Map.get(payload, "kind"), title, moment)}
    end
  end

  def render(_row, _now), do: {:error, {:invalid_payload, "reminder"}}

  # --- stating a stored occurrence -----------------------------------------

  @doc false
  # Shared with `Temporal.Registry`, which states back the occurrence a write
  # actually stored. Unlike the reminder templates below it never carries a
  # relative word: a reminder arrives beside its event, but a confirmation has to
  # settle which day was meant, and the WEEKDAY is the one part of the statement
  # that separates one candidate day from the next.
  #
  # Bang, like the caller's own `DateTime.shift_zone!`: the zone was validated at
  # acceptance and the caller shifted the clock through it before calling, so a
  # stored row that cannot be stated absolutely is a corrupt row, not a case to
  # degrade around.
  @spec stated_date!(Date.t(), Time.t() | nil, String.t(), DateTime.t()) :: String.t()
  def stated_date!(%Date{} = date, time, timezone, %DateTime{} = local_now)
      when (is_nil(time) or is_struct(time, Time)) and is_binary(timezone) and timezone != "" do
    case absolute_text(date, time, timezone, local_now) do
      {:ok, absolute} -> weekday(date) <> ", " <> absolute
      {:error, reason} -> raise ArgumentError, "cannot state #{date}: #{inspect(reason)}"
    end
  end

  @doc false
  # Spelled out, no locale machinery: `Date.day_of_week/1` counts Monday as 1.
  @spec weekday(Date.t()) :: String.t()
  def weekday(%Date{} = date), do: elem(@weekdays, Date.day_of_week(date) - 1)

  @doc false
  # Shared with `Temporal.Registry`, which names a yearly event's recurring month
  # from the stored number rather than from any date.
  @spec month_name(1..12) :: String.t()
  def month_name(month) when is_integer(month) and month in 1..12, do: elem(@months, month - 1)

  # --- payload reading -----------------------------------------------------

  defp fetch_title(payload) do
    case Map.get(payload, "title") do
      title when is_binary(title) and title != "" -> {:ok, title}
      _missing -> {:error, {:invalid_payload, "title"}}
    end
  end

  defp fetch_date(payload) do
    with value when is_binary(value) <- Map.get(payload, "event_local_date"),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _invalid -> {:error, {:invalid_payload, "event_local_date"}}
    end
  end

  defp fetch_time(payload) do
    case Map.get(payload, "event_local_time") do
      nil -> {:ok, nil}
      value when is_binary(value) -> parse_time(value)
      _invalid -> {:error, {:invalid_payload, "event_local_time"}}
    end
  end

  defp parse_time(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, {:invalid_payload, "event_local_time"}}
    end
  end

  defp fetch_timezone(payload) do
    case Map.get(payload, "timezone") do
      timezone when is_binary(timezone) and timezone != "" -> {:ok, timezone}
      _missing -> {:error, {:invalid_payload, "timezone"}}
    end
  end

  defp shift(%DateTime{} = at, timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, local} -> {:ok, local}
      {:error, :time_zone_not_found} -> {:error, {:invalid_timezone, timezone}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- composition ---------------------------------------------------------

  # The moment from the local calendar: a word a person would use when one is
  # true, else the weekday, the date and the day count. `:named` moments start
  # with that word, which a sentence lowercases; the others start with the
  # weekday, and a past date carries no relative word at all.
  defp moment(date, time, clock, occurrence_at, local_now) do
    day = weekday(date) <> ", " <> calendar_text(date, local_now)

    case Date.diff(date, DateTime.to_date(local_now)) do
      0 -> {:named, same_day(day, time, clock, occurrence_at, local_now)}
      1 -> {:named, "Tomorrow, " <> day <> at(clock)}
      days when days in 2..6 -> {:named, "This " <> day <> at(clock)}
      7 -> {:named, "A week from today, " <> day <> at(clock)}
      days when days > 7 -> {:dated, day <> at(clock) <> ", in #{days} days"}
      _past -> {:past, day <> at(clock)}
    end
  end

  defp same_day(day, nil, nil, _occurrence_at, _local_now), do: "Today, " <> day

  defp same_day(_day, %Time{} = time, clock, occurrence_at, local_now) do
    word = if Time.compare(time, @tonight_from) == :lt, do: "Today", else: "Tonight"
    word <> " at " <> clock <> hours_left(occurrence_at, local_now)
  end

  defp at(nil), do: ""
  defp at(clock), do: ", at " <> clock

  # A sentence for a birthday or an anniversary still to come; every other
  # reminder, and a date already past, leads with the moment.
  defp compose(kind, title, {class, moment}) when kind in @sentence_kinds and class != :past,
    do: bounded(title, "", " is " <> sentence_moment(class, moment) <> ".")

  defp compose(_kind, title, {_class, moment}),
    do: bounded(title, moment <> ": ", full_stop(title))

  defp sentence_moment(:named, moment), do: lowercase_first(moment)
  defp sentence_moment(:dated, moment), do: moment

  defp lowercase_first(text) do
    {first, rest} = String.split_at(text, 1)
    String.downcase(first) <> rest
  end

  defp full_stop(title) do
    if String.ends_with?(title, [".", "!", "?", @ellipsis]), do: "", else: "."
  end

  defp absolute_text(date, nil, _timezone, local_now), do: {:ok, calendar_text(date, local_now)}

  defp absolute_text(date, %Time{} = time, timezone, local_now) do
    with {:ok, clock} <- clock_with_zone(date, time, timezone) do
      {:ok, calendar_text(date, local_now) <> " at " <> clock}
    end
  end

  defp clock_with_zone(_date, nil, _timezone), do: {:ok, nil}

  defp clock_with_zone(date, %Time{} = time, timezone) do
    with {:ok, zone} <- zone_abbr(date, time, timezone) do
      {:ok, clock_text(time) <> " " <> zone}
    end
  end

  # The year is stated only when it differs from the render-time local year, so
  # an ordinary week-before reminder stays short while a next-year occurrence can
  # never be read as this year's.
  defp calendar_text(date, local_now) do
    month = elem(@months, date.month - 1)
    day = Integer.to_string(date.day)

    if date.year == local_now.year do
      month <> " " <> day
    else
      month <> " " <> day <> ", " <> Integer.to_string(date.year)
    end
  end

  defp clock_text(%Time{hour: hour, minute: minute}) do
    Integer.to_string(twelve_hour(hour)) <>
      ":" <> String.pad_leading(Integer.to_string(minute), 2, "0") <> " " <> meridiem(hour)
  end

  defp twelve_hour(0), do: 12
  defp twelve_hour(hour) when hour > 12, do: hour - 12
  defp twelve_hour(hour), do: hour

  defp meridiem(hour) when hour < 12, do: "AM"
  defp meridiem(_hour), do: "PM"

  # A calendar-day boundary is structural: a wall time inside a DST gap resolves
  # to the instant the gap ends and an ambiguous one to the first valid instant,
  # so an abbreviation always exists for a stored event.
  defp zone_abbr(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, local} -> {:ok, local.zone_abbr}
      {:ambiguous, first, _second} -> {:ok, first.zone_abbr}
      {:gap, _before, after_gap} -> {:ok, after_gap.zone_abbr}
      {:error, :time_zone_not_found} -> {:error, {:invalid_timezone, timezone}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The hours left before a timed event later today. Under half an hour, or
  # already past, says nothing rather than something a delayed retry would make
  # false.
  #
  # Round half-down to the hour: seconds of scheduler latency must never shave
  # the number (2:59:47 left reads "in 3 hours", 59:30 reads "in 1 hour"), while
  # exactly half an hour still rounds down, so a retry at 30 minutes keeps
  # dropping the clause rather than promising an hour.
  defp hours_left(%DateTime{} = occurrence_at, local_now) do
    seconds = DateTime.diff(occurrence_at, local_now, :second)

    case div(seconds + 1_799, 3_600) do
      hours when hours < 1 -> ""
      hours -> ", in " <> plural(hours, "hour")
    end
  end

  defp plural(1, unit), do: "1 " <> unit
  defp plural(count, unit), do: Integer.to_string(count) <> " " <> unit <> "s"

  # The absolute date/time is load-bearing, so only the title gives way. Cutting
  # on graphemes keeps the message valid UTF-8 for every adapter.
  defp bounded(title, prefix, suffix) do
    message = prefix <> title <> suffix

    if byte_size(message) <= @max_bytes do
      message
    else
      budget = @max_bytes - byte_size(prefix) - byte_size(suffix) - byte_size(@ellipsis)
      prefix <> truncate(title, budget) <> @ellipsis <> after_cut(suffix)
    end
  end

  # A title that ends the message ends at its ellipsis, never "…."
  defp after_cut("."), do: ""
  defp after_cut(suffix), do: suffix

  defp truncate(title, budget) when budget <= 0, do: String.first(title) || ""

  defp truncate(title, budget) do
    title
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, used} ->
      next = used + byte_size(grapheme)
      if next > budget, do: {:halt, {acc, used}}, else: {:cont, {acc <> grapheme, next}}
    end)
    |> elem(0)
  end
end
