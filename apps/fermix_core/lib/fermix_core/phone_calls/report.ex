defmodule FermixCore.PhoneCalls.Report do
  @moduledoc """
  How a call is said (M94 §10, §11): one pure view of a ledger row (`view/2`)
  and its renderings, the one owner of the words every surface uses for a
  call.

    * `text/1`, what a person reads: the report the owner's channel receives
      (`PhoneCalls.Delivery`). The recipient's words are quoted, one line each,
      and nothing in it is prompt framing, an engine code or a key name.
    * `notice/1`, what a model reads: the report a chat's follow-up turn
      starts from (`PhoneCalls.Continuation`). The same facts, with everything
      that came from outside inside an untrusted-content frame
      (`Capabilities.UntrustedContent`): what the recipient said and what was
      taken from it (`phone_call_recipient`), and OpenAI's own words
      (`phone_call_provider`).
    * `status_view/2`, the `phone_call` tool's status, for a model: the view as
      JSON-safe data, the outside words framed as in `notice/1`.

  `Management.PhoneCalls` draws its call views from `view/2` too, so the apps
  say a call in these words.

  One vocabulary: the person on the line is the recipient, Fermix's voice on
  the call is the assistant, the voice provider is OpenAI, a call whose end
  OpenAI never confirmed has its termination unconfirmed, and a request to
  the owner's agent during a call is a backend turn. The reader rule: a model
  relays these sentences and a person reads them in the apps, so they never
  address their reader. They name the owner, or say what happened without a
  subject. A surface only the owner reads (`Management.PhoneCalls`' own
  sentences, the section's rows) may say "you", for what the owner can do.

  What the outcome established (`PhoneCalls.Outcome.to_report/1`'s facts) is
  said as its meaning, never as its keys: each fact with its basis (checked
  against what was said, or Fermix's reading of what was said), how the
  recipient confirmed and what in the brief it matches, one sentence per
  judgement code could not check, and the reading's own note as a note.
  Bookkeeping the owner has no use for (the commitment word, the key lists)
  is not shown. Each fact is said once: a call never placed has no outcome
  line, a call nobody answered says nothing was agreed, and a note that only
  repeats why the call stopped is left out.

  The view is truthful about what is known. A call is `placed` `:yes`, `:no`
  (never sent to OpenAI, refused by it, or not yet dialed) or `:unknown`
  (OpenAI never said, its answer lost or one that named nothing); a call
  never placed says so and claims no voice time, carrier charge or backend
  work. The three costs stay apart and unknown stays unknown. Why a call
  stopped is one sentence per failure word the worker and the manager write
  (`reason_sentence/1`, every word in `reasons/0`): a setup the call found
  missing at its dispatch is said in `PhoneCalls.Readiness`'s own words
  (`Readiness.sentence/1`, the one owner of those sentences), and a word not
  among them is said by a sentence that claims nothing about it. Text that
  came from outside (the recipient's words, the outcome's facts, its note and
  its uncertainty, OpenAI's words) is one bounded line each, wherever it is
  shown. The backend's work is its turns and, where the turns reported them,
  their tokens: no turn reports a cost.

  A stop has one set of sentences (`stop_sentence/2`, `stop_refusal/2`), used
  by the `phone_call` tool's cancel and by `Management.PhoneCalls`' stop.
  """

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.Repo.PhoneCallsSql
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Outcome
  alias FermixCore.PhoneCalls.PromptText
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Transcript
  alias FermixCore.Text

  @recipient_source "phone_call_recipient"
  # The outcome's own note on what stays uncertain is the reading's words.
  @uncertain_lead "Still uncertain, in Fermix's reading of the call: "
  # The note the assistant gave when it ended the call (the end tool's,
  # `PhoneCalls.Call.EndReport`), written from what the recipient said.
  @end_note_lead "The assistant's note on ending the call: "
  @provider_source "phone_call_provider"

  # The facts of an outcome (`PhoneCalls.Outcome.to_report/1`), in the order
  # and the words they are shown in. Every other key is a code said as a
  # sentence (the reason, the notes, how it was confirmed, what it matched,
  # what was not checked), a basis list (said beside each fact), the zone
  # (said with the local time), the commitment word (no use to the owner) or
  # the end tool's `note` (said as the assistant's note).
  @fact_order ~w(date local_time party terms reference options)
  @fact_labels %{"local_time" => "local time", "options" => "options heard"}
  @basis %{
    verified: "checked against what was said",
    read: "Fermix's reading of what was said"
  }
  # The words for every code an outcome's report carries
  # (`PhoneCalls.Outcome.vocabulary/0`), said here and nowhere else.
  @confirmations %{
    "stated" => "The recipient stated the details.",
    "readback" => "The recipient said yes when the assistant read the details back."
  }
  # What code could not check (`Outcome`'s "What stays the extraction's
  # judgement"), one sentence each.
  @not_checked %{
    "must_not_commit" =>
      "Whether anything agreed is on the brief's list of things not to agree to is " <>
        "Fermix's reading of the call, not checked against the words.",
    "alternative" =>
      "Whether the result fits the alternative the brief allows is Fermix's reading of the " <>
        "call, not checked against the words."
  }
  @notes %{
    "transcript_cut" => "The start of a long call was left out of the review.",
    "details_left_out" => "Some details were left out of the record to fit its size."
  }
  @outcome_reasons %{
    "not_answered" => "Nobody answered.",
    "voicemail" => "The call reached voicemail; no message was left.",
    "no_recipient_speech" =>
      "The call was answered, but nothing the recipient said was transcribed.",
    "contradictory_evidence" =>
      "The recipient's words conflict on a detail that was never settled.",
    "tentative_offer" => "The recipient offered this but did not confirm it was done.",
    "awaiting_action" =>
      "The recipient said they would act on it later; nothing is confirmed yet.",
    "no_commitment" => "The recipient did not commit to anything.",
    "no_confirmation" => "The recipient never confirmed the details.",
    "assistant_only_confirmation" =>
      "Only the assistant stated the result; the recipient never confirmed it.",
    "assistant_only_evidence" => "Only the assistant said this; the recipient never did.",
    "unverifiable_excerpt" => "Words the result relies on are not in the transcript.",
    "invalid_fact" => "A date or time the result relies on is not a valid date or time.",
    "unsupported_value" => "A date or time the result relies on is not what the words said.",
    "interrupted_confirmation" =>
      "The recipient's yes came while the assistant was still speaking or reading details " <>
        "back.",
    "criterion_unstated" =>
      "The recipient's yes alone does not state what the brief requires, and nothing else " <>
        "they said does.",
    "superseded_value" => "A detail was corrected after the words the result relies on.",
    "stale_confirmation" => "A detail was corrected after the recipient confirmed.",
    "missing_required_fact" => "The call did not establish everything the brief requires.",
    "outside_mandate" => "The recipient confirmed something outside what the brief allows.",
    "unlisted_alternative" => "The result relies on an alternative the brief does not list.",
    "no_evidence" => "Nothing the recipient said supports this result.",
    "readback_not_found" =>
      "The read-back the result relies on is not among the assistant's words.",
    "readback_not_answered" =>
      "The recipient's yes did not come right after the assistant's read-back.",
    "readback_untimed" => "The call's timing cannot show the yes came after the read-back ended.",
    "later_readback_differs" => "A later read-back gave a different value for a detail.",
    "extraction_timeout" => "Fermix could not read the call's result in time.",
    "extraction_crashed" => "Fermix could not read the call's result: the reading stopped.",
    "extraction_provider_error" =>
      "Fermix could not read the call's result: the model it asked failed.",
    "extraction_refused" =>
      "Fermix could not read the call's result: the model it asked refused.",
    "extraction_malformed" =>
      "Fermix could not read the call's result: the answer was not in the expected form.",
    "not_read" => "Fermix did not read the call's result."
  }
  @matched %{
    "brief_time" => "It matches a time in the brief.",
    "alternative" => "It matches an alternative the brief allows."
  }
  # A reason code no table holds: said without a claim about it.
  @outcome_reason_other "Fermix could not tell why the result is what it is."
  @not_checked_other "Part of this result is Fermix's reading of the call, not checked " <>
                       "against the words."
  @note_other "The record of this call is incomplete."
  @speakers %{"recipient" => "The recipient", "assistant" => "The assistant"}

  @outcome_sentences %{
    "pending" => "The call has not finished.",
    "confirmed" => "The recipient confirmed what was asked for.",
    "unavailable" => "The recipient said it is not available.",
    "options" => "The recipient offered other options, and nothing was agreed.",
    "needs_owner" =>
      "The call needs a fact or a decision the brief did not give. Calling again is a new " <>
        "request.",
    "unknown" => "Fermix could not tell what was agreed, if anything."
  }
  @unreached "Nobody was reached, so nothing was agreed."

  @progress %{
    "admitted" => "The call is about to be placed.",
    "dispatching" => "The call is being placed.",
    "connecting" => "The call is connecting.",
    "ringing" => "The call is ringing.",
    "active" => "The call is connected.",
    "closing" => "The call is ending."
  }
  @stopping "The call was told to stop, and Fermix is waiting to hear that it ended."
  @ended "The call ended."
  @failed "The call failed."
  @not_dialed "Nothing was dialed."
  @placement_unknown "Whether the call was placed is unknown, because OpenAI never said. Fermix " <>
                       "never dials it again."
  @termination_unconfirmed "Fermix asked OpenAI to end the call, and its termination is " <>
                             "unconfirmed."
  @termination_unasked "Fermix lost hold of the call before it asked OpenAI to end it, and " <>
                         "its termination is unconfirmed."
  @owner_released "The call was confirmed ended from the Telnyx portal, so its call slot is " <>
                    "free. The outcome already recorded is unchanged."
  @expired "OpenAI's own limit on a call has passed, so its call slot is free."

  # The stop's sentences, for the tool's cancel and the apps' Stop alike.
  @stop_cancelled "The call had not been placed yet, so it was stopped and nothing was dialed."
  @stop_follows " It reads stopping until its end is known, and its report follows."
  @stop_asked "Fermix asked OpenAI to end the call." <>
                @stop_follows <> " Stopping a call does not undo anything agreed on it."
  @stop_in_flight "The call is still being placed, so Fermix ends it as soon as OpenAI " <>
                    "answers the dial." <> @stop_follows
  @stop_before_dial "Fermix told the call to stop before it is placed." <> @stop_follows
  @stop_told "Fermix told the call to stop." <> @stop_follows
  @stop_ended "That call has already ended."
  # A process that is not the home's running engine (a setup page served from
  # another tree, a command that booted one) owns no worker of the daemon's.
  @stop_elsewhere "That call belongs to the Fermix that is running, so it is stopped there."
  @confirm_elsewhere "That call belongs to the Fermix that is running, so its end is " <>
                       "confirmed there."
  @slot_ways_out " It holds the call slot until it is confirmed ended, in the recovery view " <>
                   "or with the settings command, or until OpenAI's own limit on " <>
                   "a call passes."
  @stop_placement_unknown "Fermix already stopped its part of that call, and whether it was " <>
                            "placed is unknown, because OpenAI never said." <> @slot_ways_out
  @stop_termination_unconfirmed "Fermix already stopped its part of that call, and its " <>
                                  "termination is unconfirmed." <> @slot_ways_out

  @carrier_placed "Carrier charges: Telnyx bills the minutes to the account the call went " <>
                    "through, and Fermix does not know them."
  @carrier_unknown "Carrier charges: if the call was placed, Telnyx bills its minutes to the " <>
                     "account it went through."
  @voice_pending "Voice time is not known yet."
  @voice_unknown "Voice time is unknown: the final figure never arrived."
  @voice_placement_unknown "Voice time is unknown."

  # The failure words the worker (`PhoneCalls.Call`) and the manager write,
  # each by the code a part of a reason starts with. A reason is one or more
  # parts apart by `;` (an end the engine's stop cut short adds
  # `engine_stopped`, a failed request to end the call adds `hangup …`), and
  # a part may add `: detail`, which is never shown.
  # A setup the call found missing at its dispatch is written in Readiness's
  # own words, said by `Readiness.sentence/1` and never here.
  @reasons %{
    "prompt_too_large" => "The brief was too long to give the call, so nothing was dialed.",
    "dispatch_claim_timeout" =>
      "Fermix's call records did not answer in time, so nothing was dialed.",
    "dispatch_claim_refused" =>
      "Fermix's call records no longer allowed the call, so nothing was dialed.",
    "dispatch_claim_failed" =>
      "Fermix could not record the call before dialing it, so nothing was dialed.",
    "no_answer" => "Nobody answered.",
    "call_deadline_reached" => "The call reached Fermix's limit on a call, so Fermix ended it.",
    "recipient_silence_timeout" =>
      "The recipient said nothing for too long, so Fermix ended " <>
        "the call.",
    "transcript_limit_reached" =>
      "The call grew too long for Fermix to keep its words, so " <>
        "Fermix ended it.",
    "cancelled_by_owner" => "The call was stopped at the owner's request.",
    "phone_calls_disabled" => "Phone calls were turned off, so Fermix ended the call.",
    "engine_stopped" => "Fermix was stopping, so it ended the call.",
    "engine_restarted" => "Fermix restarted during the call and could not follow it to its end.",
    "cannot_proceed" => "The assistant could not go on with the call, so it ended it.",
    "core_turn_limit_reached" =>
      "The call used every backend turn a call may take, so Fermix " <>
        "ended it.",
    "call_failed" => "OpenAI reported that the call failed.",
    "provider_session_expired" => "OpenAI ended the call at its own limit on a call.",
    "provider_connection_lost" => "OpenAI lost its connection to the call.",
    "provider_closed_for_content" => "OpenAI ended the call because of what was said.",
    "provider_closed" => "OpenAI ended the call.",
    "sideband_lost" => "Fermix lost its connection to the call.",
    "attach_failed" => "Fermix could not connect to the call after OpenAI placed it.",
    "attach_timeout" => "Fermix could not connect to the call in time after OpenAI placed it.",
    "session_not_recorded" => "Fermix could not record the call's session, so it ended the call.",
    "create_rejected" => "OpenAI refused to place the call.",
    "create_not_sent" => "Fermix could not send the call to OpenAI.",
    "create_unknown" => "OpenAI never said whether it placed the call.",
    "worker_start_failed" => "The call could not start.",
    "admission_unanswered" =>
      "Fermix's record of calls did not answer in time, so the call was not placed.",
    "invalid_end_report" => "Fermix could not read how the call ended.",
    "worker_lost" => "The part of Fermix running the call stopped before the call ended."
  }
  @unknown_reason "The call stopped before it finished."
  @end_request_failed "Fermix's request to end the call failed."
  # The codes that mean nothing went out to OpenAI, or OpenAI placed nothing;
  # every Readiness word is one too (`never_placed?/1`).
  @never_placed ~w(create_not_sent create_rejected worker_start_failed admission_unanswered
                   prompt_too_large dispatch_claim_timeout dispatch_claim_refused
                   dispatch_claim_failed)

  @type placed :: :yes | :no | :unknown
  @type view :: map()

  # --- the view -------------------------------------------------------------------

  @doc """
  The one view of `row`, a ledger row, at `now` (`nil` when the slot is not
  asked about). Pure.
  """
  @spec view(map(), DateTime.t() | nil) :: view()
  def view(%{id: id, status: status} = row, now \\ nil)
      when is_binary(id) and is_binary(status) do
    placed = placed(row)
    outcome = Map.get(row, :outcome) || "unknown"
    outcome_facts = Map.get(row, :outcome_facts) || %{}
    code = reason_code(Map.get(row, :failure_reason))
    why_stopped = why_stopped(Map.get(row, :failure_reason))

    %{
      id: id,
      status: status,
      state: view_state(row),
      placed: placed,
      uncertain?: status in PhoneCallsSql.uncertain_statuses(),
      holds_slot?: now && Ledger.holds_slot?(row, now),
      contact_name: mandate(row, "contact_name"),
      destination: mandate(row, "destination"),
      destination_kind: mandate(row, "destination_kind"),
      headline: headline(row, placed),
      outcome: outcome,
      outcome_sentence: outcome_sentence(outcome, placed, unreached?(code, outcome_facts)),
      outcome_reason: outcome_reason(outcome_facts, why_stopped),
      facts: facts(outcome_facts),
      confirmed_how: confirmed_how(outcome_facts),
      not_checked: not_checked(outcome_facts),
      notes: outcome_facts |> list("notes") |> Enum.map(&Map.get(@notes, &1, @note_other)),
      end_note: line(Map.get(outcome_facts, "note"), Limits.max_record_text_bytes()),
      excerpts: excerpts(Map.get(row, :evidence)),
      unread?: unread?(Map.get(outcome_facts, "reason")),
      still_uncertain: line(Map.get(row, :outcome_uncertainty), Limits.max_record_text_bytes()),
      slot: slot_sentence(row, now),
      usage: usage(row, placed),
      failure_reason: Map.get(row, :failure_reason),
      why_stopped: why_stopped,
      provider_words: line(Map.get(row, :vendor_message), Limits.max_report_vendor_bytes()),
      end_request_words: line(Map.get(row, :cleanup_error), Limits.max_report_vendor_bytes()),
      report: Map.get(row, :report_status),
      created_at: Map.get(row, :created_at),
      ended_at: Map.get(row, :ended_at)
    }
  end

  @doc """
  The words for every code an outcome's report carries, by the key that
  carries it (`PhoneCalls.Outcome.vocabulary/0`): what the view says for
  each.
  """
  @spec outcome_vocabulary() :: %{atom() => %{String.t() => String.t()}}
  def outcome_vocabulary,
    do: %{
      reason: @outcome_reasons,
      notes: @notes,
      confirmation: @confirmations,
      matched: @matched,
      not_checked: @not_checked,
      basis: %{"verified" => @basis.verified, "read" => @basis.read}
    }

  @doc "Every failure word `reason_sentence/1` has its own sentence for."
  @spec reasons() :: [String.t(), ...]
  def reasons, do: Map.keys(@reasons) ++ Enum.map(Readiness.reasons(), &Atom.to_string/1)

  @doc """
  Why a call stopped, in one sentence: the sentence of the word `reason`
  starts with, then, when the reason says a request to end the call failed,
  that it did. A word with no sentence of its own is said truthfully and
  claims nothing about it. `nil` for no reason.
  """
  @spec reason_sentence(String.t() | nil) :: String.t() | nil
  def reason_sentence(reason), do: why_stopped(reason)

  @doc "Every sentence the view can say, for the copy gate."
  @spec sentences() :: [String.t(), ...]
  def sentences do
    Map.values(@outcome_sentences) ++
      Map.values(@progress) ++
      Map.values(@reasons) ++
      [
        @stopping,
        @ended,
        @failed,
        @not_dialed,
        @placement_unknown,
        @termination_unconfirmed,
        @termination_unasked,
        @unreached,
        @owner_released,
        @stop_cancelled,
        @stop_asked,
        @stop_in_flight,
        @stop_before_dial,
        @stop_told,
        @stop_ended,
        @stop_placement_unknown,
        @stop_termination_unconfirmed,
        @stop_elsewhere,
        @confirm_elsewhere,
        running_engine_calls(1),
        running_engine_calls(2),
        @not_checked_other,
        @expired,
        slot_held_sentence(),
        @carrier_placed,
        @carrier_unknown,
        @voice_pending,
        @voice_unknown,
        @voice_placement_unknown,
        @unknown_reason,
        @end_request_failed,
        "Voice time: #{span(154)}, confirmed by OpenAI.",
        "Voice time so far: at least #{span(41)}.",
        "Voice time: at least #{span(41)}. The final figure never arrived.",
        backend_sentence(0, nil, 0),
        backend_sentence(1, nil, 1),
        backend_sentence(2, 1834, 0),
        backend_sentence(2, 917, 1)
      ] ++
      Map.values(@confirmations) ++
      Map.values(@not_checked) ++
      Map.values(@notes) ++
      Map.values(@outcome_reasons) ++
      Map.values(@matched) ++
      [@outcome_reason_other, @note_other, "It matches alternative 1 in the brief."]
  end

  # A call is placed once OpenAI took the create; never placed when nothing
  # was sent or OpenAI refused it, and unknown when OpenAI never said.
  defp placed(%{status: "dispatch_unknown"}), do: :unknown
  defp placed(%{status: "admitted"}), do: :no

  defp placed(row) do
    cond do
      is_nil(Map.get(row, :dispatch_claimed_at)) -> :no
      never_placed?(reason_code(Map.get(row, :failure_reason))) -> :no
      true -> :yes
    end
  end

  defp view_state(%{status: status} = row) do
    if not Ledger.terminal?(status) and Map.get(row, :cancel_requested_at),
      do: "stopping",
      else: status
  end

  defp headline(%{status: "dispatch_unknown"}, _placed), do: @placement_unknown

  defp headline(%{status: "closure_unconfirmed"} = row, _placed) do
    if (Map.get(row, :cleanup_attempts) || 0) > 0,
      do: @termination_unconfirmed,
      else: @termination_unasked
  end

  defp headline(%{status: "ended"}, _placed), do: @ended
  defp headline(%{status: "failed"}, :no), do: @not_dialed
  defp headline(%{status: "failed"}, _placed), do: @failed

  defp headline(row, _placed) do
    if Map.get(row, :cancel_requested_at),
      do: @stopping,
      else: Map.fetch!(@progress, row.status)
  end

  # Only an uncertain call holds the slot past its end, and how that hold ends
  # is said.
  defp slot_sentence(%{status: status} = row, now) do
    cond do
      status not in PhoneCallsSql.uncertain_statuses() -> nil
      Map.get(row, :slot_release_reason) == "owner_confirmed" -> @owner_released
      not is_nil(Map.get(row, :slot_released_at)) -> nil
      expired?(row, now) -> @expired
      true -> slot_held_sentence()
    end
  end

  defp expired?(_row, nil), do: false
  defp expired?(row, now), do: not Ledger.holds_slot?(row, now)

  defp slot_held_sentence do
    "Fermix holds the call slot until the call is confirmed ended from the Telnyx portal, " <>
      "or until OpenAI's own limit on a call passes, #{lifetime()} after the dial."
  end

  # The slot's own hold (`Limits.slot_hold_ms/0`), in whole minutes rounded
  # up, so the sentence never names a moment before the slot frees.
  defp lifetime do
    minutes = div(Limits.slot_hold_ms() + 59_999, 60_000)
    "#{count(div(minutes, 60), "hour")} and #{count(rem(minutes, 60), "minute")}"
  end

  # --- usage ------------------------------------------------------------------------

  defp usage(_row, :no) do
    %{voice: nil, carrier: nil, backend: nil, seconds: nil, state: nil, turns: 0, tokens: nil}
  end

  defp usage(row, placed) do
    turns = Map.get(row, :core_turns) || 0
    backend = Map.get(row, :backend_usage) || %{}
    tokens = whole(Map.get(backend, "total_tokens"))

    %{
      voice: voice_sentence(row, placed),
      carrier: if(placed == :yes, do: @carrier_placed, else: @carrier_unknown),
      backend: backend_sentence(turns, tokens, whole(Map.get(backend, "turns_unmeasured")) || 0),
      seconds: Map.get(row, :voice_seconds),
      state: Map.get(row, :usage_state),
      turns: turns,
      tokens: tokens
    }
  end

  defp voice_sentence(_row, :unknown), do: @voice_placement_unknown

  defp voice_sentence(row, :yes) do
    seconds = Map.get(row, :voice_seconds)

    case {Map.get(row, :usage_state), seconds} do
      {"voice_duration_confirmed", s} when is_integer(s) ->
        "Voice time: #{span(s)}, confirmed by OpenAI."

      {"provisional", s} when is_integer(s) ->
        "Voice time so far: at least #{span(s)}."

      {"provisional", nil} ->
        @voice_pending

      {_incomplete, s} when is_integer(s) ->
        "Voice time: at least #{span(s)}. The final figure never arrived."

      {_incomplete, _none} ->
        @voice_unknown
    end
  end

  # The backend's turns and the tokens they reported (`PhoneCalls.Call`'s
  # backend usage): a turn that reported none is counted apart, since unknown
  # is not zero. No turn reports a cost, so none is said.
  defp backend_sentence(0, _tokens, _unmeasured), do: "Backend work: no backend turns."

  defp backend_sentence(turns, nil, _unmeasured),
    do: "Backend work: #{count(turns, "backend turn")}, whose tokens were not reported."

  defp backend_sentence(turns, tokens, 0),
    do: "Backend work: #{count(turns, "backend turn")}, #{count(tokens, "token")}."

  defp backend_sentence(turns, tokens, unmeasured),
    do:
      "Backend work: #{count(turns, "backend turn")}, at least #{count(tokens, "token")}; " <>
        "#{count(unmeasured, "turn")} reported none."

  defp whole(value) when is_integer(value) and value >= 0, do: value
  defp whole(_value), do: nil

  # --- why it stopped -------------------------------------------------------------

  defp why_stopped(reason) when is_binary(reason) do
    reason
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&part_sentence/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp why_stopped(_none), do: nil

  defp part_sentence("hangup" <> _detail), do: @end_request_failed

  defp part_sentence(part) do
    code = reason_code(part)

    case readiness_reason(code) do
      nil -> Map.get(@reasons, code, @unknown_reason)
      reason -> Readiness.sentence(reason)
    end
  end

  defp never_placed?(code), do: code in @never_placed or not is_nil(readiness_reason(code))

  defp readiness_reason(code), do: Enum.find(Readiness.reasons(), &(Atom.to_string(&1) == code))

  defp reason_code(reason) when is_binary(reason) do
    reason |> String.split([";", ":"], parts: 2) |> hd() |> String.trim()
  end

  defp reason_code(_none), do: nil

  # --- outside text ---------------------------------------------------------------

  # Each fact the outcome established, with its basis: `{label, value,
  # basis}`, the basis `nil` where the outcome names none.
  defp facts(facts) when is_map(facts) do
    verified = list(facts, "verified")
    read = list(facts, "read")

    Enum.flat_map(@fact_order, fn key ->
      case fact_value(key, facts) do
        nil -> []
        text -> [{Map.get(@fact_labels, key, key), text, basis(key, verified, read)}]
      end
    end)
  end

  defp fact_value("local_time", facts) do
    with time when is_binary(time) <- fact_text(Map.get(facts, "local_time")) do
      case fact_text(Map.get(facts, "timezone")) do
        nil -> time
        zone -> "#{time}, #{zone} time"
      end
    end
  end

  defp fact_value(key, facts), do: fact_text(Map.get(facts, key))

  defp fact_text(value) when is_binary(value), do: line(value, Limits.max_report_fact_bytes())

  defp fact_text([_ | _] = items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.join("; ")
    |> line(Limits.max_report_fact_bytes())
  end

  defp fact_text(_absent), do: nil

  defp basis(key, verified, read) do
    cond do
      key in verified -> :verified
      key in read -> :read
      true -> nil
    end
  end

  defp list(facts, key) do
    case Map.get(facts, key) do
      items when is_list(items) -> Enum.filter(items, &is_binary/1)
      _absent -> []
    end
  end

  # How the recipient confirmed and what in the brief it matches, from the
  # outcome's codes: a code no table holds says nothing.
  defp confirmed_how(facts) do
    [Map.get(@confirmations, Map.get(facts, "confirmation")), matched(facts)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp matched(%{"matched" => "alternative", "alternative" => n}) when is_integer(n) and n > 0,
    do: "It matches alternative #{n} in the brief."

  defp matched(facts), do: Map.get(@matched, Map.get(facts, "matched"))

  # Why the outcome is what it is, unless it only says again why the call
  # stopped.
  defp outcome_reason(facts, why_stopped) do
    case Map.get(facts, "reason") do
      nil -> nil
      code -> @outcome_reasons |> Map.get(code, @outcome_reason_other) |> unless_said(why_stopped)
    end
  end

  defp unless_said(sentence, sentence), do: nil
  defp unless_said(sentence, _said), do: sentence

  # A result never read, by the worker or by a reader that failed
  # (`Outcome.unread_reasons/0`, the one list): its evidence is the call's
  # last words, each speaker's closing line.
  defp unread?(code) when is_binary(code),
    do: Enum.any?(Outcome.unread_reasons(), &(Atom.to_string(&1) == code))

  defp unread?(_none), do: false

  # Nobody was on the line: no answer, or a voicemail.
  defp unreached?(failure_code, facts),
    do: failure_code == "no_answer" or Map.get(facts, "reason") in ["not_answered", "voicemail"]

  defp not_checked(facts),
    do:
      facts
      |> list("not_checked")
      |> Enum.map(&Map.get(@not_checked, &1, @not_checked_other))
      |> Enum.uniq()

  # A call never placed has no outcome to tell; one that reached nobody agreed
  # nothing.
  defp outcome_sentence(_outcome, :no, _unreached?), do: nil
  defp outcome_sentence("unknown", _placed, true), do: @unreached

  defp outcome_sentence(outcome, _placed, _unreached?),
    do: Map.get(@outcome_sentences, outcome, @outcome_sentences["unknown"])

  # What was said, each excerpt one bounded line, a piece of another excerpt
  # by the same speaker not shown again (`unrepeated/1`); the row keeps every
  # excerpt the outcome wrote.
  defp excerpts([_ | _] = excerpts) do
    excerpts
    |> Enum.flat_map(fn
      %{"text" => text} = excerpt ->
        excerpt_words(excerpt, line(text, Limits.max_excerpt_bytes()))

      _other ->
        []
    end)
    |> unrepeated()
  end

  defp excerpts(_excerpts), do: []

  defp excerpt_words(_excerpt, nil), do: []
  defp excerpt_words(excerpt, words), do: [{speaker(excerpt["speaker"]), words}]

  # Each verified fact brings its own quote, often a piece of a line already
  # there. An excerpt whose words (`Transcript.words/1`, the outcome's own
  # comparison) run whole inside another excerpt of the same speaker's is
  # left out, as is a repeat of an earlier one; order is otherwise kept.
  defp unrepeated(excerpts) do
    indexed =
      excerpts
      |> Enum.map(fn {who, text} -> {who, text, Transcript.words(text)} end)
      |> Enum.with_index()

    for {{who, text, words}, i} <- indexed,
        not Enum.any?(indexed, &covers?(&1, {who, words, i})),
        do: {who, text}
  end

  defp covers?({{who, _text, words}, j}, {who, piece, i}) when j != i and piece != [] do
    cond do
      words == piece -> j < i
      length(words) > length(piece) -> run_inside?(words, piece)
      true -> false
    end
  end

  defp covers?(_other, _excerpt), do: false

  defp run_inside?(words, piece) when length(words) < length(piece), do: false

  defp run_inside?([_ | rest] = words, piece),
    do: List.starts_with?(words, piece) or run_inside?(rest, piece)

  defp speaker(word), do: Map.get(@speakers, word, "Someone")

  # One line of outside text, within `max` bytes, by the call's one rule for
  # it (`PromptText.line/1`) and the shared cut (`Text.truncate_utf8/2`);
  # `nil` when nothing is left.
  defp line(text, max) when is_binary(text) do
    case text |> PromptText.line() |> Text.truncate_utf8(max) |> String.trim_trailing() do
      "" -> nil
      one -> one
    end
  end

  defp line(_text, _max), do: nil

  defp mandate(row, key) do
    case Map.get(row, :mandate) do
      %{^key => value} when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  # --- what a person reads ------------------------------------------------------------

  @doc """
  The report a person reads, for a terminal `row`: sentences and quoted
  excerpts, one line each, with no frame, no engine code and no key name.
  Pure.
  """
  @spec text(map()) :: String.t()
  def text(row) when is_map(row) do
    v = view(row)

    [
      to_line(v, "Phone call to "),
      v.headline,
      outcome_line(v, "Outcome: "),
      fact_lines(v.facts),
      judgement_lines(v),
      v.end_note && @end_note_lead <> v.end_note,
      excerpt_lines(v, &~s(- #{&1}: "#{&2}")),
      v.still_uncertain && @uncertain_lead <> v.still_uncertain,
      v.slot,
      usage_lines(v),
      v.why_stopped && "Why it stopped: " <> v.why_stopped,
      v.provider_words && ~s(OpenAI said: "#{v.provider_words}"),
      v.end_request_words && ~s(The request to end the call answered: "#{v.end_request_words}")
    ]
    |> lines()
  end

  defp to_line(v, lead) do
    case {v.contact_name, v.destination} do
      {nil, nil} -> nil
      {name, nil} -> lead <> name <> kind(v)
      {nil, number} -> lead <> number <> kind(v)
      {name, number} -> lead <> name <> kind(v) <> ", " <> number
    end
  end

  defp kind(%{destination_kind: "owner"}), do: " (the owner's phone)"
  defp kind(%{destination_kind: "business"}), do: " (a business)"
  defp kind(_view), do: ""

  defp fact_lines([]), do: []

  defp fact_lines(facts),
    do: ["What the call established:" | Enum.map(facts, &fact_line/1)]

  defp fact_line({label, value, nil}), do: "- #{label}: #{value}"
  defp fact_line({label, value, basis}), do: "- #{label}: #{value} (#{Map.fetch!(@basis, basis)})"

  # How it was confirmed, what code could not check and what the record
  # left out: Fermix's own words.
  defp judgement_lines(v) do
    [
      v.confirmed_how && "How it was confirmed: " <> v.confirmed_how,
      joined("Not checked: ", v.not_checked),
      joined("About this record: ", v.notes)
    ]
  end

  defp joined(_lead, []), do: nil
  defp joined(lead, sentences), do: lead <> Enum.join(sentences, " ")

  # The outcome and why it is what it is; none for a call never placed.
  defp outcome_line(%{outcome_sentence: nil}, _lead), do: nil

  defp outcome_line(v, lead),
    do: Enum.join(Enum.reject([lead <> v.outcome_sentence, v.outcome_reason], &is_nil/1), " ")

  # What supports the outcome, or, for a result never read, the call's last
  # words: each speaker's closing line, where the call stood when it ended.
  defp excerpt_lines(%{excerpts: []}, _render), do: []

  defp excerpt_lines(%{excerpts: excerpts} = v, render),
    do: [evidence_lead(v) | Enum.map(excerpts, fn {who, words} -> render.(who, words) end)]

  defp evidence_lead(%{unread?: true}),
    do: "The call's last words, since its result was not read:"

  defp evidence_lead(_view), do: "What was said:"

  defp usage_lines(%{placed: :no}), do: []

  defp usage_lines(%{usage: usage}), do: [usage.voice, usage.carrier, usage.backend]

  defp lines(parts) do
    parts |> List.flatten() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")
  end

  # --- what a model reads ---------------------------------------------------------------

  @doc """
  The report a model reads, for a terminal `row`: the same facts as `text/1`,
  with the recipient's words, what was taken from them and OpenAI's words each
  inside an untrusted-content frame. Pure.
  """
  @spec notice(map()) :: String.t()
  def notice(%{id: id} = row) when is_binary(id) do
    v = view(row)

    [
      "[phone call #{id}] " <> v.headline,
      to_line(v, "To: "),
      outcome_line(v, "Outcome: #{v.outcome}. "),
      judgement_lines(v),
      recipient_frame(v),
      v.slot,
      usage_lines(v),
      v.why_stopped && "Why it stopped: " <> v.why_stopped,
      provider_frame(v)
    ]
    |> lines()
  end

  defp recipient_frame(v) do
    lines =
      fact_lines(v.facts) ++
        if(v.end_note, do: [@end_note_lead <> v.end_note], else: []) ++
        excerpt_lines(v, &~s(- #{String.downcase(&1)}: "#{&2}")) ++
        if(v.still_uncertain, do: [@uncertain_lead <> v.still_uncertain], else: [])

    frame(@recipient_source, lines)
  end

  defp provider_frame(v) do
    lines =
      if(v.provider_words, do: ["OpenAI said: " <> v.provider_words], else: []) ++
        if(v.end_request_words,
          do: ["The request to end the call answered: " <> v.end_request_words],
          else: []
        )

    frame(@provider_source, lines)
  end

  defp frame(_source, []), do: nil
  defp frame(source, lines), do: UntrustedContent.frame(source, Enum.join(lines, "\n"))

  @doc """
  The `phone_call` tool's status of `row` at `now`, for a model: the view as
  JSON-safe data, what came from outside framed as in `notice/1`.
  """
  @spec status_view(map(), DateTime.t()) :: map()
  def status_view(%{id: id, status: status} = row, %DateTime{} = now)
      when is_binary(id) and is_binary(status) do
    v = view(row, now)

    %{
      call_id: id,
      state: v.state,
      placed: Atom.to_string(v.placed),
      dialed: v.placed == :yes,
      sentence: v.headline,
      contact_name: v.contact_name,
      destination_kind: v.destination_kind,
      outcome: v.outcome,
      outcome_meaning: v.outcome_sentence,
      outcome_reason: v.outcome_reason,
      notes: v.notes,
      confirmed_how: v.confirmed_how,
      not_checked: v.not_checked,
      uncertainty: v.slot,
      holds_call_slot: v.holds_slot?,
      recipient_said: recipient_frame(%{v | still_uncertain: nil}),
      outcome_uncertainty:
        v.still_uncertain && frame(@recipient_source, [@uncertain_lead <> v.still_uncertain]),
      usage: %{voice: v.usage.voice, carrier_charges: v.usage.carrier, backend: v.usage.backend},
      why_stopped: v.why_stopped,
      provider_said: provider_frame(v),
      report: v.report,
      created_at: iso(v.created_at),
      ended_at: iso(v.ended_at)
    }
  end

  # --- a stop ---------------------------------------------------------------------

  @doc """
  The sentence for a stop the call manager took (`PhoneCalls.Manager.cancel/3`
  answering `:cancelled` or `:stopping`), from the call's row as it reads
  after the stop, or `nil` when it could not be read: a call not yet placed
  was told to stop before it is, one whose dial is in flight is ended as
  soon as OpenAI answers it, and one OpenAI placed was asked to end.
  """
  @spec stop_sentence(:cancelled | :stopping, map() | nil) :: String.t()
  def stop_sentence(:cancelled, _row), do: @stop_cancelled

  def stop_sentence(:stopping, %{provider_session_id: session}) when is_binary(session),
    do: @stop_asked

  def stop_sentence(:stopping, %{status: "admitted"}), do: @stop_before_dial
  def stop_sentence(:stopping, %{status: status}) when is_binary(status), do: @stop_in_flight
  def stop_sentence(:stopping, nil), do: @stop_told

  @doc """
  Why `row` cannot be stopped at `now`, or `nil` when it can (it is not yet
  over). A call whose end is unresolved and that still holds the call slot
  says so, and says the two ways out: its end confirmed (the recovery view,
  or the settings command), or OpenAI's own limit passing.
  """
  @spec stop_refusal(map(), DateTime.t()) :: String.t() | nil
  def stop_refusal(%{status: status} = row, %DateTime{} = now) when is_binary(status) do
    cond do
      not Ledger.terminal?(status) -> nil
      not Ledger.holds_slot?(row, now) -> @stop_ended
      status == "dispatch_unknown" -> @stop_placement_unknown
      status == "closure_unconfirmed" -> @stop_termination_unconfirmed
      true -> @stop_ended
    end
  end

  @doc """
  What a process that is not the home's running engine says when asked to
  stop a call (`:stop`) or to confirm that one ended (`:confirm`): the call
  belongs to the Fermix that is running, and that is where it is done
  (`PhoneCalls.Manager`'s `:owned_by_running_engine`).
  """
  @spec owned_elsewhere(:stop | :confirm) :: String.t()
  def owned_elsewhere(:stop), do: @stop_elsewhere
  def owned_elsewhere(:confirm), do: @confirm_elsewhere

  @doc """
  The off switch's word for the `count` calls the running engine still owns,
  seen from a process that is not it: the running engine applies the switch
  when it reads the setting.
  """
  @spec running_engine_calls(pos_integer()) :: String.t()
  def running_engine_calls(count) when is_integer(count) and count > 0,
    do:
      "The Fermix that is running still has #{count(count, "call")}, and applies the " <>
        "switch when it reads the setting."

  # --- helpers ---------------------------------------------------------------------

  defp span(seconds) when seconds < 60, do: count(seconds, "second")

  defp span(seconds),
    do: "#{count(div(seconds, 60), "minute")} #{count(rem(seconds, 60), "second")}"

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_absent), do: nil
end
