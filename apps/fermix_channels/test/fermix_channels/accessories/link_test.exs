defmodule FermixChannels.Accessories.LinkTest do
  @moduledoc """
  One accessory link against the simulated accessory (M91 E2): attach and its
  refusals in the contract's order, enrollment over the selected port with a
  matching and a mismatching code, receive faults, control errors, the HELLO
  rate, heartbeats and liveness, and forget and revoke. Time is the test's
  clock, moved by hand; every tick is delivered by the test.
  """

  # The attach and fault events are sessionless points pinned on their
  # metadata, which another accessory test module could also emit.
  use ExUnit.Case, async: false

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.StoreWriter
  alias FermixCore.Accessories.Capabilities
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Store
  alias FermixTestSupport.AccessoryBus
  alias FermixTestSupport.AccessoryCase
  alias FermixTestSupport.AccessorySim
  alias FermixTestSupport.TelemetryCapture

  @path "/dev/cu.usbmodem-test"

  setup do
    home = AccessoryCase.home!()
    writer = start_supervised!({StoreWriter, home: home, name: nil})
    {clock, now} = AccessoryCase.clock!()
    %{home: home, writer: writer, clock: clock, now: now}
  end

  # An accessory enrolled with this home's host key, its record in the store.
  defp enrolled(ctx, sim_opts \\ []) do
    {public, private} = P256.generate()
    {host, record} = AccessoryCase.enroll!(ctx.home, public)
    sim_opts = Keyword.merge([key: {public, private}, enrolled_host: host.public], sim_opts)
    Map.merge(ctx, %{host: host, record: record, sim_opts: sim_opts})
  end

  defp start(ctx, link_overrides \\ []) do
    sim = start_supervised!({AccessorySim, [observer: self()] ++ Map.get(ctx, :sim_opts, [])})
    bus = AccessoryCase.bus!(@path, sim)
    opts = AccessoryCase.link_opts(bus, @path, ctx.home, ctx.writer, ctx.now, link_overrides)
    link = start_supervised!({Link, opts}, restart: :temporary)
    Map.merge(ctx, %{sim: sim, bus: bus, link: link})
  end

  # Five seconds on: the host pings, and the accessory's pong is in before
  # the next step (the accessory has answered once `peek` returns, and the
  # link has read it once its status returns).
  defp heartbeat!(ctx) do
    AccessoryCase.advance(ctx.clock, 5_000)
    send(ctx.link, :tick)
    AccessoryCase.await_received(ctx.sim, "ping")
    _ = AccessorySim.peek(ctx.sim)
    Link.status(ctx.link)
  end

  defp attached!(ctx) do
    AccessoryCase.await_received(ctx.sim, "hello")
    AccessoryCase.await_received(ctx.sim, "host_proof")
    AccessoryCase.await_state(&(&1.phase == :attached))
  end

  describe "attach" do
    test "an enrolled accessory attaches with both proofs, and is told voice is ready", ctx do
      # The handler is in before the link starts, so its attach is seen.
      ctx = enrolled(ctx)
      endpoint = "accessory:" <> ctx.record.accessory_id
      TelemetryCapture.attach([[:fermix, :accessory, :attach]], endpoint: endpoint)
      ctx = start(ctx)

      hello = AccessoryCase.await_received(ctx.sim, "hello")
      assert hello.gen == 1
      assert hello.host_id == ctx.host.id
      assert {1, 1} == {hello.wire_min, hello.wire_max}

      AccessoryCase.await_received(ctx.sim, "host_proof")
      summary = AccessoryCase.await_state(&(&1.phase == :attached))
      assert summary.accessory_id == ctx.record.accessory_id
      assert summary.kind == "stackchan"
      assert :mic in summary.caps and :speaker in summary.caps

      assert %{ready: true} = AccessoryCase.await_received(ctx.sim, "voice.readiness")

      assert_receive {:telemetry, [:fermix, :accessory, :attach], %{count: 1},
                      %{status: :attached, mode: :attach, kind: :stackchan}}
    end

    test "voice that is not ready is said with its code, and the link stays attached", ctx do
      ctx = ctx |> enrolled() |> start(readiness: fn -> {:not_ready, "missing_key"} end)
      attached!(ctx)

      assert %{ready: false, code: "missing_key"} =
               AccessoryCase.await_received(ctx.sim, "voice.readiness")
    end

    test "a forgotten accessory is refused unknown_accessory and stays refused", ctx do
      ctx = enrolled(ctx)
      :ok = Store.forget(ctx.home, ctx.record.accessory_id)
      ctx = start(ctx)

      assert %{code: "unknown_accessory"} = AccessoryCase.await_received(ctx.sim, "refuse")
      summary = AccessoryCase.await_state(&(&1.phase == :refused))
      assert summary.refusal == :unknown_accessory
      refute_received {:sim, _sim, {:received, %{type: "host_proof"}}}
    end

    test "a proof that does not verify is refused bad_proof", ctx do
      ctx = ctx |> enrolled(bad_sig?: true) |> start()

      assert %{code: "bad_proof"} = AccessoryCase.await_received(ctx.sim, "refuse")
      assert AccessoryCase.await_state(&(&1.phase == :refused)).refusal == :bad_proof
    end

    test "an accessory that enrolled with another host refuses it, before any signature", ctx do
      {other_public, _other} = P256.generate()
      ctx |> enrolled(enrolled_host: other_public) |> start()

      summary = AccessoryCase.await_state(&(&1.phase == :refused))
      assert summary.refusal == {:accessory, :unknown_host}
      refute_received {:sim, _sim, {:received, %{type: "host_proof"}}}
    end

    test "an accessory without a speaker is refused capability_missing", ctx do
      caps = Capabilities.mask([:mic])
      ctx = ctx |> enrolled(caps: caps) |> start()

      assert %{code: "capability_missing"} = AccessoryCase.await_received(ctx.sim, "refuse")
    end

    test "a wire version outside the host's window is refused with the host's range", ctx do
      ctx = ctx |> enrolled(wire: 2) |> start()

      assert %{code: "wire_version", wire_min: 1, wire_max: 1} =
               AccessoryCase.await_received(ctx.sim, "refuse")
    end

    test "an unenrolled accessory is told apart and may only enroll", ctx do
      start(ctx, mode: :pairing)

      summary = AccessoryCase.await_state(&(&1.phase == :unenrolled))
      assert summary.accessory_id == nil
      assert summary.kind == "stackchan"
    end

    test "with no answer in ten seconds an attach port is greeted again", ctx do
      ctx = ctx |> enrolled(silent?: true) |> start()
      assert %{gen: 1} = AccessoryCase.await_received(ctx.sim, "hello")

      AccessoryCase.advance(ctx.clock, 10_000)
      send(ctx.link, :tick)

      assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
    end

    test "an answer past the ten-second bound is refused auth_timeout and greeted again", ctx do
      ctx = ctx |> enrolled(silent?: true) |> start()
      AccessoryCase.await_received(ctx.sim, "hello")

      AccessoryCase.advance(ctx.clock, 10_001)
      AccessorySim.set(ctx.sim, :silent?, false)

      AccessorySim.send_message(ctx.sim, %{
        type: "hello_ack",
        wire: 1,
        kind: "stackchan",
        accessory_id: nil,
        firmware: "0.1.0",
        pack: nil,
        caps: 3,
        accessory_nonce: :crypto.strong_rand_bytes(32),
        sig: nil
      })

      assert %{code: "auth_timeout"} = AccessoryCase.await_received(ctx.sim, "refuse")
      assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
    end

    test "a selected port that gives no Fermix answer ends the step", ctx do
      ctx = ctx |> Map.put(:sim_opts, silent?: true) |> start(mode: :pairing)
      AccessoryCase.await_received(ctx.sim, "hello")
      ref = Process.monitor(ctx.link)

      AccessoryCase.advance(ctx.clock, 10_000)
      send(ctx.link, :tick)

      assert_receive {:DOWN, ^ref, :process, _link, {:shutdown, :no_answer}}
      assert AccessoryBus.holder(ctx.bus, @path) == nil
    end
  end

  describe "faults and errors" do
    test "a corrupt frame after sync is a fault: reported, and a new HELLO restores the link",
         ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)
      TelemetryCapture.attach([[:fermix, :accessory, :fault]], reason: :crc_mismatch)

      # A whole frame with its CRC broken: synced, so it is a fault.
      frame = "FX" <> <<1, 1, 3, 0, 0::16-little, 99::32-little, 2::32-little, "{}", 0::32>>
      AccessorySim.send_raw(ctx.sim, frame)

      assert_receive {:telemetry, [:fermix, :accessory, :fault], %{count: 1},
                      %{reason: :crc_mismatch, stage: :receive}}

      AccessoryCase.advance(ctx.clock, 1_000)
      send(ctx.link, :tick)
      assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
      assert AccessoryCase.await_state(&(&1.phase == :attached)).gen == 2
    end

    test "the host sends at most one hello a second, however many faults arrive", ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)
      bad = "FX" <> <<1, 1, 3, 0, 0::16-little, 99::32-little, 2::32-little, "{}", 0::32>>

      # The first fault re-greets at once: the attach's hello was a second ago.
      AccessoryCase.advance(ctx.clock, 1_000)
      AccessorySim.send_raw(ctx.sim, bad)
      assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
      AccessoryCase.await_state(&(&1.phase == :attached and &1.gen == 2))

      # A second fault at once waits for the next second.
      AccessorySim.send_raw(ctx.sim, bad)
      AccessoryCase.await_state(&(&1.phase == :hello))
      send(ctx.link, :tick)
      refute_received {:sim, _sim, {:received, %{type: "hello", gen: 3}}}

      AccessoryCase.advance(ctx.clock, 1_000)
      send(ctx.link, :tick)
      assert %{gen: 3} = AccessoryCase.await_received(ctx.sim, "hello")
    end

    test "a message outside the accessory's set is answered unknown_message and acted on by neither",
         ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)

      AccessorySim.send_payload(ctx.sim, 0, ~s({"type":"teleport","gen":1}))

      assert %{code: "unknown_message", message_type: "teleport"} =
               AccessoryCase.await_received(ctx.sim, "error")

      AccessorySim.send_payload(ctx.sim, 0, "not json")
      assert %{code: "invalid_message"} = AccessoryCase.await_received(ctx.sim, "error")
      summary = AccessoryCase.await_state(&(&1.counters.control_errors[:invalid_json] == 1))
      assert summary.phase == :attached
    end

    test "a call request before the accessory attached is answered not_now", ctx do
      ctx = start(ctx, mode: :pairing)
      AccessoryCase.await_state(&(&1.phase == :unenrolled))

      AccessorySim.request_call(ctx.sim)

      assert %{code: "not_now", message_type: "call.request"} =
               AccessoryCase.await_received(ctx.sim, "error")
    end
  end

  describe "heartbeat and liveness" do
    test "outside a call the host pings every five seconds, and a peer that answers stays",
         ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)

      AccessoryCase.advance(ctx.clock, 5_000)
      send(ctx.link, :tick)
      AccessoryCase.await_received(ctx.sim, "ping")

      AccessoryCase.advance(ctx.clock, 5_000)
      send(ctx.link, :tick)
      AccessoryCase.await_received(ctx.sim, "ping")
      assert Link.status(ctx.link).phase == :attached
    end

    test "fifteen seconds with no frame from the peer is link loss, and a new HELLO", ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)
      TelemetryCapture.attach([[:fermix, :accessory, :fault]], reason: :link_lost)
      AccessorySim.set(ctx.sim, :silent?, true)

      for _ <- 1..3 do
        AccessoryCase.advance(ctx.clock, 5_000)
        send(ctx.link, :tick)
      end

      assert_receive {:telemetry, [:fermix, :accessory, :fault], _count,
                      %{reason: :link_lost, stage: :liveness}}

      assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
    end
  end

  describe "enrollment over the selected port" do
    test "matching codes enroll the accessory, write its record, and it attaches", ctx do
      ctx = start(ctx, mode: :pairing)
      AccessoryCase.await_state(&(&1.phase == :unenrolled))
      sim = ctx.sim

      assert :ok = Link.enroll_begin(ctx.link)
      begin = AccessoryCase.await_received(sim, "enroll.begin")
      assert begin.round == 1
      assert {:ok, host} = Store.load_host_key(ctx.home)
      assert begin.host_pk == host.public

      AccessoryCase.await_received(sim, "enroll.reveal")
      assert_receive {:sim, ^sim, {:code, code}}
      assert AccessoryCase.await_state(&(&1.enrollment[:code] != nil)).enrollment.code == code

      # The owner confirms in the app first; nothing commits until the
      # accessory's own confirmation arrives too.
      assert :ok = Link.enroll_confirm(ctx.link)
      refute_received {:sim, ^sim, {:received, %{type: "enroll.commit"}}}
      AccessorySim.confirm_match(sim)

      AccessoryCase.await_received(sim, "enroll.commit")
      id = AccessorySim.accessory_id(sim)
      AccessoryCase.await_state(&(&1.enrollment.phase == :done))

      # At most one hello a second: the attach's greets on the next tick.
      AccessoryCase.advance(ctx.clock, 1_000)
      send(ctx.link, :tick)
      AccessoryCase.await_state(&(&1.phase == :attached and &1.accessory_id == id))

      assert {:ok, [record]} = Store.list(ctx.home)
      assert record.accessory_id == id
      assert record.port_hint == AccessoryCase.serial()
      assert record.name == "StackChan"
    end

    test "three mismatched rounds close the attempt with mismatch_limit and write nothing",
         ctx do
      ctx = start(ctx, mode: :pairing)
      AccessoryCase.await_state(&(&1.phase == :unenrolled))
      :ok = Link.enroll_begin(ctx.link)

      for round <- 1..3 do
        assert %{round: ^round} = AccessoryCase.await_received(ctx.sim, "enroll.begin")
        AccessoryCase.await_received(ctx.sim, "enroll.reveal")
        assert :ok = Link.enroll_mismatch(ctx.link)
      end

      assert %{reason: "mismatch_limit"} = AccessoryCase.await_received(ctx.sim, "enroll.cancel")
      assert {:ok, []} = Store.list(ctx.home)
      refute_received {:sim, _sim, {:received, %{type: "enroll.commit"}}}
    end

    test "an attempt left open two minutes is cancelled expired", ctx do
      ctx = start(ctx, mode: :pairing)
      AccessoryCase.await_state(&(&1.phase == :unenrolled))
      :ok = Link.enroll_begin(ctx.link)
      AccessoryCase.await_received(ctx.sim, "enroll.reveal")

      # Two minutes of ticks, the accessory answering every ping meanwhile.
      for _ <- 1..24, do: heartbeat!(ctx)

      assert %{reason: "expired"} = AccessoryCase.await_received(ctx.sim, "enroll.cancel")
      assert {:ok, []} = Store.list(ctx.home)
    end

    test "enrollment is refused on a port the owner did not select", ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)
      assert {:error, :not_pairing} = Link.enroll_begin(ctx.link)
    end
  end

  describe "forget and revoke" do
    test "forget tells the accessory, erases the record, and the accessory reads as unenrolled",
         ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)

      assert :ok = Link.forget(ctx.link)
      AccessoryCase.await_received(ctx.sim, "accessory.forget")
      assert {:ok, []} = Store.list(ctx.home)
      AccessoryCase.advance(ctx.clock, 1_000)
      send(ctx.link, :tick)
      assert %{gen: 2} = AccessoryCase.await_received(ctx.sim, "hello")
      AccessoryCase.await_state(&(&1.phase == :unenrolled))
    end

    test "revoke erases the record only, so the accessory's next attach is refused", ctx do
      ctx = ctx |> enrolled() |> start()
      attached!(ctx)

      assert :ok = Link.revoke(ctx.link)
      assert {:ok, []} = Store.list(ctx.home)
      AccessoryCase.advance(ctx.clock, 1_000)
      send(ctx.link, :tick)
      assert %{code: "unknown_accessory"} = AccessoryCase.await_received(ctx.sim, "refuse")
      refute_received {:sim, _sim, {:received, %{type: "accessory.forget"}}}
    end
  end
end
