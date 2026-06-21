defmodule FermixCore.ComputerUse.SafetyTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Safety

  describe "gate/2" do
    test "read-only actions always auto-run" do
      config = Config.normalize([])

      for action <- ~w(screenshot mouse_move wait),
          do: assert(Safety.gate(action, config) == :auto)
    end

    test "consequential actions are confirmed by default (clicks gated)" do
      config = Config.normalize(confirm_consequential: true)

      for action <- ~w(left_click right_click double_click left_click_drag scroll type key) do
        assert Safety.gate(action, config) == :confirm
      end
    end

    test "an operator who explicitly disables confirmation auto-runs consequential actions" do
      config = Config.normalize(confirm_consequential: false)
      assert Safety.gate("left_click", config) == :auto
      # read-only is still auto regardless
      assert Safety.gate("screenshot", config) == :auto
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
      refute Safety.host_start_allowed?(:unknown)
    end
  end

  describe "frontmost_app_allowed?/2 — host (bypassable, fail-closed)" do
    test "empty allowlist permits nothing" do
      refute Safety.frontmost_app_allowed?("Safari", Config.normalize([]))
    end

    test "allows only listed apps" do
      config = Config.normalize(allowed_apps: ["Safari", "Finder"])
      assert Safety.frontmost_app_allowed?("Safari", config)
      refute Safety.frontmost_app_allowed?("Terminal", config)
    end
  end

  describe "domain_allowed?/2 — browser mode (fail-closed)" do
    test "empty allowlist permits nothing" do
      refute Safety.domain_allowed?("example.com", Config.normalize([]))
    end

    test "allows only listed hosts" do
      config = Config.normalize(allowed_domains: ["example.com"])
      assert Safety.domain_allowed?("example.com", config)
      refute Safety.domain_allowed?("evil.com", config)
    end
  end
end
