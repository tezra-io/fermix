defmodule FermixCore.Realtime.LiveDelegationTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.LiveDelegation

  describe "create/4" do
    test "the first delegation becomes active" do
      assert {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)

      assert %{id: "dg_1", offset_ms: 1_000, created_at_ms: 10, revision: 1, status: :created} =
               LiveDelegation.active(state)

      assert LiveDelegation.pending(state) == nil
    end

    test "a second delegation waits as pending while the first is active" do
      {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)
      assert {:ok, state} = LiveDelegation.create(state, "dg_2", 2_000, 20)

      assert LiveDelegation.active(state).id == "dg_1"
      assert %{id: "dg_2", status: :pending} = LiveDelegation.pending(state)
    end

    test "a third delegation is refused with a typed reason and changes nothing" do
      {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)
      {:ok, state} = LiveDelegation.create(state, "dg_2", 2_000, 20)

      assert {:rejected, :too_many_pending, ^state} =
               LiveDelegation.create(state, "dg_3", 3_000, 30)
    end

    test "a duplicate id is reported and changes nothing" do
      {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)

      assert {:duplicate, ^state} = LiveDelegation.create(state, "dg_1", 1_400, 20)
    end

    test "a duplicate of an already finished delegation is still a duplicate" do
      {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)
      {:ok, _record, state} = LiveDelegation.complete(state, "dg_1", "done")

      assert {:duplicate, ^state} = LiveDelegation.create(state, "dg_1", 4_000, 40)
    end
  end

  describe "start/4" do
    test "records the bridge reference and the revision the session submitted" do
      {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)

      assert {:ok, state} = LiveDelegation.start(state, "dg_1", :task_ref, 1)

      assert %{status: :running, bridge_ref: :task_ref, revision: 1} =
               LiveDelegation.active(state)

      assert LiveDelegation.revision_for(state, "dg_1") == 1
    end

    test "an unknown id is a typed error" do
      assert {:error, :unknown_delegation} =
               LiveDelegation.start(LiveDelegation.new(), "nope", :ref, 1)
    end
  end

  describe "terminal transitions" do
    setup do
      {:ok, state} = LiveDelegation.create(LiveDelegation.new(), "dg_1", 1_000, 10)
      {:ok, state} = LiveDelegation.start(state, "dg_1", :ref_1, 1)
      {:ok, state} = LiveDelegation.create(state, "dg_2", 2_000, 20)
      %{state: state}
    end

    test "completing the active one frees the slot and next_to_start promotes the pending one",
         %{state: state} do
      assert {:ok, %{id: "dg_1", status: :completed}, state} =
               LiveDelegation.complete(state, "dg_1", "the room is booked")

      assert LiveDelegation.active(state) == nil

      assert {:ok, %{id: "dg_2", status: :created}, state} = LiveDelegation.next_to_start(state)
      assert LiveDelegation.active(state).id == "dg_2"
      assert LiveDelegation.pending(state) == nil
    end

    test "next_to_start is :none while work is still running", %{state: state} do
      assert LiveDelegation.next_to_start(state) == :none
    end

    test "failing the active one records the reason", %{state: state} do
      assert {:ok, %{status: :failed, summary: "insufficient_context"}, state} =
               LiveDelegation.fail(state, "dg_1", "insufficient_context")

      assert LiveDelegation.active(state) == nil
    end

    test "cancelling the pending one leaves the active one alone", %{state: state} do
      assert {:ok, %{id: "dg_2", status: :cancelled}, state} =
               LiveDelegation.cancel(state, "dg_2")

      assert LiveDelegation.pending(state) == nil
      assert LiveDelegation.active(state).id == "dg_1"
    end

    test "a terminal delegation cannot be cancelled twice", %{state: state} do
      {:ok, _record, state} = LiveDelegation.cancel(state, "dg_1")

      assert {:error, :unknown_delegation} = LiveDelegation.cancel(state, "dg_1")
    end

    test "fetch/2 finds the active and pending records and refuses an unknown id", %{state: state} do
      assert {:ok, %{id: "dg_1", bridge_ref: :ref_1}} = LiveDelegation.fetch(state, "dg_1")
      assert {:ok, %{id: "dg_2"}} = LiveDelegation.fetch(state, "dg_2")
      assert LiveDelegation.fetch(state, "dg_9") == :error
    end

    test "in_flight/1 lists the active and pending records for teardown", %{state: state} do
      assert LiveDelegation.in_flight(state) |> Enum.map(& &1.id) == ["dg_1", "dg_2"]
    end
  end

  describe "history bound" do
    test "the finished-delegation ledger stays bounded" do
      state =
        Enum.reduce(1..100, LiveDelegation.new(), fn index, acc ->
          {:ok, acc} = LiveDelegation.create(acc, "dg_#{index}", index * 10, index)
          {:ok, _record, acc} = LiveDelegation.complete(acc, "dg_#{index}", "ok")
          acc
        end)

      assert length(state.finished) == 64
      assert {:duplicate, ^state} = LiveDelegation.create(state, "dg_100", 1_000, 1_000)
    end
  end
end
