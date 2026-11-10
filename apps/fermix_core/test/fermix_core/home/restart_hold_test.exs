defmodule FermixCore.Home.RestartHoldTest do
  # M97 §3.4: a server's restart after an update waits for a move, and for
  # work in progress on a computer at most ten minutes from the oldest one's
  # start. The clock is handed in.
  use ExUnit.Case, async: true

  alias FermixCore.Home.RestartHold
  alias FermixCore.Management.Copy

  @now ~U[2031-05-04 12:00:00Z]

  defp started(seconds_ago), do: %{started_at: DateTime.add(@now, -seconds_ago, :second)}

  test "nothing running and no move holds nothing" do
    assert RestartHold.view(nil, [], @now) == nil
    assert RestartHold.view("committed", [], @now) == nil
    assert RestartHold.to_map(nil) == nil
  end

  test "a pending move holds the restart for as long as it runs" do
    for phase <- ~w(requested streaming committing aborting enrolling receiving staged activating) do
      assert %{reason: :move, count: 0, wait_s: 600} =
               RestartHold.view(phase, [started(900)], @now)
    end
  end

  test "work in progress holds it until ten minutes after the oldest started" do
    assert %{reason: :computer_work, count: 1, wait_s: 600} =
             RestartHold.view(nil, [started(0)], @now)

    assert %{count: 2, wait_s: 120} = RestartHold.view(nil, [started(30), started(480)], @now)
    assert %{wait_s: 1} = RestartHold.view(nil, [started(599)], @now)
    assert %{wait_s: 0} = RestartHold.view(nil, [started(600)], @now)
    assert %{wait_s: 0, count: 1} = RestartHold.view("done", [started(4_000)], @now)
  end

  test "a start in the future waits the whole bound, never more" do
    assert %{wait_s: 600} = RestartHold.view(nil, [started(-90)], @now)
  end

  test "home.status answers it with string keys, and its words follow the copy rules" do
    hold = RestartHold.view(nil, [started(60), started(10)], @now)

    assert RestartHold.to_map(hold) == %{
             "reason" => "computer_work",
             "count" => 2,
             "wait_s" => 540,
             "sentence" =>
               "Fermix on your server restarts once the work it runs on your computers ends, " <>
                 "or in ten minutes at most."
           }

    for sentence <- RestartHold.sentences() do
      assert Copy.violations(sentence, :prose) == [], sentence
    end
  end

  test "work in progress must say when it started" do
    assert_raise ArgumentError, ~r/started_at/, fn ->
      RestartHold.view(nil, [%{kind: :command}], @now)
    end
  end
end
