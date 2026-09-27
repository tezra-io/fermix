defmodule FermixCore.Browser.HostLauncherTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.HostLauncher

  @at ~U[2026-09-26 10:00:00Z]
  @timeout 3_000
  @cooldown 300_000

  # ── the table ──────────────────────────────────────────────────────────────

  @listening %HostAvailability{listening: true}
  @silent %HostAvailability{listening: true, attached: true}
  @ready %HostAvailability{@silent | available: true, updated_at: @at}
  @busy %HostAvailability{@silent | reason: "the pane is closed", updated_at: @at}
  @stopping %HostAvailability{@silent | stopping: true}
  @quit %HostAvailability{@listening | quit: true, reason: "the app quit"}

  defp clock(launch_app?, remaining_ms, now_ms \\ 0) do
    %{launch_app?: launch_app?, remaining_ms: remaining_ms, now_ms: now_ms, cooldown_ms: @cooldown}
  end

  test "each row of the decision table" do
    rows = [
      # host, clock, step
      {@ready, clock(false, 100), :fermix_app},
      {@ready, clock(true, 0), :fermix_app},
      {@busy, clock(true, 100), {:managed, "the pane is closed"}},
      {@stopping, clock(true, 100), {:managed, "the app is quitting"}},
      {@silent, clock(false, 100), :wait},
      {@silent, clock(true, 0),
       {:managed, "the app connected but did not report its browser in time"}},
      {%HostAvailability{}, clock(true, 100), {:managed, "nothing in this engine serves it"}},
      {@listening, clock(false, 100), {:managed, "the app is not connected"}},
      {@quit, clock(true, 100),
       {:managed, "the app was quit, and is not opened again until it is started"}},
      {@listening, clock(true, 100), :launch},
      {%{@listening | launch_until: 500}, clock(true, 100, 100), :wait},
      {%{@listening | launch_until: 100}, clock(true, 0, 100),
       {:managed, "the app was opened but did not connect in time"}},
      {%{@listening | launch_until: 100}, clock(true, 100, 200),
       {:managed, "the app was opened but did not connect in time"}},
      {%{@listening | launch_until: 100}, clock(true, 100, 100 + @cooldown - 1),
       {:managed, "the app was opened but did not connect in time"}},
      {%{@listening | launch_until: 100}, clock(true, 100, 100 + @cooldown), :launch}
    ]

    for {host, clock, expected} <- rows do
      assert HostLauncher.step(host, clock) == expected, "#{inspect({host, clock})}"
    end
  end

  # ── the loop, over an injected launcher and clock ──────────────────────────

  defp config(launch_app) do
    {:ok, config} =
      Config.current(%{launch_app: launch_app, host_launch_timeout_ms: @timeout})

    config
  end

  defp host do
    start_supervised!({HostAvailability, name: nil, clock: fn -> @at end}, id: make_ref())
  end

  defp listening(host) do
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)
    host
  end

  defp attach(host, connection_id \\ 1) do
    connection = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(connection, :kill) end)
    :ok = HostAvailability.attached(host, connection, connection_id)
    connection
  end

  # A millisecond clock that only `sleep` moves, and a sleep that can make the
  # host speak once the clock passes a mark.
  defp fake_clock(on_tick \\ fn _now -> :ok end) do
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    now = fn -> Agent.get(clock, & &1) end

    sleep = fn ms ->
      Agent.update(clock, &(&1 + ms))
      on_tick.(now.())
    end

    %{now: now, sleep: sleep}
  end

  defp decide(config, host, launcher, clock \\ fake_clock()) do
    HostLauncher.decide(config,
      host_availability: host,
      launcher: launcher,
      now: clock.now,
      sleep: clock.sleep
    )
  end

  defp counting_launcher(on_launch \\ fn -> :ok end) do
    test = self()

    fn timeout_ms ->
      send(test, {:launched, timeout_ms})
      on_launch.()
    end
  end

  test "a host that is ready is used at once, and nothing is opened" do
    ready = listening(host())
    attach(ready)
    :ok = HostAvailability.report(ready, true, nil)
    clock = fake_clock()

    assert decide(config(true), ready, counting_launcher(), clock) == :fermix_app
    refute_received {:launched, _}
    assert clock.now.() == 0
  end

  test "a host that says its pane is not ready is Chrome, and nothing is opened" do
    busy = listening(host())
    attach(busy)
    :ok = HostAvailability.report(busy, false, "the pane is closed")

    assert decide(config(true), busy, counting_launcher()) == {:managed, "the pane is closed"}
    refute_received {:launched, _}
  end

  test "with launching off, an app that is not connected is Chrome and never opened" do
    assert {:managed, _reason} = decide(config(false), listening(host()), counting_launcher())
    refute_received {:launched, _}
  end

  # Nothing serves the wire, so nothing could ever attach: opening the app would
  # cost the whole deadline for a decision that is already known.
  test "with nothing listening for a host, the app is never opened" do
    assert decide(config(true), host(), counting_launcher()) ==
             {:managed, "nothing in this engine serves it"}

    refute_received {:launched, _}
  end

  test "an app opened on demand that attaches and reports ready gets the task" do
    pane = listening(host())

    launcher =
      counting_launcher(fn ->
        attach(pane)
        :ok = HostAvailability.report(pane, true, nil)
      end)

    assert decide(config(true), pane, launcher) == :fermix_app
    assert_received {:launched, timeout_ms}
    assert timeout_ms <= @timeout
    refute_received {:launched, _}
  end

  test "an app that attaches and reports late is waited for under the one deadline" do
    pane = listening(host())
    launcher = counting_launcher(fn -> attach(pane) && :ok end)

    clock =
      fake_clock(fn now ->
        if now >= 500 and not HostAvailability.reported?(HostAvailability.current(pane)),
          do: HostAvailability.report(pane, true, nil)
      end)

    assert decide(config(true), pane, launcher, clock) == :fermix_app
    assert clock.now.() >= 500 and clock.now.() < @timeout
  end

  test "the app is opened once, and the decision gives up at the deadline" do
    clock = fake_clock()

    assert decide(config(true), listening(host()), counting_launcher(), clock) ==
             {:managed, "the app was opened but did not connect in time"}

    assert_received {:launched, _}
    refute_received {:launched, _}
    assert clock.now.() >= @timeout
  end

  test "an app that cannot be opened is Chrome at once, with the reason" do
    launcher = counting_launcher(fn -> {:error, "open exited 1: no such app"} end)
    clock = fake_clock()

    assert decide(config(true), listening(host()), launcher, clock) ==
             {:managed, "the app could not be opened: open exited 1: no such app"}

    assert clock.now.() == 0
  end

  test "a clock that never moves still ends the decision" do
    stopped = %{now: fn -> 0 end, sleep: fn _ms -> :ok end}

    assert decide(config(true), listening(host()), counting_launcher(), stopped) ==
             {:managed, "the app was opened but did not connect in time"}
  end

  # A task that finds a launch already pending waits on that SAME launch's
  # deadline and never opens the app itself (`SingleLaunch`, BROWSER-3); the
  # pending launch attaching ends its wait too.
  test "a task that finds a launch pending gets the task once that launch attaches" do
    pane = listening(host())
    :ok = HostAvailability.launching(pane, 500)
    refuse_launch = fn _timeout_ms -> flunk("must not launch: a launch is already pending") end

    clock =
      fake_clock(fn now ->
        if now >= 100, do: attach(pane) && HostAvailability.report(pane, true, nil)
      end)

    assert decide(config(true), pane, refuse_launch, clock) == :fermix_app
    assert clock.now.() >= 100 and clock.now.() < 500
  end

  # BROWSER-8: a task that finds a launch pending waits on that launch's own
  # deadline, never past its own; only that deadline ends the wait, since a
  # crashed launch looks identical to a slow one.
  test "a task that finds a launch pending gives up at that launch's own, sooner, deadline" do
    pane = listening(host())
    :ok = HostAvailability.launching(pane, 120)
    refuse_launch = fn _timeout_ms -> flunk("must not launch: a launch is already pending") end
    clock = fake_clock()

    assert decide(config(true), pane, refuse_launch, clock) ==
             {:managed, "the app was opened but did not connect in time"}

    assert clock.now.() >= 120 and clock.now.() < @timeout
  end

  # BROWSER-8: a launch whose app died before it attached is ended only by the
  # deadline, and a task that starts within the cooldown afterwards runs on
  # Chrome without a second launch.
  test "a launch that never attached is not retried for the cooldown after its deadline" do
    pane = listening(host())
    :ok = HostAvailability.launching(pane, 100)
    clock = %{now: fn -> 101 end, sleep: fn _ms -> flunk("nothing to wait on") end}

    assert decide(config(true), pane, fn _ -> flunk("must not launch again in the cooldown") end, clock) ==
             {:managed, "the app was opened but did not connect in time"}
  end

end
