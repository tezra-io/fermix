defmodule FermixCore.OpenLoops.ChildGatingTest do
  # async: false: exercises the enabled and memory branches through global app env.
  use ExUnit.Case, async: false

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.OpenLoops.CheckInSupervisor
  alias FermixCore.OpenLoops.Scheduler

  @children [{Scheduler, [timer_enabled: true]}, CheckInSupervisor]

  setup do
    open_loops = Application.fetch_env(:fermix_core, :open_loops)
    memory = Application.fetch_env(:fermix_core, :memory)

    on_exit(fn ->
      restore(:open_loops, open_loops)
      restore(:memory, memory)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:fermix_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:fermix_core, key)

  test "the children are absent under mix test regardless of config" do
    Application.put_env(:fermix_core, :open_loops, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: true)

    assert CoreApplication.maybe_open_loops_children() == []
  end

  test "outside test env the children require the switch AND memory" do
    Application.put_env(:fermix_core, :open_loops, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: true)
    assert CoreApplication.maybe_open_loops_children(:prod) == @children

    Application.put_env(:fermix_core, :open_loops, enabled: false)
    assert CoreApplication.maybe_open_loops_children(:prod) == []

    Application.put_env(:fermix_core, :open_loops, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: false)
    assert CoreApplication.maybe_open_loops_children(:prod) == []
  end

  test "an absent section is off: the first release ships default-off" do
    Application.put_env(:fermix_core, :open_loops, [])
    Application.put_env(:fermix_core, :memory, enabled: true)

    assert CoreApplication.maybe_open_loops_children(:prod) == []
  end
end
