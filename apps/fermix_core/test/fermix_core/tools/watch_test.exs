defmodule FermixCore.Tools.WatchTest do
  use ExUnit.Case, async: false

  alias FermixCore.Tools.StopWatch
  alias FermixCore.Tools.Watch
  alias FermixCore.Watch.Supervisor, as: WatchSupervisor

  setup do
    start_supervised!(WatchSupervisor)
    :ok
  end

  defp ctx(extra \\ %{}) do
    Map.merge(%{computer_use_origin: :interactive, conversation_key: {"cli", "c1", :root}}, extra)
  end

  test "watch refuses a missing task" do
    assert {:ok, %{success: false, error: msg}} = Watch.execute(%{}, ctx())
    assert msg =~ "task"
  end

  test "watch refuses when there is no conversation to report to" do
    assert {:ok, %{success: false, error: msg}} =
             Watch.execute(%{"task" => "watch it"}, %{computer_use_origin: :interactive})

    assert msg =~ "conversation"
  end

  test "watch refuses an unattended origin, pointing at schedule_job" do
    unattended = %{conversation_key: {"background", "j1", :root}}

    assert {:ok, %{success: false, error: msg}} =
             Watch.execute(%{"task" => "watch it"}, unattended)

    assert msg =~ "attended"
    assert msg =~ "schedule_job"
  end

  test "stop_watch is a success no-op when nothing is watching" do
    assert {:ok, %{success: true, output: out}} = StopWatch.execute(%{}, ctx())
    assert out =~ "Stopped"
  end

  test "tool metadata is well-formed" do
    assert Watch.name() == "watch"
    assert StopWatch.name() == "stop_watch"
    assert is_binary(Watch.when_to_use())
    assert %{required: ["task"]} = Watch.parameters()
    assert Watch.category() == :gui
  end
end
