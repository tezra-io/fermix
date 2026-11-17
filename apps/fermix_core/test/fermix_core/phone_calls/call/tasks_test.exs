defmodule FermixCore.PhoneCalls.Call.TasksTest do
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Call.Tasks

  # A task that waits for this test's word, so the test decides when it ends.
  defp waiting(test, tag) do
    fn ->
      send(test, {:started, tag, self()})

      receive do
        {:finish, result} -> result
      after
        10_000 -> :gave_up
      end
    end
  end

  defp started!(tag) do
    assert_receive {:started, ^tag, pid}
    pid
  end

  test "a named task's result is owned by its kind and dropped once read" do
    tasks = Tasks.start(Tasks.new(), :create, waiting(self(), :create))
    send(started!(:create), {:finish, {:ok, :created}})
    assert_receive {ref, {:ok, :created}} when is_reference(ref)

    assert {:named, :create} = Tasks.owner(tasks, ref)
    tasks = Tasks.drop(tasks, ref)
    assert :none = Tasks.owner(tasks, ref)
    refute Tasks.running?(tasks, :create)
    # The monitor was flushed with it.
    refute_received {:DOWN, ^ref, _process, _pid, _reason}
  end

  test "one task of a kind at a time" do
    tasks = Tasks.start(Tasks.new(), :hangup, waiting(self(), :hangup))
    assert Tasks.running?(tasks, :hangup)

    assert_raise FunctionClauseError, fn ->
      Tasks.start(tasks, :hangup, fn -> :again end)
    end

    _tasks = Tasks.shutdown(tasks, :hangup)
  end

  test "past its watchdog a task is killed, or its result kept when it already came" do
    tasks = Tasks.start(Tasks.new(), :extract, waiting(self(), :extract))
    pid = started!(:extract)
    assert {:killed, tasks} = Tasks.expire(tasks, :extract)
    refute Process.alive?(pid)
    assert :none = Tasks.expire(tasks, :extract)

    tasks = Tasks.start(tasks, :extract, fn -> {:ok, :read} end)
    %{named: %{extract: %Task{pid: done}}} = tasks
    monitor = Process.monitor(done)
    # Ended, so its result is in the mailbox before the watchdog is handled.
    assert_receive {:DOWN, ^monitor, :process, ^done, _reason}
    assert {:result, {:ok, :read}, tasks} = Tasks.expire(tasks, :extract)
    refute Tasks.running?(tasks, :extract)
  end

  test "a turn's stop is never waited on, and ends with the call when still running" do
    tasks = Tasks.start_stop(Tasks.new(), waiting(self(), :stop))
    pid = started!(:stop)
    [ref] = Map.keys(tasks.stops)
    assert :stop = Tasks.owner(tasks, ref)

    tasks = Tasks.shutdown_stops(tasks)
    assert tasks.stops == %{}
    refute Process.alive?(pid)
  end

  test "shutting down a kind that does not run changes nothing" do
    tasks = Tasks.new()
    assert Tasks.shutdown(tasks, :hangup) == tasks
  end
end
