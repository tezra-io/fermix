defmodule FermixCore.PhoneCalls.Outcome do
  @moduledoc """
  What a finished phone call established (M94 §7, "Completion reporting";
  §11, the `confirmed` rule).

  `extract/4` runs once, after the call, never per transcript delta. A call
  nobody answered, one that reached voicemail, and one in which the called
  party said nothing are decided here in code from what the transport proved,
  with no model call. Otherwise one bounded, tool-free extraction
  (`Outcome.Extraction`) reads the brief and the transcript into a claim, and
  `verify/3` decides what survives of it. A failed or malformed extraction is
  no exception: the outcome is `unknown`, with its failure class kept.

  ## What code decides

  `verify/3` is pure and is the authority. The extraction's words are a
  reading, never proof: every quote it relies on must be found in the
  transcript (`Transcript.locate/2`, by its words), and only the called
  party's words (`:remote`) are evidence, with the one exception below.
  What the outcome keeps as an excerpt is what the transcript turn said
  there, from the quote's first word to its last, one line
  (`Transcript.said/4`): never the extraction's characters.

  `confirmed` survives only with all of (`Outcome.Confirmed`):

    * no contradiction the extraction reports, and a `completed` commitment:
      an offered slot is `options`, and a request awaiting action stays
      `unknown`;
    * the called party's confirmation, found in a `:remote` turn: the
      assistant's own words, a goodbye, silence or a finished transport never
      count;
    * that confirmation clear of the assistant's speech: no assistant turn
      the offsets place over it, wherever the turn arrived (turns are chunked
      by arrival, not by speech), and no detail the extraction relies on read
      on in the assistant's next turn that no assistant turn before the yes
      had said, so a yes in the middle of a read-back never confirms it;
    * every completion criterion met by a recipient quote outside the
      confirmation's own words, or by the affirmed read-back: a bare yes
      states no criterion by itself;
    * when the brief names times, the date and (for a time of day) the local
      time found and said by their own words in digits (`Outcome.Values`);
    * every supporting quote and the confirmation at or after the last
      correction of what they support;
    * a match with the mandate: one of the brief's own times; or a permitted
      alternative the extraction names by number, which must be one the brief
      lists, and, when the alternative writes clock times, whose times hold
      the agreed time; anything else was agreed outside the brief and
      `needs_owner`.

  Each fact on a confirmed outcome carries its basis: `:verified` when its
  own words say its value (a date's day and month, a time in digits, any
  other value word for word), `:read` when the value is the extraction's
  reading of the excerpt. A reference number is kept when the called party
  gave one; its absence invalidates nothing. Each downgrade records its
  reason (`reason/1`), and the uncertainty is only Fermix's own sentences;
  the extraction's note is kept apart, as a reading.

  ## A yes to a finished read-back

  The design's task procedure ends a call with the assistant reading the
  details back and the called party confirming them, so a plain "yes" to a
  complete read-back is the expected confirmation. The rule, whole, is
  `Outcome.Confirmed`'s `readback_affirmed/3`: an `:assistant` turn the
  extraction names (`readback_quote`) carries the values it states when the
  confirmation is the called party's very next turn and the offsets prove it
  began after the read-back ended. The checks above still apply: an overlap,
  a read-back that went on after the yes, a later correction, a contradiction
  or a later read-back of the same detail with another value refuse it. Its
  refusal is the reason when the values then lack proof; when the called
  party stated them, a refused read-back changes nothing. The outcome says
  which kind of confirmation it was (`:stated` or `:readback`). This is the
  build's reading for the owner to veto: deleting `readback_affirmed/3` and
  making its one call `{nil, nil}` turns it off.

  ## What stays the extraction's judgement

  Code checks who said a quote, where and when, and what digits and names it
  holds. It does not read what the words mean, so these remain the
  extraction's reading, unverified:

    * that a recipient's quote, other than the confirmation's own words,
      states the completion criterion it is cited for;
    * that the confirmation is an affirmation of the result: a "mm-hm" that
      overlaps nothing reads like a "yes";
    * that a read-back's yes answered the read-back and not a question the
      same assistant turn ended with;
    * every fact marked `:read`: party and terms as summarised, a reference
      not said word for word, and a date or time not written in digits where
      the brief fixes none;
    * whether anything agreed is on the brief's "Do not agree to" list
      (`not_checked: [:must_not_commit]`);
    * whether an agreed result fits a permitted alternative that writes no
      clock time, or a date the brief's times do not hold
      (`not_checked: [:alternative]`);
    * the commitment word and the absence of a contradiction, which can only
      downgrade a result, never raise it.
  """

  require Logger

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Outcome.Claim
  alias FermixCore.PhoneCalls.Outcome.Confirmed
  alias FermixCore.PhoneCalls.Outcome.Extraction
  alias FermixCore.PhoneCalls.Outcome.Record
  alias FermixCore.PhoneCalls.PromptText
  alias FermixCore.PhoneCalls.Transcript

  @words [:confirmed, :unavailable, :options, :needs_owner, :unknown]
  @end_reasons [
    :no_answer,
    :busy,
    :rejected,
    :failed,
    :voicemail,
    :hangup,
    :deadline,
    :cancelled,
    :connection_lost
  ]
  @abrupt_ends [:deadline, :cancelled, :connection_lost]
  @note_max_bytes 400
  @kinds %{
    stated: "the recipient stated the details",
    readback: "the recipient said yes to the assistant's read-back"
  }

  @reasons %{
    no_answer: "Nobody answered.",
    busy: "The line was busy.",
    rejected: "The call was rejected before anyone answered.",
    failed: "The call failed before anyone answered.",
    deadline: "Nobody answered before the time limit.",
    cancelled: "The call was stopped before anyone answered.",
    connection_lost: "The connection was lost before anyone answered.",
    voicemail: "The call reached voicemail; no message was left.",
    no_recipient_speech: "The call was answered, but nothing the recipient said was transcribed.",
    contradictory_evidence: "The recipient's words conflict on a detail that was never settled.",
    tentative_offer: "The recipient offered this but did not confirm it was done.",
    awaiting_action: "The recipient said they would act on it later; nothing is confirmed yet.",
    no_commitment: "The recipient did not commit to anything.",
    no_confirmation: "The recipient never confirmed the details.",
    assistant_only_confirmation:
      "Only the assistant stated the result; the recipient never confirmed it.",
    assistant_only_evidence: "Only the assistant said this; the recipient never did.",
    unverifiable_excerpt: "Words the result relies on are not in the transcript.",
    invalid_fact: "A date or time the result relies on is not a valid date or time.",
    unsupported_value: "A date or time the result relies on is not what the words said.",
    interrupted_confirmation:
      "The recipient's yes came while the assistant was still speaking or reading details back.",
    criterion_unstated:
      "The recipient's yes alone does not state what the brief requires, and nothing else they said does.",
    superseded_value: "A detail was corrected after the words the result relies on.",
    stale_confirmation: "A detail was corrected after the recipient confirmed.",
    missing_required_fact: "The call did not establish everything the brief requires.",
    outside_mandate: "The recipient confirmed something outside what the brief allows.",
    unlisted_alternative: "The result relies on an alternative the brief does not list.",
    no_evidence: "Nothing the recipient said supports this result.",
    readback_not_found: "The read-back the result relies on is not among the assistant's words.",
    readback_not_answered:
      "The recipient's yes did not come right after the assistant's read-back.",
    readback_untimed: "The call's timing cannot show the yes came after the read-back ended.",
    later_readback_differs: "A later read-back gave a different value for a detail.",
    details_left_out: "Some details were left out of the record to fit its size.",
    extraction_timeout: "Fermix could not read the call's result in time.",
    extraction_crashed: "Fermix could not read the call's result: the reader stopped.",
    extraction_provider_error: "Fermix could not read the call's result: the provider failed.",
    extraction_refused: "Fermix could not read the call's result: the provider refused.",
    extraction_malformed:
      "Fermix could not read the call's result: the answer was not in the expected form."
  }

  @extraction_reasons %{
    timeout: :extraction_timeout,
    crashed: :extraction_crashed,
    provider_error: :extraction_provider_error,
    refused: :extraction_refused,
    malformed: :extraction_malformed
  }

  defstruct outcome: :unknown,
            reason: nil,
            facts: %{},
            basis: %{},
            not_checked: [],
            options: [],
            excerpts: [],
            uncertainty: nil,
            extraction_note: nil,
            confirmation: nil,
            extraction: :not_needed

  @type word :: :confirmed | :unavailable | :options | :needs_owner | :unknown
  @type end_reason ::
          :no_answer
          | :busy
          | :rejected
          | :failed
          | :voicemail
          | :hangup
          | :deadline
          | :cancelled
          | :connection_lost
  @typedoc "What the transport proved: whether the call was answered, and how it ended."
  @type transport :: %{answered: boolean(), end_reason: end_reason()}
  @type excerpt :: %{
          speaker: Transcript.speaker(),
          text: String.t(),
          start_ms: integer() | nil,
          end_ms: integer() | nil
        }
  @type extraction :: :not_needed | :ok | {:failed, Extraction.failure(), String.t()}
  @type t :: %__MODULE__{
          outcome: word(),
          reason: atom() | nil,
          facts: %{optional(atom()) => String.t()},
          basis: %{optional(atom()) => :verified | :read},
          not_checked: [:alternative | :must_not_commit],
          options: [String.t()],
          excerpts: [excerpt()],
          uncertainty: String.t() | nil,
          extraction_note: String.t() | nil,
          confirmation: :stated | :readback | nil,
          extraction: extraction()
        }
  @type report :: %{
          outcome: String.t(),
          outcome_facts: map() | nil,
          evidence: [%{speaker: String.t(), text: String.t()}],
          uncertainty: String.t() | nil
        }

  @doc "Every reason an outcome can carry."
  @spec reasons() :: [atom(), ...]
  def reasons, do: Map.keys(@reasons)

  @doc "The sentence the owner reads for `reason`."
  @spec reason(atom()) :: String.t()
  def reason(reason) when is_map_key(@reasons, reason), do: Map.fetch!(@reasons, reason)

  @doc """
  The call's outcome, once, after the call. `transcript` is its
  `Transcript.entry/0`s; `transport` what the transport proved. Opts:
  `:started_at` (required, a `DateTime`, dates the brief the extraction
  reads), `:session_id` (required, the call's own), and the extraction's
  `:routes` and `:timeout_ms`. Always `{:ok, outcome}`: a failed extraction
  is an `unknown` outcome with its class kept.
  """
  @spec extract(Brief.t(), [Transcript.entry()], transport(), keyword()) :: {:ok, t()}
  def extract(
        %Brief{} = brief,
        transcript,
        %{answered: answered, end_reason: ended} = transport,
        opts
      )
      when is_list(transcript) and is_boolean(answered) and ended in @end_reasons and
             is_list(opts) do
    required_opts!(opts)
    turns = Transcript.turns(transcript)

    case decided(transport, turns) do
      {:decided, reason} -> {:ok, %__MODULE__{reason: reason, uncertainty: reason(reason)}}
      :extract -> {:ok, extracted(brief, turns, transport, opts)}
    end
  end

  @doc """
  What survives of `claim` (`Outcome.Claim`) against `brief` and
  `transcript`. Pure; see the module doc for the rules.
  """
  @spec verify(Brief.t(), [Transcript.entry()], Claim.t()) :: t()
  def verify(%Brief{} = brief, transcript, %{outcome: outcome} = claim)
      when is_list(transcript) and outcome in @words,
      do: checked(brief, Transcript.turns(transcript), claim)

  @doc """
  The outcome as the call worker reports it to `PhoneCalls.Manager`: the
  outcome word; the facts under string keys, with `options` and the
  extraction's note (`extraction_note`) when there are any, and the lists
  `verified` (values code checked against the words), `read` (the
  extraction's reading) and `not_checked` (judgements code cannot make);
  the excerpts as evidence (`speaker` `recipient` or `assistant`); and the
  uncertainty sentence. Fitted to the ledger's bounds after encoding
  (`fit_report/1`).
  """
  @spec to_report(t()) :: report()
  def to_report(%__MODULE__{} = outcome) do
    fit_report(%{
      outcome: Atom.to_string(outcome.outcome),
      outcome_facts: report_facts(outcome),
      evidence: Enum.map(outcome.excerpts, &%{speaker: label(&1.speaker), text: &1.text}),
      uncertainty: outcome.uncertainty
    })
  end

  @doc """
  A report fitted to the ledger's bounds after encoding
  (`Outcome.Record.fit/2`), deterministically, saying in its uncertainty when
  details were left out. Whoever adds to a report after `to_report/1` fits it
  again with this.
  """
  @spec fit_report(report()) :: report()
  def fit_report(%{outcome: word} = report) when is_binary(word),
    do: Record.fit(report, reason(:details_left_out))

  defp report_facts(outcome) do
    read = names(outcome.basis, :read)

    outcome.facts
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> put_list("options", outcome.options)
    |> put_value("extraction_note", outcome.extraction_note)
    |> put_list("verified", names(outcome.basis, :verified))
    |> put_list(
      "read",
      read ++
        present("options", outcome.options) ++ present("extraction_note", outcome.extraction_note)
    )
    |> put_list("not_checked", Enum.map(outcome.not_checked, &Atom.to_string/1))
    |> then(&if(&1 == %{}, do: nil, else: &1))
  end

  defp names(basis, kind),
    do: for({field, ^kind} <- basis, do: Atom.to_string(field)) |> Enum.sort()

  defp present(_name, nil), do: []
  defp present(_name, []), do: []
  defp present(name, _value), do: [name]

  defp put_list(facts, _key, []), do: facts
  defp put_list(facts, key, list), do: Map.put(facts, key, list)

  defp put_value(facts, _key, nil), do: facts
  defp put_value(facts, key, value), do: Map.put(facts, key, value)

  # Asserted on every path, the ones that need no model call too.
  defp required_opts!(opts) do
    case {Keyword.get(opts, :started_at), Keyword.get(opts, :session_id)} do
      {%DateTime{}, session_id} when is_binary(session_id) and session_id != "" ->
        :ok

      other ->
        raise ArgumentError,
              "Outcome.extract/4 needs opts[:started_at] and opts[:session_id], got: " <>
                inspect(other)
    end
  end

  # -- decided in code ----------------------------------------------------------

  defp decided(%{answered: false, end_reason: ended}, _turns), do: {:decided, unanswered(ended)}
  defp decided(%{end_reason: :voicemail}, _turns), do: {:decided, :voicemail}

  defp decided(_transport, turns) do
    if Transcript.remote_speech?(turns), do: :extract, else: {:decided, :no_recipient_speech}
  end

  defp unanswered(ended) when ended in [:hangup, :voicemail], do: :no_answer
  defp unanswered(ended), do: ended

  # -- the extraction -------------------------------------------------------------

  defp extracted(brief, turns, transport, opts) do
    started_at = Keyword.fetch!(opts, :started_at)
    {messages, cut?} = Extraction.messages(brief, turns, started_at)

    case Extraction.run(messages, opts) do
      {:ok, claim} ->
        brief
        |> checked(turns, claim)
        |> Map.put(:extraction, :ok)
        |> noted(cut_note(cut?) ++ end_note(transport))

      {:error, {class, detail}} ->
        extraction_failed(class, detail, Keyword.fetch!(opts, :session_id))
    end
  end

  defp extraction_failed(class, detail, session_id) do
    Logger.warning(
      "phone_call: the outcome of #{session_id} could not be read: #{class} #{detail}"
    )

    reason = Map.fetch!(@extraction_reasons, class)
    %__MODULE__{reason: reason, uncertainty: reason(reason), extraction: {:failed, class, detail}}
  end

  defp cut_note(true), do: ["The start of a long call was left out of the review."]
  defp cut_note(false), do: []

  defp end_note(%{end_reason: ended}) when ended in @abrupt_ends,
    do: ["The call ended early (#{ended})."]

  defp end_note(_transport), do: []

  # -- verification ----------------------------------------------------------------

  defp checked(brief, turns, %{outcome: :confirmed} = claim) do
    case Confirmed.check(brief, turns, claim) do
      {:ok, checked} -> confirmed(brief, checked, claim, turns)
      {:downgrade, word, reason} -> downgraded(word, reason, turns, claim)
    end
  end

  defp checked(_brief, turns, %{outcome: :unavailable} = claim) do
    with :ok <- Confirmed.no_contradiction(claim),
         {:ok, evidence} <- remote_evidence(claim.reason_quote, turns) do
      kept(:unavailable, [evidence], turns, claim)
    else
      {:downgrade, word, reason} -> downgraded(word, reason, turns, claim)
    end
  end

  defp checked(_brief, turns, %{outcome: :options} = claim) do
    case {Confirmed.no_contradiction(claim), verified_options(claim.options, turns)} do
      {{:downgrade, word, reason}, _options} -> downgraded(word, reason, turns, claim)
      {:ok, []} -> downgraded(:unknown, options_missing(claim.options), turns, claim)
      {:ok, _options} -> kept(:options, [], turns, claim)
    end
  end

  defp checked(_brief, turns, %{outcome: :needs_owner} = claim),
    do: kept(:needs_owner, reason_excerpt(claim.reason_quote, turns), turns, claim)

  defp checked(_brief, turns, %{outcome: :unknown} = claim), do: kept(:unknown, [], turns, claim)

  # -- results -----------------------------------------------------------------------

  defp confirmed(brief, checked, claim, turns) do
    values =
      checked.facts
      |> Map.new(fn {field, fact} -> {field, PromptText.line(fact.value)} end)
      |> Map.merge(%{commitment: "completed", confirmation: Map.fetch!(@kinds, checked.kind)})
      |> put_value(:matched, checked.matched)
      |> put_zone(brief, checked.facts)

    %__MODULE__{
      outcome: :confirmed,
      facts: values,
      basis: checked.basis,
      not_checked: checked.not_checked,
      confirmation: checked.kind,
      excerpts: excerpts(checked.evidence, turns),
      extraction_note: note(claim.note)
    }
  end

  defp put_zone(values, %Brief{timezone: zone}, facts) do
    if Map.has_key?(facts, :date) or Map.has_key?(facts, :local_time),
      do: Map.put(values, :timezone, zone),
      else: values
  end

  defp kept(word, evidence, turns, claim) do
    options = verified_options(claim.options, turns)

    %__MODULE__{
      outcome: word,
      options: options |> Enum.map(&PromptText.line(&1.value)) |> Enum.reject(&(&1 == "")),
      excerpts: excerpts(evidence ++ options, turns),
      extraction_note: note(claim.note)
    }
  end

  defp downgraded(word, reason, turns, claim),
    do: %__MODULE__{kept(word, [], turns, claim) | reason: reason, uncertainty: reason(reason)}

  defp note(nil), do: nil

  defp note(text) do
    case text |> PromptText.line() |> PromptText.cut(@note_max_bytes) do
      "" -> nil
      line -> line
    end
  end

  defp remote_evidence(nil, _turns), do: {:downgrade, :unknown, :no_evidence}

  defp remote_evidence(quote, turns) do
    case Transcript.locate(quote, turns) do
      %{remote: {_turn, _word} = at} -> {:ok, %{quote: quote, at: at}}
      %{any: {_turn, _word}} -> {:downgrade, :unknown, :assistant_only_evidence}
      %{any: nil} -> {:downgrade, :unknown, :unverifiable_excerpt}
    end
  end

  defp reason_excerpt(quote, turns) do
    case remote_evidence(quote, turns) do
      {:ok, evidence} -> [evidence]
      {:downgrade, _word, _reason} -> []
    end
  end

  defp verified_options(options, turns) do
    for %{value: value, quote: quote} <- options,
        %{remote: {_turn, _word} = at} <- [Transcript.locate(quote, turns)],
        do: %{value: value, quote: quote, at: at}
  end

  defp options_missing([]), do: :no_evidence
  defp options_missing(_claimed), do: :unverifiable_excerpt

  defp noted(outcome, []), do: outcome

  defp noted(outcome, notes) do
    note = [outcome.uncertainty | notes] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    %{outcome | uncertainty: PromptText.cut(note, Record.bounds().text_bytes)}
  end

  # -- excerpts ----------------------------------------------------------------------

  # What each turn said where its quote was found, never the quote itself,
  # within the record's own evidence bounds (`Outcome.Record.bounds/0`).
  defp excerpts(evidence, turns) do
    %{excerpts: count, excerpt_bytes: bytes} = Record.bounds()

    evidence
    |> Enum.map(fn %{quote: quote, at: {index, _word} = at} ->
      turn = Enum.at(turns, index)
      text = turn |> Transcript.said(at, quote) |> PromptText.cut(bytes)
      %{speaker: turn.speaker, text: text, start_ms: turn.start_ms, end_ms: turn.end_ms}
    end)
    |> Enum.uniq_by(&{&1.speaker, &1.start_ms, &1.text})
    |> Enum.take(count)
  end

  defp label(:remote), do: "recipient"
  defp label(:assistant), do: "assistant"
end
