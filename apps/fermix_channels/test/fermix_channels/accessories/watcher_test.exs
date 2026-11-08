defmodule FermixChannels.Accessories.WatcherTest do
  @moduledoc """
  The port watcher (M91 §05): it enumerates the USB-Serial-JTAG ports
  (303A:1001) on a poll the test delivers, opens only the port the owner
  selected for pairing or one whose USB serial string an enrolled
  accessory's hint names, tells a busy port, an unrelated 303A:1001 device
  and a vanished port apart, retries a busy port five times (1, 2, 4, 8 and
  15 s apart) and then waits for Retry, and releases a port for a firmware
  update until Reconnect.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.StoreWriter
  alias FermixChannels.Accessories.Watcher
  alias FermixCore.Accessories.P256
  alias FermixTestSupport.AccessoryBus
  alias FermixTestSupport.AccessoryCase
  alias FermixTestSupport.AccessoryMemoryTransport
  alias FermixTestSupport.AccessorySim

  @robot "/dev/cu.usbmodem21101"
  @other "/dev/cu.usbmodem31201"

  setup do
    home = AccessoryCase.home!()
    writer = start_supervised!({StoreWriter, home: home, name: nil})
    {clock, now} = AccessoryCase.clock!()
    links = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :links)
    bus = start_supervised!(AccessoryBus)
    test = self()

    opts = [
      name: nil,
      transport: AccessoryMemoryTransport,
      transport_opts: [bus: bus],
      home: home,
      link_supervisor: links,
      clock: now,
      send_after: fn _dest, message, ms -> send(test, {:scheduled, message, ms}) && make_ref() end,
      observer: test,
      link_opts: [
        store_writer: writer,
        clock: now,
        send_after: fn _dest, _message, _ms -> make_ref() end,
        readiness: fn -> :ready end
      ]
    ]

    %{home: home, writer: writer, clock: clock, now: now, bus: bus, watcher_opts: opts}
  end

  defp watcher(ctx), do: start_supervised!({Watcher, ctx.watcher_opts})

  defp poll(watcher) do
    send(watcher, :poll)
    Watcher.status(watcher)
  end

  defp port(status, path), do: Enum.find(status.ports, &(&1.path == path))

  defp attached?(%{state: :linked, link: %{phase: :attached}}), do: true
  defp attached?(_entry), do: false

  defp enrolled_sim(ctx, opts \\ []) do
    {public, private} = P256.generate()
    {host, record} = AccessoryCase.enroll!(ctx.home, public, opts)

    sim =
      start_supervised!(
        {AccessorySim, observer: self(), key: {public, private}, enrolled_host: host.public}
      )

    {sim, record}
  end

  # Waits for the watcher to show `path` in a state `match` accepts.
  defp await_port(watcher, path, match, tries \\ 50) do
    status = Watcher.status(watcher)

    cond do
      match.(port(status, path)) ->
        port(status, path)

      tries == 0 ->
        flunk(
          "#{path} never reached the state the test waits for: #{inspect(port(status, path))}"
        )

      true ->
        await_change(watcher, path, match, tries)
    end
  end

  defp await_change(watcher, path, match, tries) do
    receive do
      {:watcher_changed, ^watcher} -> await_port(watcher, path, match, tries - 1)
    after
      2_000 -> await_port(watcher, path, match, 0)
    end
  end

  test "a port whose serial an enrolled accessory's hint names is opened and attaches", ctx do
    {sim, record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    w = watcher(ctx)

    poll(w)
    AccessoryCase.await_received(sim, "host_proof")
    entry = await_port(w, @robot, &attached?/1)
    assert entry.link.accessory_id == record.accessory_id
    assert entry.serial == AccessoryCase.serial()
  end

  test "another 303A:1001 device is unrelated and never opened; other vendors are not listed",
       ctx do
    AccessoryBus.plug(ctx.bus, @other, serial: "11:22:33:44:55:66")
    AccessoryBus.plug(ctx.bus, "/dev/cu.Bluetooth-Incoming-Port", vendor_id: nil, product_id: nil)
    w = watcher(ctx)

    status = poll(w)
    assert port(status, @other).state == :unrelated
    assert port(status, "/dev/cu.Bluetooth-Incoming-Port") == nil
    assert AccessoryBus.holder(ctx.bus, @other) == nil
  end

  test "a busy port is retried five times, 1, 2, 4, 8 and 15 s apart, then waits for Retry",
       ctx do
    {sim, _record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim, busy?: true)
    w = watcher(ctx)

    poll(w)

    for delay <- [1_000, 2_000, 4_000, 8_000, 15_000] do
      assert_receive {:scheduled, {:retry_open, @robot}, ^delay}
      assert await_port(w, @robot, &(&1.state == :busy)).busy.waiting?
      send(w, {:retry_open, @robot})
    end

    entry = await_port(w, @robot, &(&1.state == :busy and not &1.busy.waiting?))
    assert entry.busy.attempts == 6
    refute_receive {:scheduled, {:retry_open, @robot}, _delay}, 100

    # Polls do not reopen a port that gave up; the owner's Retry does.
    poll(w)
    assert port(Watcher.status(w), @robot).state == :busy
    AccessoryBus.set_busy(ctx.bus, @robot, false)
    assert :ok = Watcher.retry(w, @robot)
    AccessoryCase.await_received(sim, "host_proof")
  end

  test "an unplugged port reads as vanished, and plugged back it attaches again", ctx do
    {sim, _record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    w = watcher(ctx)
    poll(w)
    await_port(w, @robot, &attached?/1)

    AccessoryBus.unplug(ctx.bus, @robot)
    await_port(w, @robot, &(&1.state == :vanished))
    assert port(poll(w), @robot).state == :vanished

    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    poll(w)
    await_port(w, @robot, &attached?/1)
  end

  test "a port the owner selects is opened for pairing; one that gives no answer ends the step",
       ctx do
    silent = start_supervised!({AccessorySim, observer: self(), silent?: true})
    AccessoryBus.plug(ctx.bus, @other, serial: "11:22:33:44:55:66", peer: silent)
    w = watcher(ctx)
    poll(w)

    assert {:error, :not_present} = Watcher.pair(w, "/dev/cu.nothing")
    assert :ok = Watcher.pair(w, @other)
    AccessoryCase.await_received(silent, "hello")
    entry = await_port(w, @other, &(&1.state == :linked and &1.link != nil))
    assert entry.link.mode == :pairing

    AccessoryCase.advance(ctx.clock, 10_000)
    send(entry.pid, :tick)
    assert await_port(w, @other, &(&1.state == :no_answer))
    assert port(poll(w), @other).state == :no_answer
  end

  # Once a pairing commits, the port is an enrolled accessory's: a replug
  # reopens it by its hint, where a slow first answer is greeted again rather
  # than ending a pairing step that is long over.
  test "after a pairing commits, a replugged port reopens as the enrolled accessory's", ctx do
    sim = start_supervised!({AccessorySim, observer: self()})
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    w = watcher(ctx)
    poll(w)

    assert :ok = Watcher.pair(w, @robot)

    entry =
      await_port(
        w,
        @robot,
        &(&1.state == :linked and &1.link != nil and &1.link.phase == :unenrolled)
      )

    :ok = Link.enroll_begin(entry.pid)
    AccessoryCase.await_received(sim, "enroll.reveal")
    AccessorySim.confirm_match(sim)
    :ok = Link.enroll_confirm(entry.pid)
    AccessoryCase.await_received(sim, "enroll.commit")
    AccessoryCase.advance(ctx.clock, 1_000)
    send(entry.pid, :tick)
    await_port(w, @robot, &attached?/1)

    AccessoryBus.unplug(ctx.bus, @robot)
    await_port(w, @robot, &(&1.state == :vanished))
    AccessorySim.set(sim, :silent?, true)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    poll(w)

    reopened = await_port(w, @robot, &(&1.state == :linked and &1.link != nil))
    assert reopened.link.mode == :attach
    AccessoryCase.await_received(sim, "hello")
    AccessoryCase.advance(ctx.clock, 10_000)
    send(reopened.pid, :tick)
    AccessoryCase.await_received(sim, "hello")
    assert port(Watcher.status(w), @robot).state == :linked
  end

  test "release for a firmware update closes the port and ignores it until Reconnect", ctx do
    {sim, _record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    w = watcher(ctx)
    poll(w)
    await_port(w, @robot, &attached?/1)

    assert :ok = Watcher.release(w, @robot)
    assert port(Watcher.status(w), @robot).state == :released
    assert AccessoryBus.holder(ctx.bus, @robot) == nil
    assert port(poll(w), @robot).state == :released
    assert AccessoryBus.holder(ctx.bus, @robot) == nil

    # Pairing a released port is refused by name: Reconnect comes first.
    assert {:error, :released} = Watcher.pair(w, @robot)
    assert port(Watcher.status(w), @robot).state == :released
    assert AccessoryBus.holder(ctx.bus, @robot) == nil

    assert :ok = Watcher.reconnect(w, @robot)
    await_port(w, @robot, &attached?/1)
  end

  test "every port that goes reads as vanished, whatever it read before, and a bounded few are kept",
       ctx do
    {sim, _record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    AccessoryBus.plug(ctx.bus, @other, serial: "11:22:33:44:55:66")
    w = watcher(ctx)
    poll(w)
    await_port(w, @robot, &attached?/1)
    :ok = Watcher.release(w, @robot)
    assert port(Watcher.status(w), @other).state == :unrelated

    AccessoryBus.unplug(ctx.bus, @robot)
    AccessoryBus.unplug(ctx.bus, @other)
    status = poll(w)
    assert port(status, @robot).state == :vanished
    assert port(status, @other).state == :vanished

    # Released is kept by the serial string: plugged back, it stays released.
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    assert port(poll(w), @robot).state == :released

    for n <- 1..20, do: AccessoryBus.plug(ctx.bus, "/dev/cu.usbmodem9#{n}", serial: "AA:#{n}")
    poll(w)
    for n <- 1..20, do: AccessoryBus.unplug(ctx.bus, "/dev/cu.usbmodem9#{n}")
    status = poll(w)

    assert Enum.count(status.ports, &(&1.state == :vanished)) == 16
    assert port(status, @robot).state == :released

    # With nothing attached at all, the bound still holds.
    for n <- 21..40, do: AccessoryBus.plug(ctx.bus, "/dev/cu.usbmodem9#{n}", serial: "AA:#{n}")
    poll(w)
    AccessoryBus.unplug(ctx.bus, @robot)
    for n <- 21..40, do: AccessoryBus.unplug(ctx.bus, "/dev/cu.usbmodem9#{n}")
    assert length(poll(w).ports) == 16
  end

  test "a link that crashes takes down no other link, and its port is opened again", ctx do
    {sim, _record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    w = watcher(ctx)
    poll(w)
    entry = await_port(w, @robot, &attached?/1)

    Process.exit(entry.pid, :kill)
    await_port(w, @robot, &(&1.state != :linked or &1.pid != entry.pid))
    poll(w)
    reopened = await_port(w, @robot, &attached?/1)
    assert reopened.pid != entry.pid
    assert Process.alive?(w)
  end

  # A build without the serial helper fails every poll the same way: the
  # watcher says so once, not every two seconds.
  test "polls with the serial helper missing log one line, not one a poll", ctx do
    opts =
      Keyword.merge(ctx.watcher_opts,
        transport: FermixChannels.Accessories.Serial,
        transport_opts: [helper_path: "/nonexistent/fermix_serial", os_type: {:unix, :darwin}]
      )

    w = start_supervised!({Watcher, opts}, id: :serial_watcher)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        poll(w)
        poll(w)
      end)

    assert log |> String.split("fermix_serial helper is not in this build") |> length() == 2
  end

  test "an accessory is found by its ID for the commands E3 sends", ctx do
    {sim, record} = enrolled_sim(ctx)
    AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
    w = watcher(ctx)
    poll(w)
    await_port(w, @robot, &attached?/1)

    assert {:ok, link} = Watcher.link_for(w, record.accessory_id)
    assert Link.status(link).accessory_id == record.accessory_id
    assert Watcher.link_for(w, String.duplicate("0", 64)) == {:error, :not_attached}
  end

  # M91 E3: what `accessories.status` and its long poll read.
  describe "the view the Mac reads" do
    test "a subscriber is told each change, and a touch, with the version", ctx do
      w = watcher(ctx)
      # Fable review 1: the first word comes with the subscribe, as
      # `Home.StatusWatch.join/2`'s does, so a change made before it is heard.
      assert {:ok, ^w} = Watcher.subscribe(w, self())
      assert_receive {:accessories_changed, first}

      AccessoryBus.plug(ctx.bus, @other, serial: "11:22:33:44:55:66")
      poll(w)
      assert_receive {:accessories_changed, version}
      assert version > first

      assert :ok = Watcher.touch(w)
      assert_receive {:accessories_changed, touched}
      assert touched == version + 1

      assert :ok = Watcher.unsubscribe(w, self())
      assert :ok = Watcher.touch(w)
      refute_received {:accessories_changed, _version}
    end

    # Fable review 4: Release for firmware update waits for the robot's call
    # to end (PROTOCOL.md: "End the call first.").
    test "a port whose link carries a call is not released", ctx do
      {sim, _record} = enrolled_sim(ctx)
      AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
      w = watcher(ctx)
      poll(w)
      entry = await_port(w, @robot, &attached?/1)

      call = %{call_id: "voice-1", stream: 1, source: :mac, phase: :active, view: nil}
      send(w, {:link_view, @robot, entry.pid, %{entry.link | call: call}})
      await_port(w, @robot, &match?(%{link: %{call: %{}}}, &1))

      assert {:error, :call_active} = Watcher.release(w, @robot)
      assert port(Watcher.status(w), @robot).state == :linked
      assert AccessoryBus.holder(ctx.bus, @robot) != nil
    end

    test "cancelling pairing closes the selected port and clears the choice", ctx do
      sim = start_supervised!({AccessorySim, observer: self()})
      AccessoryBus.plug(ctx.bus, @robot, serial: "11:22:33:44:55:66", peer: sim)
      w = watcher(ctx)
      poll(w)

      assert :ok = Watcher.pair(w, @robot)
      await_port(w, @robot, &(&1.state == :linked and &1.link != nil))
      assert Watcher.status(w).selected == @robot

      assert :ok = Watcher.cancel_pairing(w, @robot)
      status = Watcher.status(w)
      assert status.selected == nil
      assert port(status, @robot).state == :unrelated
      assert AccessoryBus.holder(ctx.bus, @robot) == nil
    end

    test "voice readiness is read at each poll, so a change of it moves the view", ctx do
      {:ok, voice} = Agent.start_link(fn -> :ready end)

      opts =
        put_in(ctx.watcher_opts, [:link_opts, :readiness], fn -> Agent.get(voice, & &1) end)

      w = start_supervised!({Watcher, opts}, id: :voice_watcher)
      assert poll(w).voice == :ready
      version = Watcher.status(w).version

      Agent.update(voice, fn _ -> {:not_ready, "restart_required"} end)
      status = poll(w)
      assert status.voice == {:not_ready, "restart_required"}
      assert status.version > version
    end

    test "a link that goes with a call on it leaves how the call ended", ctx do
      {sim, record} = enrolled_sim(ctx)
      AccessoryBus.plug(ctx.bus, @robot, serial: AccessoryCase.serial(), peer: sim)
      w = watcher(ctx)
      poll(w)
      entry = await_port(w, @robot, &attached?/1)

      # The link's own view with a call on it, as a call publishes it.
      call = %{call_id: "voice-1", stream: 1, source: :screen_tap, phase: :active, view: nil}
      send(w, {:link_view, @robot, entry.pid, %{entry.link | call: call}})
      await_port(w, @robot, &match?(%{link: %{call: %{call_id: "voice-1"}}}, &1))

      AccessoryBus.unplug(ctx.bus, @robot)
      await_port(w, @robot, &(&1.state == :vanished))

      assert %{call_id: "voice-1", reason: "unplugged", ended_at: %DateTime{}} =
               Watcher.status(w).last_calls[record.accessory_id]
    end
  end
end
