defmodule FermixChannels.RetryHint do
  @moduledoc false

  @http_date_pattern ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/
  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  # This helper only normalizes platform hints. Callers must still compare
  # the returned delay to their live-turn or scheduled-delivery deadline.
  @spec retry_after_ms(map()) :: {:ok, non_neg_integer()} | :error
  def retry_after_ms(%{} = response) do
    response
    |> retry_after_values()
    |> Enum.find_value(&parse_retry_after_ms/1)
    |> case do
      nil -> :error
      ms -> {:ok, ms}
    end
  end

  defp retry_after_values(response) do
    header_values(Map.get(response, :headers) || Map.get(response, "headers")) ++
      body_values(Map.get(response, :body) || Map.get(response, "body"))
  end

  defp header_values(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, values} -> matching_header_values(key, values)
      _other -> []
    end)
  end

  defp header_values(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {key, values} -> matching_header_values(key, values) end)
  end

  defp header_values(_headers), do: []

  defp matching_header_values(key, values) do
    if String.downcase(to_string(key)) == "retry-after" do
      List.wrap(values)
    else
      []
    end
  end

  defp body_values(%{"parameters" => %{"retry_after" => value}}), do: [value]
  defp body_values(%{"retry_after" => value}), do: [value]
  defp body_values(%{parameters: %{retry_after: value}}), do: [value]
  defp body_values(%{retry_after: value}), do: [value]
  defp body_values(_body), do: []

  defp parse_retry_after_ms(value) when is_integer(value) and value >= 0, do: value * 1_000
  defp parse_retry_after_ms(value) when is_float(value) and value >= 0, do: ceil(value * 1_000)

  defp parse_retry_after_ms(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_retry_after_string()
  end

  defp parse_retry_after_ms(_value), do: nil

  defp parse_retry_after_string(""), do: nil

  defp parse_retry_after_string(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 -> ceil(seconds * 1_000)
      _other -> parse_http_date_ms(value)
    end
  end

  defp parse_http_date_ms(value) do
    with [_, day, month, year, hour, minute, second] <- Regex.run(@http_date_pattern, value),
         {:ok, {year, month, day, hour, minute, second}} <-
           http_date_parts(year, month, day, hour, minute, second),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, retry_at} <- DateTime.from_naive(naive, "Etc/UTC") do
      max(DateTime.diff(retry_at, DateTime.utc_now(), :millisecond), 0)
    else
      _error -> nil
    end
  end

  defp http_date_parts(year, month, day, hour, minute, second) do
    with {year, ""} <- Integer.parse(year),
         month when is_integer(month) <- Map.get(@months, month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second) do
      {:ok, {year, month, day, hour, minute, second}}
    else
      _error -> :error
    end
  end
end
