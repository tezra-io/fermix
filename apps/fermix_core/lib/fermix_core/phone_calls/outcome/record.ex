defmodule FermixCore.PhoneCalls.Outcome.Record do
  @moduledoc """
  An outcome report fitted to the ledger's bounds after encoding (M94 §9, §11),
  so a report is never refused for its size and a call that ended is never
  settled as unconfirmed for it.

  The bounds are the ledger's own (`PhoneCalls.Ledger.report_bounds/0`), read
  there, so a bound that moves there moves here; the outcome report test
  writes the worst case through the real ledger.

  `fit/2` is deterministic. Every string value, and every string in a list,
  is made one line by `PromptText.line/1` (no control character, separator
  or bidirectional control is left to escape), and an empty one is dropped.
  While the facts encode past their bound, entries go in this order, the
  least important first: the extraction's note, the options from the last,
  then `terms`, `party` and `reference`, each also struck from the
  `verified` and `read` lists. Then every value is halved, at most
  `@max_rounds` times and never below `@min_value_bytes`; and should the
  facts still not fit, keys go in sorted order until they do. Whenever
  anything was left out or shortened, the uncertainty starts with the
  sentence the caller hands in. Evidence keeps at most the ledger's count of
  excerpts, each one line within its bytes; the uncertainty is cut to its
  bytes.
  """

  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.PromptText

  @drop_order ~w(extraction_note options terms party reference)
  @lists ~w(verified read not_checked)
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

  @doc "`report` fitted to `bounds/0` (see the module doc); `left_out` says details went."
  @spec fit(report(), String.t()) :: report()
  def fit(
        %{outcome_facts: facts, evidence: evidence, uncertainty: uncertainty} = report,
        left_out
      )
      when is_list(evidence) and is_binary(left_out) do
    {facts, shortened?} = facts |> cleaned() |> fitted()

    %{
      report
      | outcome_facts: facts,
        evidence: evidence(evidence),
        uncertainty: uncertainty(uncertainty, shortened?, left_out)
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

  defp fitted(nil), do: {nil, false}

  defp fitted(facts) do
    if fits?(facts),
      do: {facts, false},
      else: {facts |> dropped() |> shortened(0) |> last_resort(), true}
  end

  defp fits?(facts), do: byte_size(Jason.encode!(facts)) <= bounds().facts_json_bytes

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
      {key, value} when is_binary(value) and key not in @lists ->
        {key, PromptText.cut(value, max(div(byte_size(value), 2), @min_value_bytes))}

      pair ->
        pair
    end)
  end

  defp last_resort(facts) do
    facts
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while(facts, fn key, acc ->
      if fits?(acc), do: {:halt, acc}, else: {:cont, Map.delete(acc, key)}
    end)
    |> empty_to_nil()
  end

  # -- evidence and the uncertainty ------------------------------------------------------

  defp evidence(excerpts) do
    excerpts
    |> Enum.map(fn %{text: text} = excerpt ->
      %{excerpt | text: text |> PromptText.line() |> PromptText.cut(bounds().excerpt_bytes)}
    end)
    |> Enum.reject(&(&1.text == ""))
    |> Enum.take(bounds().excerpts)
  end

  defp uncertainty(nil, false, _left_out), do: nil
  defp uncertainty(nil, true, left_out), do: PromptText.cut(left_out, bounds().text_bytes)

  defp uncertainty(text, shortened?, left_out) when is_binary(text) do
    joined = if shortened?, do: left_out <> " " <> text, else: text
    joined |> PromptText.line() |> PromptText.cut(bounds().text_bytes)
  end
end
