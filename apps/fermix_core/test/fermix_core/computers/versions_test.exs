defmodule FermixCore.Computers.VersionsTest do
  # M97 §3.4 and §17: a computer is served up to two minor versions behind its
  # server, counted by major.minor, so patch releases never close the window.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Versions

  @server "4.12.3"

  describe "standing/2" do
    test "the server's major.minor is current, whatever the patch" do
      for computer <- ["4.12.3", "4.12.0", "4.12.9", "4.12.40"] do
        assert Versions.standing(computer, @server) == :current, computer
      end
    end

    test "one or two minor versions behind is behind, and served" do
      for computer <- ["4.11.0", "4.11.7", "4.10.0", "4.10.99"] do
        assert Versions.standing(computer, @server) == :behind, computer
        assert Versions.served?(:behind)
      end
    end

    test "three minor versions behind keeps settings alone" do
      for computer <- ["4.9.9", "4.0.0", "4.9.0"] do
        assert Versions.standing(computer, @server) == :settings_only, computer
      end

      refute Versions.served?(:settings_only)
    end

    test "an older major keeps settings alone, however close its minor" do
      assert Versions.standing("3.12.3", @server) == :settings_only
      assert Versions.standing("3.99.0", "4.0.1") == :settings_only
    end

    test "a newer computer is ahead, by minor or by major" do
      for computer <- ["4.13.0", "4.20.1", "5.0.0"] do
        assert Versions.standing(computer, @server) == :ahead, computer
      end
    end

    test "minors compare as numbers, not text" do
      assert Versions.standing("0.10.0", "0.9.4") == :ahead
      assert Versions.standing("0.9.4", "0.10.0") == :behind
      assert Versions.standing("0.8.0", "0.10.0") == :behind
      assert Versions.standing("0.7.9", "0.10.0") == :settings_only
    end

    test "a computer's version that is not one keeps settings alone" do
      for computer <- ["latest", "4.12", "", "v4.12.3"] do
        assert Versions.standing(computer, @server) == :settings_only, computer
      end
    end

    test "a prerelease counts by its major.minor" do
      assert Versions.standing("4.12.0-rc.1", @server) == :current
      assert Versions.standing("4.11.0-dev", @server) == :behind
    end

    test "the server's own version must be one" do
      assert_raise ArgumentError, ~r/not a version/, fn -> Versions.standing("4.12.3", "x") end
    end
  end

  test "the window is two minor versions" do
    assert Versions.window_minors() == 2
    assert Versions.standings() == [:current, :behind, :ahead, :settings_only]
  end
end
