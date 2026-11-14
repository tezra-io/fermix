defmodule FermixCore.Home.ServerRestartTest do
  # M97 D28c (§19.6): `home.restart`, a linked computer's Restart <server>,
  # taken on the server as `fermix restart` would be there, after its
  # restart hold (§3.4 rule 6). The clock, the hold and the stopper are the
  # test's; each tick is delivered by hand, never waited for.
  use ExUnit.Case, async: true

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
    name = :"server_restart_#{:erlang.phash2(ctx.test)}"

    pid =
      start_supervised!(
        {ServerRestart,
         name: name,
         now_ms: fn -> Agent.get(clock, & &1) end,
         timer: fn message, delay ->
           send(test, {:armed, message, delay})
           make_ref()
         end}
      )

    world = %{
      hold: fn -> Agent.get(hold, & &1) end,
      restart: fn ->
        send(test, :restarted)
        :ok
      end,
      restarts_itself: true
    }

    %{name: name, pid: pid, clock: clock, hold: hold, world: world}
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
    assert_received {:armed, tick, 5_000}

    # Still running at the first look: nothing restarts, and it looks again.
    advance(ctx, 5_000)
    send(ctx.pid, tick)
    _state = :sys.get_state(ctx.pid)
    refute_received :restarted
    assert_received {:armed, tick, 5_000}

    # The work ended.
    Agent.update(ctx.hold, fn _ -> nil end)
    advance(ctx, 5_000)
    send(ctx.pid, tick)
    assert_receive :restarted
    _state = :sys.get_state(ctx.pid)
    refute_received {:armed, _message, _delay}
  end

  test "a second request while one waits answers the same wait", ctx do
    Agent.update(ctx.hold, fn _ -> work(600) end)

    assert {:ok, %{"when" => "after_work", "wait_s" => 600}} =
             ServerRestart.request(ctx.name, ctx.world)

    assert_received {:armed, tick, 5_000}
    advance(ctx, 30_000)

    assert {:ok, %{"when" => "after_work", "wait_s" => 570, "sentence" => @work_sentence}} =
             ServerRestart.request(ctx.name, ctx.world)

    # One waiter: the second request armed nothing of its own.
    refute_received {:armed, _message, _delay}
    refute_received :restarted

    Agent.update(ctx.hold, fn _ -> nil end)
    send(ctx.pid, tick)
    assert_receive :restarted
    _state = :sys.get_state(ctx.pid)
    refute_received :restarted
  end

  test "it never waits past ten minutes, whatever work keeps running", ctx do
    Agent.update(ctx.hold, fn _ -> work(600) end)
    assert {:ok, %{"wait_s" => 600}} = ServerRestart.request(ctx.name, ctx.world)
    assert_received {:armed, tick, 5_000}

    # New work keeps the hold's own wait above zero; the request's ten minutes
    # end it all the same.
    advance(ctx, RestartHold.max_wait_s() * 1_000)
    send(ctx.pid, tick)
    assert_receive :restarted
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
    assert_received {:armed, tick, 5_000}

    Agent.update(ctx.hold, fn _ -> RestartHold.view("requested", [], ~U[2031-05-04 12:00:00Z]) end)

    send(ctx.pid, tick)
    _state = :sys.get_state(ctx.pid)
    refute_received :restarted
    refute_received {:armed, _message, _delay}

    # The wait is over, so a request after it decides again.
    Agent.update(ctx.hold, fn _ -> nil end)
    assert {:ok, %{"when" => "now"}} = ServerRestart.request(ctx.name, ctx.world)
    assert_received :restarted
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

  defp work(wait_s) do
    now = ~U[2031-05-04 12:00:00Z]
    started = DateTime.add(now, wait_s - RestartHold.max_wait_s(), :second)
    RestartHold.view(nil, [%{started_at: started}], now)
  end

  defp advance(ctx, ms), do: Agent.update(ctx.clock, &(&1 + ms))
end
