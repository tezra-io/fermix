defmodule FermixCore.PhoneCalls.Call.EndReport do
  @moduledoc """
  The one end report a phone call's worker sends `PhoneCalls.Manager`
  (`Manager.report_end/3`), composed from what the call proved. Pure.

  The status says what is known about the remote call, never more (M94 §09):

    * nothing was sent (`dispatch: :none`), or the create was refused or
      provably not sent (`:rejected`, `:not_sent`) → `failed`, with no voice
      time, confirmed: nothing was placed;
    * the create's answer was lost (`:unknown`) → `dispatch_unknown`, usage
      incomplete, outcome `unknown`;
    * a session existed (`:created`) and `session.closed` arrived → `ended`,
      or `failed` when the carrier reported the call failed; its final usage
      is confirmed only when `session.closed` carried it;
    * a session existed and `session.closed` never arrived →
      `closure_unconfirmed`, usage incomplete, whatever the transport said.

  The outcome is the extraction's (`Outcome.to_report/1`'s shape), or
  `unknown` when none ran. A call its backend turn ended as needing the owner
  reports `needs_owner` with whatever options the extraction heard, and the
  turn's note rides in `outcome_facts` as `"note"`, after which the report is
  fitted to the ledger's bounds again (`Outcome.fit_report/1`, the contract
  for anything added after `Outcome.to_report/1`). `confirmed` is kept only
  where the ledger admits it (an `ended` or `closure_unconfirmed` call with
  evidence), so a report is never refused for it and lost.
  """

  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Outcome

  @type dispatch :: :none | :rejected | :not_sent | :unknown | :created
  @type facts :: %{
          required(:dispatch) => dispatch(),
          required(:finalized?) => boolean(),
          required(:closed_seconds) => number() | nil,
          required(:usage_seconds) => number() | nil,
          required(:call_failed?) => boolean(),
          required(:failure_reason) => String.t() | nil,
          required(:vendor_message) => String.t() | nil,
          required(:outcome) => map() | nil,
          required(:finish) => %{reason: atom(), note: String.t() | nil} | nil,
          required(:backend_usage) => map() | nil
        }

  @doc "The end report for `facts` (see the module doc)."
  @spec build(facts()) :: map()
  def build(%{dispatch: dispatch} = facts)
      when dispatch in [:none, :rejected, :not_sent, :unknown, :created] do
    status = status(facts)

    facts
    |> usage(status)
    |> Map.merge(outcome(facts, status))
    |> Map.merge(%{
      status: status,
      backend_usage: facts.backend_usage,
      failure_reason: facts.failure_reason,
      vendor_message: facts.vendor_message
    })
  end

  defp status(%{dispatch: dispatch}) when dispatch in [:none, :rejected, :not_sent], do: "failed"
  defp status(%{dispatch: :unknown}), do: "dispatch_unknown"
  defp status(%{finalized?: false}), do: "closure_unconfirmed"
  defp status(%{call_failed?: true}), do: "failed"
  defp status(_created_and_closed), do: "ended"

  defp usage(%{dispatch: dispatch}, _status) when dispatch in [:none, :rejected, :not_sent],
    do: %{usage: nil, voice_seconds: 0, usage_state: "voice_duration_confirmed"}

  defp usage(%{dispatch: :unknown}, _status),
    do: %{usage: nil, voice_seconds: nil, usage_state: "incomplete"}

  # Voice time in the ledger's one rule (`Ledger.whole_voice_seconds/1`), so a
  # reported call and its settled row never differ; a negative time, which
  # the ledger refuses, confirms nothing.
  defp usage(%{finalized?: true, closed_seconds: seconds}, _status)
       when is_number(seconds) and seconds >= 0,
       do: %{
         usage: %{"seconds" => seconds, "final" => true},
         voice_seconds: Ledger.whole_voice_seconds(seconds),
         usage_state: "voice_duration_confirmed"
       }

  defp usage(%{usage_seconds: seconds}, _status) when is_number(seconds) and seconds >= 0,
    do: %{
      usage: %{"seconds" => seconds, "final" => false},
      voice_seconds: Ledger.whole_voice_seconds(seconds),
      usage_state: "incomplete"
    }

  defp usage(_facts, _status), do: %{usage: nil, voice_seconds: nil, usage_state: "incomplete"}

  defp outcome(%{dispatch: :created, outcome: %{} = extracted} = facts, status) do
    %{
      outcome: extracted.outcome,
      outcome_facts: extracted.outcome_facts,
      evidence: extracted.evidence,
      uncertainty: extracted.uncertainty
    }
    |> finished(facts.finish)
    |> Outcome.fit_report()
    |> admitted(status)
  end

  defp outcome(facts, _status) do
    %{outcome: "unknown", outcome_facts: nil, evidence: [], uncertainty: nil}
    |> finished(facts.finish)
  end

  defp finished(report, %{reason: :needs_owner, note: note}),
    do: report |> Map.put(:outcome, "needs_owner") |> put_note(note)

  defp finished(report, %{note: note}), do: put_note(report, note)
  defp finished(report, nil), do: report

  defp put_note(report, nil), do: report

  defp put_note(report, note) when is_binary(note),
    do: Map.put(report, :outcome_facts, Map.put(report.outcome_facts || %{}, "note", note))

  # The ledger admits `confirmed` only with evidence, on a call that ended or
  # whose closure is unconfirmed; anything else would refuse the whole report.
  defp admitted(%{outcome: "confirmed", evidence: [_ | _]} = report, status)
       when status in ["ended", "closure_unconfirmed"],
       do: report

  defp admitted(%{outcome: "confirmed"} = report, _status), do: %{report | outcome: "unknown"}
  defp admitted(report, _status), do: report
end
