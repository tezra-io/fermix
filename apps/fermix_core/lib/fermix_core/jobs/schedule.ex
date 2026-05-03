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
    with {:error, :not_interval} <- parse_interval(expr, timezone, now),
         {:error, :not_once} <- parse_once(expr, timezone),
         {:error, :not_cron} <- parse_cron(expr, timezone, now) do
      {:error, {:invalid_schedule, expr}}
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

    with true <- valid_cron_fields?(fields),
         {:ok, next_run_at} <- next_cron_run(fields, now) do
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

  defp valid_cron_fields?(fields) when length(fields) == 5 do
    fields
    |> Enum.zip(@cron_ranges)
    |> Enum.all?(fn {field, range} -> cron_field?(field, range) end)
  end

  defp valid_cron_fields?(_fields), do: false

  defp cron_field?("*", _range), do: true

  defp cron_field?("*/" <> step, _range) do
    case Integer.parse(step) do
      {value, ""} when value > 0 -> true
      _other -> false
    end
  end

  defp cron_field?(value, range) do
    case Integer.parse(value) do
      {integer, ""} -> in_range?(integer, range)
      _other -> false
    end
  end

  defp next_cron_run(fields, now) do
    start = now |> truncate_to_minute() |> DateTime.add(60, :second)

    Enum.reduce_while(0..525_600, {:error, :no_future_run}, fn offset, _acc ->
      candidate = DateTime.add(start, offset * 60, :second)

      if cron_match?(fields, candidate) do
        {:halt, {:ok, candidate}}
      else
        {:cont, {:error, :no_future_run}}
      end
    end)
  end

  defp truncate_to_minute(%DateTime{} = value) do
    %{value | second: 0, microsecond: {0, 0}}
  end

  defp cron_match?([minute, hour, day, month, weekday], %DateTime{} = dt) do
    cron_value_match?(minute, dt.minute) and
      cron_value_match?(hour, dt.hour) and
      cron_value_match?(day, dt.day) and
      cron_value_match?(month, dt.month) and
      cron_value_match?(weekday, Date.day_of_week(DateTime.to_date(dt)) |> rem(7))
  end

  defp cron_value_match?("*", _value), do: true

  defp cron_value_match?("*/" <> step, value) do
    case Integer.parse(step) do
      {step, ""} when step > 0 -> rem(value, step) == 0
      _other -> false
    end
  end

  defp cron_value_match?(field, value) do
    case Integer.parse(field) do
      {7, ""} -> value == 0
      {expected, ""} -> expected == value
      _other -> false
    end
  end

  defp in_range?(value, {min, max}), do: value >= min and value <= max
end
