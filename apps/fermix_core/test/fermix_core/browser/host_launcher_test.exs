defmodule FermixCore.Browser.HostLauncherTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.HostLauncher

  @at ~U[2026-09-26 10:00:00Z]
  @timeout 3_000

  # ── the table ──────────────────────────────────────────────────────────────

  @listening %HostAvailability{listening: true}
  @silent %HostAvailability{listening: true, attached: true}
  @ready %HostAvailability{@silent | available: true, updated_at: @at}
  @busy %HostAvailability{@silent | reason: "the pane is closed", updated_at: @at}

  test "each row of the decision table" do
    rows = [
      # host, launched?, launch_app?, remaining ms, step
      {@ready, false, false, 100, :fermix_app},
      {@ready, true, true, 0, :fermix_app},
      {@busy, false, true, 100, {:managed, "the pane is closed"}},
      {@silent, false, false, 100, :wait},
      {@silent, true, true, 0,
       {:managed, "the app connected but did not report its browser in time"}},
      {%HostAvailability{}, false, true, 100, {:managed, "nothing in this engine serves it"}},
      {@listening, false, false, 100, {:managed, "the app is not connected"}},
      {%{@listening | reason: "the app quit"}, false, false, 100, {:managed, "the app quit"}},
      {@listening, false, true, 100, :launch},
      {@listening, true, true, 100, :wait},
      {@listening, true, true, 0, {:managed, "the app was opened but did not connect in time"}}
    ]

    for {host, launched?, launch_app?, remaining, expected} <- rows do
      assert HostLauncher.step(host, launched?, launch_app?, remaining) == expected,
             "#{inspect({host, launched?, launch_app?, remaining})}"
    end
  end

  # ── the loop, over an injected launcher and clock ──────────────────────────

  defp config(launch_app) do
    {:ok, config} = Config.current(%{launch_app: launch_app, host_launch_timeout_ms: @timeout})
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

  # A millisecond clock that only `sleep` moves, and a sleep that can make the
  # host speak once the clock passes a mark.
  defp clock(on_tick \\ fn _now -> :ok end) do
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    now = fn -> Agent.get(clock, & &1) end

    sleep = fn ms ->
      Agent.update(clock, &(&1 + ms))
      on_tick.(now.())
    end

    %{now: now, sleep: sleep}
  end

  defp decide(config, host, launcher, clock \\ clock()) do
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
    :ok = HostAvailability.attached(ready)
    :ok = HostAvailability.report(ready, true, nil)
    clock = clock()

    assert decide(config(true), ready, counting_launcher(), clock) == :fermix_app
    refute_received {:launched, _}
    assert clock.now.() == 0
  end

  test "a host that says its pane is not ready is Chrome, and nothing is opened" do
    busy = listening(host())
    :ok = HostAvailability.attached(busy)
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
        :ok = HostAvailability.attached(pane)
        :ok = HostAvailability.report(pane, true, nil)
      end)

    assert decide(config(true), pane, launcher) == :fermix_app
    assert_received {:launched, timeout_ms}
    assert timeout_ms <= @timeout
    refute_received {:launched, _}
  end

  test "an app that attaches and reports late is waited for under the one deadline" do
    pane = listening(host())
    launcher = counting_launcher(fn -> HostAvailability.attached(pane) end)

    clock =
      clock(fn now ->
        if now >= 500 and not HostAvailability.reported?(HostAvailability.current(pane)),
          do: HostAvailability.report(pane, true, nil)
      end)

    assert decide(config(true), pane, launcher, clock) == :fermix_app
    assert clock.now.() >= 500 and clock.now.() < @timeout
  end

  test "the app is opened once, and the decision gives up at the deadline" do
    clock = clock()

    assert decide(config(true), listening(host()), counting_launcher(), clock) ==
             {:managed, "the app was opened but did not connect in time"}

    assert_received {:launched, _}
    refute_received {:launched, _}
    assert clock.now.() >= @timeout
  end

  test "an app that cannot be opened is Chrome at once, with the reason" do
    launcher = counting_launcher(fn -> {:error, "open exited 1: no such app"} end)
    clock = clock()

    assert decide(config(true), listening(host()), launcher, clock) ==
             {:managed, "the app could not be opened: open exited 1: no such app"}

    assert clock.now.() == 0
  end

  test "a clock that never moves still ends the decision" do
    stopped = %{now: fn -> 0 end, sleep: fn _ms -> :ok end}

    assert decide(config(true), listening(host()), counting_launcher(), stopped) ==
             {:managed, "the app was opened but did not connect in time"}
  end
end
