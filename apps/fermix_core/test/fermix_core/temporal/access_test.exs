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
      refute Access.operator_read_turn?(%{source_trust: :operator, skill_depth: 1})
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

    # `Capabilities.Skill.invoke` keeps the parent turn's trust and origin and
    # raises only `skill_depth`, so the depth is all that tells its worker apart.
    test "a skill worker of an attended owner turn is refused" do
      refute Access.attended_operator_turn?(attended(%{skill_depth: 1}))
      assert Access.attended_operator_turn?(attended(%{skill_depth: 0}))
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

  # The one definition of a delegated worker, shared with
  # `Harness.Authorization` and `Capabilities.AccessGate`.
  describe "worker?/1" do
    test "a subagents or skill worker at any depth is one; a top-level turn is not" do
      assert Access.worker?(%{subagent_depth: 1})
      assert Access.worker?(%{skill_depth: 2})
      assert Access.worker?(attended(%{skill_depth: 1}))
      refute Access.worker?(attended())
      refute Access.worker?(attended(%{subagent_depth: 0, skill_depth: 0}))
    end

    test "a malformed depth counts as a worker" do
      assert Access.worker?(%{subagent_depth: "0"})
      assert Access.worker?(%{skill_depth: -1})
    end

    # Only an absent depth or a zero is a top-level turn; a key someone set to
    # nil is not proof of one.
    test "an explicit nil depth counts as a worker" do
      assert Access.worker?(%{subagent_depth: nil})
      assert Access.worker?(%{skill_depth: nil})
      refute Access.attended_operator_turn?(attended(%{skill_depth: nil}))
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
