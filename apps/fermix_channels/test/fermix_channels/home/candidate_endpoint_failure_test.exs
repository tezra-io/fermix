defmodule FermixChannels.Home.CandidateEndpointFailureTest do
  # M75 Always On: a candidate whose own iroh endpoint failed (on a server, a
  # fixed port another process holds) dials nothing, every attempt answers
  # `:not_ready`, and the owner reads why where they look: the retry's log
  # line and the sentence the expired code leaves in `fermix home status`.
  #
  # Not async: the retry line is an info line, under the suite's warning
  # level, so this module lets the candidate's own lines through.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Test.HomeMove

  @failure "bind_failed: UDP port 4033 could not be bound: Address already in use [os error 98]"

  setup do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    rail = start_supervised!({HomeMove.RailStatus, %{state: :failed, failure: @failure}})
    home = HomeMove.candidate_home!(code)
    %{primary: primary, home: home, rail: rail}
  end

  defp start!(ctx, now) do
    HomeMove.start_candidate!(ctx.home, ctx.primary,
      now: now,
      helper: ctx.rail,
      connect: fn -> {:error, {:dial, :not_ready}} end
    )
  end

  test "each retry's log line says the endpoint's failure", ctx do
    Logger.put_module_level(CandidateProcess, :info)
    on_exit(fn -> Logger.delete_module_level(CandidateProcess) end)

    log =
      capture_log([level: :info], fn ->
        _candidate = start!(ctx, HomeMove.now())
        assert_receive {:scheduled, :enroll, 1_000}, 10_000
      end)

    assert log =~
             "candidate: studio-mac not reached yet (this host's iroh endpoint could not " <>
               "start: #{@failure}); trying again"
  end

  test "the expired code's sentence says the endpoint's failure", ctx do
    _candidate = start!(ctx, DateTime.add(HomeMove.now(), 31 * 60, :second))

    state = HomeMove.await_phase(ctx.home, "failed")

    assert state["sentence"] ==
             "The enrollment code expired before this host reached studio-mac: this host's " <>
               "iroh endpoint could not start: #{@failure}."
  end
end
