defmodule FermixCore.Jobs.Schedule do
  @moduledoc """
  Small schedule parser for persisted scheduled jobs.
  """

  @interval_units %{
    "minute" => 60,
    "minutes" => 60,
    "hour" => 3_600,
    "hours" => 3_600,
    "day" => 86_400,
    "days" => 86_400
  }

  @cron_ranges [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}]

  @type parsed :: %{
          kind: String.t(),
          expr: String.t(),
          timezone: String.t(),
          next_run_at: DateTime.t() | nil,
          summary: String.t()
        }

  @spec parse(String.t(), keyword()) :: {:ok, parsed()} | {:error, term()}
  def parse(expr, opts \\ []) when is_binary(expr) do
    expr = String.trim(expr)
    timezone = Keyword.get(opts, :timezone, "UTC")
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if expr == "" do
      {:error, {:invalid_schedule, expr}}
    else
      parse_non_empty(expr, timezone, now)
    end
  end

  defp parse_non_empty(expr, timezone, now) do
    with :ok <- validate_timezone(timezone, now),
         {:error, :not_interval} <- parse_interval(expr, timezone, now),
         {:error, :not_once} <- parse_once(expr, timezone),
         {:error, :not_cron} <- parse_cron(expr, timezone, now) do
      {:error, {:invalid_schedule, expr}}
    end
  end

  # A job's timezone only affects cron wall-clock matching, but an unresolvable
  # zone is a config error for any schedule kind — reject it up front and loud
  # rather than store a value that silently mis-fires later (UTC is always valid
  # and needs no database lookup).
  defp validate_timezone(timezone, _now) when timezone in ["UTC", "Etc/UTC"], do: :ok

  defp validate_timezone(timezone, now) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, _local} -> :ok
      {:error, _reason} -> {:error, {:invalid_timezone, timezone}}
    end
  end

  defp parse_interval(expr, timezone, now) do
    case Regex.run(~r/^every\s+([1-9]\d*)\s+(minute|minutes|hour|hours|day|days)$/i, expr) do
      [_match, count, unit] ->
        seconds = String.to_integer(count) * Map.fetch!(@interval_units, String.downcase(unit))

        {:ok,
         %{
           kind: "interval",
           expr: expr,
           timezone: timezone,
           next_run_at: DateTime.add(now, seconds, :second),
           summary: expr
         }}

      nil ->
        {:error, :not_interval}
    end
  end

  defp parse_once(expr, timezone) do
    case DateTime.from_iso8601(expr) do
      {:ok, next_run_at, _offset} ->
        {:ok,
         %{
           kind: "once",
           expr: expr,
           timezone: timezone,
           next_run_at: next_run_at,
           summary: "once at #{DateTime.to_iso8601(next_run_at)}"
         }}

      {:error, _reason} ->
        {:error, :not_once}
    end
  end

  defp parse_cron(expr, timezone, now) do
    fields = String.split(expr, ~r/\s+/, trim: true)

    with {:ok, matchers} <- cron_matchers(fields),
         {:ok, next_run_at} <- next_cron_run(matchers, timezone, now) do
      {:ok,
       %{
         kind: "cron",
         expr: expr,
         timezone: timezone,
         next_run_at: next_run_at,
         summary: "cron #{expr} #{timezone}"
       }}
    else
      _other -> {:error, :not_cron}
    end
  end

  # Expand the five cron fields into the explicit sets of values they match.
  # One expansion serves both validation (a malformed field => :error) and
  # matching (membership test per candidate minute), so the two never drift.
  # The weekday set is normalized so 7 collapses onto Sunday (0).
  defp cron_matchers(fields) when length(fields) == 5 do
    fields
    |> Enum.zip(@cron_ranges)
    |> Enum.reduce_while({:ok, []}, fn {field, range}, {:ok, acc} ->
      case cron_field_set(field, range) do
        {:ok, set} -> {:cont, {:ok, [set | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finalize_matchers()
  end

  defp cron_matchers(_fields), do: :error

  defp finalize_matchers({:ok, reversed}), do: {:ok, normalize_weekday(Enum.reverse(reversed))}
  defp finalize_matchers(:error), do: :error

  defp normalize_weekday([minute, hour, day, month, weekday]) do
    weekday =
      if MapSet.member?(weekday, 7),
        do: weekday |> MapSet.delete(7) |> MapSet.put(0),
        else: weekday

    [minute, hour, day, month, weekday]
  end

  # A field is a comma list of terms; each term is "*", "*/step", a single
  # value, a "lo-hi" range, or a "lo-hi/step" stepped range. Any malformed or
  # out-of-range term rejects the whole field.
  defp cron_field_set(field, range) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn term, {:ok, acc} ->
      case cron_term_values(term, range) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp cron_term_values("*", {min, max}), do: {:ok, range_set(min, max, 1)}

  defp cron_term_values("*/" <> step, {min, max}) do
    case positive_int(step) do
      {:ok, step} -> {:ok, range_set(min, max, step)}
      :error -> :error
    end
  end

  defp cron_term_values(term, range) do
    case String.split(term, "/", parts: 2) do
      [base] -> base_values(base, range, 1)
      [base, step] -> base_with_step(base, step, range)
    end
  end

  defp base_with_step(base, step, range) do
    case positive_int(step) do
      {:ok, step} -> base_values(base, range, step)
      :error -> :error
    end
  end

  # A "lo-hi" range, or a bare value (which with a step counts up to the field
  # max, matching standard cron's "N/step" semantics).
  defp base_values(base, range, step) do
    case String.split(base, "-", parts: 2) do
      [single] -> single_value(single, range, step)
      [lo, hi] -> range_values(lo, hi, range, step)
    end
  end

  defp single_value(str, {min, max}, step) do
    case Integer.parse(str) do
      {value, ""} when value >= min and value <= max and step == 1 ->
        {:ok, MapSet.new([value])}

      {value, ""} when value >= min and value <= max ->
        {:ok, range_set(value, max, step)}

      _other ->
        :error
    end
  end

  defp range_values(lo_str, hi_str, {min, max}, step) do
    with {lo, ""} <- Integer.parse(lo_str),
         {hi, ""} <- Integer.parse(hi_str),
         true <- lo >= min and hi <= max and lo <= hi do
      {:ok, range_set(lo, hi, step)}
    else
      _other -> :error
    end
  end

  defp positive_int(str) do
    case Integer.parse(str) do
      {value, ""} when value > 0 -> {:ok, value}
      _other -> :error
    end
  end

  defp range_set(from, to, step) when from <= to and step > 0 do
    MapSet.new(from..to//step)
  end

  # Candidates advance in UTC (one unambiguous instant per minute), but the cron
  # fields are matched against the candidate's wall-clock *in the job's
  # timezone* — so "0 9 * * *" fires at 09:00 local and tracks DST. The returned
  # instant stays UTC (what the scheduler arms on). Bounded to one year of
  # minutes; an unsatisfiable expression returns :no_future_run.
  defp next_cron_run(matchers, timezone, now) do
    start = now |> truncate_to_minute() |> DateTime.add(60, :second)

    Enum.reduce_while(0..525_600, {:error, :no_future_run}, fn offset, _acc ->
      candidate = DateTime.add(start, offset * 60, :second)

      if cron_match?(matchers, in_zone!(candidate, timezone)) do
        {:halt, {:ok, candidate}}
      else
        {:cont, {:error, :no_future_run}}
      end
    end)
  end

  # Converting a UTC instant to a zone's wall-clock is always unambiguous (the
  # gap/overlap cases only arise the other direction), and the timezone was
  # validated in `parse_non_empty`, so a failure here is a genuine invariant
  # break — raise rather than silently fall back to UTC.
  defp in_zone!(%DateTime{} = dt, timezone) when timezone in ["UTC", "Etc/UTC"], do: dt

  defp in_zone!(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, local} ->
        local

      {:error, reason} ->
        raise ArgumentError,
              "cannot shift #{DateTime.to_iso8601(dt)} into #{inspect(timezone)}: #{inspect(reason)}"
    end
  end

  defp truncate_to_minute(%DateTime{} = value) do
    %{value | second: 0, microsecond: {0, 0}}
  end

  # Each matcher is the explicit MapSet of values its field accepts, so a match
  # is a membership test per component. The weekday is taken mod 7 so Sunday is
  # 0 (the matcher set already collapsed 7 onto 0 at parse time).
  defp cron_match?([minute, hour, day, month, weekday], %DateTime{} = dt) do
    MapSet.member?(minute, dt.minute) and
      MapSet.member?(hour, dt.hour) and
      MapSet.member?(day, dt.day) and
      MapSet.member?(month, dt.month) and
      MapSet.member?(weekday, rem(Date.day_of_week(DateTime.to_date(dt)), 7))
  end
end
