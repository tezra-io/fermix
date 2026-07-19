defmodule FermixCore.ComputerUse.CourtesyTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Courtesy

  describe "disturbing?/1" do
    test "cursor-moving and typing actions disturb the human" do
      for action <-
            ~w(left_click right_click double_click mouse_move left_click_drag scroll type key paste) do
        assert Courtesy.disturbing?(action), "expected #{action} to be disturbing"
      end
    end

    test "read-only / observation actions do not disturb" do
      for action <- ~w(screenshot wait inspect wait_for_change elements) do
        refute Courtesy.disturbing?(action), "expected #{action} to be non-disturbing"
      end
    end

    test "mouse_move disturbs even though it mutates no app state (it warps the cursor)" do
      assert Courtesy.disturbing?("mouse_move")
      # contrast: the protocol treats mouse_move as read-only (no post-shot)
      assert Compux.Protocol.read_only?("mouse_move")
    end
  end

  describe "human_active?/3" do
    test "active when recent input exists and the agent has not acted yet (first action)" do
      assert Courtesy.human_active?(200, :never, 1_000)
    end

    test "not active when the human has been quiet past the threshold" do
      refute Courtesy.human_active?(5_000, :never, 1_000)
    end

    test "not active when the agent itself acted recently (its own event can't be mistaken for the human)" do
      # idle=100ms but the agent acted 100ms ago → the recent event is the agent's own
      refute Courtesy.human_active?(100, 100, 1_000)
    end

    test "active when the agent has been quiet long enough AND input is recent" do
      # agent last acted 5s ago (quiet past threshold), input seen 200ms ago → human
      assert Courtesy.human_active?(200, 5_000, 1_000)
    end

    test "not active at the idle boundary (idle == threshold is idle enough)" do
      refute Courtesy.human_active?(1_000, :never, 1_000)
    end
  end

  test "defer_ms is a positive bound" do
    assert is_integer(Courtesy.defer_ms()) and Courtesy.defer_ms() > 0
  end
end
