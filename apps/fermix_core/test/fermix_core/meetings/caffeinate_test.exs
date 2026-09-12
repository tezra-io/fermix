defmodule FermixCore.Meetings.CaffeinateTest do
  # The darwin branch is proven through `caffeinate_args/1`, never by spawning:
  # a test that starts the real binary would hold the machine awake for as long
  # as it took CI to notice.
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Caffeinate

  describe "start/2" do
    test "is inactive where there is nothing to keep awake" do
      assert Caffeinate.start({:bounded, 60}, os_type: {:unix, :linux}) == :inactive
      assert Caffeinate.start({:watch_pid, 42}, os_type: {:unix, :linux}) == :inactive
      assert Caffeinate.start({:bounded, 60}, os_type: {:win32, :nt}) == :inactive
    end

    test "refuses a mode that names no process and no bound" do
      assert_raise FunctionClauseError, fn ->
        Caffeinate.start({:watch_pid, 0}, os_type: {:unix, :linux})
      end

      assert_raise FunctionClauseError, fn ->
        Caffeinate.start({:bounded, 0}, os_type: {:unix, :linux})
      end
    end
  end

  describe "caffeinate_args/1" do
    test "watch-pid mode ties the guard's life to the sidecar's" do
      assert Caffeinate.caffeinate_args({:watch_pid, 42}) == ["-dims", "-w", "42"]
    end

    test "bounded mode self-bounds in whole seconds" do
      assert Caffeinate.caffeinate_args({:bounded, 14_700}) == ["-dims", "-t", "14700"]
    end
  end

  test "stop/1 is a no-op for a guard that never started" do
    assert Caffeinate.stop(nil) == :ok
  end
end
