defmodule FermixCore.Browser.HeldTurnTest do
  # M97 §6.4: a server's turn on the computer whose browser it uses. Each of
  # the turn's requests runs in one process here, which ends as the turn
  # ended on the server: normally, which a pane task that was handed over
  # survives, or stopped, which no task survives. Every registry and
  # supervisor is this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HeldTurn

  setup do
    n = System.unique_integer([:positive])
    seams = %{registry: :"held_turns_#{n}", supervisor: :"held_turn_sup_#{n}"}
    start_supervised!({Registry, keys: :unique, name: seams.registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: seams.supervisor})
    %{seams: seams}
  end

  test "a turn's requests run in one process of their own, in order", %{seams: seams} do
    first = HeldTurn.run(seams, "main-41", fn -> self() end)
    second = HeldTurn.run(seams, "main-41", fn -> self() end)
    other = HeldTurn.run(seams, "main-42", fn -> self() end)

    assert first == second
    refute first == self()
    refute other == first
  end

  test "a turn that ended normally ends its process normally", %{seams: seams} do
    held = HeldTurn.run(seams, "main-43", fn -> self() end)
    ref = Process.monitor(held)

    :ok = HeldTurn.finish(seams, "main-43", "ended")
    assert_receive {:DOWN, ^ref, :process, ^held, :normal}
  end

  test "a turn that was stopped ends its process as stopped", %{seams: seams} do
    held = HeldTurn.run(seams, "main-44", fn -> self() end)
    ref = Process.monitor(held)

    :ok = HeldTurn.finish(seams, "main-44", "stopped")
    assert_receive {:DOWN, ^ref, :process, ^held, {:shutdown, :turn_stopped}}
  end

  test "the end of a turn this computer never held is already done", %{seams: seams} do
    assert :ok = HeldTurn.finish(seams, "main-45", "ended")
    assert Registry.count(seams.registry) == 0
  end

  test "a request after its turn's process ended starts a fresh one", %{seams: seams} do
    held = HeldTurn.run(seams, "main-46", fn -> self() end)
    ref = Process.monitor(held)
    :ok = HeldTurn.finish(seams, "main-46", "ended")
    assert_receive {:DOWN, ^ref, :process, ^held, :normal}

    again = HeldTurn.run(seams, "main-46", fn -> self() end)
    refute again == held
  end

  test "a session id is a turn's as the wire carries it" do
    assert HeldTurn.session?("main-41")
    refute HeldTurn.session?("")
    refute HeldTurn.session?("main 41")
    refute HeldTurn.session?(nil)
  end
end
