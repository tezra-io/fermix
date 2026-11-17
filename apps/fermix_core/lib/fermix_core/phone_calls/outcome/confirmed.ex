defmodule FermixCore.PhoneCalls.Outcome.Confirmed do
  @moduledoc """
  The checks a claimed `confirmed` outcome must pass (`Outcome.verify/3`,
  whose module doc states the rules and what stays the extraction's
  judgement). `check/3` answers what survives, `{:ok, checked}`, or the first
  rule that refuses it, `{:downgrade, word, reason}`.

  Evidence items are `%{quote: quote, at: {turn, word}}`: where in the
  transcript a quote was said (`Transcript.locate/2`). What the outcome keeps
  is what the turn said there (`Transcript.said/4`), never the quote.
  """

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Outcome.Claim
  alias FermixCore.PhoneCalls.Outcome.Values
  alias FermixCore.PhoneCalls.Transcript

  @type evidence :: %{quote: String.t(), at: Transcript.position()}
  @type checked :: %{
          facts: %{atom() => %{value: String.t(), quote: String.t(), at: Transcript.position()}},
          basis: %{atom() => :verified | :read},
          matched: :brief_time | {:alternative, pos_integer()} | nil,
          not_checked: [:alternative | :must_not_commit],
          kind: :stated | :readback,
          evidence: [evidence()]
        }
  @type downgrade :: {:downgrade, atom(), atom()}

  @fact_order [:date, :local_time, :party, :terms, :reference]
  # Words of the turn after a quote's own that a clock time's meridiem may take.
  @meridiem_words 2

  @doc "What survives of a claimed `confirmed` (see the module doc)."
  @spec check(Brief.t(), [Transcript.turn()], Claim.t()) :: {:ok, checked()} | downgrade()
  def check(%Brief{} = brief, turns, %{outcome: :confirmed} = claim) when is_list(turns) do
    with :ok <- no_contradiction(claim),
         :ok <- completed(claim.commitment),
         {:ok, confirmation} <- confirmation(claim.confirmation_quote, turns),
         :ok <- not_overlapped(confirmation, turns),
         :ok <- not_read_on(claim, confirmation, turns) do
      {readback, refusal} = readback_affirmed(claim, confirmation, turns)

      case values(brief, turns, claim, confirmation, readback) do
        {:ok, checked} -> {:ok, checked}
        {:downgrade, word, reason} -> {:downgrade, word, why(reason, refusal)}
      end
    end
  end

  @doc "The checks any claim answers to first: no contradiction it reports."
  @spec no_contradiction(Claim.t()) :: :ok | downgrade()
  def no_contradiction(%{contradiction: nil}), do: :ok
  def no_contradiction(_claim), do: downgrade(:unknown, :contradictory_evidence)

  # When the values lack proof and the read-back that would have carried them
  # was refused, the refusal is why.
  defp why(reason, refusal)
       when reason in [:unverifiable_excerpt, :missing_required_fact] and not is_nil(refusal),
       do: refusal

  defp why(reason, _refusal), do: reason

  defp values(brief, turns, claim, confirmation, readback) do
    with {:ok, facts} <- verified_facts(claim.facts, turns, readback),
         :ok <- no_later_readback(claim.facts, facts, readback, turns),
         :ok <- after_corrections(claim.corrections, facts, confirmation, turns),
         {:ok, criteria} <- criteria_met(brief, claim, turns, readback, confirmation),
         :ok <- required_times(brief, facts, claim.facts),
         {:ok, basis} <- supported(brief, facts, turns),
         {:ok, mandate} <- mandate_match(brief, claim.alternative, facts, basis) do
      fact_evidence = for field <- @fact_order, fact = facts[field], do: fact
      lead = if readback, do: [readback, confirmation], else: [confirmation]

      {:ok,
       %{
         facts: facts,
         basis: basis,
         matched: mandate.matched,
         not_checked: mandate.not_checked ++ must_not_commit(brief),
         kind: kind(criteria ++ fact_evidence, readback),
         evidence: lead ++ criteria ++ fact_evidence
       }}
    end
  end

  # A `must_not_commit` item is the extraction's judgement: no string match
  # can tell whether what was agreed is one.
  defp must_not_commit(%Brief{must_not_commit: []}), do: []
  defp must_not_commit(_brief), do: [:must_not_commit]

  defp kind(_evidence, nil), do: :stated

  defp kind(evidence, %{at: {index, _word}}) do
    if Enum.any?(evidence, &match?(%{at: {^index, _}}, &1)), do: :readback, else: :stated
  end

  defp completed(:completed), do: :ok
  defp completed(:offered), do: downgrade(:options, :tentative_offer)
  defp completed(:requested), do: downgrade(:unknown, :awaiting_action)
  defp completed(:none), do: downgrade(:unknown, :no_commitment)

  defp confirmation(nil, _turns), do: downgrade(:unknown, :no_confirmation)

  defp confirmation(quote, turns) do
    case Transcript.locate(quote, turns) do
      %{remote: {_turn, _word} = at} -> {:ok, %{quote: quote, at: at}}
      %{any: {_turn, _word}} -> downgrade(:unknown, :assistant_only_confirmation)
      %{any: nil} -> downgrade(:unknown, :unverifiable_excerpt)
    end
  end

  # -- the yes is clear of the assistant's speech -------------------------------------

  # Turns arrive in arrival order, not speech order, so the yes is held to
  # every assistant turn the offsets place over it, wherever it arrived. An
  # untimed pair cannot show an overlap and passes this check.
  defp not_overlapped(%{at: {index, _word}}, turns) do
    yes = Enum.at(turns, index)

    if Enum.any?(turns, &(&1.speaker == :assistant and overlap?(&1, yes))),
      do: downgrade(:unknown, :interrupted_confirmation),
      else: :ok
  end

  defp overlap?(%{start_ms: a0, end_ms: a1}, %{start_ms: y0, end_ms: y1})
       when is_integer(a0) and is_integer(a1) and is_integer(y0) and is_integer(y1),
       do: a0 < y1 and y0 < a1

  defp overlap?(_assistant, _yes), do: false

  # The assistant read details on after the yes: a claimed fact or criterion
  # said in its very next turn that no assistant turn before the yes said. A
  # read-back that goes on after the yes is not finished, however it chunked.
  defp not_read_on(claim, %{at: {index, _word}}, turns) do
    case Enum.at(turns, index + 1) do
      %{speaker: :assistant} = next ->
        before = turns |> Enum.take(index) |> Enum.filter(&(&1.speaker == :assistant))

        if Enum.any?(claim_quotes(claim), &read_on?(&1, next, before)),
          do: downgrade(:unknown, :interrupted_confirmation),
          else: :ok

      _no_assistant_after ->
        :ok
    end
  end

  defp read_on?(quote, next, before),
    do:
      Transcript.within(quote, next) != nil and
        Enum.all?(before, &(Transcript.within(quote, &1) == nil))

  defp claim_quotes(claim),
    do: Enum.map(claim.facts, & &1.quote) ++ Enum.map(claim.criteria, & &1.quote)

  # -- a yes to a finished read-back ------------------------------------------------

  # The rule (see `Outcome`'s module doc), whole: `{readback, nil}` when the
  # confirmation is a yes to the finished read-back the claim names, else
  # `{nil, refusal}`, or `{nil, nil}` when it names none.
  defp readback_affirmed(%{readback_quote: nil}, _confirmation, _turns), do: {nil, nil}

  defp readback_affirmed(%{readback_quote: quote}, %{at: {yes_at, _}}, turns) do
    read = if yes_at > 0, do: Enum.at(turns, yes_at - 1)
    word = if read, do: Transcript.within(quote, read)

    cond do
      Transcript.locate(quote, turns).assistant == nil ->
        {nil, :readback_not_found}

      is_nil(word) or read.speaker != :assistant ->
        {nil, :readback_not_answered}

      untimed?(read, Enum.at(turns, yes_at), Enum.at(turns, yes_at + 1)) ->
        {nil, :readback_untimed}

      true ->
        {%{quote: quote, at: {yes_at - 1, word}}, nil}
    end
  end

  # Every offset the proof that the yes came after the read-back needs.
  defp untimed?(read, yes, next) do
    next_start = if next, do: next.start_ms, else: :none
    Enum.any?([read.end_ms, yes.start_ms, yes.end_ms, next_start], &is_nil/1)
  end

  # Where `quote` is evidence: its latest place in a `:remote` turn, else its
  # place in the affirmed read-back, else nowhere.
  defp evidence_at(quote, turns, readback) do
    case Transcript.locate(quote, turns) do
      %{remote: {_turn, _word} = at} -> at
      _not_remote -> readback_at(quote, turns, readback)
    end
  end

  defp readback_at(_quote, _turns, nil), do: nil

  defp readback_at(quote, turns, %{at: {index, _word}}) do
    case Transcript.within(quote, Enum.at(turns, index)) do
      nil -> nil
      word -> {index, word}
    end
  end

  # A claimed value said only by the assistant after the read-back, for a
  # detail the read-back settled, that differs from it.
  defp no_later_readback(_claimed, _facts, nil, _turns), do: :ok

  defp no_later_readback(claimed, facts, %{at: {index, _word}}, turns) do
    differs? = fn %{field: field, value: value, quote: quote} ->
      found = Transcript.locate(quote, turns)

      found.remote == nil and later?(found.assistant, index) and Map.has_key?(facts, field) and
        facts[field].value != value
    end

    if Enum.any?(claimed, differs?), do: downgrade(:unknown, :later_readback_differs), else: :ok
  end

  defp later?({turn, _word}, index), do: turn > index
  defp later?(nil, _index), do: false

  # -- facts ------------------------------------------------------------------------

  # Each claimed fact found in a `:remote` turn or the affirmed read-back, by
  # field, at its latest place. A claimed date or time that is not one, or two
  # found values that differ, end the check.
  defp verified_facts(claimed, turns, readback) do
    found =
      for %{field: field, value: value, quote: quote} <- claimed,
          {_turn, _word} = at <- [evidence_at(quote, turns, readback)],
          do: {field, %{value: value, quote: quote, at: at}}

    cond do
      Enum.any?(found, &invalid_value?/1) -> downgrade(:unknown, :invalid_fact)
      conflicting?(found) -> downgrade(:unknown, :contradictory_evidence)
      true -> {:ok, found |> Enum.sort_by(fn {_field, fact} -> fact.at end) |> Map.new()}
    end
  end

  defp invalid_value?({:date, %{value: value}}),
    do: not match?({:ok, _}, Date.from_iso8601(value))

  defp invalid_value?({:local_time, %{value: value}}),
    do:
      not (Regex.match?(~r/\A\d{2}:\d{2}\z/, value) and
             match?({:ok, _}, Time.from_iso8601(value <> ":00")))

  defp invalid_value?(_fact), do: false

  defp conflicting?(found) do
    found
    |> Enum.group_by(fn {field, _fact} -> field end, fn {_field, fact} -> fact.value end)
    |> Enum.any?(fn {_field, values} -> length(Enum.uniq(values)) > 1 end)
  end

  defp after_corrections([], _facts, _confirmation, _turns), do: :ok

  defp after_corrections(corrections, facts, confirmation, turns) do
    located = Enum.map(corrections, &{&1.field, Transcript.locate(&1.quote, turns).any})

    cond do
      Enum.any?(located, fn {_field, at} -> is_nil(at) end) ->
        downgrade(:unknown, :unverifiable_excerpt)

      Enum.any?(located, fn {field, at} -> superseded?(Map.get(facts, field), at) end) ->
        downgrade(:unknown, :superseded_value)

      Enum.any?(located, fn {_field, at} -> confirmation.at < at end) ->
        downgrade(:unknown, :stale_confirmation)

      true ->
        :ok
    end
  end

  defp superseded?(nil, _correction_at), do: false
  defp superseded?(%{at: at}, correction_at), do: at < correction_at

  # -- criteria ---------------------------------------------------------------------

  defp criteria_met(%Brief{completion_criteria: criteria}, claim, turns, readback, confirmation) do
    Enum.reduce_while(1..length(criteria), {:ok, []}, fn index, {:ok, met} ->
      case criterion(index, claim.criteria, turns, readback, confirmation) do
        {:ok, evidence} -> {:cont, {:ok, met ++ [evidence]}}
        {:downgrade, _word, _reason} = down -> {:halt, down}
      end
    end)
  end

  # A criterion is met by a quote said by the recipient, outside the words of
  # the confirmation itself, or said in the affirmed read-back. The yes alone
  # states nothing a criterion asks for.
  defp criterion(index, claimed, turns, readback, confirmation) do
    quotes = for %{index: ^index, quote: quote} <- claimed, do: quote
    found = Enum.find_value(quotes, &criterion_at(&1, turns, readback, confirmation))

    cond do
      found != nil ->
        {:ok, found}

      quotes == [] ->
        downgrade(:unknown, :missing_required_fact)

      Enum.any?(quotes, &said_by_recipient?(&1, turns)) ->
        downgrade(:unknown, :criterion_unstated)

      true ->
        downgrade(:unknown, :unverifiable_excerpt)
    end
  end

  defp criterion_at(quote, turns, readback, confirmation) do
    outside =
      for {:remote, at} <- Transcript.occurrences(quote, turns),
          not inside?(at, quote, confirmation),
          do: at

    case {Enum.max(outside, fn -> nil end), readback_at(quote, turns, readback)} do
      {nil, nil} -> nil
      {nil, at} -> %{quote: quote, at: at}
      {at, _readback} -> %{quote: quote, at: at}
    end
  end

  defp said_by_recipient?(quote, turns), do: Transcript.locate(quote, turns).remote != nil

  # Whether a quote at `at` lies within the confirmation's own words.
  defp inside?({turn, word}, quote, %{quote: yes, at: {yes_turn, yes_word}}) do
    turn == yes_turn and word >= yes_word and
      word + length(Transcript.words(quote)) <= yes_word + length(Transcript.words(yes))
  end

  defp required_times(%Brief{times: []}, _facts, _claimed), do: :ok

  defp required_times(%Brief{times: times}, facts, claimed) do
    case Enum.reject(fixed_fields(times), &Map.has_key?(facts, &1)) do
      [] -> :ok
      missing -> downgrade(:unknown, missing_reason(missing, claimed))
    end
  end

  defp fixed_fields(times),
    do:
      if(Enum.any?(times, &String.contains?(&1.at, "T")), do: [:date, :local_time], else: [:date])

  # A required fact the extraction claimed but the transcript does not show is
  # unverifiable; one it never claimed is missing.
  defp missing_reason(missing, claimed) do
    if Enum.any?(claimed, &(&1.field in missing)),
      do: :unverifiable_excerpt,
      else: :missing_required_fact
  end

  # -- values and the mandate ---------------------------------------------------------

  # Each fact is `:verified` when its own words say its value, else `:read`,
  # the extraction's reading of them. A date or time the brief's times fix must
  # be verified.
  defp supported(brief, facts, turns) do
    basis = Map.new(facts, fn {field, fact} -> {field, basis(field, fact, turns)} end)
    fixed = if brief.times == [], do: [], else: fixed_fields(brief.times)

    if Enum.any?(fixed, &(basis[&1] != :verified)),
      do: downgrade(:unknown, :unsupported_value),
      else: {:ok, basis}
  end

  defp basis(field, %{value: value, quote: quote, at: {index, _word} = at}, turns) do
    turn = Enum.at(turns, index)
    if said?(field, value, turn, at, quote), do: :verified, else: :read
  end

  defp said?(:date, value, turn, at, quote),
    do: Values.date_said?(value, Transcript.said(turn, at, quote))

  defp said?(:local_time, value, turn, at, quote),
    do: Values.time_said?(value, Transcript.said(turn, at, quote, @meridiem_words))

  defp said?(_field, value, turn, at, quote),
    do: Values.said?(value, Transcript.said(turn, at, quote))

  defp mandate_match(brief, alternative, facts, basis) do
    listed = alternative_text(brief, alternative)

    cond do
      alternative != nil and listed == nil ->
        downgrade(:unknown, :unlisted_alternative)

      brief.times != [] and slot_matches?(brief.times, facts) ->
        {:ok, matched(:brief_time)}

      alternative != nil ->
        alternative_match(alternative, listed, brief, facts, basis)

      brief.times == [] ->
        {:ok, matched(nil)}

      true ->
        downgrade(:needs_owner, :outside_mandate)
    end
  end

  defp matched(matched, not_checked \\ []), do: %{matched: matched, not_checked: not_checked}

  defp alternative_text(_brief, nil), do: nil
  defp alternative_text(%Brief{alternatives: alternatives}, n), do: Enum.at(alternatives, n - 1)

  # An alternative that writes clock times holds the agreed time to them; one
  # that writes none is the extraction's reading, and says so.
  defp alternative_match(n, text, brief, facts, basis) do
    stated = Values.clock_times(text)
    label = {:alternative, n}

    cond do
      MapSet.size(stated) == 0 ->
        {:ok, matched(label, [:alternative])}

      not Map.has_key?(facts, :local_time) ->
        downgrade(:unknown, :missing_required_fact)

      basis.local_time != :verified ->
        downgrade(:unknown, :unsupported_value)

      MapSet.member?(stated, facts.local_time.value) ->
        {:ok, matched(label, date_read(brief, facts))}

      true ->
        downgrade(:needs_owner, :outside_mandate)
    end
  end

  # A date the brief's times do not hold rests on the alternative's words,
  # which code does not read.
  defp date_read(%Brief{times: []}, _facts), do: []

  defp date_read(%Brief{times: times}, facts) do
    dates = Enum.map(times, &(&1.at |> String.split("T") |> hd()))
    if Map.has_key?(facts, :date) and facts.date.value not in dates, do: [:alternative], else: []
  end

  defp slot_matches?(times, facts) do
    agreed = {facts.date.value, facts |> Map.get(:local_time) |> value()}
    Enum.any?(times, &slot?(&1.at, agreed))
  end

  defp slot?(at, {date, time}) do
    case String.split(at, "T") do
      [^date] -> true
      [^date, ^time] -> true
      _other -> false
    end
  end

  defp value(nil), do: nil
  defp value(%{value: value}), do: value

  defp downgrade(word, reason), do: {:downgrade, word, reason}
end
