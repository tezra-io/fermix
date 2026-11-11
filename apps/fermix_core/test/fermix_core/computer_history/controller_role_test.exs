defmodule FermixCore.ComputerHistory.ControllerRoleTest do
  # M97 §8.1: both roles record where history is switched on, so both run the
  # recorder; the scheduler runs always on the home (its roll-up across every
  # machine) and only while recording on a computer, which keeps no notes and
  # sends its sittings over the link.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Summarizer.Scheduler

  test "the home records where switched on and always runs its scheduler, sending in process" do
    assert [
             %{name: Capturer, spec: Capturer, want: :recording},
             %{name: Scheduler, spec: {Scheduler, opts}, want: :always}
           ] = Controller.default_children(:primary)

    assert is_function(Keyword.fetch!(opts, :uplink), 1)
    refute Keyword.has_key?(opts, :repo)
  end

  test "a computer records where switched on and sends while it records, with no home store" do
    assert [
             %{name: Capturer, spec: Capturer, want: :recording},
             %{name: Scheduler, spec: {Scheduler, opts}, want: :recording}
           ] = Controller.default_children(:device)

    assert is_function(Keyword.fetch!(opts, :uplink), 1)
    assert Keyword.fetch!(opts, :repo) == nil
  end

  test "the scheduler's options carry the supervisor's timer posture" do
    assert [_capture, %{spec: {Scheduler, opts}}] =
             Controller.default_children(:primary, timer_enabled: false)

    assert Keyword.fetch!(opts, :timer_enabled) == false
  end

  # Its own DynamicSupervisor: the app tree's scheduler runs under the app's,
  # so a stop this controller decides finds nothing of its own to end.
  test "a controller reconciles the children of the role it was started in" do
    name = :"ch_controller_role_#{System.unique_integer([:positive])}"
    dynamic = :"ch_dynamic_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: dynamic, strategy: :one_for_one})

    pid =
      start_supervised!(
        {Controller,
         name: name,
         engine_role: :device,
         dynamic_supervisor: dynamic,
         operative_fun: fn -> false end,
         installed_fun: fn -> false end},
        id: name
      )

    assert [%{name: Capturer}, %{name: Scheduler, want: :recording}] =
             :sys.get_state(pid).children
  end
end
