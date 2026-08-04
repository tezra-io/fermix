defmodule FermixCore.Temporal.AccessTest do
  use ExUnit.Case, async: true

  alias FermixCore.Temporal.Access

  # MILESTONE_30 §12.1: the ONE shared predicate behind both the advertise?/1
  # callback and execute/2. Every axis is asserted here so the two gates can
  # never disagree about what "attended top-level operator turn" means.

  defp attended(overrides \\ %{}) do
    Map.merge(%{source_trust: :operator, computer_use_origin: :interactive}, overrides)
  end

  describe "operator_read_turn?/1 (§12.1 read carve-out)" do
    test "every attended operator turn passes" do
      assert Access.operator_read_turn?(attended())
      assert Access.operator_read_turn?(attended(%{computer_use_origin: :voice}))
    end

    test "an operator-created scheduled run passes: operator trust, no origin marker" do
      assert Access.operator_read_turn?(%{source_trust: :operator})
    end

    test "an explicit nil origin is not a scheduled run" do
      refute Access.operator_read_turn?(%{source_trust: :operator, computer_use_origin: nil})
    end

    test "a guest-created scheduled run is refused" do
      refute Access.operator_read_turn?(%{source_trust: :guest})
    end

    test "a detached background run is refused" do
      refute Access.operator_read_turn?(%{
               source_trust: :operator,
               computer_use_origin: :unattended
             })
    end

    test "a delegated worker inside a scheduled run is refused" do
      refute Access.operator_read_turn?(%{source_trust: :operator, subagent_depth: 1})
    end

    test "a coding continuation inside a scheduled run is refused" do
      refute Access.operator_read_turn?(%{
               source_trust: :operator,
               harness_continuation_depth: 1
             })
    end
  end

  describe "attended_operator_turn?/1" do
    test "an attended top-level operator turn passes" do
      assert Access.attended_operator_turn?(attended())
    end

    test "a live voice call passes" do
      assert Access.attended_operator_turn?(attended(%{computer_use_origin: :voice}))
    end

    test "explicit zero depths pass" do
      assert Access.attended_operator_turn?(
               attended(%{subagent_depth: 0, harness_continuation_depth: 0})
             )
    end

    test "guest trust is refused" do
      refute Access.attended_operator_turn?(attended(%{source_trust: :guest}))
    end

    test "a missing source_trust fails closed" do
      refute Access.attended_operator_turn?(%{computer_use_origin: :interactive})
    end

    test "a missing computer_use_origin fails closed (scheduled runs omit it)" do
      refute Access.attended_operator_turn?(%{source_trust: :operator})
    end

    test "a detached background run is refused" do
      refute Access.attended_operator_turn?(attended(%{computer_use_origin: :unattended}))
    end

    test "a delegated subagent worker is refused" do
      refute Access.attended_operator_turn?(attended(%{subagent_depth: 1}))
    end

    test "a synthesized coding continuation is refused" do
      refute Access.attended_operator_turn?(attended(%{harness_continuation_depth: 1}))
    end

    test "a malformed depth fails closed rather than widening the gate" do
      refute Access.attended_operator_turn?(attended(%{subagent_depth: "0"}))
      refute Access.attended_operator_turn?(attended(%{harness_continuation_depth: -1}))
    end

    test "an empty context fails closed" do
      refute Access.attended_operator_turn?(%{})
    end
  end

  describe "refusal/1" do
    test "names the refused tool and does not read like success" do
      message = Access.refusal("event_store")

      assert message =~ "event_store"
      assert message =~ "attended"
    end
  end
end
