defmodule FermixCore.ComputerHistory.ControllerTest do
  @moduledoc """
  MILESTONE_32 §6.3 — the reconcile controller: starts the runtime children when
  the feature is operative AND the sidecar is installed, stops them otherwise,
  and is idempotent so every enable/disable surface can call it unconditionally.
  Uses injected operative/installed predicates and dummy children so the logic is
  proven without a real sidecar.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Controller

  # A child whose teardown waits for the test's release: a Capturer whose
  # terminate/2 flush is slow, which a stop has to wait out.
  defmodule SlowStop do
    @moduledoc false
    use GenServer

    def start_link({name, test_pid}), do: GenServer.start_link(__MODULE__, test_pid, name: name)

    @impl true
    def init(test_pid) do
      Process.flag(:trap_exit, true)
      {:ok, test_pid}
    end

    @impl true
    def terminate(_reason, test_pid) do
      send(test_pid, {:stopping, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end
    end
  end

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

  # CH-3: `/history off` may say the recorder stopped only when the Controller
  # confirmed it. An exit of the call is returned, never read as a stop.
  test "reconcile_runtime returns the failure when no controller answers" do
    absent = :"absent_ch_ctrl_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert {:error, {:reconcile_failed, {:noproc, _call}}} =
                 ComputerHistory.reconcile_runtime(absent)
      end)

    assert log =~ "reconcile_runtime failed"
  end

  # Rule 6: a malformed server or timeout fails at the call itself, not as an
  # exit a caller would read as an unconfirmed stop.
  test "reconcile and reconcile_runtime refuse a malformed server or timeout" do
    for timeout <- [-1, "15000"] do
      error = assert_raise FunctionClauseError, fn -> Controller.reconcile(:absent, timeout) end
      assert {error.module, error.function, error.arity} == {Controller, :reconcile, 2}
    end

    error =
      assert_raise FunctionClauseError, fn -> ComputerHistory.reconcile_runtime("controller") end

    assert {error.module, error.function, error.arity} ==
             {ComputerHistory, :reconcile_runtime, 1}
  end

  test "reconcile gives up after the timeout it is given while a stop is still running", ctx do
    name = :"ch_ctrl_slow_#{System.unique_integer([:positive])}"
    slow = %{name: name, spec: %{id: name, start: {SlowStop, :start_link, [{name, self()}]}}}
    pid = start_controller(%{ctx | children: [slow]})
    :ok = Controller.reconcile(pid)

    set(ctx, %{operative?: false})
    assert {:timeout, _call} = catch_exit(Controller.reconcile(pid, 50))

    assert_receive {:stopping, stopping}
    send(stopping, :release)
    # The stop the timed-out call was waiting for still completes.
    assert :ok = Controller.reconcile(pid)
    assert Process.whereis(name) == nil
  end

  # CH-4: a start that races the `/history off` flip is declined by the child's
  # own init (`:ignore`); the Controller takes that answer instead of crashing.
  test "a child that declines to start (:ignore) leaves the Controller up", ctx do
    declining = %{
      name: :"ch_ctrl_declining_#{System.unique_integer([:positive])}",
      spec: %{id: :declining, start: {Kernel, :apply, [fn -> :ignore end, []]}}
    }

    set(ctx, %{operative?: false})
    pid = start_controller(%{ctx | children: [declining]})

    set(ctx, %{operative?: true})
    assert :ok = Controller.reconcile(pid)
    assert Process.alive?(pid)
  end
end
