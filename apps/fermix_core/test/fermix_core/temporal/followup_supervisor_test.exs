defmodule FermixCore.Temporal.FollowupSupervisorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Temporal.Followup
  alias FermixCore.Temporal.FollowupSupervisor

  # M30 §22.4: capacity is a refusal, never a queue. Model runs are minutes
  # long where deliveries are seconds long, so the ceiling is deliberately
  # lower than the delivery supervisor's four.
  setup do
    name = :"temporal_followup_sup_#{System.unique_integer([:positive])}"
    start_supervised!({FollowupSupervisor, name: name})
    %{supervisor: name}
  end

  defp park(supervisor) do
    DynamicSupervisor.start_child(supervisor, %{
      id: {:parked, System.unique_integer([:positive])},
      start: {Agent, :start_link, [fn -> :parked end]},
      restart: :temporary
    })
  end

  test "the concurrent ceiling is two", %{supervisor: supervisor} do
    assert FollowupSupervisor.max_children() == 2

    assert {:ok, _first} = park(supervisor)
    assert {:ok, _second} = park(supervisor)
    assert park(supervisor) == {:error, :max_children}
  end

  test "a full supervisor refuses a follow-up rather than queueing it", %{supervisor: supervisor} do
    assert {:ok, _first} = park(supervisor)
    assert {:ok, _second} = park(supervisor)

    args = %{
      reminder: %{id: "rem_1", event_id: "evt_1"},
      delivered_text: "Today: something.",
      repo: :unused,
      delivery_opts: []
    }

    assert FollowupSupervisor.start_followup(supervisor, args) == {:error, :max_children}
  end

  # A completed or crashed follow-up must never be restarted: it exists only
  # behind one already-delivered reminder.
  test "a follow-up child is :temporary" do
    spec =
      Followup.child_spec(%{
        reminder: %{id: "rem_1", event_id: "evt_1"},
        delivered_text: "Today: something.",
        repo: :unused,
        delivery_opts: []
      })

    assert spec.restart == :temporary
  end
end
