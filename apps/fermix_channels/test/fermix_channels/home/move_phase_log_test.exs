defmodule FermixChannels.Home.MovePhaseLogTest do
  @moduledoc """
  EC2 test 2026-11-08: a move logged "always on: move_now" and where the home
  went, and nothing between, so neither an owner nor Doctor could tell the
  transfer from the archiving. Each side now logs one info line per phase
  (`FermixCore.Home.MoveTelemetry.phase_ended/3`): how it ended, when it
  started and ended, how long it took, and the bytes it captured, sent or
  received, and never a path inside either home.

  A whole move between two real homes in one VM, as `Home.MoveTest` runs it.
  `async: false`: the lines are info and the suite logs warnings, so this
  module raises `MoveTelemetry`'s level, which is the VM's.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.MoveWorker
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveTelemetry
  alias FermixCore.Home.Snapshot.Recipient

  @primary_record %{role: :primary, primary: nil}

  setup do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    home = HomeMove.candidate_home!(code)
    candidate = HomeMove.start_candidate!(home, primary)
    %{"candidate_id" => candidate_id} = HomeMove.await_phase(home, "enrolled")
    recipient = Recipient.public(Recipient.generate())

    {:ok, started} =
      Move.start(primary.root, @primary_record, candidate_id, recipient, HomeMove.start_opts())

    Logger.put_module_level(MoveTelemetry, :info)
    on_exit(fn -> Logger.delete_module_level(MoveTelemetry) end)
    %{primary: primary, candidate: candidate, home: home, started: started}
  end

  test "each side logs one line per phase, with its bytes, and no path of either home", ctx do
    source = ctx.primary.root
    opts = HomeMove.worker_opts(source, ctx.candidate)

    log =
      capture_log([level: :info], fn ->
        :ok = Task.await(Task.async(fn -> MoveWorker.run(opts) end), 60_000)
      end)

    assert_received :source_restart
    {:ok, %{"capture" => %{"size" => size}}} = Move.read_phase(source)
    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "move #{ctx.started.move_id} "))

    # The two sides log from their own processes, so only each side's own
    # order is fixed.
    assert Enum.sort(Enum.map(lines, &phase_of/1)) ==
             Enum.sort([
               {"source", "capture", "done"},
               {"source", "send", "done"},
               {"source", "staging", "done"},
               {"source", "commit", "done"},
               {"candidate", "receive", "done"},
               {"candidate", "staging", "done"},
               {"candidate", "activation", "done"}
             ])

    assert Enum.find(lines, &(&1 =~ "source: capture")) =~ ", #{size} bytes captured"
    assert Enum.find(lines, &(&1 =~ "source: send")) =~ ", #{size} bytes sent"
    assert Enum.find(lines, &(&1 =~ "candidate: receive")) =~ ", #{size} bytes received"

    # Each side's own clock: the test's for the processes that take one, the
    # host's for the responder that writes the stream.
    for line <- lines do
      assert line =~ ~r/, \d{4}-\d\d-\d\dT[\d:]+Z to \d{4}-\d\d-\d\dT[\d:]+Z \(\d+\.\d s\)/
      refute line =~ source
      refute line =~ ctx.home
    end
  end

  defp phase_of(line) do
    [_line, side, phase, outcome] = Regex.run(~r/ (source|candidate): (\w+) (\w+),/, line)
    {side, phase, outcome}
  end
end
