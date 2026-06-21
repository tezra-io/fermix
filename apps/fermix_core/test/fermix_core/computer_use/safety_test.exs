defmodule FermixCore.ComputerUse.SafetyTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Safety

  @mutating ~w(left_click right_click double_click left_click_drag scroll type key)

  # `access` is derived from the sandbox mode at Config.current/0; for pure gate unit
  # tests we set the effective posture directly on the struct.
  defp at_access(access), do: %{Config.normalize([]) | access: access}

  describe "gate/2 — by access posture" do
    test "read-only actions always auto-run, in every access mode" do
      for access <- [:strict, :standard, :open],
          action <- ~w(screenshot mouse_move wait) do
        assert Safety.gate(action, at_access(access)) == :auto
      end
    end

    test "strict refuses every mutating action (the one deterministic floor)" do
      config = at_access(:strict)
      for action <- @mutating, do: assert(Safety.gate(action, config) == :refuse)
    end

    test "standard auto-runs mutating actions (confirm-destructive is prompt-driven, not a gate)" do
      config = at_access(:standard)
      for action <- @mutating, do: assert(Safety.gate(action, config) == :auto)
    end

    test "open auto-runs mutating actions (the truly-dangerous confirm is prompt-driven too)" do
      config = at_access(:open)
      for action <- @mutating, do: assert(Safety.gate(action, config) == :auto)
    end

    test "the struct default access is standard — mutating actions run" do
      assert Safety.gate("left_click", Config.normalize([])) == :auto
    end
  end

  describe "within_action_budget?/2" do
    test "true below the cap, false at/over it" do
      config = Config.normalize(max_actions: 3)
      assert Safety.within_action_budget?(0, config)
      assert Safety.within_action_budget?(2, config)
      refute Safety.within_action_budget?(3, config)
      refute Safety.within_action_budget?(4, config)
    end
  end

  describe "host_start_allowed?/1 — attended-origin gate" do
    test "interactive chat and voice pet may start a host session" do
      assert Safety.host_start_allowed?(:interactive)
      assert Safety.host_start_allowed?(:voice)
    end

    test "unattended origins fail closed" do
      refute Safety.host_start_allowed?(:scheduled)
      refute Safety.host_start_allowed?(:cron)
      refute Safety.host_start_allowed?(:unattended)
    end
  end
end
