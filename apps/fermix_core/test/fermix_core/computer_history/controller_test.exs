defmodule FermixCore.ComputerHistory.ControllerTest do
  @moduledoc """
  MILESTONE_32 §6.3 — the reconcile controller: starts the runtime children when
  the feature is operative AND the sidecar is installed, stops them otherwise,
  and is idempotent so every enable/disable surface can call it unconditionally.
  Uses injected operative/installed predicates and dummy children so the logic is
  proven without a real sidecar.
  """
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Controller

  setup do
    unique = System.unique_integer([:positive])
    sup = :"ch_ctrl_dynsup_#{unique}"
    start_supervised!({DynamicSupervisor, name: sup, strategy: :one_for_one})

    flag = start_supervised!({Agent, fn -> %{operative?: true, installed?: true} end})

    child_a = :"ch_ctrl_child_a_#{unique}"
    child_b = :"ch_ctrl_child_b_#{unique}"

    children = [
      %{name: child_a, spec: dummy_spec(child_a)},
      %{name: child_b, spec: dummy_spec(child_b)}
    ]

    %{sup: sup, flag: flag, children: children, names: [child_a, child_b]}
  end

  defp dummy_spec(name) do
    %{id: name, start: {Agent, :start_link, [fn -> :ok end, [name: name]]}}
  end

  defp start_controller(ctx) do
    start_supervised!(
      {Controller,
       [
         name: :"ch_ctrl_#{System.unique_integer([:positive])}",
         dynamic_supervisor: ctx.sup,
         operative_fun: fn -> Agent.get(ctx.flag, & &1.operative?) end,
         installed_fun: fn -> Agent.get(ctx.flag, & &1.installed?) end,
         children: ctx.children
       ]}
    )
  end

  defp set(ctx, kv), do: Agent.update(ctx.flag, &Map.merge(&1, kv))
  defp running(names), do: Enum.map(names, &(Process.whereis(&1) != nil))

  test "operative + installed starts every runtime child on boot", ctx do
    pid = start_controller(ctx)
    :ok = Controller.reconcile(pid)

    assert running(ctx.names) == [true, true]
  end

  test "not operative leaves the children absent", ctx do
    set(ctx, %{operative?: false})
    pid = start_controller(ctx)
    :ok = Controller.reconcile(pid)

    assert running(ctx.names) == [false, false]
  end

  test "operative but sidecar not installed is fail-closed — nothing starts", ctx do
    set(ctx, %{installed?: false})
    pid = start_controller(ctx)
    :ok = Controller.reconcile(pid)

    assert running(ctx.names) == [false, false]
  end

  test "reconcile is idempotent — a second call does not start a duplicate", ctx do
    pid = start_controller(ctx)
    :ok = Controller.reconcile(pid)
    first = Enum.map(ctx.names, &Process.whereis/1)

    :ok = Controller.reconcile(pid)
    second = Enum.map(ctx.names, &Process.whereis/1)

    assert Enum.all?(first, &(&1 != nil))
    # Same pids — no child was restarted or duplicated.
    assert first == second
  end

  test "a disable transition stops the running children", ctx do
    pid = start_controller(ctx)
    :ok = Controller.reconcile(pid)
    assert running(ctx.names) == [true, true]

    set(ctx, %{operative?: false})
    :ok = Controller.reconcile(pid)

    assert running(ctx.names) == [false, false]
  end

  test "a re-enable transition restarts the children", ctx do
    set(ctx, %{operative?: false})
    pid = start_controller(ctx)
    :ok = Controller.reconcile(pid)
    assert running(ctx.names) == [false, false]

    set(ctx, %{operative?: true})
    :ok = Controller.reconcile(pid)

    assert running(ctx.names) == [true, true]
  end
end
