defmodule FermixCore.Home.ServerRestartTest do
  # M97 D28c (§19.6): `home.restart`, a linked computer's Restart <server>,
  # taken on the server as `fermix restart` would be there, after its
  # restart hold (§3.4 rule 6). The clock, the hold and the stopper are the
  # test's; each tick is delivered by hand, never waited for, and a look is
  # over once its read's task has exited (`look/2`).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Home.RestartHold
  alias FermixCore.Home.ServerRestart
  alias FermixCore.Management.Copy

  @work_sentence "Fermix on your server restarts once the work it runs on a computer ends, or " <>
                   "in ten minutes at most."
  @move_sentence "A move is under way, so Fermix on your server restarts once it is done."

  setup ctx do
    test = self()
    clock = start_supervised!({Agent, fn -> 1_000_000 end}, id: :clock)
    hold = start_supervised!({Agent, fn -> nil end}, id: :hold)
    tasks = start_supervised!(Task.Supervisor)
    name = :"server_restart_#{:erlang.phash2(ctx.test)}"
    pid = start_supervised!({ServerRestart, waiter_opts(name, clock, tasks)})

    world = %{
      hold: fn ->
        send(test, {:read_by, self()})
        hold |> Agent.get(& &1) |> held()
      end,
      restart: fn ->
        send(test, :restarted)
        :ok
      end,
      restarts_itself: true
    }

    %{name: name, pid: pid, clock: clock, hold: hold, tasks: tasks, world: world}
  end

  test "with nothing holding it, the server restarts right after it answers", ctx do
    assert {:ok, %{"when" => "now", "wait_s" => 0, "sentence" => sentence}} =
             ServerRestart.request(ctx.name, ctx.world)

    assert sentence == "Fermix on your server restarts now, with the changes that waited for it."
    assert_received :restarted
    refute_received {:armed, _message, _delay}
  end

  test "work in progress on a computer: it answers that it waits, then restarts once it ends",
       ctx do
    Agent.update(ctx.hold, fn _ -> work(540) end)

    assert {:ok, %{"when" => "after_work", "wait_s" => 540, "sentence" => @work_sentence}} =
             ServerRestart.request(ctx.name, ctx.world)

    refute_received :restarted
    tick = armed_tick()

    # Still running at the first look: nothing restarts, and it looks again.
    advance(ctx, 5_000)
    look(ctx, tick)
    refute_received :restarted
    tick = armed_tick()

    # The work ended.
    Agent.update(ctx.hold, fn _ -> nil end)
    advance(ctx, 5_000)
    look(ctx, tick)
    assert_received :restarted
    refute_received {:armed, {:restart_tick, _token}, _delay}
  end

  test "a second request while one waits answers the same wait", ctx do
    Agent.update(ctx.hold, fn _ -> work(600) end)

    assert {:ok, %{"when" => "after_work", "wait_s" => 600}} =
             ServerRestart.request(ctx.name, ctx.world)

    tick = armed_tick()
    advance(ctx, 30_000)

    assert {:ok, %{"when" => "after_work", "wait_s" => 570, "sentence" => @work_sentence}} =
             ServerRestart.request(ctx.name, ctx.world)

    # One waiter: the second request armed nothing of its own.
    refute_received {:armed, _message, _delay}
    refute_received :restarted

    Agent.update(ctx.hold, fn _ -> nil end)
    look(ctx, tick)
    assert_received :restarted
    refute_received :restarted
  end

  # A second request is a look of its own: the work it waited for has ended,
  # so it restarts now rather than at the next tick.
  test "a second request once nothing holds it any more restarts now", ctx do
    Agent.update(ctx.hold, fn _ -> work(540) end)
    assert {:ok, %{"when" => "after_work"}} = ServerRestart.request(ctx.name, ctx.world)
    tick = armed_tick()

    Agent.update(ctx.hold, fn _ -> nil end)
    assert {:ok, %{"when" => "now", "wait_s" => 0}} = ServerRestart.request(ctx.name, ctx.world)
    assert_received :restarted

    # The wait is over: its tick is stale, and nothing restarts twice.
    send(ctx.pid, tick)
    _state = :sys.get_state(ctx.pid)
    refute_received :restarted
  end

  # The request's ten minutes, not the first hold's wait: the work that held
  # it ended, younger work began, and the restart waits for that one.
  test "work that starts while it waits holds the restart, within the request's ten minutes",
       ctx do
    Agent.update(ctx.hold, fn _ -> work(10) end)
    assert {:ok, %{"wait_s" => 10}} = ServerRestart.request(ctx.name, ctx.world)
    tick = armed_tick()

    Agent.update(ctx.hold, fn _ -> work(585) end)
    advance(ctx, 10_000)
    look(ctx, tick)
    refute_received :restarted
    tick = armed_tick()

    # The live hold's wait, never the first one's.
    assert {:ok, %{"when" => "after_work", "wait_s" => 585}} =
             ServerRestart.request(ctx.name, ctx.world)

    advance(ctx, 579_000)

    assert {:ok, %{"when" => "after_work", "wait_s" => 11}} =
             ServerRestart.request(ctx.name, ctx.world)

    advance(ctx, 11_000)
    look(ctx, tick)
    assert_received :restarted
  end

  test "it never waits past ten minutes, whatever work keeps running", ctx do
    Agent.update(ctx.hold, fn _ -> work(600) end)
    assert {:ok, %{"wait_s" => 600}} = ServerRestart.request(ctx.name, ctx.world)
    tick = armed_tick()

    # New work keeps the hold's own wait above zero; the request's ten minutes
    # end it all the same.
    advance(ctx, RestartHold.max_wait_s() * 1_000)
    look(ctx, tick)
    assert_received :restarted
  end

  test "a move under way refuses it in the hold's own words", ctx do
    Agent.update(ctx.hold, fn _ -> RestartHold.view("streaming", [], ~U[2031-05-04 12:00:00Z]) end)

    assert ServerRestart.request(ctx.name, ctx.world) ==
             {:error, {:unavailable, "home", @move_sentence}}

    refute_received :restarted
    refute_received {:armed, _message, _delay}
  end

  test "a move that starts while it waits ends the wait: the move restarts it", ctx do
    Agent.update(ctx.hold, fn _ -> work(540) end)
    assert {:ok, %{"when" => "after_work"}} = ServerRestart.request(ctx.name, ctx.world)
    tick = armed_tick()

    Agent.update(ctx.hold, fn _ -> RestartHold.view("requested", [], ~U[2031-05-04 12:00:00Z]) end)

    assert look(ctx, tick).waiting == nil
    refute_received :restarted
    refute_received {:armed, {:restart_tick, _token}, _delay}

    # The wait is over, so a request after it decides again.
    Agent.update(ctx.hold, fn _ -> nil end)
    assert {:ok, %{"when" => "now"}} = ServerRestart.request(ctx.name, ctx.world)
    assert_received :restarted
  end

  # The waiter is an early child of the engine's `:rest_for_one` root: a read
  # that fails is a hold that still holds, said once, and neither the waiter
  # nor the child after it goes down, nor the restart the computer was told of.
  test "a look whose read fails still waits, with the children after it left running", ctx do
    test = self()
    {:ok, cell} = Agent.start_link(fn -> work(540) end)
    name = :"#{ctx.name}_cascade"

    children = [
      {ServerRestart, waiter_opts(name, ctx.clock, ctx.tasks)},
      %{id: :sibling, start: {Agent, :start_link, [fn -> :sibling end]}}
    ]

    root =
      start_supervised!(%{
        id: :root,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      })

    %{ServerRestart => waiter, :sibling => sibling} = children(root)

    world = %{
      ctx.world
      | hold: fn ->
          send(test, {:read_by, self()})
          cell |> Agent.get(& &1) |> held()
        end
    }

    assert {:ok, %{"when" => "after_work"}} = ServerRestart.request(name, world)
    tick = armed_tick()
    Agent.update(cell, fn _ -> :exits end)

    log =
      capture_log(fn ->
        look(%{ctx | pid: waiter}, tick)
        tick = armed_tick()
        look(%{ctx | pid: waiter}, tick)
        tick = armed_tick()
        Agent.update(cell, fn _ -> :raises end)
        look(%{ctx | pid: waiter}, tick)
        tick = armed_tick()
        send(test, {:still_waiting, tick})
      end)

    assert_received {:still_waiting, tick}
    assert occurrences(log, "the restart hold could not be read (") == 1
    refute_received :restarted
    assert children(root) == %{ServerRestart => waiter, :sibling => sibling}

    log =
      capture_log(fn ->
        Agent.update(cell, fn _ -> nil end)
        look(%{ctx | pid: waiter}, tick)
      end)

    assert occurrences(log, "the restart hold reads again") == 1
    assert_received :restarted
  end

  # A hold that never reads again still ends at the request's ten minutes,
  # and the reads that kept failing end with the wait, said once each way.
  test "reads that keep failing still restart it at the request's ten minutes", ctx do
    Agent.update(ctx.hold, fn _ -> work(540) end)
    assert {:ok, %{"when" => "after_work"}} = ServerRestart.request(ctx.name, ctx.world)
    tick = armed_tick()
    Agent.update(ctx.hold, fn _ -> :exits end)

    log =
      capture_log(fn ->
        look(ctx, tick)
        refute_received :restarted
        tick = armed_tick()
        advance(ctx, RestartHold.max_wait_s() * 1_000)
        look(ctx, tick)
      end)

    assert_received :restarted
    assert occurrences(log, "the restart hold could not be read (") == 1
    assert occurrences(log, "the wait ended while the restart hold could not be read") == 1
    assert :sys.get_state(ctx.pid).unread == nil
  end

  test "a look whose read outlasts its bound is a failed read, and it waits on", ctx do
    Agent.update(ctx.hold, fn _ -> work(540) end)
    assert {:ok, %{"when" => "after_work"}} = ServerRestart.request(ctx.name, ctx.world)
    tick = armed_tick()
    Agent.update(ctx.hold, fn _ -> :blocks end)

    send(ctx.pid, tick)
    assert_receive {:read_by, reader} when reader != self()
    assert_receive {:armed, {:hold_read_late, _ref} = late, 10_000}
    ref = Process.monitor(reader)

    log =
      capture_log(fn ->
        send(ctx.pid, late)
        assert_receive {:DOWN, ^ref, :process, ^reader, :killed}
        _state = :sys.get_state(ctx.pid)
      end)

    assert log =~ "the restart hold could not be read (:read_timed_out)"
    assert armed_tick()
    refute_received :restarted
  end

  # The first decision's read runs in the caller: a hold that exits there
  # fails that request alone, and the waiter is the one it was.
  test "a request whose hold cannot be read fails in the caller, never in the waiter", ctx do
    world = %{
      ctx.world
      | hold: fn -> exit({:timeout, {GenServer, :call, [:calls, :running, 5_000]}}) end
    }

    assert {:timeout, _call} = catch_exit(ServerRestart.request(ctx.name, world))
    assert Process.whereis(ctx.name) == ctx.pid
    assert :sys.get_state(ctx.pid).waiting == nil

    odd = %{ctx.world | hold: fn -> %{reason: :computer_work} end}

    assert_raise ArgumentError, ~r/not a restart hold/, fn ->
      ServerRestart.request(ctx.name, odd)
    end

    assert Process.whereis(ctx.name) == ctx.pid
    refute_received :restarted
  end

  test "Fermix run from a terminal, which nothing starts again, is not stopped", ctx do
    world = %{ctx.world | restarts_itself: false}

    assert {:error, {:unavailable, "home", sentence}} = ServerRestart.request(ctx.name, world)
    assert sentence =~ "runs from a terminal"
    refute_received :restarted
  end

  test "with no waiter running, it says it cannot restart from here" do
    assert {:error, {:unavailable, "home", sentence}} =
             ServerRestart.request(:invented_no_server_restart, %{
               hold: fn -> nil end,
               restart: fn -> flunk("restarted with no waiter") end,
               restarts_itself: true
             })

    assert sentence =~ "cannot be restarted from here"
  end

  test "every sentence it says obeys the copy rules" do
    for sentence <- ServerRestart.sentences() do
      assert Copy.violations(sentence, :prose) == [], sentence
      assert Copy.summary_violations(sentence) == [], sentence
    end
  end

  defp waiter_opts(name, clock, tasks) do
    test = self()

    [
      name: name,
      now_ms: fn -> Agent.get(clock, & &1) end,
      task_supervisor: tasks,
      timer: fn message, delay ->
        send(test, {:armed, message, delay})
        make_ref()
      end
    ]
  end

  # The hold the test set, or a read that fails as a real one can.
  defp held(:exits), do: exit({:timeout, {GenServer, :call, [:calls, :running_effects, 5_000]}})
  defp held(:raises), do: raise("the move's phase file is unreadable")

  defp held(:blocks) do
    receive do
      :never -> nil
    end
  end

  defp held(hold), do: hold

  # One look: the tick starts a read in a task, whose answer the waiter takes
  # in before anything it is asked after the task is gone.
  defp look(ctx, tick) do
    send(ctx.pid, tick)
    assert_receive {:read_by, reader} when reader != self()
    ref = Process.monitor(reader)
    assert_receive {:DOWN, ^ref, :process, ^reader, _reason}
    :sys.get_state(ctx.pid)
  end

  defp armed_tick do
    assert_received {:armed, {:restart_tick, _token} = tick, 5_000}
    tick
  end

  defp occurrences(log, text), do: length(String.split(log, text)) - 1

  defp children(root),
    do: Map.new(Supervisor.which_children(root), fn {id, pid, _type, _mods} -> {id, pid} end)

  defp work(wait_s) do
    now = ~U[2031-05-04 12:00:00Z]
    started = DateTime.add(now, wait_s - RestartHold.max_wait_s(), :second)
    RestartHold.view(nil, [%{started_at: started}], now)
  end

  defp advance(ctx, ms), do: Agent.update(ctx.clock, &(&1 + ms))
end
