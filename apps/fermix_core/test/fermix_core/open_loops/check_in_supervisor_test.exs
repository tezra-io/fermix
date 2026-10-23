defmodule FermixCore.OpenLoops.CheckInSupervisorTest do
  use ExUnit.Case, async: true

  alias FermixCore.OpenLoops.CheckIn
  alias FermixCore.OpenLoops.CheckInSupervisor

  # M78 §06 caps: two concurrent check-in runs, and a refusal is a traced skip,
  # never a queue.
  setup do
    name = :"open_loops_checkin_sup_#{System.unique_integer([:positive])}"
    start_supervised!({CheckInSupervisor, name: name})
    %{supervisor: name}
  end

  defp park(supervisor) do
    DynamicSupervisor.start_child(supervisor, %{
      id: {:parked, System.unique_integer([:positive])},
      start: {Agent, :start_link, [fn -> :parked end]},
      restart: :temporary
    })
  end

  defp args do
    %{
      loop: %{id: "loop_supervisor01", touches: 0, state: "due"},
      claimed_at: ~U[2031-06-07 17:00:00Z],
      touch: 1,
      rung: 2,
      active_hours: %{start: ~T[09:00:00], finish: ~T[21:00:00]},
      repo: :unused,
      delivery_opts: []
    }
  end

  test "the concurrent ceiling is two", %{supervisor: supervisor} do
    assert CheckInSupervisor.max_children() == 2

    assert {:ok, _first} = park(supervisor)
    assert {:ok, _second} = park(supervisor)
    assert park(supervisor) == {:error, :max_children}
  end

  test "a full supervisor refuses a check-in rather than queueing it", %{supervisor: supervisor} do
    assert {:ok, _first} = park(supervisor)
    assert {:ok, _second} = park(supervisor)

    assert CheckInSupervisor.start_checkin(supervisor, args()) == {:error, :max_children}
    assert DynamicSupervisor.count_children(supervisor).active == 2
  end

  # A finished or crashed check-in is never restarted: its claim is the
  # scheduler's to recover, under a fresh decision.
  test "a check-in child is :temporary" do
    assert CheckIn.child_spec(args()).restart == :temporary
  end
end
