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
  @typedoc "Where a value rests: the recipient's words, or a line a yes affirmed."
  @type source :: :remote | :readback | :answered
  @type checked :: %{
          facts: %{
            atom() => %{
              value: String.t(),
              quote: String.t(),
              at: Transcript.position(),
              from: source()
            }
          },
          basis: %{atom() => :verified | :read},
          matched: :brief_time | {:alternative, pos_integer()} | nil,
          not_checked: [:alternative | :brief_time | :must_not_commit],
          kind: :stated | :readback | :answered,
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
      answers = answers(claim, turns, readback)
      lines = answered_lines(readback, answers)

      case values(brief, turns, claim, confirmation, {readback, answers, lines}) do
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

  defp values(brief, turns, claim, confirmation, {readback, answers, lines}) do
    with {:ok, facts} <- verified_facts(claim.facts, turns, lines),
         :ok <- no_later_readback(claim.facts, facts, lines, turns),
         :ok <- after_corrections(claim.corrections, facts, confirmation, turns),
         {:ok, criteria} <- criteria_met(brief, claim, turns, {answers, lines}, confirmation),
         {:ok, said} <- supported(brief, facts, turns),
         {:ok, mandate} <- times_checked(brief, claim, facts, said, turns) do
      fact_evidence = for field <- @fact_order, fact = facts[field], do: fact
      kind = kind(Enum.map(criteria, & &1.from) ++ Enum.map(fact_evidence, & &1.from))
      lead = if readback, do: [readback, confirmation], else: [confirmation]
      shown = Enum.flat_map(criteria, & &1.evidence)

      {:ok,
       %{
         facts: facts,
         basis: basis(facts, said),
         matched: mandate.matched,
         not_checked: mandate.not_checked ++ must_not_commit(brief),
         kind: kind,
         evidence: ordered(kind, lead, shown) ++ fact_evidence
       }}
    end
  end

  # A yes to the assistant's questions reads in the order each was asked.
  defp ordered(:answered, lead, criteria), do: criteria ++ lead
  defp ordered(_kind, lead, criteria), do: lead ++ criteria

  # A `must_not_commit` item is the extraction's judgement: no string match
  # can tell whether what was agreed is one.
  defp must_not_commit(%Brief{must_not_commit: []}), do: []
  defp must_not_commit(_brief), do: [:must_not_commit]

  # How the result was confirmed: by a yes to the assistant's own questions,
  # by a yes to its read-back, or in the recipient's own words throughout.
  defp kind(sources) do
    cond do
      :answered in sources -> :answered
      :readback in sources -> :readback
      true -> :stated
    end
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
    if read_on_after?(claim, index, turns),
      do: downgrade(:unknown, :interrupted_confirmation),
      else: :ok
  end

  defp read_on_after?(claim, index, turns) do
    case Enum.at(turns, index + 1) do
      %{speaker: :assistant} = next ->
        before = turns |> Enum.take(index) |> Enum.filter(&(&1.speaker == :assistant))
        Enum.any?(claim_quotes(claim), &read_on?(&1, next, before))

      _no_assistant_after ->
        false
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

  # -- a yes to the assistant's question --------------------------------------------

  # Each criterion that names the assistant line it answers (`asked`), with
  # what its yes proves: `{:ok, pair}` or `{:refused, reason}`. The read-back's
  # rule, applied to each line: the line said by the assistant, the yes the
  # recipient's very next turn, the offsets placing it after the line ended,
  # no assistant speech over it, and no detail read on after it, unless the
  # assistant's next turn is itself a line the recipient answered.
  defp answers(claim, turns, readback) do
    placed =
      for %{asked: asked} = item <- claim.criteria, asked != nil, do: {item, answer(item, turns)}

    asked_turns = for %{at: {index, _word}} <- answered_lines(readback, placed), do: index

    Enum.map(placed, fn {item, result} ->
      {item, not_read_on_answer(result, claim, turns, asked_turns)}
    end)
  end

  defp answer(%{asked: asked, quote: quote}, turns) do
    said = Transcript.locate(quote, turns)

    cond do
      Transcript.locate(asked, turns).assistant == nil -> {:refused, :readback_not_found}
      said.remote == nil and said.any != nil -> {:refused, :assistant_only_evidence}
      said.remote == nil -> {:refused, :unverifiable_excerpt}
      true -> placed_answer(asked, quote, turns)
    end
  end

  defp placed_answer(asked, quote, turns) do
    case right_after(asked, quote, turns) do
      nil ->
        {:refused, :readback_not_answered}

      {asked_at, answer_at} ->
        timed_answer(%{quote: asked, at: asked_at}, quote, answer_at, turns)
    end
  end

  # The latest place the recipient said `quote` as the very next turn after an
  # assistant turn that said `asked`.
  defp right_after(asked, quote, turns) do
    found =
      for {:remote, {yes_at, _word} = answer_at} <- Transcript.occurrences(quote, turns),
          yes_at > 0,
          %{speaker: :assistant} = line <- [Enum.at(turns, yes_at - 1)],
          word when is_integer(word) <- [Transcript.within(asked, line)],
          do: {{yes_at - 1, word}, answer_at}

    List.last(found)
  end

  defp timed_answer(%{at: {line_at, _}} = asked, quote, {yes_at, _} = answer_at, turns) do
    yes = %{quote: quote, at: answer_at}

    cond do
      untimed?(Enum.at(turns, line_at), Enum.at(turns, yes_at), Enum.at(turns, yes_at + 1)) ->
        {:refused, :readback_untimed}

      not_overlapped(yes, turns) != :ok ->
        {:refused, :interrupted_confirmation}

      true ->
        {:ok, %{asked: asked, answer: yes}}
    end
  end

  defp not_read_on_answer({:ok, %{answer: %{at: {yes_at, _}}}} = ok, claim, turns, asked_turns) do
    if (yes_at + 1) in asked_turns or not read_on_after?(claim, yes_at, turns),
      do: ok,
      else: {:refused, :interrupted_confirmation}
  end

  defp not_read_on_answer(refused, _claim, _turns, _asked_turns), do: refused

  # Every assistant line a yes affirmed: the confirmation's read-back and each
  # answered criterion's line, each with what it is.
  defp answered_lines(readback, answers) do
    own = for {_item, {:ok, pair}} <- answers, do: Map.put(pair.asked, :from, :answered)
    if readback, do: [Map.put(readback, :from, :readback) | own], else: own
  end

  # Where `quote` is evidence, and what kind: its latest place in a `:remote`
  # turn, else its latest place in a line a yes affirmed, else nowhere.
  defp evidence_at(quote, turns, lines) do
    case Transcript.locate(quote, turns) do
      %{remote: {_turn, _word} = at} -> {at, :remote}
      _not_remote -> line_at(quote, turns, lines)
    end
  end

  defp line_at(quote, turns, lines) do
    found =
      for %{at: {index, _word}, from: from} <- lines,
          word when is_integer(word) <- [Transcript.within(quote, Enum.at(turns, index))],
          do: {{index, word}, from}

    Enum.max_by(found, fn {at, _from} -> at end, fn -> nil end)
  end

  # A claimed value said only by the assistant after a line a yes affirmed,
  # for a detail that differs from what was settled.
  defp no_later_readback(_claimed, _facts, [], _turns), do: :ok

  defp no_later_readback(claimed, facts, lines, turns) do
    index = lines |> Enum.map(fn %{at: {turn, _word}} -> turn end) |> Enum.min()

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

  # Each claimed fact found in a `:remote` turn or a line a yes affirmed, by
  # field, at its latest place. A claimed date or time that is not one, or two
  # found values that differ, end the check.
  defp verified_facts(claimed, turns, lines) do
    found =
      for %{field: field, value: value, quote: quote} <- claimed,
          {{_turn, _word} = at, from} <- [evidence_at(quote, turns, lines)],
          do: {field, %{value: value, quote: quote, at: at, from: from}}

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

  defp criteria_met(%Brief{completion_criteria: criteria}, claim, turns, said, confirmation) do
    Enum.reduce_while(1..length(criteria), {:ok, []}, fn index, {:ok, met} ->
      case criterion(index, claim.criteria, turns, said, confirmation) do
        {:ok, evidence} -> {:cont, {:ok, met ++ [evidence]}}
        {:downgrade, _word, _reason} = down -> {:halt, down}
      end
    end)
  end

  # A criterion is met by the recipient's yes to the one assistant line it
  # names (`asked`), and only so when it names one; else by a quote said by
  # the recipient, outside the words of the confirmation itself, or said in a
  # line a yes affirmed. The confirmation's yes alone states nothing a
  # criterion asks for.
  defp criterion(index, claimed, turns, {answers, lines}, confirmation) do
    items = for %{index: ^index} = item <- claimed, do: item
    found = Enum.find_value(items, &item_met(&1, turns, {answers, lines}, confirmation))

    cond do
      found != nil -> {:ok, found}
      items == [] -> downgrade(:unknown, :missing_required_fact)
      true -> downgrade(:unknown, unmet(items, turns, answers))
    end
  end

  defp item_met(%{asked: nil, quote: quote}, turns, {_answers, lines}, confirmation) do
    case criterion_at(quote, turns, lines, confirmation) do
      nil -> nil
      {at, from} -> %{evidence: [%{quote: quote, at: at}], from: from}
    end
  end

  defp item_met(item, _turns, {answers, _lines}, _confirmation) do
    case List.keyfind(answers, item, 0) do
      {_item, {:ok, pair}} -> %{evidence: [pair.asked, pair.answer], from: :answered}
      {_item, {:refused, _reason}} -> nil
    end
  end

  # Why no item met the criterion: a refused yes says why; a statement the
  # recipient made inside the confirmation's own words states nothing.
  defp unmet(items, turns, answers) do
    refusals =
      for item <- items, {_item, {:refused, why}} <- [List.keyfind(answers, item, 0)], do: why

    cond do
      refusals != [] ->
        hd(refusals)

      Enum.any?(items, &(&1.asked == nil and said_by_recipient?(&1.quote, turns))) ->
        :criterion_unstated

      true ->
        :unverifiable_excerpt
    end
  end

  defp criterion_at(quote, turns, lines, confirmation) do
    outside =
      for {:remote, at} <- Transcript.occurrences(quote, turns),
          not inside?(at, quote, confirmation),
          do: at

    case Enum.max(outside, fn -> nil end) do
      nil -> line_at(quote, turns, lines)
      at -> {at, :remote}
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

  # Whether each fact's own words say its value, whoever said them. A date or
  # time the brief's times fix whose words write another in full is refused.
  defp supported(brief, facts, turns) do
    said = Map.new(facts, fn {field, fact} -> {field, value_said?(field, fact, turns)} end)
    fixed = if brief.times == [], do: [], else: fixed_fields(brief.times)
    otherwise? = &(said[&1] == false and states?(&1, facts[&1], turns))

    if Enum.any?(fixed, otherwise?),
      do: downgrade(:unknown, :unsupported_value),
      else: {:ok, said}
  end

  defp states?(:date, %{quote: quote, at: {index, _word} = at}, turns),
    do: Values.date_stated?(Transcript.said(Enum.at(turns, index), at, quote))

  defp states?(:local_time, %{quote: quote, at: {index, _word} = at}, turns),
    do: Values.time_stated?(Transcript.said(Enum.at(turns, index), at, quote, @meridiem_words))

  # The brief's times held to the words: in full when the words state them,
  # and when the claim names an alternative or the brief names no time. When
  # every criterion is met but the words leave the brief's date or time
  # unstated, the result stands and its match is not checked.
  defp times_checked(brief, claim, facts, said, turns) do
    if brief.times == [] or claim.alternative != nil or stated?(brief, said) do
      with :ok <- required_times(brief, facts, claim.facts),
           :ok <- all_said(brief, said),
           do: mandate_match(brief, claim.alternative, facts, said)
    else
      unchecked_time(brief, claim.facts, turns)
    end
  end

  defp stated?(%Brief{times: times}, said),
    do: Enum.all?(fixed_fields(times), &(said[&1] == true))

  defp all_said(%Brief{times: []}, _said), do: :ok

  defp all_said(brief, said),
    do: if(stated?(brief, said), do: :ok, else: downgrade(:unknown, :unsupported_value))

  # What the reading gave for the brief's date and time still has to be one
  # of its times: a quote the transcript does not hold, a value that is no
  # date or time, or one outside every time the brief names refuses it.
  defp unchecked_time(%Brief{times: times}, claimed, turns) do
    read = for %{field: field} = fact <- claimed, field in fixed_fields(times), do: fact

    cond do
      Enum.any?(read, &(Transcript.locate(&1.quote, turns).any == nil)) ->
        downgrade(:unknown, :unverifiable_excerpt)

      Enum.any?(read, &invalid_value?({&1.field, &1})) ->
        downgrade(:unknown, :invalid_fact)

      Enum.any?(times, fn %{at: at} -> Enum.all?(read, &part_of?(at, &1)) end) ->
        {:ok, matched(nil, [:brief_time])}

      true ->
        downgrade(:needs_owner, :outside_mandate)
    end
  end

  defp part_of?(at, %{field: :date, value: date}), do: hd(String.split(at, "T")) == date

  defp part_of?(at, %{field: :local_time, value: time}),
    do: match?([_, ^time], String.split(at, "T"))

  # `:verified` when the recipient's own words say the value; `:read` when the
  # value is the extraction's reading, of their words or of a yes to the
  # assistant's.
  defp basis(facts, said) do
    Map.new(facts, fn {field, fact} ->
      {field, if(said[field] and fact.from == :remote, do: :verified, else: :read)}
    end)
  end

  defp value_said?(field, %{value: value, quote: quote, at: {index, _word} = at}, turns),
    do: said?(field, value, Enum.at(turns, index), at, quote)

  defp said?(:date, value, turn, at, quote),
    do: Values.date_said?(value, Transcript.said(turn, at, quote))

  defp said?(:local_time, value, turn, at, quote),
    do: Values.time_said?(value, Transcript.said(turn, at, quote, @meridiem_words))

  defp said?(_field, value, turn, at, quote),
    do: Values.said?(value, Transcript.said(turn, at, quote))

  defp mandate_match(brief, alternative, facts, said) do
    listed = alternative_text(brief, alternative)

    cond do
      alternative != nil and listed == nil ->
        downgrade(:unknown, :unlisted_alternative)

      brief.times != [] and slot_matches?(brief.times, facts) ->
        {:ok, matched(:brief_time)}

      alternative != nil ->
        alternative_match(alternative, listed, brief, facts, said)

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
  defp alternative_match(n, text, brief, facts, said) do
    stated = Values.clock_times(text)
    label = {:alternative, n}

    cond do
      MapSet.size(stated) == 0 ->
        {:ok, matched(label, [:alternative])}

      not Map.has_key?(facts, :local_time) ->
        downgrade(:unknown, :missing_required_fact)

      not said.local_time ->
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
