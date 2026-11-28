defmodule FermixCore.PhoneCalls.Call.EndReportTest do
  # Pure: the one end report from what a call proved. Every word here is
  # invented.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Call.EndReport

  @said [%{speaker: "recipient", text: "Thanks, that's all I needed."}]

  defp facts(overrides) do
    Map.merge(
      %{
        dispatch: :created,
        finalized?: true,
        closed_seconds: 42,
        usage_seconds: 42,
        call_failed?: false,
        failure_reason: nil,
        vendor_message: nil,
        outcome: nil,
        finish: nil,
        backend_usage: nil
      },
      overrides
    )
  end

  defp read(word, evidence \\ @said),
    do: %{outcome: word, outcome_facts: nil, evidence: evidence, uncertainty: nil}

  describe "a finished call" do
    test "stays finished on an ended call, evidence or none" do
      for evidence <- [@said, []] do
        report = EndReport.build(facts(%{outcome: read("finished", evidence)}))
        assert {report.status, report.outcome} == {"ended", "finished"}, inspect(evidence)
      end
    end

    # The ledger refuses `finished` anywhere else, which would lose the report.
    test "is reported unknown on any other status, so the ledger never refuses the report" do
      failed = EndReport.build(facts(%{call_failed?: true, outcome: read("finished")}))
      assert {failed.status, failed.outcome} == {"failed", "unknown"}

      lost = EndReport.build(facts(%{dispatch: :unknown, outcome: read("finished")}))
      assert {lost.status, lost.outcome} == {"dispatch_unknown", "unknown"}

      # A call whose end the provider never confirmed has not been shown to
      # finish.
      unconfirmed = EndReport.build(facts(%{finalized?: false, outcome: read("finished")}))
      assert {unconfirmed.status, unconfirmed.outcome} == {"closure_unconfirmed", "unknown"}
    end

    test "gives way to a backend turn that ended the call as needing the owner" do
      finish = %{reason: :needs_owner, note: "They need a card before they hold the time."}
      report = EndReport.build(facts(%{outcome: read("finished"), finish: finish}))

      assert report.outcome == "needs_owner"
      assert report.outcome_facts == %{"note" => finish.note}
    end

    test "keeps the note a backend turn ended it with" do
      finish = %{reason: :done, note: "The message was passed on."}
      report = EndReport.build(facts(%{outcome: read("finished"), finish: finish}))

      assert report.outcome == "finished"
      assert report.outcome_facts == %{"note" => finish.note}
    end
  end

  test "a confirmed result keeps its own admission: evidence, on an ended or unconfirmed call" do
    assert EndReport.build(facts(%{outcome: read("confirmed")})).outcome == "confirmed"
    assert EndReport.build(facts(%{outcome: read("confirmed", [])})).outcome == "unknown"

    failed = EndReport.build(facts(%{call_failed?: true, outcome: read("confirmed")}))
    assert failed.outcome == "unknown"
  end
end
