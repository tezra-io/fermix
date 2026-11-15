defmodule FermixCore.Computers.OriginTest do
  # M97 §6.1: what kind of turn asked a computer, from the facts every other
  # gate reads.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Origin

  @owner %{source_trust: :operator, session_id: "main-14"}

  test "each kind of turn has its origin" do
    cases = [
      {%{computer_use_origin: :interactive}, :chat},
      {%{computer_use_origin: :voice}, :voice},
      {%{computer_use_origin: :unattended}, :background},
      {%{trigger: "schedule"}, :scheduled},
      {%{trigger: "manual"}, :scheduled},
      {%{trigger: "watcher"}, :scheduled},
      {%{trigger: "cue"}, :cue},
      {%{computer_use_origin: :interactive, subagent_depth: 1}, :worker},
      {%{computer_use_origin: :voice, skill_depth: 2}, :worker},
      {%{trigger: "cue", subagent_depth: 1}, :worker},
      {%{computer_use_origin: :interactive, harness_continuation_depth: 1}, :background},
      {%{computer_use_origin: :interactive, subagent_depth: 0, skill_depth: 0}, :chat}
    ]

    for {facts, origin} <- cases do
      assert Origin.of(Map.merge(@owner, facts)) == origin, inspect(facts)
    end
  end

  test "absence is never read as authority" do
    assert Origin.of(%{}) == :background
    assert Origin.of(%{computer_use_origin: :somewhere}) == :background
    assert Origin.of(%{computer_use_origin: :interactive, subagent_depth: nil}) == :worker
  end

  test "the wire carries a turn's origins and a computer's own request" do
    assert Origin.wire_origins() == [
             :chat,
             :voice,
             :scheduled,
             :cue,
             :worker,
             :background,
             :computer
           ]

    assert Origin.from_wire("computer") == {:ok, :computer}
    assert Origin.from_wire("attended") == :error

    assert Enum.all?(Origin.origins(), &Origin.turn?/1)
    refute Origin.turn?(:computer)
    assert Enum.filter(Origin.wire_origins(), &Origin.attended?/1) == [:chat, :voice]
  end
end
