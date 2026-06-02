defmodule FermixCore.Agents.IterationLimitsTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.IterationLimits

  setup do
    previous = Application.get_env(:fermix_core, :iteration_limits)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :iteration_limits)
        config -> Application.put_env(:fermix_core, :iteration_limits, config)
      end
    end)

    Application.delete_env(:fermix_core, :iteration_limits)
    :ok
  end

  test "defaults all bounded agent loop entry points to 100 iterations" do
    assert IterationLimits.interactive() == 100
    assert IterationLimits.subagent() == 100
    assert IterationLimits.scheduled_job_default() == 100
  end

  test "reads system-side application env overrides" do
    Application.put_env(:fermix_core, :iteration_limits,
      interactive: 80,
      subagent: 70,
      scheduled_job_default: 60
    )

    assert IterationLimits.interactive() == 80
    assert IterationLimits.subagent() == 70
    assert IterationLimits.scheduled_job_default() == 60
  end

  test "rejects invalid limits loudly" do
    Application.put_env(:fermix_core, :iteration_limits, interactive: 0)

    assert_raise ArgumentError, ~r/iteration_limits.interactive/, fn ->
      IterationLimits.interactive()
    end
  end
end
