defmodule FermixCore.Accessories.TasksTest do
  @moduledoc """
  M91 D21: every engine's task work becomes the accessory's one `task.event`.
  The OpenAI Realtime fixtures are the A1 list: concurrent tool calls give one
  task and one success, one errored call fails the batch, a reconnect mid-batch
  cancels it with no success, and an unmatched settle is counted and opens
  nothing.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Tasks

  defp running, do: %{type: "tool_event", status: "running", name: "web_search"}
  defp completed, do: %{type: "tool_event", status: "completed", name: "web_search"}
  defp errored, do: %{type: "tool_event", status: "error", name: "calendar", reason: "denied"}

  # Folds tool events through one call's batch state, collecting what the
  # accessory is sent; a fault is collected as `{:fault, reason}`.
  defp run(events, state \\ Tasks.new()) do
    Enum.reduce(events, {[], state}, fn
      :reconnect, {sent, state} ->
        {more, state} = Tasks.reconnect(state)
        {sent ++ more, state}

      event, {sent, state} ->
        case Tasks.tool_event(state, event) do
          {:ok, more, state} -> {sent ++ more, state}
          {:fault, reason, state} -> {sent ++ [{:fault, reason}], state}
        end
    end)
  end

  describe "OpenAI Realtime tool batches" do
    test "three concurrent calls are one task: one running, one completed" do
      {sent, state} =
        run([running(), running(), running(), completed(), completed(), completed()])

      assert sent == [
               %{task: "rt:1", revision: 1, status: "running", in_chat: false},
               %{task: "rt:1", revision: 1, status: "completed", in_chat: false}
             ]

      assert state.open == 0
    end

    test "one errored call fails the whole batch, and no success is sent" do
      {sent, _state} = run([running(), running(), errored(), completed()])

      assert Enum.map(sent, & &1.status) == ["running", "failed"]
      refute Enum.any?(sent, &(&1.status == "completed"))
    end

    test "a reconnect mid-batch cancels it with no success, and the next batch is a new task" do
      {sent, _state} =
        run([running(), running(), completed(), :reconnect, running(), completed()])

      assert sent == [
               %{task: "rt:1", revision: 1, status: "running", in_chat: false},
               %{task: "rt:1", revision: 1, status: "cancelled", in_chat: false},
               %{task: "rt:2", revision: 1, status: "running", in_chat: false},
               %{task: "rt:2", revision: 1, status: "completed", in_chat: false}
             ]
    end

    test "a reconnect with no open batch sends nothing" do
      assert {[], %Tasks{open: 0}} = Tasks.reconnect(Tasks.new())
    end

    test "an unmatched settle is a counted fault and opens no batch" do
      {sent, state} = run([completed(), errored()])

      assert sent == [{:fault, :unmatched_settle}, {:fault, :unmatched_settle}]
      assert state.open == 0 and state.batch == 0
      assert Tasks.faults(state) == 2
    end

    test "a status outside the three is a counted fault" do
      assert {:fault, :unknown_status, state} =
               Tasks.tool_event(Tasks.new(), %{type: "tool_event", status: "paused"})

      assert Tasks.faults(state) == 1
    end

    test "no event carries the tool's name or its error reason" do
      {sent, _state} = run([running(), errored()])

      assert Enum.all?(
               sent,
               &(Map.keys(&1) |> Enum.sort() == [:in_chat, :revision, :status, :task])
             )
    end
  end

  describe "task-engine frames" do
    test "a pending task is sent as running, with its delegation and revision" do
      frame = %{type: "task", delegation_id: "d7", revision: 2, status: "pending"}

      assert {:ok, %{task: "d7", revision: 2, status: "running", in_chat: false}} =
               Tasks.from_task_frame(frame)
    end

    test "a result shown in the chat is in_chat" do
      frame = %{
        type: "task",
        delegation_id: "d7",
        revision: 1,
        status: "completed",
        server_seq: 41
      }

      assert {:ok, %{status: "completed", in_chat: true}} = Tasks.from_task_frame(frame)
    end

    test "the frame that detaches a task at the end of a call is not sent" do
      frame = %{
        type: "task",
        delegation_id: "d7",
        revision: 1,
        status: "running",
        detached: true
      }

      assert Tasks.from_task_frame(frame) == :skip
    end

    test "a delegation the link cannot name is refused by its field" do
      long = String.duplicate("a", 65)

      assert {:error, :delegation_id} =
               Tasks.from_task_frame(%{
                 type: "task",
                 delegation_id: long,
                 revision: 1,
                 status: "running"
               })

      assert {:error, :delegation_id} =
               Tasks.from_task_frame(%{
                 type: "task",
                 delegation_id: "a b",
                 revision: 1,
                 status: "running"
               })

      assert {:error, :revision} =
               Tasks.from_task_frame(%{
                 type: "task",
                 delegation_id: "d1",
                 revision: 0,
                 status: "running"
               })

      assert {:error, :status} =
               Tasks.from_task_frame(%{
                 type: "task",
                 delegation_id: "d1",
                 revision: 1,
                 status: "lost"
               })
    end
  end
end
