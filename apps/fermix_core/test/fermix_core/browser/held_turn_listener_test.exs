defmodule FermixCore.Browser.HeldTurnListenerTest do
  # M97 §7.4, INVOKE-1: this computer's master or browser switch going off
  # ends every server turn its browser holds, a request one of them runs
  # included, as the screen's seat lets go of the screen. Every registry,
  # supervisor and switch is this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HeldTurn
  alias FermixCore.Browser.HeldTurnListener
  alias FermixCore.Computers.Switches

  setup do
    n = System.unique_integer([:positive])
    turns = %{registry: :"listener_turns_#{n}", supervisor: :"listener_turn_sup_#{n}"}
    start_supervised!({Registry, keys: :unique, name: turns.registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: turns.supervisor})
    switches = start_supervised!({Agent, fn -> Switches.only([:browser]) end})

    listener =
      start_supervised!(
        {HeldTurnListener,
         name: :"listener_#{n}", turns: turns, switches: fn -> Agent.get(switches, & &1) end}
      )

    %{turns: turns, switches: switches, listener: listener}
  end

  test "the browser switch off ends every turn held here, the one at work too", ctx do
    test = self()
    idle = HeldTurn.run(ctx.turns, turn("main-61"), fn -> self() end)

    spawn(fn ->
      HeldTurn.run(ctx.turns, turn("main-62", "owner-c2hlZA"), fn ->
        send(test, {:working, self()})
        receive do: (:never -> :ok)
      end)
    end)

    assert_receive {:working, busy}
    refs = Enum.map([idle, busy], &Process.monitor/1)

    Agent.update(ctx.switches, &Keyword.put(&1, :browser, false))
    :ok = HeldTurnListener.changed(ctx.listener)

    for {ref, pid} <- Enum.zip(refs, [idle, busy]),
        do: assert_receive({:DOWN, ^ref, :process, ^pid, :shutdown})
  end

  test "the master switch off ends them too", ctx do
    held = HeldTurn.run(ctx.turns, turn("main-63"), fn -> self() end)
    ref = Process.monitor(held)

    Agent.update(ctx.switches, &Keyword.put(&1, :enabled, false))
    :ok = HeldTurnListener.changed(ctx.listener)

    assert_receive {:DOWN, ^ref, :process, ^held, :shutdown}
  end

  test "a change that leaves the browser on ends nothing", ctx do
    held = HeldTurn.run(ctx.turns, turn("main-64"), fn -> self() end)

    Agent.update(ctx.switches, &Keyword.put(&1, :files, true))
    :ok = HeldTurnListener.changed(ctx.listener)

    # The listener took the change: a call behind it is answered after it.
    _state = :sys.get_state(ctx.listener)
    assert Process.alive?(held)
  end

  defp turn(session, conversation \\ "owner-YWxsb3RtZW50"),
    do: %{session: session, conversation: conversation, worker?: false}
end
