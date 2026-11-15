defmodule FermixCore.ComputerUse.SeatTest do
  # M97 §6.4, §7.4: this computer's screen while its server drives it. The
  # helper is a double (`ScreenHelperDouble`): no real input is ever sent.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Seat
  alias FermixCore.ComputerUse.ServerControl
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.ScreenHelperDouble

  setup do
    home = SafeRm.make_tmp_dir!("screen_seat")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    test = self()
    {spec, knobs} = ScreenHelperDouble.driver(test)
    {:ok, switches} = Agent.start_link(fn -> Switches.only([:computer_use]) end)
    name = :"seat_#{System.unique_integer([:positive])}"

    seat =
      start_supervised!(
        {Seat,
         name: name,
         driver: fn -> {:ok, spec} end,
         config: fn -> Config.normalize(enabled: true) end,
         switches: fn -> Agent.get(switches, & &1) end,
         home: home,
         changed: fn -> send(test, :screen_changed) end,
         timer: fn message, _delay -> send(test, {:lapse_armed, message}) end}
      )

    %{seat: seat, name: name, home: home, knobs: knobs, switches: switches}
  end

  test "the first seat takes the screen, starts the helper and shows the mark", %{name: name} do
    assert Seat.view(name) == nil
    assert {:ok, held} = Seat.acquire(name, "cua_one")

    assert {ScreenHelperDouble, _state} = held.driver
    assert held.capabilities.input_methods == ["ax"]
    assert held.last_action_at == :never
    assert_receive :screen_changed
    assert %{since: %DateTime{}} = Seat.view(name)
    assert Seat.watch_state(name, "cua_one") == :held
  end

  test "a second seat is refused while one holds the screen", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    assert {:error, {:busy, %DateTime{}}} = Seat.acquire(name, "cua_two")
  end

  test "the person's Stop ends the hold at once and refuses that seat from then on", %{
    name: name
  } do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    watcher = Task.async(fn -> Seat.watch(name, "cua_one") end)
    await_watcher(name)

    assert Seat.stop(name) == :stopped
    assert_receive {:screen_helper_control, :release}
    assert_receive :screen_helper_stopped
    assert Task.await(watcher) == :stopped
    assert Seat.view(name) == nil
    assert Seat.watch_state(name, "cua_one") == :stopped
    assert {:error, :stopped} = Seat.acquire(name, "cua_one")
    assert Seat.watch(name, "cua_one") == :stopped

    # Another seat of the server, a new session, may take it again.
    assert {:ok, _held} = Seat.acquire(name, "cua_two")
  end

  test "the screen switch going off ends the hold as a Stop does", %{
    name: name,
    switches: switches
  } do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    watcher = Task.async(fn -> Seat.watch(name, "cua_one") end)
    await_watcher(name)

    Agent.update(switches, fn _on -> Switches.only([]) end)
    GenServer.cast(name, :switches_changed)

    assert Task.await(watcher) == :switched_off
    assert_receive :screen_helper_stopped
    assert {:error, :stopped} = Seat.acquire(name, "cua_one")
  end

  test "a switch change that leaves the screen on changes nothing", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    GenServer.cast(name, :switches_changed)
    assert Seat.watch_state(name, "cua_one") == :held
  end

  # C8: a hold that lapsed is over, and its watch answered: the same seat is
  # never taken again without one. Its server's next session takes a new seat.
  test "a hold that sends nothing lets go, and that seat is not taken again", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    assert_receive {:lapse_armed, {:lapse, ref}}
    watcher = Task.async(fn -> Seat.watch(name, "cua_one") end)
    await_watcher(name)

    send(name |> Process.whereis(), {:lapse, ref})

    assert Task.await(watcher) == :idle
    assert Seat.watch_state(name, "cua_one") == :gone
    assert {:error, :ended} = Seat.acquire(name, "cua_one")
    assert {:ok, _held} = Seat.acquire(name, "cua_two")
  end

  # C1: the server renews its hold while its session exists, paused or not,
  # so the lapse frees only a screen whose server went quiet.
  test "a renewal keeps the hold, and makes the lapse before it stale", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    assert_receive {:lapse_armed, {:lapse, first}}

    assert Seat.keep(name, "cua_one") == :held
    assert_receive {:lapse_armed, {:lapse, _second}}
    send(Process.whereis(name), {:lapse, first})
    assert Seat.watch_state(name, "cua_one") == :held

    assert Seat.keep(name, "cua_other") == :gone
    refute_received {:lapse_armed, _message}
  end

  test "a lapse armed before the last request is stale", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    assert_receive {:lapse_armed, {:lapse, first}}
    {:ok, _held} = Seat.acquire(name, "cua_one")
    assert_receive {:lapse_armed, {:lapse, _second}}

    send(Process.whereis(name), {:lapse, first})
    assert Seat.watch_state(name, "cua_one") == :held
  end

  test "the server letting go closes the hold, by seat or by the watch that waits", %{
    name: name
  } do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    watcher = Task.async(fn -> Seat.watch(name, "cua_one") end)
    await_watcher(name)

    :ok = Seat.close(name, watcher.pid)

    assert Task.await(watcher) == :closed
    assert Seat.watch_state(name, "cua_one") == :gone
    assert Seat.stop(name) == :none
  end

  test "a disturbing action stamps the time courtesy reads; a look does not", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    :ok = Seat.acted(name, "cua_one", "screenshot")
    assert {:ok, %{last_action_at: :never}} = Seat.acquire(name, "cua_one")

    :ok = Seat.acted(name, "cua_one", "left_click")
    assert {:ok, %{last_action_at: at}} = Seat.acquire(name, "cua_one")
    assert is_integer(at)
  end

  test "the helper ending ends the hold without a release", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    watcher = Task.async(fn -> Seat.watch(name, "cua_one") end)
    await_watcher(name)

    send(Process.whereis(name), {:compux_sidecar_exit, self(), 75})

    assert Task.await(watcher) == :helper_exited
    refute_received {:screen_helper_control, :release}
    assert Seat.watch_state(name, "cua_one") == :gone
  end

  test "the helper's own Stop button is the person's Stop", %{name: name} do
    {:ok, _held} = Seat.acquire(name, "cua_one")

    send(
      Process.whereis(name),
      {:compux_session_event, self(), %{"kind" => "indicator", "event" => "operator_stop"}}
    )

    assert {:error, :stopped} = Seat.acquire(name, "cua_one")
  end

  test "each stretch is recorded for the history recorder", %{name: name, home: home} do
    {:ok, _held} = Seat.acquire(name, "cua_one")
    assert Seat.stop(name) == :stopped

    assert {:ok, [%{seat: "cua_one", started_at: started, ended_at: ended, why: :stopped}]} =
             ServerControl.stretches(home)

    assert DateTime.compare(started, ended) in [:lt, :eq]
    assert File.stat!(ServerControl.path(home)).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a helper that will not start is said, and holds nothing", %{home: home} do
    name = :"seat_failing_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Seat,
       name: name,
       driver: fn -> {:error, {:sidecar_unavailable, :not_installed}} end,
       home: home,
       changed: fn -> :ok end},
      id: :failing
    )

    assert {:error, {:helper, {:sidecar_unavailable, :not_installed}}} =
             Seat.acquire(name, "cua_one")

    assert Seat.view(name) == nil
  end

  test "a computer that runs no seat shows no mark" do
    assert Seat.view(:no_seat_runs_here) == nil
  end

  # A helper that takes its time to start: it tells the test, then waits.
  defmodule SlowStart do
    @moduledoc false
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      send(Keyword.fetch!(opts, :test), {:starting, self()})

      receive do
        :go -> {:ok, %{test: Keyword.fetch!(opts, :test)}}
      after
        10_000 -> {:error, :never_let_go}
      end
    end

    @impl true
    def execute(_state, %{"action" => "hello"}),
      do: {:ok, %{"actions" => [], "capabilities" => %{"input_methods" => ["ax"]}}}

    def execute(_state, _request), do: {:ok, %{"ok" => true}}

    @impl true
    def stop(state) do
      send(state.test, :slow_helper_stopped)
      :ok
    end
  end

  # C7: the helper starts beside the seat, so what the app asks meanwhile (the
  # mark, the person's Stop) is answered at once, and a Stop wins.
  test "the mark and Stop answer while the helper starts, and Stop wins", %{home: home} do
    name = :"seat_slow_#{System.unique_integer([:positive])}"
    test = self()

    start_supervised!(
      {Seat,
       name: name,
       driver: fn -> {:ok, {SlowStart, test: test}} end,
       home: home,
       changed: fn -> :ok end,
       timer: fn _message, _delay -> make_ref() end},
      id: :slow
    )

    taking = Task.async(fn -> Seat.acquire(name, "cua_slow") end)
    assert_receive {:starting, starter}
    ref = Process.monitor(starter)

    assert Seat.view(name) == nil
    assert Seat.watch_state(name, "cua_slow") == :held
    assert {:error, {:busy, %DateTime{}}} = Seat.acquire(name, "cua_other")
    assert Seat.stop(name) == :stopped

    assert Task.await(taking) == {:error, :stopped}
    assert_receive {:DOWN, ^ref, :process, ^starter, _reason}
    assert {:error, :stopped} = Seat.acquire(name, "cua_slow")
  end

  test "a helper that starts slowly is answered once it started", %{home: home} do
    name = :"seat_slow_ok_#{System.unique_integer([:positive])}"
    test = self()

    start_supervised!(
      {Seat,
       name: name,
       driver: fn -> {:ok, {SlowStart, test: test}} end,
       home: home,
       changed: fn -> send(test, :screen_changed) end,
       timer: fn _message, _delay -> make_ref() end},
      id: :slow_ok
    )

    taking = Task.async(fn -> Seat.acquire(name, "cua_slow") end)
    again = Task.async(fn -> Seat.acquire(name, "cua_slow") end)
    assert_receive {:starting, starter}
    send(starter, :go)

    assert {:ok, %{driver: {SlowStart, _state}}} = Task.await(taking)
    assert {:ok, %{driver: {SlowStart, _state}}} = Task.await(again)
    assert_receive :screen_changed
    assert %{since: %DateTime{}} = Seat.view(name)
    refute_received {:starting, _second}

    assert Seat.stop(name) == :stopped
    assert_receive :slow_helper_stopped
  end

  # The watch is a call the seat holds: wait until it is held, never for time.
  defp await_watcher(name, attempts \\ 1_000) do
    watchers = :sys.get_state(name).held.watchers

    cond do
      watchers != [] ->
        :ok

      attempts == 0 ->
        flunk("the watch never reached the seat")

      true ->
        # sleep: the seat tells nobody when a watch arrives
        Process.sleep(5)
        await_watcher(name, attempts - 1)
    end
  end
end
