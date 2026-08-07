defmodule FermixCore.Temporal.Renderer do
  @moduledoc """
  Deterministic reminder text (M30 §13).

  Pure: no model, no provider, no database, no configuration. The message is
  built from the reminder row's bounded semantic payload — the snapshot taken
  when the row was materialized, so a later event edit never rewrites sent
  history — plus the render-time clock.

  Rules the templates enforce:

    * the absolute event date is always present, with the wall time and its zone
      whenever the event carries one;
    * the relative clause ("in 7 days", "in 1 hour") is computed at render time
      and dropped whenever it would mislead — a retry that lands under an hour
      before a timed event, or after the event has begun, simply omits it;
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
         {:ok, absolute} <- absolute_text(date, time, timezone, local_now) do
      {:ok, compose(title, absolute, date, time, occurrence_at, local_now)}
    end
  end

  def render(_row, _now), do: {:error, {:invalid_payload, "reminder"}}

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

  # Date-only, and today in the event's own zone: the "today" template. Everything
  # else is the lead-time template, which carries the relative clause when one is
  # still truthful.
  defp compose(title, absolute, date, nil, _occurrence_at, local_now) do
    if Date.compare(date, DateTime.to_date(local_now)) == :eq do
      bounded(title, "Today: ", " — " <> absolute <> ".")
    else
      bounded(
        title,
        "Reminder: ",
        " is " <> absolute <> relative(date, nil, nil, local_now) <> "."
      )
    end
  end

  defp compose(title, absolute, date, time, occurrence_at, local_now) do
    suffix = " — " <> absolute <> relative(date, time, occurrence_at, local_now) <> "."
    bounded(title, "Reminder: ", suffix)
  end

  defp absolute_text(date, nil, _timezone, local_now), do: {:ok, calendar_text(date, local_now)}

  defp absolute_text(date, %Time{} = time, timezone, local_now) do
    with {:ok, zone} <- zone_abbr(date, time, timezone) do
      {:ok, calendar_text(date, local_now) <> " at " <> clock_text(time) <> " " <> zone}
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

  # Date-only events count whole local calendar days; timed events count the real
  # remaining duration. Anything under an hour, or already past, says nothing
  # rather than something a delayed retry would make false.
  defp relative(date, nil, _occurrence_at, local_now) do
    case Date.diff(date, DateTime.to_date(local_now)) do
      days when days > 0 -> " (in " <> plural(days, "day") <> ")"
      _past_or_today -> ""
    end
  end

  # Round half-down to the displayed unit: seconds of scheduler latency must
  # never shave the number (23:59:59 left reads "in 24 hours", 59:30 reads
  # "in 1 hour"), while exactly half a unit still rounds down, so a retry at
  # 30 minutes keeps dropping the clause rather than promising an hour.
  defp relative(_date, %Time{}, %DateTime{} = occurrence_at, local_now) do
    seconds = DateTime.diff(occurrence_at, local_now, :second)
    hours = div(seconds + 1_799, 3_600)

    cond do
      hours < 1 -> ""
      hours < 48 -> " (in " <> plural(hours, "hour") <> ")"
      true -> " (in " <> plural(div(seconds + 43_199, 86_400), "day") <> ")"
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
      prefix <> truncate(title, budget) <> @ellipsis <> suffix
    end
  end

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
