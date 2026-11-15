defmodule FermixChannels.Home.MoveWorkerCopyTest do
  # What the move worker records for a move's screens reaches the undone
  # screen's note as it is, so it is under the copy gate: plain words, none
  # of the engine's own, no code (M75 lean v1 §7, the Always On pane R1).
  use ExUnit.Case, async: true

  alias FermixChannels.Home.MoveWorker
  alias FermixCore.Management.Copy

  @plain "studio-mac turned the move down, so nothing moved. Fermix's log says why."

  test "every sentence the move worker records obeys the copy and summary rules" do
    sentences = MoveWorker.sentences("studio-mac")
    assert length(sentences) >= 7

    for sentence <- sentences do
      assert Copy.violations(sentence, :prose, ["studio-mac"]) == [], sentence
      assert Copy.summary_violations(sentence) == [], sentence
    end
  end

  test "a server's refusal keeps its own words only where an owner reads them" do
    disk =
      "This Mac needs about 9 GiB free to take Fermix back and has 2 GiB: make room on its " <>
        "disk, then move back again."

    assert Copy.move_refused("studio-mac", disk) ==
             "studio-mac turned the move down, so nothing moved. " <> disk

    for said <- [
          "the candidate's key changed; enroll it again",
          "The stream could not be written ({:error, :enospc}).",
          "move_chunk does not belong to the move under way.",
          "   "
        ] do
      assert Copy.move_refused("studio-mac", said) == @plain, said
    end
  end
end
