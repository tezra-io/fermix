defmodule FermixCore.ComputerHistory.ControllerRoleTest do
  # M75 D5: a device-role engine makes no provider call, so it keeps capture and
  # the 48-hour purge and leaves the summarizer, which calls a provider, out.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Summarizer.Scheduler

  @capture %{name: Capturer, spec: Capturer}
  @summarizer %{name: Scheduler, spec: Scheduler}

  test "the primary runs capture and the summarizer" do
    assert Controller.default_children(:primary) == [@capture, @summarizer]
  end

  test "a device runs capture only" do
    assert Controller.default_children(:device) == [@capture]
  end

  test "a controller reconciles the children of the role it was started in" do
    name = :"ch_controller_role_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Controller,
         name: name,
         engine_role: :device,
         dynamic_supervisor: :"ch_dynamic_#{System.unique_integer([:positive])}",
         operative_fun: fn -> false end,
         installed_fun: fn -> false end},
        id: name
      )

    assert :sys.get_state(pid).children == [@capture]
  end
end
