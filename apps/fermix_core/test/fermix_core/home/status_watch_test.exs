defmodule FermixCore.Home.StatusWatchTest do
  # Companion protocol 6 (M75 lean v1 §7): the apps no longer poll Always On.
  # One process reads the summary when something that feeds it happens, or at
  # the next time it changes by the clock alone, and tells its subscribers
  # (the companion connections) when it changed. The read, the timer and its
  # cancel are the test's: nothing here waits on a clock, a deadline is
  # delivered by hand, and `:sys.get_state/1` is the point after which every
  # message sent before it was handled.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Home.StatusWatch

  setup do
    test = self()
    {:ok, read} = Agent.start_link(fn -> %{key: :on, off: false, next_change_ms: nil} end)
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    watch =
      start_supervised!(
        {StatusWatch,
         name: nil,
         read: fn ->
           Agent.update(reads, &(&1 + 1))
           Agent.get(read, & &1)
         end,
         timer: fn message, delay ->
           send(test, {:armed, message, delay})
           make_ref()
         end,
         cancel_timer: fn ref ->
           send(test, {:cancelled, ref})
           false
         end,
         clock_monitor: false}
      )

    %{watch: watch, read: read, reads: reads}
  end

  describe "a subscriber" do
    test "is told once at once when Always On is not off", ctx do
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)

      assert_received :home_status_changed
      refute_received :home_status_changed
    end

    test "is told nothing when Always On is off", ctx do
      off!(ctx)
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)

      refute_received :home_status_changed
    end

    test "joining beside another reads nothing more, and is told at once", ctx do
      first = forwarder(:first)
      :ok = StatusWatch.subscribe(ctx.watch, first)
      settle(ctx)
      assert_receive {:first, :home_status_changed}

      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      flush(first, :first)

      assert_received :home_status_changed
      refute_received {:first, :home_status_changed}
      assert reads(ctx) == 1
    end
  end

  describe "a change" do
    test "of the key tells every subscriber once; the same key tells none", ctx do
      other = forwarder(:other)
      :ok = StatusWatch.subscribe(ctx.watch, self())
      :ok = StatusWatch.subscribe(ctx.watch, other)
      settle(ctx)
      assert_received :home_status_changed
      assert_receive {:other, :home_status_changed}

      :ok = StatusWatch.changed(ctx.watch, :ledger)
      settle(ctx)
      flush(other, :other)
      refute_received :home_status_changed
      refute_received {:other, :home_status_changed}

      Agent.update(ctx.read, &%{&1 | key: :problem})
      :ok = StatusWatch.changed(ctx.watch, :ledger)
      settle(ctx)
      flush(other, :other)

      assert_received :home_status_changed
      assert_received {:other, :home_status_changed}
      refute_received :home_status_changed
      refute_received {:other, :home_status_changed}
    end

    test "with nobody subscribed reads nothing", ctx do
      :ok = StatusWatch.changed(ctx.watch, :ledger)
      settle(ctx)
      assert reads(ctx) == 0
    end

    test "in a burst is one read", ctx do
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      assert reads(ctx) == 1

      :ok = :sys.suspend(ctx.watch)

      for kind <- [:ledger, :move, :enrollment, :snapshots, :link],
          do: StatusWatch.changed(ctx.watch, kind)

      :ok = :sys.resume(ctx.watch)
      settle(ctx)

      assert reads(ctx) == 2
    end

    test "that changed the key to off tells, and then only a change that can end off is read",
         ctx do
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      assert_received :home_status_changed

      off!(ctx)
      :ok = StatusWatch.changed(ctx.watch, :ledger)
      settle(ctx)
      assert_received :home_status_changed
      assert reads(ctx) == 2

      for kind <- [:snapshots, :link, :server], do: StatusWatch.changed(ctx.watch, kind)
      send(ctx.watch, {:CHANGE, make_ref(), :time_offset, :clock_service, 42})
      settle(ctx)
      assert reads(ctx) == 2

      for kind <- [:ledger, :enrollment, :move] do
        :ok = StatusWatch.changed(ctx.watch, kind)
        settle(ctx)
      end

      assert reads(ctx) == 5
      refute_received :home_status_changed
    end

    # A settings write feeds only the `off` line, which an app reads when its
    # pane opens and is never told (the owner's rule: an app forgets Always
    # On while it is off), so it is nothing the watch hears.
    test "a settings write is not a change the watch hears", ctx do
      assert_raise FunctionClauseError, fn -> StatusWatch.changed(ctx.watch, :config) end
    end
  end

  describe "the next deadline" do
    test "is armed from the read, fires once, and is armed again from the next read", ctx do
      Agent.update(ctx.read, &%{&1 | next_change_ms: 600_000})
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      assert_received :home_status_changed
      assert_received {:armed, deadline, 600_000}

      Agent.update(ctx.read, &%{&1 | key: :problem, next_change_ms: 86_400_000})
      send(ctx.watch, deadline)
      settle(ctx)

      assert_received :home_status_changed
      assert_received {:armed, next_deadline, 86_400_000}
      assert reads(ctx) == 2

      # The deadline it replaced is spent: delivered again, it reads nothing.
      send(ctx.watch, deadline)
      settle(ctx)
      assert reads(ctx) == 2
      refute_received :home_status_changed
      refute next_deadline == deadline
    end

    test "that changes nothing tells nobody", ctx do
      Agent.update(ctx.read, &%{&1 | next_change_ms: 5_000})
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      assert_received :home_status_changed
      assert_received {:armed, deadline, 5_000}

      Agent.update(ctx.read, &%{&1 | next_change_ms: nil})
      send(ctx.watch, deadline)
      settle(ctx)

      refute_received :home_status_changed
      refute_received {:armed, _message, _delay}
    end

    test "is never sooner than a second", ctx do
      Agent.update(ctx.read, &%{&1 | next_change_ms: 3})
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      assert_received {:armed, _deadline, 1_000}
    end

    test "is replaced, not added to, by a read that moves it", ctx do
      Agent.update(ctx.read, &%{&1 | next_change_ms: 600_000})
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)
      assert_received {:armed, _first, 600_000}

      Agent.update(ctx.read, &%{&1 | next_change_ms: 300_000})
      :ok = StatusWatch.changed(ctx.watch, :link)
      settle(ctx)

      assert_received {:cancelled, _ref}
      assert_received {:armed, _second, 300_000}
    end

    test "nothing is armed while Always On is off, whatever the read says", ctx do
      Agent.update(ctx.read, &%{&1 | key: :off, off: true, next_change_ms: 60_000})
      :ok = StatusWatch.subscribe(ctx.watch, self())
      settle(ctx)

      refute_received {:armed, _message, _delay}
      refute_received :home_status_changed
    end

    test "is cancelled, and the state forgotten, when the last subscriber leaves", ctx do
      Agent.update(ctx.read, &%{&1 | next_change_ms: 600_000})
      subscriber = forwarder(:only)
      :ok = StatusWatch.subscribe(ctx.watch, subscriber)
      settle(ctx)
      assert_received {:armed, _deadline, 600_000}

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
      settle(ctx)
      assert_received {:cancelled, _timer}

      :ok = StatusWatch.changed(ctx.watch, :ledger)
      settle(ctx)
      assert reads(ctx) == 1
    end
  end

  # The engine's monotonic clock stops while the computer sleeps, so a timer
  # for a time of day fires late by the sleep: the runtime's time offset moves
  # when it wakes, and the watch reads again and arms the deadline afresh.
  test "a jump of the clock (a wake from sleep) reads again and arms the deadline afresh", ctx do
    Agent.update(ctx.read, &%{&1 | next_change_ms: 86_400_000})
    :ok = StatusWatch.subscribe(ctx.watch, self())
    settle(ctx)
    assert_received {:armed, _deadline, 86_400_000}

    Agent.update(ctx.read, &%{&1 | next_change_ms: 3_600_000})
    send(ctx.watch, {:CHANGE, make_ref(), :time_offset, :clock_service, 42})
    settle(ctx)

    assert reads(ctx) == 2
    assert_received {:armed, _again, 3_600_000}
  end

  test "a read that fails is logged and changes nothing", ctx do
    :ok = StatusWatch.subscribe(ctx.watch, self())
    settle(ctx)
    assert_received :home_status_changed

    Agent.update(ctx.read, fn _value -> :not_a_read end)

    log =
      capture_log(fn ->
        :ok = StatusWatch.changed(ctx.watch, :ledger)
        settle(ctx)
      end)

    assert log =~ "Always On status could not be read"
    refute_received :home_status_changed
    assert Process.alive?(ctx.watch)
  end

  test "changed/2 and subscribe/2 to a watch that does not run are no-ops" do
    assert :ok = StatusWatch.changed(:"status_watch_absent_#{System.unique_integer()}", :ledger)
    assert :ok = StatusWatch.subscribe(:"status_watch_absent_#{System.unique_integer()}", self())
  end

  defp off!(ctx), do: Agent.update(ctx.read, &%{&1 | key: :off, off: true})

  defp reads(ctx), do: Agent.get(ctx.reads, & &1)

  # Every message sent to the watch before this call has been handled, and
  # the read a change asks for: the watch sends that to itself, queued behind
  # what came with it, so it is handled before a second round trip returns.
  defp settle(ctx) do
    _state = :sys.get_state(ctx.watch)
    _state = :sys.get_state(ctx.watch)
  end

  # Every message the subscriber had before this call has reached the test.
  defp flush(subscriber, tag) do
    send(subscriber, :flush)
    assert_receive {^tag, :flush}
  end

  # A subscriber of its own that tells the test what it was sent, tagged.
  defp forwarder(tag) do
    test = self()

    pid =
      spawn(fn ->
        receive_loop = fn loop ->
          receive do
            message ->
              send(test, {tag, message})
              loop.(loop)
          end
        end

        receive_loop.(receive_loop)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
