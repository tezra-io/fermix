defmodule FermixCore.Browser.HeldTurnListenerTest do
  # M97 §7.4, INVOKE-1: this computer's master or browser switch going off
  # ends every server turn its browser holds, a request one of them runs
  # included, as the screen's seat lets go of the screen. Every registry,
  # supervisor and switch is this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HeldTurn
  alias FermixCore.Browser.HeldTurnListener
  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse.ServerControl
  alias FermixTestSupport.SafeRm

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

    Agent.update(ctx.switches, &Keyword.put(&1, :files_and_shell, true))
    :ok = HeldTurnListener.changed(ctx.listener)

    # The listener took the change: a call behind it is answered after it.
    _state = :sys.get_state(ctx.listener)
    assert Process.alive?(held)
  end

  # M97 §8.7: the stretch the server's browser work on this computer runs is
  # recorded for the computer-history recorder (`ComputerUse.ServerControl`),
  # from the first turn held here to the end of the last one, however it ends,
  # so the recorder marks what happened in it as Fermix's own. The clock tells
  # the test each time a line is written.
  describe "the record of the server's browser work" do
    setup do
      n = System.unique_integer([:positive])
      home = SafeRm.make_tmp_dir!("held_turn_listener_record")
      on_exit(fn -> SafeRm.rm_rf!(home) end)

      turns = %{
        registry: :"record_turns_#{n}",
        supervisor: :"record_turn_sup_#{n}",
        listener: :"record_listener_#{n}"
      }

      start_supervised!({Registry, keys: :unique, name: turns.registry}, id: turns.registry)

      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: turns.supervisor},
        id: turns.supervisor
      )

      switches = start_supervised!({Agent, fn -> Switches.only([:browser]) end}, id: :switches)
      clock = start_supervised!({Agent, fn -> at(0) end}, id: :clock)
      test = self()

      read_clock = fn ->
        now = Agent.get(clock, & &1)
        send(test, {:recorded, now})
        now
      end

      opts = [
        name: turns.listener,
        turns: turns,
        home: home,
        clock: read_clock,
        switches: fn -> Agent.get(switches, & &1) end
      ]

      listener = start_supervised!({HeldTurnListener, opts}, id: :record_listener)

      %{
        turns: turns,
        home: home,
        clock: clock,
        switches: switches,
        listener: listener,
        opts: opts
      }
    end

    test "the first turn held here opens it and the last one's end closes it", ctx do
      [one, three, five] = [at(1), at(3), at(5)]
      set_clock(ctx, one)
      first = HeldTurn.run(ctx.turns, turn("main-71"), fn -> self() end)
      assert_receive {:recorded, ^one}

      set_clock(ctx, at(2))
      _second = HeldTurn.run(ctx.turns, turn("main-72", "owner-c2hlZA"), fn -> self() end)

      set_clock(ctx, three)
      await_end(ctx, first, fn -> HeldTurn.finish(ctx.turns, "main-71", "ended") end)
      _state = :sys.get_state(ctx.listener)
      refute_received {:recorded, _at}
      assert {:ok, true} = ServerControl.browser_open?(ctx.home)

      set_clock(ctx, five)
      :ok = HeldTurn.finish(ctx.turns, "main-72", "stopped")
      assert_receive {:recorded, ^five}
      _state = :sys.get_state(ctx.listener)

      assert {:ok, [%{seat: "browser", started_at: ^one, ended_at: ^five, why: :closed}]} =
               ServerControl.stretches(ctx.home)
    end

    test "the browser switch off closes it at once", ctx do
      _held = HeldTurn.run(ctx.turns, turn("main-73"), fn -> self() end)
      assert_receive {:recorded, _started}

      four = at(4)
      set_clock(ctx, four)
      Agent.update(ctx.switches, &Keyword.put(&1, :browser, false))
      :ok = HeldTurnListener.changed(ctx.listener)
      assert_receive {:recorded, ^four}
      _state = :sys.get_state(ctx.listener)

      assert {:ok, [%{ended_at: ^four, why: :switched_off}]} = ServerControl.stretches(ctx.home)
    end

    test "a turn that dies however it dies closes it", ctx do
      held = HeldTurn.run(ctx.turns, turn("main-74"), fn -> self() end)
      assert_receive {:recorded, _started}

      six = at(6)
      set_clock(ctx, six)
      await_end(ctx, held, fn -> Process.exit(held, :kill) end)
      assert_receive {:recorded, ^six}
      _state = :sys.get_state(ctx.listener)

      assert {:ok, [%{ended_at: ^six, why: :closed}]} = ServerControl.stretches(ctx.home)
    end

    test "a stretch a stopped engine left open is closed when the listener starts", ctx do
      :ok = stop_listener(ctx)
      one = at(1)
      :ok = ServerControl.browser_started(ctx.home, one)
      seven = at(7)
      set_clock(ctx, seven)

      restarted = start_supervised!({HeldTurnListener, ctx.opts}, id: :restarted)
      assert_receive {:recorded, ^seven}
      _state = :sys.get_state(restarted)

      assert {:ok, [%{started_at: ^one, ended_at: ^seven, why: :closed}]} =
               ServerControl.stretches(ctx.home)
    end

    test "a listener that starts beside a turn still held keeps its stretch open", ctx do
      held = HeldTurn.run(ctx.turns, turn("main-75"), fn -> self() end)
      assert_receive {:recorded, _started}
      # The line that read the clock is written before the listener stops.
      _state = :sys.get_state(ctx.listener)
      :ok = stop_listener(ctx)

      restarted = start_supervised!({HeldTurnListener, ctx.opts}, id: :restarted)
      _state = :sys.get_state(restarted)
      refute_received {:recorded, _at}
      assert {:ok, true} = ServerControl.browser_open?(ctx.home)

      eight = at(8)
      set_clock(ctx, eight)
      await_end(ctx, held, fn -> HeldTurn.finish(ctx.turns, "main-75", "ended") end)
      assert_receive {:recorded, ^eight}
      _state = :sys.get_state(restarted)
      assert {:ok, false} = ServerControl.browser_open?(ctx.home)
    end
  end

  defp at(minute), do: DateTime.add(~U[2026-11-11 09:00:00Z], minute, :minute)

  defp set_clock(ctx, at), do: Agent.update(ctx.clock, fn _now -> at end)

  # The listener of this describe stops, as an engine's does, and is gone
  # before the next starts under the same name.
  defp stop_listener(ctx) do
    ref = Process.monitor(ctx.listener)
    :ok = stop_supervised(:record_listener)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    :ok
  end

  defp await_end(_ctx, pid, ender) do
    ref = Process.monitor(pid)
    ender.()
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  defp turn(session, conversation \\ "owner-YWxsb3RtZW50"),
    do: %{session: session, conversation: conversation, worker?: false}
end
