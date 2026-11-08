defmodule FermixChannels.Accessories.LinkReattachTest do
  @moduledoc """
  A link that starts again on a port the accessory already had, and an
  accessory's own `auth_timeout`. A new link process (a daemon restart, a
  replug the accessory did not see, a new pairing link) numbers its control
  frames from 0, while the accessory keeps its receive side's base; a
  control frame with seq 0 starts a new sequence, so the first HELLO is read
  at once instead of waiting out the ten-second attach bound. An accessory
  that refuses `auth_timeout` is greeted again, at the HELLO rate; every other
  refusal still holds the port idle.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.StoreWriter
  alias FermixCore.Accessories.P256
  alias FermixTestSupport.AccessoryBus
  alias FermixTestSupport.AccessoryCase
  alias FermixTestSupport.AccessorySim

  @path "/dev/cu.usbmodem-reattach"

  setup do
    home = AccessoryCase.home!()
    writer = start_supervised!({StoreWriter, home: home, name: nil})
    {clock, now} = AccessoryCase.clock!()
    {public, private} = P256.generate()
    {host, _record} = AccessoryCase.enroll!(home, public)
    sim_opts = [observer: self(), key: {public, private}, enrolled_host: host.public]
    sim = start_supervised!({AccessorySim, sim_opts})
    bus = AccessoryCase.bus!(@path, sim)
    opts = AccessoryCase.link_opts(bus, @path, home, writer, now)
    %{sim: sim, bus: bus, opts: opts, clock: clock}
  end

  test "a new link process on a port the accessory kept is attached on its first HELLO", ctx do
    first = start_supervised!({Link, ctx.opts}, id: :first, restart: :temporary)
    AccessoryCase.await_received(ctx.sim, "hello")
    AccessoryCase.await_received(ctx.sim, "host_proof")
    AccessoryCase.await_state(&(&1.phase == :attached))

    # The first link sent a few control frames; the accessory's base is past 0.
    AccessoryCase.advance(ctx.clock, 5_000)
    send(first, :tick)
    AccessoryCase.await_received(ctx.sim, "ping")
    :ok = stop_supervised(:first)
    assert AccessoryBus.holder(ctx.bus, @path) == nil

    second = start_supervised!({Link, ctx.opts}, id: :second, restart: :temporary)

    assert %{gen: 1} = AccessoryCase.await_received(ctx.sim, "hello")
    AccessoryCase.await_received(ctx.sim, "host_proof")
    AccessoryCase.await_state(&(&1.phase == :attached and &1.gen == 1))
    refute_received {:sim, _sim, {:fault, :control_seq_gap}}
    assert Process.alive?(second)
  end

  test "an accessory's auth_timeout refusal is greeted again, at the HELLO rate", ctx do
    AccessorySim.set(ctx.sim, :silent?, true)
    link = start_supervised!({Link, ctx.opts}, restart: :temporary)
    assert %{gen: 1} = AccessoryCase.await_received(ctx.sim, "hello")
    AccessorySim.set(ctx.sim, :silent?, false)

    AccessorySim.send_message(ctx.sim, %{type: "refuse", code: "auth_timeout"})

    summary = AccessoryCase.await_state(&(&1.refusal == {:accessory, :auth_timeout}))
    assert summary.phase == :hello

    # The HELLO a second ago holds the next one back until the rate allows.
    send(link, :tick)
    _ = Link.status(link)
    refute_received {:sim, _sim, {:received, %{type: "hello", gen: 2}}}

    AccessoryCase.advance(ctx.clock, 1_000)
    send(link, :tick)
    assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
    AccessoryCase.await_state(&(&1.phase == :attached and &1.gen == 2))
  end

  test "the accessory's other refusals still hold the port idle", ctx do
    AccessorySim.set(ctx.sim, :silent?, true)
    link = start_supervised!({Link, ctx.opts}, restart: :temporary)
    AccessoryCase.await_received(ctx.sim, "hello")
    AccessorySim.set(ctx.sim, :silent?, false)

    AccessorySim.send_message(ctx.sim, %{type: "refuse", code: "bad_proof"})
    AccessoryCase.await_state(&(&1.phase == :refused))

    AccessoryCase.advance(ctx.clock, 1_000)
    send(link, :tick)
    _ = Link.status(link)
    refute_received {:sim, _sim, {:received, %{type: "hello", gen: 2}}}
  end
end
