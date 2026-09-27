defmodule FermixCore.Browser.TurnMarkerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Error
  alias FermixCore.Browser.TurnMarker

  # `TurnMarker` is read by name (an atom), never by pid: `lookup/3` finds its
  # table with `:ets.whereis/1`, which only resolves a named table. Each test
  # gets its own name so the ETS tables never collide.
  defp start_marker do
    name = Module.concat(__MODULE__, "Marker#{System.unique_integer([:positive])}")
    start_supervised!({TurnMarker, name: name}, id: make_ref())
    name
  end

  defp turn(fun \\ fn -> Process.sleep(:infinity) end) do
    pid = spawn(fun)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "an unmarked owner and turn find nothing" do
    marker = start_marker()
    refute TurnMarker.lookup(marker, "owner-a", turn())
  end

  test "a mark is read back for the same owner and turn, never for another" do
    marker = start_marker()
    error = Error.new("host_lost", "the app quit")
    turn_a = turn()
    turn_b = turn()

    :ok = TurnMarker.mark(marker, "owner-a", turn_a, error)

    assert TurnMarker.lookup(marker, "owner-a", turn_a) == error
    refute TurnMarker.lookup(marker, "owner-b", turn_a)
    refute TurnMarker.lookup(marker, "owner-a", turn_b)
  end

  test "the turn's exit clears every mark it holds, whatever the owner" do
    marker = start_marker()
    error = Error.new("host_lost", "the app quit")
    turn_pid = turn()

    :ok = TurnMarker.mark(marker, "owner-a", turn_pid, error)
    :ok = TurnMarker.mark(marker, "owner-b", turn_pid, error)

    Process.exit(turn_pid, :kill)

    assert eventually(fn ->
             is_nil(TurnMarker.lookup(marker, "owner-a", turn_pid)) and
               is_nil(TurnMarker.lookup(marker, "owner-b", turn_pid))
           end)
  end

  test "a later mark for the same owner and turn replaces the earlier one" do
    marker = start_marker()
    turn_pid = turn()
    first = Error.new("host_lost", "the app quit")
    second = Error.new("host_lost", "the Mac is locked")

    :ok = TurnMarker.mark(marker, "owner-a", turn_pid, first)
    :ok = TurnMarker.mark(marker, "owner-a", turn_pid, second)

    assert TurnMarker.lookup(marker, "owner-a", turn_pid) == second
  end

  # A tree with no marker process (an isolated test tree) has no turn to hold
  # it for: `mark/4` is a silent no-op and `lookup/3` finds nothing, rather
  # than crashing every caller that has no marker started.
  test "a tree with no marker process answers as if nothing were ever marked" do
    error = Error.new("host_lost", "the app quit")
    assert :ok = TurnMarker.mark(:no_such_turn_marker, "owner-a", turn(), error)
    refute TurnMarker.lookup(:no_such_turn_marker, "owner-a", turn())
  end

  defp eventually(predicate, attempts \\ 40) do
    cond do
      predicate.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(predicate, attempts - 1)
    end
  end
end
