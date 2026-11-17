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
  the owner's agent during a call is a backend turn. A person and a model both
  read these sentences, so they name the owner and never say "you".

  The view is truthful about what is known. A call is `placed` `:yes`, `:no`
  (never sent to OpenAI, refused by it, or not yet dialed) or `:unknown`
  (OpenAI never said, its answer lost or one that named nothing); a call
  never placed says so and claims no voice time, carrier charge or backend
  work. The three costs stay apart and unknown stays unknown. Why a call
  stopped is one sentence per failure word the worker and the manager write
  (`reason_sentence/1`, every word in `reasons/0`): a setup the call found
  missing at its dispatch is said in `PhoneCalls.Readiness`'s own words
  (`Readiness.sentence/1`, the one owner of those sentences), and a word not
  among them is said by a sentence that claims nothing about it. Text that came from outside (the recipient's words, the
  outcome's facts and its uncertainty note, OpenAI's words) is one bounded
  line each, wherever it is shown.
  """

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.Repo.PhoneCallsSql
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Readiness

  @recipient_source "phone_call_recipient"
  @provider_source "phone_call_provider"

  # The order and the words the outcome's facts (`PhoneCalls.Outcome.to_report/1`)
  # are shown in; a fact not named here follows, by name.
  @fact_order ~w(date local_time timezone party terms reference commitment confirmation matched
                 note options)
  @fact_labels %{
    "local_time" => "local time",
    "confirmation" => "confirmed by",
    "matched" => "matches",
    "options" => "options heard"
  }
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

  @progress %{
    "admitted" => "The call is about to be placed.",
    "dispatching" => "The call is being placed.",
    "connecting" => "The call is connecting.",
    "ringing" => "The call is ringing.",
    "active" => "The call is connected.",
    "closing" => "The call is ending."
  }
  @stopping "Fermix asked the call to end and is waiting to hear that it ended."
  @ended "The call ended."
  @failed "The call failed."
  @not_dialed "Nothing was dialed."
  @placement_unknown "Whether the call was placed is unknown, because OpenAI never said. Fermix " <>
                       "never dials it again."
  @termination_unconfirmed "Fermix asked OpenAI to end the call, and its termination is " <>
                             "unconfirmed."
  @owner_released "The call was confirmed ended from the Telnyx portal, so its call slot is " <>
                    "free. What was agreed stays unknown."
  @expired "OpenAI's own limit on a call has passed, so its call slot is free."

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
      outcome: Map.get(row, :outcome) || "unknown",
      outcome_sentence: Map.fetch!(@outcome_sentences, Map.get(row, :outcome) || "unknown"),
      facts: facts(Map.get(row, :outcome_facts)),
      excerpts: excerpts(Map.get(row, :evidence)),
      still_uncertain: line(Map.get(row, :outcome_uncertainty), Limits.max_record_text_bytes()),
      slot: slot_sentence(row, now),
      usage: usage(row, placed),
      failure_reason: Map.get(row, :failure_reason),
      why_stopped: why_stopped(Map.get(row, :failure_reason)),
      provider_words: line(Map.get(row, :vendor_message), Limits.max_report_vendor_bytes()),
      end_request_words: line(Map.get(row, :cleanup_error), Limits.max_report_vendor_bytes()),
      report: Map.get(row, :report_status),
      created_at: Map.get(row, :created_at),
      ended_at: Map.get(row, :ended_at)
    }
  end

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
        @owner_released,
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
        backend_sentence(1, nil),
        backend_sentence(2, 0.01)
      ]
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
  defp headline(%{status: "closure_unconfirmed"}, _placed), do: @termination_unconfirmed
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
    %{voice: nil, carrier: nil, backend: nil, seconds: nil, state: nil, turns: 0, cost: nil}
  end

  defp usage(row, placed) do
    turns = Map.get(row, :core_turns) || 0
    cost = backend_cost(Map.get(row, :backend_usage))

    %{
      voice: voice_sentence(row, placed),
      carrier: if(placed == :yes, do: @carrier_placed, else: @carrier_unknown),
      backend: backend_sentence(turns, cost),
      seconds: Map.get(row, :voice_seconds),
      state: Map.get(row, :usage_state),
      turns: turns,
      cost: cost
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

  defp backend_cost(%{"cost_usd" => cost}) when is_number(cost) and cost >= 0, do: cost
  defp backend_cost(_usage), do: nil

  # The amount is a number beside the sentence, never inside it.
  defp backend_sentence(turns, nil),
    do: "Backend work: #{count(turns, "backend turn")}. Its cost is unknown."

  defp backend_sentence(turns, _cost), do: "Backend work: #{count(turns, "backend turn")}."

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

  defp facts(facts) when is_map(facts) and map_size(facts) > 0 do
    {named, rest} = Enum.split_with(facts, fn {key, _value} -> key in @fact_order end)

    ordered =
      Enum.sort_by(named, fn {key, _value} -> Enum.find_index(@fact_order, &(&1 == key)) end)

    Enum.flat_map(ordered ++ Enum.sort(rest), fn {key, value} ->
      case fact_value(value) do
        nil -> []
        text -> [{label(key), text}]
      end
    end)
  end

  defp facts(_facts), do: []

  defp label(key), do: Map.get(@fact_labels, key, String.replace(to_string(key), "_", " "))

  defp fact_value(value) when is_binary(value), do: line(value, Limits.max_report_fact_bytes())

  defp fact_value([_ | _] = items) do
    items
    |> Enum.map(fn item -> if is_binary(item), do: item, else: Jason.encode!(item) end)
    |> Enum.join("; ")
    |> line(Limits.max_report_fact_bytes())
  end

  defp fact_value(value),
    do: value |> Jason.encode!() |> line(Limits.max_report_fact_bytes())

  defp excerpts([_ | _] = excerpts) do
    Enum.flat_map(excerpts, fn
      %{"text" => text} = excerpt ->
        excerpt_words(excerpt, line(text, Limits.max_excerpt_bytes()))

      _other ->
        []
    end)
  end

  defp excerpts(_excerpts), do: []

  defp excerpt_words(_excerpt, nil), do: []
  defp excerpt_words(excerpt, words), do: [{speaker(excerpt["speaker"]), words}]

  defp speaker(word), do: Map.get(@speakers, word, "Someone")

  # One line of outside text, within `max` bytes: every run of whitespace (a
  # line break, a tab, a Unicode line separator) is one space, every other
  # control character goes, and a cut never splits a character.
  defp line(text, max) when is_binary(text) do
    text
    |> String.replace(~r/[\s\x{2028}\x{2029}]+/u, " ")
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "")
    |> String.trim()
    |> bounded(max)
    |> case do
      "" -> nil
      one -> one
    end
  end

  defp line(_text, _max), do: nil

  defp bounded(text, max) when byte_size(text) <= max, do: text
  defp bounded(text, max), do: text |> binary_part(0, max) |> valid_prefix()

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end

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
      "Outcome: " <> v.outcome_sentence,
      fact_lines(v.facts),
      excerpt_lines(v.excerpts, &~s(- #{&1}: "#{&2}")),
      v.still_uncertain && "Still uncertain: " <> v.still_uncertain,
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
    do: [
      "What the call established:"
      | Enum.map(facts, fn {label, value} -> "- #{label}: #{value}" end)
    ]

  defp excerpt_lines([], _render), do: []

  defp excerpt_lines(excerpts, render),
    do: ["What was said:" | Enum.map(excerpts, fn {who, words} -> render.(who, words) end)]

  defp usage_lines(%{placed: :no}), do: []

  defp usage_lines(%{usage: usage}) do
    cost =
      if usage.cost,
        do: " It cost about $#{:erlang.float_to_binary(usage.cost / 1, decimals: 4)}."

    [usage.voice, usage.carrier, usage.backend <> (cost || "")]
  end

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
      "Outcome: #{v.outcome}. " <> v.outcome_sentence,
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
        excerpt_lines(v.excerpts, &~s(- #{String.downcase(&1)}: "#{&2}")) ++
        if(v.still_uncertain, do: ["Still uncertain: " <> v.still_uncertain], else: [])

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
      uncertainty: v.slot,
      holds_call_slot: v.holds_slot?,
      recipient_said: recipient_frame(%{v | still_uncertain: nil}),
      outcome_uncertainty:
        v.still_uncertain && frame(@recipient_source, ["Still uncertain: " <> v.still_uncertain]),
      usage: %{voice: v.usage.voice, carrier_charges: v.usage.carrier, backend: v.usage.backend},
      why_stopped: v.why_stopped,
      provider_said: provider_frame(v),
      report: v.report,
      created_at: iso(v.created_at),
      ended_at: iso(v.ended_at)
    }
  end

  # --- helpers ---------------------------------------------------------------------

  defp span(seconds) when seconds < 60, do: count(seconds, "second")

  defp span(seconds),
    do: "#{count(div(seconds, 60), "minute")} #{count(rem(seconds, 60), "second")}"

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_absent), do: nil
end
