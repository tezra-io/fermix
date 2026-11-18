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
  reason as a code (`reasons/0`, `vocabulary/0`): this module writes no
  sentence for an owner, the view (`PhoneCalls.Report`) says each code once.
  The uncertainty is only the extraction's own note, the model's words.

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
  alias FermixCore.Text

  @words [:confirmed, :unavailable, :options, :needs_owner, :unknown]
  # How the worker's `Call.Ending` reads each end (`Ending.end_reason/1`).
  @end_reasons [:no_answer, :failed, :voicemail, :hangup, :deadline, :cancelled, :connection_lost]

  # Every reason an outcome carries, as the code the report holds. The words
  # for each are the view's (`PhoneCalls.Report`), said once, there.
  @reason_codes [
    :not_answered,
    :voicemail,
    :no_recipient_speech,
    :contradictory_evidence,
    :tentative_offer,
    :awaiting_action,
    :no_commitment,
    :no_confirmation,
    :assistant_only_confirmation,
    :assistant_only_evidence,
    :unverifiable_excerpt,
    :invalid_fact,
    :unsupported_value,
    :interrupted_confirmation,
    :criterion_unstated,
    :superseded_value,
    :stale_confirmation,
    :missing_required_fact,
    :outside_mandate,
    :unlisted_alternative,
    :no_evidence,
    :readback_not_found,
    :readback_not_answered,
    :readback_untimed,
    :later_readback_differs,
    :extraction_timeout,
    :extraction_crashed,
    :extraction_provider_error,
    :extraction_refused,
    :extraction_malformed,
    :not_read
  ]
  # A result the worker could not read, as `unread_report/1` writes it: its
  # transcript full or the engine stopping (the row's failure words say
  # which), or its own wait for the reading run out or broken.
  @unread_codes [:not_read, :extraction_timeout, :extraction_crashed]

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
            notes: [],
            confirmation: nil,
            extraction: :not_needed

  @type word :: :confirmed | :unavailable | :options | :needs_owner | :unknown
  @type end_reason ::
          :no_answer | :failed | :voicemail | :hangup | :deadline | :cancelled | :connection_lost
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
          facts: %{optional(atom()) => String.t() | pos_integer()},
          basis: %{optional(atom()) => :verified | :read},
          not_checked: [:alternative | :must_not_commit],
          options: [String.t()],
          excerpts: [excerpt()],
          uncertainty: String.t() | nil,
          notes: [:transcript_cut],
          confirmation: :stated | :readback | nil,
          extraction: extraction()
        }
  @type report :: %{
          outcome: String.t(),
          outcome_facts: map() | nil,
          evidence: [%{speaker: String.t(), text: String.t()}],
          uncertainty: String.t() | nil
        }

  @doc "Every reason an outcome can carry, as the atom its struct holds."
  @spec reasons() :: [atom(), ...]
  def reasons, do: @reason_codes

  @doc """
  The reasons that mean the call's result was not read: the worker's own
  (`unread_report/1`) and every class of a reader that itself failed
  (`extract/4`). A report with one of them carries the call's last words as
  its evidence, never what supports a result; the view says so
  (`PhoneCalls.Report`).
  """
  @spec unread_reasons() :: [atom(), ...]
  def unread_reasons, do: Enum.uniq(@unread_codes ++ Map.values(@extraction_reasons))

  @doc """
  Every code a report (`to_report/1`) can carry, by the key that carries it:
  `reason` (`outcome_facts["reason"]`), `notes`, `confirmation`, `matched`,
  `not_checked`, and `basis` (the names of the `verified` and `read`
  lists). The view (`PhoneCalls.Report`) owns the words for each, and holds
  a sentence for every code here.
  """
  @spec vocabulary() :: %{atom() => [String.t(), ...]}
  def vocabulary,
    do: %{
      reason: @reason_codes |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      notes: ["details_left_out", "transcript_cut"],
      confirmation: ["readback", "stated"],
      matched: ["alternative", "brief_time"],
      not_checked: ["alternative", "must_not_commit"],
      basis: ["read", "verified"]
    }

  @doc """
  The report of a result the worker never read (`reason`, one of
  `:not_read`, `:extraction_timeout`, `:extraction_crashed`): `unknown`, the
  reason as its code, nothing else.
  """
  @spec unread_report(atom()) :: report()
  def unread_report(reason) when reason in @unread_codes,
    do: to_report(%__MODULE__{reason: reason})

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
      {:decided, reason} -> {:ok, %__MODULE__{reason: reason}}
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
  The outcome as the call worker reports it to `PhoneCalls.Manager`, the
  contract the view (`PhoneCalls.Report`) renders. Every word for an owner
  is the view's: this carries codes (`vocabulary/0`) and what was said.

    * `outcome`: `confirmed`, `unavailable`, `options`, `needs_owner` or
      `unknown`.
    * `outcome_facts` (`nil` when empty), under string keys:
      * `reason`: why the outcome is what it is, a code; absent for a
        confirmed result and an extraction's own word that needed none;
      * `notes`: codes, `transcript_cut` (the review left out the start of a
        long call) and `details_left_out` (the record was fitted to size);
      * a confirmed result's values, one line each: `date` (`YYYY-MM-DD`),
        `local_time` (`HH:MM`), `timezone`, `party`, `terms`, `reference`;
        and its codes: `commitment` (`completed`), `confirmation` (`stated`
        or `readback`), `matched` (`brief_time` or `alternative`, with
        `alternative`, the number of the brief's alternative);
      * `options`: what the recipient offered, one line each, the
        extraction's reading;
      * `verified`, `read`: the names of the values code checked against the
        words, and of those that are the extraction's reading (`options`
        among them); `not_checked`: `alternative`, `must_not_commit`.
    * `evidence`: what was said, `%{speaker: "recipient" | "assistant",
      text: ...}`, the transcript's own words, one line each.
    * `uncertainty`: the extraction's own note on what stays uncertain, the
      model's words, one line, or `nil`: render it as outside text.

  Fitted to the ledger's bounds after encoding (`fit_report/1`).
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
  (`Outcome.Record.fit/1`), deterministically, its notes saying when details
  were left out. Whoever adds to a report after `to_report/1` fits it again
  with this.
  """
  @spec fit_report(report()) :: report()
  def fit_report(%{outcome: word} = report) when is_binary(word), do: Record.fit(report)

  defp report_facts(outcome) do
    outcome.facts
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> put_value("reason", outcome.reason && Atom.to_string(outcome.reason))
    |> put_list("notes", Enum.map(outcome.notes, &Atom.to_string/1))
    |> put_list("options", outcome.options)
    |> put_list("verified", names(outcome.basis, :verified))
    |> put_list("read", names(outcome.basis, :read) ++ present("options", outcome.options))
    |> put_list("not_checked", Enum.map(outcome.not_checked, &Atom.to_string/1))
    |> then(&if(&1 == %{}, do: nil, else: &1))
  end

  defp names(basis, kind),
    do: for({field, ^kind} <- basis, do: Atom.to_string(field)) |> Enum.sort()

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

  # How it ended without an answer is the row's failure words, said by the view.
  defp unanswered(_ended), do: :not_answered

  # -- the extraction -------------------------------------------------------------

  defp extracted(brief, turns, _transport, opts) do
    started_at = Keyword.fetch!(opts, :started_at)
    {messages, cut?} = Extraction.messages(brief, turns, started_at)

    case Extraction.run(messages, opts) do
      {:ok, claim} ->
        brief
        |> checked(turns, claim)
        |> Map.put(:extraction, :ok)
        |> noted(cut?)

      {:error, {class, detail}} ->
        extraction_failed(class, detail, Keyword.fetch!(opts, :session_id))
    end
  end

  defp extraction_failed(class, detail, session_id) do
    Logger.warning(
      "phone_call: the outcome of #{session_id} could not be read: #{class} #{detail}"
    )

    %__MODULE__{
      reason: Map.fetch!(@extraction_reasons, class),
      extraction: {:failed, class, detail}
    }
  end

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
      |> Map.merge(%{commitment: "completed", confirmation: Atom.to_string(checked.kind)})
      |> Map.merge(matched(checked.matched))
      |> put_zone(brief, checked.facts)

    %__MODULE__{
      outcome: :confirmed,
      facts: values,
      basis: checked.basis,
      not_checked: checked.not_checked,
      confirmation: checked.kind,
      excerpts: excerpts(checked.evidence, turns),
      uncertainty: note(claim.note)
    }
  end

  defp matched(nil), do: %{}
  defp matched(:brief_time), do: %{matched: "brief_time"}
  defp matched({:alternative, n}), do: %{matched: "alternative", alternative: n}

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
      uncertainty: note(claim.note)
    }
  end

  defp downgraded(word, reason, turns, claim),
    do: %__MODULE__{kept(word, [], turns, claim) | reason: reason}

  # The extraction's own note, the one thing only it can say, one line
  # within the record's text bound.
  defp note(nil), do: nil

  defp note(text) do
    case text |> PromptText.line() |> Text.truncate_utf8(Record.bounds().text_bytes) do
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

  defp noted(outcome, false), do: outcome
  defp noted(outcome, true), do: %{outcome | notes: [:transcript_cut]}

  # -- excerpts ----------------------------------------------------------------------

  # What each turn said where its quote was found, never the quote itself,
  # within the record's own evidence bounds (`Outcome.Record.bounds/0`).
  defp excerpts(evidence, turns) do
    %{excerpts: count, excerpt_bytes: bytes} = Record.bounds()

    evidence
    |> Enum.map(fn %{quote: quote, at: {index, _word} = at} ->
      turn = Enum.at(turns, index)
      text = turn |> Transcript.said(at, quote) |> Text.truncate_utf8(bytes)
      %{speaker: turn.speaker, text: text, start_ms: turn.start_ms, end_ms: turn.end_ms}
    end)
    |> Enum.uniq_by(&{&1.speaker, &1.start_ms, &1.text})
    |> Enum.take(count)
  end

  defp label(:remote), do: "recipient"
  defp label(:assistant), do: "assistant"
end
