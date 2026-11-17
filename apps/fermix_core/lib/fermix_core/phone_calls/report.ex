defmodule FermixCore.PhoneCalls.Report do
  @moduledoc """
  What a finished call says to the owner (M94 §10, §11): one pure,
  golden-tested composition of a terminal ledger row, read by every path that
  reports a call (the inline send, the `DeliveryWorker`'s retries and the
  chat continuation notice), and the JSON-safe view `phone_call(status)`
  returns.

  The report states the outcome word honestly and what it means, labels every
  uncertainty (whether the call was placed, whether it was hung up, whether
  final usage arrived), keeps the three costs apart (voice time, carrier
  charges, backend work), each `unknown` when it is, and carries the vendor's
  own failure words. Anything the called party said or that was taken from
  what they said (the outcome facts and the evidence excerpts) is rendered
  inside the untrusted-content frame (`Capabilities.UntrustedContent`): the
  recipient supplies facts, not authority.
  """

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.PhoneCalls.Ledger

  @recipient_source "phone_call_recipient"

  @outcome_meaning %{
    "confirmed" => "the recipient confirmed what the brief asked for.",
    "unavailable" => "the recipient said it is not available.",
    "options" => "the recipient offered alternatives; nothing was agreed.",
    "needs_owner" =>
      "the call needs a fact or a decision from you. Calling again is a new request.",
    "unknown" => "Fermix could not establish what was agreed, if anything.",
    "pending" => "the call has not finished."
  }

  @doc "The report text for a terminal `row`. Pure."
  @spec compose(map()) :: String.t()
  def compose(%{id: id, status: status} = row) when is_binary(id) and is_binary(status) do
    [
      header(row),
      to_line(row),
      outcome_line(row),
      uncertainty(row),
      recipient_frame(row),
      voice_line(row),
      "Carrier charges: unknown — Telnyx bills the call's minutes to your own account.",
      backend_line(row),
      failure_line(row),
      vendor_line(row),
      cleanup_line(row)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc """
  The JSON-safe status of `row` at `now`, for its owner: its state (`stopping`
  while a stop was asked and the call is not yet over), whether anything was
  dialed, its outcome and uncertainty, whether it still holds the one-call
  slot, its usage labelled by kind, its report state and the vendor's words.
  Anything taken from what the called party said is framed.
  """
  @spec status_view(map(), DateTime.t()) :: map()
  def status_view(%{id: id, status: status} = row, %DateTime{} = now)
      when is_binary(id) and is_binary(status) do
    %{
      call_id: id,
      state: view_state(row),
      dialed: dialed?(row),
      contact_name: mandate_field(row, "contact_name"),
      destination_kind: mandate_field(row, "destination_kind"),
      outcome: Map.get(row, :outcome),
      outcome_meaning: Map.get(@outcome_meaning, Map.get(row, :outcome)),
      uncertainty: uncertainty(row),
      holds_call_slot: Ledger.holds_slot?(row, now),
      recipient_said: recipient_frame(row),
      usage: %{
        voice: voice_line(row),
        carrier_charges: "unknown",
        backend: backend_line(row)
      },
      failure_reason: Map.get(row, :failure_reason),
      vendor_message: Map.get(row, :vendor_message),
      report: Map.get(row, :report_status),
      last_delivery_error: Map.get(row, :last_delivery_error),
      created_at: iso(Map.get(row, :created_at)),
      ended_at: iso(Map.get(row, :ended_at))
    }
  end

  # --- lines -------------------------------------------------------------------

  defp header(%{id: id} = row), do: "[phone call #{id}] #{headline(row)}"

  defp headline(%{status: "ended"}), do: "ended"
  defp headline(%{status: "dispatch_unknown"}), do: "may or may not have been placed"
  defp headline(%{status: "closure_unconfirmed"}), do: "ended here; hang-up not confirmed"

  defp headline(%{status: "failed"} = row) do
    if dialed?(row), do: "failed", else: "stopped before dialing — nothing was dialed"
  end

  defp headline(%{status: status} = row) do
    if Map.get(row, :cancel_requested_at), do: "stopping", else: "#{status} (in progress)"
  end

  defp to_line(row) do
    case {mandate_field(row, "contact_name"), mandate_field(row, "destination")} do
      {nil, nil} -> ""
      {name, nil} -> "To: #{name}#{kind_suffix(row)}"
      {nil, number} -> "To: #{number}#{kind_suffix(row)}"
      {name, number} -> "To: #{name}#{kind_suffix(row)}, #{number}"
    end
  end

  defp kind_suffix(row) do
    case mandate_field(row, "destination_kind") do
      "owner" -> " (your own phone)"
      "business" -> " (a business)"
      _other -> ""
    end
  end

  defp outcome_line(row) do
    outcome = Map.get(row, :outcome) || "unknown"
    "Outcome: #{outcome} — #{Map.get(@outcome_meaning, outcome, "unknown.")}"
  end

  defp uncertainty(%{status: "dispatch_unknown"} = row) do
    "Whether the call was placed is unknown: the provider's answer to the dial was " <>
      "lost. Fermix never dials it again, and holds the one-call slot " <>
      "#{until(row)} or until the call is shown to have ended."
  end

  defp uncertainty(%{status: "closure_unconfirmed"} = row) do
    "Fermix asked the provider to end the call but could not confirm it ended. The " <>
      "provider ends any call by itself within its own limit (#{until(row)}); Fermix " <>
      "holds the one-call slot until then or until the call is shown to have ended."
  end

  defp uncertainty(_row), do: nil

  defp until(row) do
    case Map.get(row, :slot_expires_at) do
      %DateTime{} = at -> "until #{DateTime.to_iso8601(at)}"
      _unknown -> "until the provider's limit has passed"
    end
  end

  # What the recipient said, and what was taken from it, framed: their words
  # are data the owner reads, never instructions anyone follows.
  defp recipient_frame(row) do
    lines = fact_lines(Map.get(row, :outcome_facts)) ++ excerpt_lines(Map.get(row, :evidence))

    case lines do
      [] -> nil
      lines -> UntrustedContent.frame(@recipient_source, Enum.join(lines, "\n"))
    end
  end

  defp fact_lines(facts) when is_map(facts) and map_size(facts) > 0 do
    [
      "What the call established:"
      | Enum.map(Enum.sort(facts), fn {k, v} -> "- #{k}: #{value(v)}" end)
    ]
  end

  defp fact_lines(_facts), do: []

  defp excerpt_lines([_ | _] = excerpts) do
    ["What was said:" | Enum.map(excerpts, &"- #{&1["speaker"]}: \"#{&1["text"]}\"")]
  end

  defp excerpt_lines(_excerpts), do: []

  defp voice_line(row) do
    seconds = Map.get(row, :voice_seconds)

    cond do
      not dialed?(row) ->
        "Voice time: none — nothing was dialed."

      row.usage_state == "voice_duration_confirmed" ->
        "Voice time: #{duration(seconds)} (confirmed by the provider)."

      is_integer(seconds) ->
        "Voice time: at least #{duration(seconds)} (#{usage_word(row)})."

      true ->
        "Voice time: unknown (#{usage_word(row)})."
    end
  end

  defp usage_word(%{usage_state: "provisional"}), do: "provisional"
  defp usage_word(_incomplete), do: "the final figure never arrived"

  defp backend_line(row) do
    turns = Map.get(row, :core_turns) || 0
    cost = backend_cost(Map.get(row, :backend_usage))
    "Backend work: #{turns} reasoning #{plural(turns, "turn")}; cost #{cost}."
  end

  defp backend_cost(%{"cost_usd" => cost}) when is_number(cost),
    do: "about $#{:erlang.float_to_binary(cost / 1, decimals: 4)}"

  defp backend_cost(_usage), do: "unknown"

  defp failure_line(row) do
    case Map.get(row, :failure_reason) do
      reason when is_binary(reason) and reason != "" -> "Why it stopped: #{reason}"
      _none -> nil
    end
  end

  defp vendor_line(row) do
    case Map.get(row, :vendor_message) do
      text when is_binary(text) and text != "" -> "The provider said: #{one_line(text)}"
      _none -> nil
    end
  end

  defp cleanup_line(row) do
    case Map.get(row, :cleanup_error) do
      text when is_binary(text) and text != "" -> "The hang-up request failed: #{one_line(text)}"
      _none -> nil
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp view_state(%{status: status} = row) do
    if not Ledger.terminal?(status) and Map.get(row, :cancel_requested_at),
      do: "stopping",
      else: status
  end

  defp dialed?(row), do: not is_nil(Map.get(row, :dispatch_claimed_at))

  defp mandate_field(row, key) do
    case Map.get(row, :mandate) do
      %{^key => value} when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp duration(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"
  defp duration(seconds) when is_integer(seconds), do: "#{div(seconds, 60)}m#{rem(seconds, 60)}s"

  defp value(v) when is_binary(v), do: one_line(v)
  defp value(v), do: Jason.encode!(v)

  defp one_line(text), do: String.replace(text, ~r/\s*[\r\n]+\s*/, " ")

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_absent), do: nil
end
