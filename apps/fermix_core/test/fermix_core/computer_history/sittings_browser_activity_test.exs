defmodule FermixCore.ComputerHistory.SittingsBrowserActivityTest do
  # M97 §8.7, D11: while a turn on the server uses this computer's browser
  # (a turn this computer holds, `Browser.HeldTurn`), the events the recorder
  # sees are Fermix's own, as they are while the server drives its screen; the
  # sitting marks them, so the summary never reports the agent's clicks as the
  # owner's. The stretch is the held turn's own life: the listener records it,
  # with a clock that tells the test each time it writes.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HeldTurn
  alias FermixCore.Browser.HeldTurnListener
  alias FermixCore.ComputerHistory.Sittings
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse.ServerControl
  alias FermixTestSupport.SafeRm

  @t0 ~U[2026-11-11 09:00:00.000Z]

  setup do
    home = SafeRm.make_tmp_dir!("sittings_browser_activity")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    spool = start_supervised!({Spool, path: Spool.path(home), name: nil})

    n = System.unique_integer([:positive])

    turns = %{
      registry: :"browser_activity_turns_#{n}",
      supervisor: :"browser_activity_turn_sup_#{n}",
      listener: :"browser_activity_listener_#{n}"
    }

    start_supervised!({Registry, keys: :unique, name: turns.registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: turns.supervisor})
    clock = start_supervised!({Agent, fn -> at(0) end})
    test = self()

    listener =
      start_supervised!(
        {HeldTurnListener,
         name: turns.listener,
         turns: turns,
         home: home,
         switches: fn -> Switches.only([:browser]) end,
         clock: fn ->
           now = Agent.get(clock, & &1)
           send(test, {:recorded, now})
           now
         end}
      )

    %{home: home, spool: spool, turns: turns, clock: clock, listener: listener}
  end

  defp at(minutes), do: DateTime.add(@t0, minutes, :minute)

  defp field(seq, minutes, text) do
    %{
      boot_id: "b",
      source_seq: seq,
      ts: DateTime.to_unix(at(minutes), :millisecond),
      type: "field.value",
      bundle_id: "com.example.notes",
      field_label: "Body",
      text: text
    }
  end

  defp send_sittings(ctx) do
    test_pid = self()

    uplink = fn payload ->
      send(test_pid, {:sent, payload})
      {:ok, %{status: :summarized, reason: nil, intervals: []}}
    end

    Sittings.run(
      uplink: uplink,
      spool: ctx.spool,
      home: ctx.home,
      now: at(60),
      timezone: "Etc/UTC",
      config: [enabled: true]
    )
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.filter(&(&1 =~ "field.value"))

  test "an event stamped while a server turn held this browser is marked as Fermix's own", ctx do
    [two, four] = [at(2), at(4)]
    Agent.update(ctx.clock, fn _now -> two end)

    held =
      HeldTurn.run(
        ctx.turns,
        %{session: "main-81", conversation: "owner-b3du", worker?: false},
        fn -> self() end
      )

    assert_receive {:recorded, ^two}

    ref = Process.monitor(held)
    Agent.update(ctx.clock, fn _now -> four end)
    :ok = HeldTurn.finish(ctx.turns, "main-81", "ended")
    assert_receive {:DOWN, ^ref, :process, ^held, :normal}
    assert_receive {:recorded, ^four}
    _state = :sys.get_state(ctx.listener)

    events = [
      field(1, 1, "owner wrote the packing list"),
      field(2, 3, "the agent filled the booking form"),
      field(3, 5, "owner wrote again")
    ]

    {:ok, 3} = Spool.insert_events(events, server: ctx.spool)

    assert {:ok, %{sent: 1}} = send_sittings(ctx)
    assert_received {:sent, %{"text" => text}}

    [owner, agent, again] = lines(text)
    refute owner =~ "by=fermix"
    assert agent =~ "by=fermix"
    refute again =~ "by=fermix"
  end

  test "the screen's stretches still mark beside the browser's", ctx do
    :ok = ServerControl.started(ctx.home, "cua_x3", at(6))
    :ok = ServerControl.ended(ctx.home, "cua_x3", at(8), :closed)
    :ok = ServerControl.browser_started(ctx.home, at(2))
    :ok = ServerControl.browser_ended(ctx.home, at(4), :closed)

    events = [
      field(1, 3, "the agent searched for trains"),
      field(2, 5, "owner read the reply"),
      field(3, 7, "the agent clicked through the screen")
    ]

    {:ok, 3} = Spool.insert_events(events, server: ctx.spool)

    assert {:ok, %{sent: 1}} = send_sittings(ctx)
    assert_received {:sent, %{"text" => text}}

    [browser, owner, screen] = lines(text)
    assert browser =~ "by=fermix"
    refute owner =~ "by=fermix"
    assert screen =~ "by=fermix"
  end
end
