defmodule FermixCore.PhoneCalls.Outcome.Values do
  @moduledoc """
  What code can check about a value against the words it was read from
  (M94 §11): format checks on digits and on names derived from the value
  itself, never a reading of natural language.

    * `clock_times/1`: the clock times written in digits in a text, each a
      `HH:MM` on a 24-hour clock. A time needs minutes (`7:30`) or a meridiem
      (`7 PM`, `7 p.m.`) to count, so a day number never reads as a time; one
      with no meridiem is either reading (`7:30` is `07:30` or `19:30`). A
      time in words ("half past seven") is not one.
    * `date_said?/2`: a date's day of the month written in digits (`5`,
      `5th`) together with its month, named in English as `Calendar` names it
      (`December`, `Dec`) or as a number beside its year. A weekday alone, or
      "tomorrow", does not say a date.
    * `said?/2`: a value's words, in order, among a text's words: the value is
      the speaker's own words, not a reading of them.
  """

  alias FermixCore.PhoneCalls.Transcript

  @clock ~r/(?<![\p{L}\p{N}:])(\d{1,2})(?::(\d{2}))?(?:\s*([ap])\.?\s*m\b\.?)?(?![\p{L}\p{N}])/iu
  @ordinal ~r/\A\p{L}{0,2}\z/u

  @doc "The clock times written in digits in `text` (see the module doc)."
  @spec clock_times(String.t()) :: MapSet.t(String.t())
  def clock_times(text) when is_binary(text) do
    @clock
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.flat_map(&readings/1)
    |> MapSet.new()
  end

  @doc "Whether `text` writes the `HH:MM` time `value` (see the module doc)."
  @spec time_said?(String.t(), String.t()) :: boolean()
  def time_said?(value, text) when is_binary(value) and is_binary(text),
    do: MapSet.member?(clock_times(text), value)

  @doc "Whether `text` says the ISO date `value` (see the module doc)."
  @spec date_said?(String.t(), String.t()) :: boolean()
  def date_said?(value, text) when is_binary(value) and is_binary(text) do
    case Date.from_iso8601(value) do
      {:ok, date} -> day_said?(date, Transcript.words(text)) and month_said?(date, text)
      {:error, _reason} -> false
    end
  end

  @doc "Whether `value`'s words are, in order, among `text`'s words."
  @spec said?(String.t(), String.t()) :: boolean()
  def said?(value, text) when is_binary(value) and is_binary(text) do
    case Transcript.words(value) do
      [] -> false
      needle -> contains?(Transcript.words(text), needle)
    end
  end

  # -- clock times ------------------------------------------------------------------

  defp readings([hour, minutes, meridiem]), do: readings(hour, minutes, String.downcase(meridiem))
  defp readings([hour, minutes]), do: readings(hour, minutes, "")
  defp readings([_hour]), do: []

  defp readings(_hour, "", ""), do: []

  defp readings(hour, minutes, meridiem) do
    h = String.to_integer(hour)
    m = if minutes == "", do: 0, else: String.to_integer(minutes)
    if m > 59, do: [], else: Enum.map(hours(h, meridiem), &clock(&1, m))
  end

  defp hours(h, "p") when h in 1..12, do: [rem(h, 12) + 12]
  defp hours(h, "a") when h in 1..12, do: [rem(h, 12)]
  defp hours(h, "") when h in 1..11, do: [h, h + 12]
  defp hours(h, "") when h in [0, 12] or h in 13..23, do: [h]
  defp hours(_h, _meridiem), do: []

  defp clock(h, m),
    do: String.pad_leading("#{h}", 2, "0") <> ":" <> String.pad_leading("#{m}", 2, "0")

  # -- dates ------------------------------------------------------------------------

  defp day_said?(%Date{day: day}, words), do: Enum.any?(words, &number?(&1, day, @ordinal))

  defp month_said?(date, text) do
    words = Transcript.words(text)
    names = [Calendar.strftime(date, "%B"), Calendar.strftime(date, "%b")]

    Enum.any?(words, &(&1 in Enum.map(names, fn name -> String.downcase(name) end))) or
      (Enum.any?(words, &number?(&1, date.month, ~r/\A\z/)) and
         Enum.any?(words, &number?(&1, date.year, ~r/\A\z/)))
  end

  defp number?(word, expected, suffix) do
    case Integer.parse(word) do
      {^expected, rest} -> Regex.match?(suffix, rest)
      _other -> false
    end
  end

  defp contains?([], _needle), do: false

  defp contains?([_word | rest] = words, needle),
    do: prefix?(needle, words) or contains?(rest, needle)

  defp prefix?([], _words), do: true
  defp prefix?([word | needle], [word | words]), do: prefix?(needle, words)
  defp prefix?(_needle, _words), do: false
end
