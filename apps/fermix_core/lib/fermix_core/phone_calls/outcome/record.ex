defmodule FermixCore.PhoneCalls.Outcome.Record do
  @moduledoc """
  An outcome report fitted to the ledger's bounds after encoding (M94 §9, §11),
  so a report is never refused for its size and a call that ended is never
  settled as unconfirmed for it.

  The bounds are the ledger's own (`PhoneCalls.Ledger.report_bounds/0`), read
  there, so a bound that moves there moves here; the outcome report test
  writes the worst case through the real ledger.

  `fit/1` is deterministic. Every string value, and every string in a list,
  is made one line by `PromptText.line/1` (no control character, separator
  or bidirectional control is left to escape), and an empty one is dropped.
  While the facts encode past their bound (less the room the
  `details_left_out` note takes), entries go in this order, the least
  important first: the options from the last, then `terms`, `party` and
  `reference`, each also struck from the `verified` and `read` lists. Then
  every free-text value (none of the codes `@codes` names, nor the date, time
  and zone) is halved, at most `@max_rounds` times and never below
  `@min_value_bytes`; and should the facts still not fit, keys go in sorted
  order, the free ones before the codes, until they do. Whenever anything
  was left out or shortened, `notes` gains `details_left_out`. Evidence keeps
  at most the ledger's count of excerpts, each one line within its bytes;
  the uncertainty is one line, cut to its bytes.
  """

  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.PromptText
  alias FermixCore.Text

  @drop_order ~w(options terms party reference)
  @lists ~w(verified read not_checked notes)
  # What `Outcome.to_report/1` writes as a code or a checked value: never
  # shortened, and dropped only after every free key.
  @codes ~w(reason commitment confirmation matched alternative date local_time timezone)
  @left_out "details_left_out"
  @max_rounds 8
  @min_value_bytes 16

  @type report :: %{
          required(:outcome) => String.t(),
          required(:outcome_facts) => map() | nil,
          required(:evidence) => [%{speaker: String.t(), text: String.t()}],
          required(:uncertainty) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "The ledger's bounds a report is fitted to."
  @spec bounds() :: %{atom() => pos_integer()}
  def bounds, do: Ledger.report_bounds()

  @doc "`report` fitted to `bounds/0` (see the module doc)."
  @spec fit(report()) :: report()
  def fit(%{outcome_facts: facts, evidence: evidence, uncertainty: uncertainty} = report)
      when is_list(evidence) do
    %{
      report
      | outcome_facts: facts |> cleaned() |> fitted(),
        evidence: evidence(evidence),
        uncertainty: uncertainty(uncertainty)
    }
  end

  # -- the facts ----------------------------------------------------------------------

  defp cleaned(nil), do: nil

  defp cleaned(facts) when is_map(facts) do
    facts
    |> Enum.flat_map(fn {key, value} -> cleaned(key, value) end)
    |> Map.new()
    |> empty_to_nil()
  end

  defp cleaned(key, value) when is_binary(value) do
    case PromptText.line(value) do
      "" -> []
      line -> [{key, line}]
    end
  end

  defp cleaned(key, values) when is_list(values) do
    case values
         |> Enum.filter(&is_binary/1)
         |> Enum.map(&PromptText.line/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> []
      lines -> [{key, lines}]
    end
  end

  defp cleaned(key, value), do: [{key, value}]

  defp empty_to_nil(facts) when map_size(facts) == 0, do: nil
  defp empty_to_nil(facts), do: facts

  defp fitted(nil), do: nil

  defp fitted(facts) do
    if fits?(facts, 0),
      do: facts,
      else: facts |> dropped() |> shortened(0) |> last_resort() |> left_out()
  end

  # Room for the note the fit adds itself, so adding it never undoes the fit.
  defp fits?(facts, reserve \\ reserve()),
    do: byte_size(Jason.encode!(facts)) + reserve <= bounds().facts_json_bytes

  defp reserve, do: byte_size(Jason.encode!(%{"notes" => [@left_out]}))

  defp left_out(facts) do
    notes = facts |> Map.get("notes", []) |> List.delete(@left_out)
    Map.put(facts, "notes", notes ++ [@left_out])
  end

  # The least important entries first, one at a time, until the facts fit.
  defp dropped(facts) do
    Enum.reduce_while(drops(facts), facts, fn drop, acc ->
      if fits?(acc), do: {:halt, acc}, else: {:cont, drop.(acc)}
    end)
  end

  defp drops(facts) do
    Enum.flat_map(@drop_order, fn
      "options" -> option_drops(Map.get(facts, "options", []))
      key -> [&strike(&1, key)]
    end)
  end

  # The options from the last, then the key itself.
  defp option_drops(options),
    do: for(n <- (length(options) - 1)..0//-1, do: &keep_options(&1, n))

  defp keep_options(facts, 0), do: strike(facts, "options")
  defp keep_options(facts, n), do: Map.update!(facts, "options", &Enum.take(&1, n))

  defp strike(facts, key) do
    facts
    |> Map.delete(key)
    |> Map.new(fn
      {list, names} when list in @lists -> {list, List.delete(names, key)}
      pair -> pair
    end)
    |> Map.reject(fn {list, names} -> list in @lists and names == [] end)
  end

  defp shortened(facts, round) do
    if fits?(facts) or round >= @max_rounds,
      do: facts,
      else: facts |> halved() |> shortened(round + 1)
  end

  defp halved(facts) do
    Map.new(facts, fn
      {key, value} when is_binary(value) and key not in @codes ->
        {key, Text.truncate_utf8(value, max(div(byte_size(value), 2), @min_value_bytes))}

      pair ->
        pair
    end)
  end

  defp last_resort(facts) do
    {codes, free} = facts |> Map.keys() |> Enum.sort() |> Enum.split_with(&(&1 in @codes))

    Enum.reduce_while(free ++ codes, facts, fn key, acc ->
      if fits?(acc), do: {:halt, acc}, else: {:cont, Map.delete(acc, key)}
    end)
  end

  # -- evidence and the uncertainty ------------------------------------------------------

  defp evidence(excerpts) do
    excerpts
    |> Enum.map(fn %{text: text} = excerpt ->
      %{excerpt | text: text |> PromptText.line() |> Text.truncate_utf8(bounds().excerpt_bytes)}
    end)
    |> Enum.reject(&(&1.text == ""))
    |> Enum.take(bounds().excerpts)
  end

  defp uncertainty(nil), do: nil

  defp uncertainty(text) when is_binary(text) do
    case text |> PromptText.line() |> Text.truncate_utf8(bounds().text_bytes) do
      "" -> nil
      line -> line
    end
  end
end
