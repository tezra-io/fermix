defmodule FermixChannels.Companion.ProposalsTest do
  @moduledoc """
  `Companion.Proposals` alone (M60 app surface §3.7): only the owner's
  connection may answer, whatever else it was placed as, and a card is never
  cut to fit the wire: one over the cap is refused there.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Proposals
  alias FermixCore.Companion.Protocol
  alias FermixCore.Cues.ProposalView

  @answer %{"proposal_id" => "cpr_1", "decision" => "confirm"}

  test "an answer from a connection not placed as the owner's is refused, nil included" do
    for caller <- [nil, :daemon_descendant, :detached] do
      assert Proposals.answer(@answer, caller, []) == {:error, Proposals.not_owner_sentence()},
             "#{inspect(caller)} was not refused"
    end
  end

  test "a card whose arguments are over the cap is not cut, and the wire refuses it" do
    long = %{"title" => String.duplicate("x", ProposalView.max_args_chars())}
    card = ProposalView.card(row(Jason.encode!(long)))

    assert card.outside.args_text == Jason.encode!(long, pretty: true)
    assert String.length(card.outside.args_text) > ProposalView.max_args_chars()

    event = Proposals.offered(card)

    assert {:error, {:invalid_field, "proposal"}} =
             Protocol.encode_server_event("proposal", Map.delete(event, "t"))

    short = ProposalView.card(row(~s({"title":"Phoenix 2.0"})))

    assert {:ok, _line} =
             Protocol.encode_server_event("proposal", Map.delete(Proposals.offered(short), "t"))
  end

  defp row(args_json) do
    %{
      id: "cpr_1",
      state: "waiting",
      mandate: "release-issues",
      tool: "github_create_issue",
      job_id: "release_issues",
      job_name: "release issues",
      watcher: "release-watch",
      source_ref: "eng-blogs",
      created_at: ~U[2026-10-10 12:00:00Z],
      expires_at: ~U[2026-10-10 12:30:00Z],
      decided_at: nil,
      decided_from: nil,
      result_status: nil,
      args_json: args_json,
      received_at: ~U[2026-10-10 11:59:00Z],
      occurred_at: nil,
      snapshot: nil
    }
  end
end
