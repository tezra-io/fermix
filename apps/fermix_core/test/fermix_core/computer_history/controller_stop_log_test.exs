defmodule FermixCore.ComputerHistory.ControllerStopLogTest do
  @moduledoc """
  CH-4's second path: the pid the Controller's `whereis` found is no longer the
  DynamicSupervisor's child, so `terminate_child` answers `{:error, :not_found}`,
  and the Controller logs "already gone" instead of claiming it stopped
  something.
  """
  # async: false — the case lowers the Controller's Logger module level (global
  # VM state) to see its :info lines; config/test.exs pins the level to :warning.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Controller

  setup do
    previous = Logger.get_module_level(Controller)
    Logger.put_module_level(Controller, :info)
    on_exit(fn -> restore_module_level(previous) end)
  end

  defp restore_module_level([{Controller, level}]), do: Logger.put_module_level(Controller, level)
  defp restore_module_level([]), do: Logger.delete_module_level(Controller)

  defp stray_spec(name),
    do: %{id: name, start: {Agent, :start_link, [fn -> :ok end, [name: name]]}}

  test "a stop the DynamicSupervisor answers not_found is logged as already gone" do
    unique = System.unique_integer([:positive])
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    name = :"ch_ctrl_stray_#{unique}"

    # Registered under the child's name, but never the DynamicSupervisor's child.
    start_supervised!(stray_spec(name))

    log =
      capture_log([level: :info], fn ->
        pid =
          start_supervised!(
            {Controller,
             name: :"ch_ctrl_#{unique}",
             dynamic_supervisor: sup,
             operative_fun: fn -> false end,
             installed_fun: fn -> true end,
             children: [%{name: name, spec: stray_spec(name)}]}
          )

        assert :ok = Controller.reconcile(pid)
      end)

    assert log =~ "already gone"
    refute log =~ "stopped #{inspect(name)}"
  end
end
