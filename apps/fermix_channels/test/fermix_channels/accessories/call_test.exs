defmodule FermixChannels.Accessories.CallTest do
  @moduledoc """
  Accessory calls end to end (M91 E2): the simulated accessory, its link, the
  per-call process and the shared voice core (`CallClient` under a real
  `SessionGuard` and one call lease), with an engine session double. A tap
  starts a call, the microphone becomes the engine's 100 ms chunks, the
  engine's audio goes out within credit and the segment rules, mute,
  interrupt, flush and drain each reach the right side, a call-ending fault
  ends it cleanly, an unplug frees the lease, a desktop and an accessory
  starting at once open exactly one session, and OpenAI Realtime's tool
  batches become one task each.
  """

  # The call's link event and the lease are observed across processes.
  use ExUnit.Case, async: false

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.StoreWriter
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Store
  alias FermixCore.Realtime.CallClient
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionGuard
  alias FermixTestSupport.AccessoryBus
  alias FermixTestSupport.AccessoryCase
  alias FermixTestSupport.AccessoryEngine
  alias FermixTestSupport.AccessorySim
  alias FermixTestSupport.CallLeases
  alias FermixTestSupport.TelemetryCapture

  @path "/dev/cu.usbmodem-call"

  setup do
    home = AccessoryCase.home!()
    writer = start_supervised!({StoreWriter, home: home, name: nil})
    {clock, now} = AccessoryCase.clock!()
    unique = System.unique_integer([:positive])
    tasks = start_supervised!({Task.Supervisor, name: :"accessory_call_tasks_#{unique}"})
    guard = :"accessory_call_guard_#{unique}"
    start_supervised!({SessionGuard, name: guard, task_supervisor: tasks})
    lease = CallLeases.own!()

    %{
      home: home,
      writer: writer,
      clock: clock,
      now: now,
      tasks: tasks,
      guard: guard,
      lease: lease
    }
  end

  defp attached(ctx, opts \\ []) do
    engine = Keyword.get(opts, :engine, "openai_realtime")
    {public, private} = P256.generate()
    {host, record} = AccessoryCase.enroll!(ctx.home, public, Keyword.take(opts, [:selected]))
    sim_opts = [observer: self(), key: {public, private}, enrolled_host: host.public]
    sim = start_supervised!({AccessorySim, sim_opts ++ Keyword.get(opts, :sim, [])})
    bus = AccessoryCase.bus!(@path, sim)

    call_opts = [
      config: Config.normalize(enabled: true, engine: engine),
      session_module: AccessoryEngine,
      session_starter: AccessoryEngine.starter(self(), lease: ctx.lease, engine: engine),
      session_guard: ctx.guard,
      task_supervisor: ctx.tasks,
      clock: ctx.now
    ]

    link_opts =
      AccessoryCase.link_opts(bus, @path, ctx.home, ctx.writer, ctx.now,
        call_opts: call_opts,
        readiness: Keyword.get(opts, :readiness, fn -> :ready end)
      )

    link = start_supervised!({Link, link_opts}, restart: :temporary)
    AccessoryCase.await_received(sim, "host_proof")
    AccessoryCase.await_state(&(&1.phase == :attached))
    Map.merge(ctx, %{sim: sim, bus: bus, link: link, record: record, engine: engine})
  end

  # A tap, admitted: the session's started, and the accessory listens.
  defp call_up(ctx, source \\ "screen_tap") do
    request = AccessorySim.request_call(ctx.sim, source)

    assert %{request: ^request, result: "accepted"} =
             AccessoryCase.await_received(ctx.sim, "call.result")

    start = AccessoryCase.await_received(ctx.sim, "call.start")
    assert_receive {:engine_started, session, session_opts}
    assert %{state: "connecting"} = AccessoryCase.await_received(ctx.sim, "call.state")
    assert %{state: "listening"} = AccessoryCase.await_received(ctx.sim, "call.state")

    Map.merge(ctx, %{
      session: session,
      session_opts: session_opts,
      stream: start.stream,
      call_id: start.call
    })
  end

  defp audio(bytes),
    do: %{type: "audio_delta", audio: Base.encode64(:binary.copy(<<7, 0>>, div(bytes, 2)))}

  defp pcm_received(sim, wanted, got \\ 0)
  defp pcm_received(_sim, wanted, got) when got >= wanted, do: got

  defp pcm_received(sim, wanted, got) do
    receive do
      {:sim, ^sim, {:pcm, pcm}} -> pcm_received(sim, wanted, got + byte_size(pcm))
    after
      2_000 -> flunk("the accessory got #{got} of #{wanted} speaker bytes")
    end
  end

  defp no_violation(sim), do: refute_received({:sim, ^sim, {:violation, _code}})

  # Waits for the session to end and for the lease it held to be free.
  defp session_gone(session, lease) do
    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}
    assert CallLease.holder(lease) == :none
  end

  describe "starting a call" do
    test "a tap starts the call through the shared voice core, as the accessory's endpoint",
         ctx do
      ctx = ctx |> attached() |> call_up()

      assert Keyword.fetch!(ctx.session_opts, :endpoint) == {:accessory, ctx.record.accessory_id}
      assert Keyword.fetch!(ctx.session_opts, :session_scope) == ctx.call_id
      assert ctx.stream == 1
      assert {:ok, %{endpoint: "accessory:" <> _}} = CallLease.holder(ctx.lease)
    end

    # M91 E3: the Mac's start answers at once, inside any client's timeout;
    # the call's admission and its id then show in the link's own view, which
    # the app's status long poll reads.
    test "a start from the Mac answers at once, and its admission shows in the link's view",
         ctx do
      ctx = attached(ctx)

      assert {:ok, %{stream: 1}} = Link.start_call(ctx.link)
      assert %{stream: 1, call: call_id} = AccessoryCase.await_received(ctx.sim, "call.start")
      refute_received {:sim, _sim, {:received, %{type: "call.result"}}}

      assert %{call: %{call_id: ^call_id, phase: :active, source: :mac}} =
               AccessoryCase.await_state(&match?(%{call: %{phase: :active}}, &1))
    end

    test "a start from the Mac the home's call lease refuses says why in the link's view", ctx do
      ctx = attached(ctx)
      desktop = desktop_call(ctx)
      assert_receive {:desktop, ^desktop, :started}

      assert {:ok, %{stream: 1}} = Link.start_call(ctx.link)

      assert %{call: nil, last_call: %{reason: "call_in_progress"}} =
               AccessoryCase.await_state(&match?(%{last_call: %{}}, &1))

      refute_received {:sim, _sim, {:received, %{type: "call.start"}}}
    end

    # M91 §07: a tap on a paired robot that is not the voice device is refused
    # with its own reason and never changes the choice; the Mac's start is the
    # owner's own act on it, so it is not.
    test "a tap on an accessory that is not the voice device is refused not_selected", ctx do
      ctx = attached(ctx, selected: false)

      request = AccessorySim.request_call(ctx.sim)

      assert %{request: ^request, result: "refused", code: "not_selected"} =
               AccessoryCase.await_received(ctx.sim, "call.result")

      refute_received {:engine_started, _session, _opts}
      assert {:ok, %{stream: 1}} = Link.start_call(ctx.link)
      AccessoryCase.await_received(ctx.sim, "call.start")
    end

    # Fable review 3: a choice that cannot be read is no choice of this robot;
    # the tap is refused with its own reason, never read as chosen or not.
    test "a tap while the voice device cannot be read is refused voice_device_unreadable", ctx do
      ctx = attached(ctx)
      path = Store.voice_device_path(ctx.home)
      File.write!(path, "not json")
      File.chmod!(path, 0o600)

      request = AccessorySim.request_call(ctx.sim)

      assert %{request: ^request, result: "refused", code: "voice_device_unreadable"} =
               AccessoryCase.await_received(ctx.sim, "call.result")

      refute_received {:engine_started, _session, _opts}
    end

    test "an accessory short of power is refused power_too_low, from a tap and from the Mac",
         ctx do
      ctx = attached(ctx)

      AccessorySim.send_message(ctx.sim, %{
        type: "accessory.state",
        battery: 4,
        power: "low",
        brownout: true,
        volume: 60,
        brightness: 70,
        motion: "off",
        calibration: "valid"
      })

      AccessoryCase.await_state(&match?(%{accessory_state: %{power: "low"}}, &1))
      request = AccessorySim.request_call(ctx.sim)

      assert %{request: ^request, code: "power_too_low"} =
               AccessoryCase.await_received(ctx.sim, "call.result")

      assert {:error, {:refused, "power_too_low"}} = Link.start_call(ctx.link)
      refute_received {:engine_started, _session, _opts}
    end

    test "voice that is not ready is refused before any session, with its code", ctx do
      ctx = attached(ctx, readiness: fn -> {:not_ready, "restart_required"} end)

      request = AccessorySim.request_call(ctx.sim)

      assert %{request: ^request, result: "refused", code: "restart_required"} =
               AccessoryCase.await_received(ctx.sim, "call.result")

      refute_received {:engine_started, _session, _opts}
    end

    test "a call held at the Mac refuses the tap call_in_progress before a second session", ctx do
      ctx = attached(ctx)
      desktop = desktop_call(ctx)
      assert_receive {:engine_started, _desktop_session, _opts}
      assert_receive {:desktop, ^desktop, :started}

      AccessorySim.request_call(ctx.sim)

      assert %{result: "refused", code: "call_in_progress"} =
               AccessoryCase.await_received(ctx.sim, "call.result")

      refute_received {:sim, _sim, {:received, %{type: "call.start"}}}
      refute_received {:engine_started, _session, _opts}
    end

    test "a desktop and an accessory starting at once open exactly one session", ctx do
      ctx = attached(ctx)
      desktop = desktop_call(ctx, hold: true)
      AccessorySim.request_call(ctx.sim)
      send(desktop, :go)

      result = AccessoryCase.await_received(ctx.sim, "call.result")
      assert_receive {:desktop, ^desktop, desktop_outcome}
      assert_receive {:engine_started, _session, _opts}
      refute_receive {:engine_started, _second, _opts}, 200

      case result do
        %{result: "accepted"} ->
          assert {:refused, %{reason: "call_in_progress", held_by: "accessory:" <> _}} =
                   desktop_outcome

        %{result: "refused", code: "call_in_progress"} ->
          assert desktop_outcome == :started
      end
    end
  end

  # M91 E3: the Mac observes a robot call through the link's view and
  # controls it by the call's id.
  describe "the Mac's view of the call" do
    test "the link publishes the voice the call started with, its lines, tasks and mute", ctx do
      ctx = ctx |> attached() |> call_up()
      call_id = ctx.call_id

      :ok =
        AccessoryEngine.emit(ctx.session, %{type: "transcript_delta", text: "What is on today?"})

      :ok =
        AccessoryEngine.emit(ctx.session, %{
          type: "tool_event",
          status: "running",
          name: "calendar"
        })

      :ok = AccessoryEngine.emit(ctx.session, %{type: "usage", cost_cents: 0.5})
      assert :ok = Link.mute(ctx.link, call_id, true)

      summary =
        AccessoryCase.await_state(
          &match?(%{call: %{view: %{muted_by: :mac, usage: %{}, tasks: [_]}}}, &1)
        )

      assert %{call_id: ^call_id, phase: :active, source: :screen_tap, view: view} = summary.call
      assert view.engine == "openai_realtime"
      assert view.model == Config.normalize(enabled: true, engine: "openai_realtime").model
      assert [%{speaker: :user, text: "What is on today?", final?: true}] = view.transcript
      assert [%{task: "rt:1", status: "running"}] = view.tasks
      assert view.usage.cost_cents == 0.5
      assert %DateTime{} = view.started_at
    end

    test "a control for a call that is not the current one is refused", ctx do
      ctx = attached(ctx)
      assert {:error, :no_call} = Link.end_call(ctx.link, "voice-gone")

      ctx = call_up(ctx)
      assert {:error, :stale_call} = Link.end_call(ctx.link, "voice-gone")
      assert {:error, :stale_call} = Link.interrupt(ctx.link, "voice-gone")
      refute_received {:sim, _sim, {:received, %{type: "call.end"}}}

      assert :ok = Link.end_call(ctx.link, ctx.call_id)
      assert %{reason: "mac_end"} = AccessoryCase.await_received(ctx.sim, "call.end")
    end

    test "how the call ended is kept for the Mac", ctx do
      ctx = ctx |> attached() |> call_up()
      call_id = ctx.call_id
      accessory_id = ctx.record.accessory_id

      AccessorySim.end_request(ctx.sim)

      assert %{
               call: nil,
               last_call: %{call_id: ^call_id, accessory_id: ^accessory_id, reason: "end_request"}
             } = AccessoryCase.await_state(&match?(%{last_call: %{}}, &1))
    end

    test "a setup check is refused while a call runs", ctx do
      ctx = ctx |> attached() |> call_up()
      assert {:error, :call_active} = Link.check_start(ctx.link, :tone, nil)
    end
  end

  describe "the microphone" do
    test "five 960-byte frames become one 4,800-byte chunk, and a gap is counted", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session
      TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: ctx.call_id)

      AccessorySim.send_mic(ctx.sim, 5)
      AccessorySim.send_mic(ctx.sim, 5, skip: 1)

      assert_receive {:engine, ^session, {:audio, chunk}}
      assert byte_size(chunk) == 4_800
      assert_receive {:engine, ^session, {:audio, second}}
      assert byte_size(second) == 4_800

      AccessorySim.end_request(ctx.sim)

      assert_receive {:telemetry, [:fermix, :accessory, :call_link], counters,
                      %{reason: :end_request, source: :screen_tap, engine: "openai_realtime"}}

      assert %{mic_frames: 10, mic_chunks: 2, pcm_seq_gaps: 1} = counters
    end

    test "the accessory's own mute reaches the engine, and the Mac's mute reaches both", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session

      AccessorySim.mic_state(ctx.sim, "muted")
      assert_receive {:engine, ^session, {:mute, true}}

      assert :ok = Link.mute(ctx.link, ctx.call_id, false)
      assert %{muted: false} = AccessoryCase.await_received(ctx.sim, "mute.set")
      assert_receive {:engine, ^session, {:mute, false}}
    end

    test "a microphone backlog on the accessory ends the call", ctx do
      ctx = ctx |> attached() |> call_up()

      AccessorySim.mic_state(ctx.sim, "off", "mic_backlog")

      assert %{reason: "mic_backlog"} = AccessoryCase.await_received(ctx.sim, "call.end")
      session_gone(ctx.session, ctx.lease)
    end
  end

  # M91 F3, HW-08's host-side proof: the robot sends no microphone audio
  # before it says its microphone is live. A frame that comes earlier is a
  # counted contract fault, and its audio never reaches the voice provider.
  describe "microphone audio before the robot says it is live" do
    test "is counted and kept from the engine, and audio after live goes on", ctx do
      ctx = ctx |> attached(sim: [auto_live?: false]) |> call_up()
      session = ctx.session
      TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: ctx.call_id)
      TelemetryCapture.attach([[:fermix, :accessory, :fault]], reason: :mic_before_live)

      AccessorySim.send_mic(ctx.sim, 5)
      AccessorySim.mic_state(ctx.sim, "live")
      AccessorySim.send_mic(ctx.sim, 5)

      assert_receive {:engine, ^session, {:audio, chunk}}
      assert chunk == :binary.list_to_bin(for i <- 1..5, do: :binary.copy(<<rem(i, 251)>>, 960))
      refute_received {:engine, ^session, {:audio, _second}}

      assert_receive {:telemetry, [:fermix, :accessory, :fault], %{count: 1},
                      %{reason: :mic_before_live, stage: :call}}

      AccessorySim.end_request(ctx.sim)

      assert_receive {:telemetry, [:fermix, :accessory, :call_link], counters, _meta}
      assert %{mic_frames_before_live: 5, mic_frames: 10, mic_chunks: 1} = counters
    end

    test "is zero on a call whose audio came after live", ctx do
      ctx = ctx |> attached() |> call_up()
      TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: ctx.call_id)
      _ = AccessorySim.peek(ctx.sim)
      _ = Link.status(ctx.link)
      AccessorySim.send_mic(ctx.sim, 5)
      AccessorySim.end_request(ctx.sim)

      assert_receive {:telemetry, [:fermix, :accessory, :call_link], %{mic_frames_before_live: 0},
                      _meta}
    end
  end

  # M91 F3: the robot's own counters and the interrupts' positions ride the
  # call's link event.
  describe "the call's link event" do
    test "carries the robot's diag counters and each interrupt's played position", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session
      TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: ctx.call_id)

      AccessorySim.send_message(ctx.sim, %{type: "diag.counters", counters: robot_counters()})
      :ok = AccessoryEngine.emit(ctx.session, audio(8_000))
      pcm_received(ctx.sim, 8_000)
      AccessorySim.play(ctx.sim, 4_800)
      :ok = AccessoryEngine.emit(ctx.session, %{type: "playback_stop"})
      assert_receive {:engine, ^session, {:interrupt, 100}}

      :ok = AccessoryEngine.emit(ctx.session, audio(2_000))
      pcm_received(ctx.sim, 2_000)
      AccessorySim.play(ctx.sim, 960)
      :ok = AccessoryEngine.emit(ctx.session, %{type: "playback_stop"})
      assert_receive {:engine, ^session, {:interrupt, 20}}

      AccessorySim.end_request(ctx.sim)

      assert_receive {:telemetry, [:fermix, :accessory, :call_link], counters, _meta}

      assert %{
               interrupts: 2,
               interrupt_played_ms_last: 20,
               interrupt_played_ms_total: 120,
               robot_uptime_s: 61,
               robot_frames_rx: 812,
               robot_frames_tx: 940,
               robot_crc_errors: 0,
               robot_resync_bytes: 0,
               robot_pcm_seq_gaps: 0,
               robot_mic_overflows: 0,
               robot_spk_underflows: 3
             } = counters
    end

    test "names no robot counter the robot never reported", ctx do
      ctx = ctx |> attached() |> call_up()
      TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: ctx.call_id)
      AccessorySim.end_request(ctx.sim)

      assert_receive {:telemetry, [:fermix, :accessory, :call_link], counters, _meta}
      refute Map.has_key?(counters, :robot_crc_errors)
      assert %{interrupts: 0, interrupt_played_ms_total: 0} = counters
    end
  end

  describe "the speaker" do
    test "audio goes out within credit, and the rest as the accessory plays", ctx do
      ctx = ctx |> attached() |> call_up()
      :ok = AccessoryEngine.emit(ctx.session, audio(12_000))

      assert %{segment: 1, playback_id: nil} = AccessoryCase.await_received(ctx.sim, "spk.begin")
      assert pcm_received(ctx.sim, 8_192) == 8_192
      refute_received {:sim, _sim, {:pcm, _more}}

      AccessorySim.play(ctx.sim, 12_000)
      assert pcm_received(ctx.sim, 3_808) == 3_808
      no_violation(ctx.sim)
    end

    test "with no credit nothing is sent, and a grant releases exactly that much", ctx do
      ctx = ctx |> attached(sim: [auto_credit: 0]) |> call_up()
      :ok = AccessoryEngine.emit(ctx.session, audio(9_600))
      AccessoryCase.await_received(ctx.sim, "spk.begin")
      _ = Link.status(ctx.link)
      refute_received {:sim, _sim, {:pcm, _pcm}}

      AccessorySim.grant(ctx.sim, 3_840)
      assert pcm_received(ctx.sim, 3_840) == 3_840
      _ = Link.status(ctx.link)
      refute_received {:sim, _sim, {:pcm, _pcm}}
      no_violation(ctx.sim)
    end

    test "a grant past 8,192 outstanding is refused credit_overgrant and ends the call", ctx do
      ctx = ctx |> attached(sim: [auto_credit: 0]) |> call_up()

      AccessorySim.grant(ctx.sim, 8_192)
      AccessorySim.grant(ctx.sim, 1)

      assert %{code: "credit_overgrant"} = AccessoryCase.await_received(ctx.sim, "error")
      assert %{reason: "credit_overgrant"} = AccessoryCase.await_received(ctx.sim, "call.end")
      session_gone(ctx.session, ctx.lease)
    end

    test "a reply's segment ends with the reply and drains as it plays out", ctx do
      ctx = ctx |> attached() |> call_up()
      :ok = AccessoryEngine.emit(ctx.session, %{type: "state", state: "speaking"})
      :ok = AccessoryEngine.emit(ctx.session, audio(1_000))
      :ok = AccessoryEngine.emit(ctx.session, %{type: "state", state: "listening"})

      assert %{segment: 1} = AccessoryCase.await_received(ctx.sim, "spk.end")
      AccessorySim.play(ctx.sim, 1_000)
      assert AccessorySim.peek(ctx.sim).call.open == %{}
      no_violation(ctx.sim)
    end

    test "a ninth open segment waits until one drains", ctx do
      ctx = ctx |> attached() |> call_up()

      for _reply <- 1..9 do
        :ok = AccessoryEngine.emit(ctx.session, %{type: "state", state: "speaking"})
        :ok = AccessoryEngine.emit(ctx.session, audio(100))
        :ok = AccessoryEngine.emit(ctx.session, %{type: "state", state: "listening"})
      end

      for segment <- 1..8,
          do: assert(%{segment: ^segment} = AccessoryCase.await_received(ctx.sim, "spk.begin"))

      _ = Link.status(ctx.link)
      refute_received {:sim, _sim, {:received, %{type: "spk.begin", segment: 9}}}

      AccessorySim.play(ctx.sim, 1_000)
      assert %{segment: 9} = AccessoryCase.await_received(ctx.sim, "spk.begin")
      no_violation(ctx.sim)
    end

    test "the engine's playback_stop flushes, and the flushed position is its interrupt", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session
      :ok = AccessoryEngine.emit(ctx.session, audio(8_000))
      pcm_received(ctx.sim, 8_000)
      AccessorySim.play(ctx.sim, 4_800)

      :ok = AccessoryEngine.emit(ctx.session, %{type: "playback_stop"})

      AccessoryCase.await_received(ctx.sim, "spk.flush")
      assert_receive {:engine, ^session, {:interrupt, 100}}
      no_violation(ctx.sim)
    end

    test "the Mac's interrupt flushes the accessory and interrupts the engine", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session
      :ok = AccessoryEngine.emit(ctx.session, audio(2_000))
      pcm_received(ctx.sim, 2_000)

      assert :ok = Link.interrupt(ctx.link, ctx.call_id)
      AccessoryCase.await_received(ctx.sim, "spk.flush")
      assert_receive {:engine, ^session, {:interrupt, 0}}

      # Nothing is left to flush: a second interrupt sends nothing.
      assert :ok = Link.interrupt(ctx.link, ctx.call_id)
      _ = Link.status(ctx.link)
      refute_received {:sim, _sim, {:received, %{type: "spk.flush"}}}
    end

    test "Grok's playback ids open a segment each, and progress reaches the engine", ctx do
      ctx = ctx |> attached(engine: "xai_realtime") |> call_up()
      session = ctx.session
      delta = Map.put(audio(480), :playback_id, "p1")
      :ok = AccessoryEngine.emit(ctx.session, delta)

      assert %{segment: 1, playback_id: "p1"} = AccessoryCase.await_received(ctx.sim, "spk.begin")

      AccessorySim.send_message(ctx.sim, %{
        type: "playback.progress",
        stream: ctx.stream,
        playback_id: "p1",
        played_ms: 10,
        drained: true
      })

      assert_receive {:engine, ^session, {:playback_progress, "p1", 10, true}}
    end
  end

  describe "the end of a call" do
    # PROTOCOL.md (accessory), *Calls*: an accessory that ended its call plays
    # nothing more and sends no credit, progress or `spk.flushed` until the
    # host's `call.end`. A flush still waiting and audio still held do not
    # hold the call up.
    test "a robot that ends the call with a flush and audio outstanding is ended at once", ctx do
      ctx = ctx |> attached(sim: [auto_credit: 0]) |> call_up()
      session = ctx.session
      :ok = AccessoryEngine.emit(ctx.session, audio(9_600))
      AccessorySim.grant(ctx.sim, 2_000)
      pcm_received(ctx.sim, 2_000)
      AccessorySim.set(ctx.sim, :silent?, true)
      :ok = AccessoryEngine.emit(ctx.session, %{type: "playback_stop"})
      AccessoryCase.await_received(ctx.sim, "spk.flush")

      AccessorySim.end_request(ctx.sim)

      assert %{reason: "end_request"} = AccessoryCase.await_received(ctx.sim, "call.end")
      assert_receive {:engine, ^session, :call_stop}
      refute_received {:engine, ^session, {:interrupt, _played_ms}}
      session_gone(session, ctx.lease)
    end

    test "a swipe back ends the call: the session is torn down and the lease freed", ctx do
      ctx = ctx |> attached() |> call_up("head_swipe")
      session = ctx.session

      AccessorySim.end_request(ctx.sim)

      assert_receive {:engine, ^session, :call_stop}
      assert %{reason: "end_request"} = AccessoryCase.await_received(ctx.sim, "call.end")
      session_gone(session, ctx.lease)
    end

    test "unplugging mid-call ends the call and frees the lease", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session
      link = Process.monitor(ctx.link)

      AccessoryBus.unplug(ctx.bus, @path)

      assert_receive {:DOWN, ^link, :process, _link, {:shutdown, {:transport_closed, :vanished}}}
      assert_receive {:engine, ^session, :call_stop}
      session_gone(session, ctx.lease)
    end

    test "a link killed mid-call takes its session with it and leaves the voice core up", ctx do
      ctx = ctx |> attached() |> call_up()
      guard = Process.whereis(ctx.guard)

      Process.exit(ctx.link, :kill)

      session_gone(ctx.session, ctx.lease)
      assert Process.alive?(guard)
      assert :sys.get_state(guard).bindings == %{}
    end

    # A hello_ack answers only the attaching link's challenge: a second one,
    # mid-call, is out of phase and changes nothing, even with the pairing
    # store unreadable (it is not read).
    test "a duplicate hello_ack mid-call is answered not_now and the call stays up", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session
      File.chmod!(Path.join(ctx.home, "accessories"), 0o755)

      AccessorySim.send_message(ctx.sim, duplicate_ack())

      assert %{code: "not_now", message_type: "hello_ack"} =
               AccessoryCase.await_received(ctx.sim, "error")

      assert Link.status(ctx.link).phase == :attached
      assert %{call: %{stream: 1, ending?: false}} = Link.status(ctx.link)
      refute_received {:engine, ^session, :call_stop}
      refute_received {:sim, _sim, {:received, %{type: "call.end"}}}
      assert {:ok, _holder} = CallLease.holder(ctx.lease)
    end

    test "the accessory refusing mid-call leaves no call behind, and frees the lease", ctx do
      ctx = ctx |> attached() |> call_up()

      AccessorySim.send_message(ctx.sim, %{type: "refuse", code: "bad_proof"})

      assert %{reason: "refused"} = AccessoryCase.await_received(ctx.sim, "call.end")
      session_gone(ctx.session, ctx.lease)
      AccessoryCase.await_state(&(&1.phase == :refused and &1.call == nil))
    end

    # A link stopped by its supervisor (the subtree turned off, the daemon
    # stopping) has settled its call by the time it is gone: the session is
    # torn down while the voice core still runs, never after it.
    test "a link stopped mid-call has torn its session down by the time it is gone", ctx do
      ctx = ctx |> attached() |> call_up()
      session = ctx.session

      :ok = stop_supervised(Link)

      assert_received {:engine, ^session, :call_stop}
      session_gone(session, ctx.lease)
    end

    test "an engine error ends the call with its kind", ctx do
      ctx = ctx |> attached() |> call_up()

      :ok =
        AccessoryEngine.emit(ctx.session, %{
          type: "error",
          reason: "cost_limit",
          kind: "cost_limit"
        })

      assert %{reason: "cost_limit"} = AccessoryCase.await_received(ctx.sim, "call.end")
      session_gone(ctx.session, ctx.lease)
    end
  end

  describe "task reactions (D21)" do
    test "OpenAI Realtime's concurrent tool calls are one task: one running, one completed",
         ctx do
      ctx = ctx |> attached() |> call_up()

      for status <- ~w(running running completed completed) do
        :ok =
          AccessoryEngine.emit(ctx.session, %{
            type: "tool_event",
            status: status,
            name: "web_search"
          })
      end

      assert %{task: "rt:1", revision: 1, status: "running", in_chat: false} =
               AccessoryCase.await_received(ctx.sim, "task.event")

      assert %{task: "rt:1", status: "completed"} =
               AccessoryCase.await_received(ctx.sim, "task.event")

      _ = Link.status(ctx.link)
      refute_received {:sim, _sim, {:received, %{type: "task.event"}}}
    end

    test "a reconnect mid-batch cancels it, and an unmatched settle opens nothing", ctx do
      ctx = ctx |> attached() |> call_up()
      TelemetryCapture.attach([[:fermix, :accessory, :call_link]], session_id: ctx.call_id)

      :ok = AccessoryEngine.emit(ctx.session, %{type: "tool_event", status: "running", name: "x"})
      :ok = AccessoryEngine.emit(ctx.session, %{type: "state", state: "reconnecting"})

      :ok =
        AccessoryEngine.emit(ctx.session, %{type: "tool_event", status: "completed", name: "x"})

      assert %{status: "running"} = AccessoryCase.await_received(ctx.sim, "task.event")

      assert %{task: "rt:1", status: "cancelled"} =
               AccessoryCase.await_received(ctx.sim, "task.event")

      AccessorySim.end_request(ctx.sim)

      assert_receive {:telemetry, [:fermix, :accessory, :call_link],
                      %{task_events: 2, task_faults: 1}, _meta}
    end

    test "a GPT-Live task frame is the accessory's task.event, and its detach is not sent", ctx do
      ctx = ctx |> attached(engine: "openai_live") |> call_up()

      frame = %{
        type: "task",
        delegation_id: "d4",
        revision: 2,
        status: "completed",
        server_seq: 12
      }

      :ok = AccessoryEngine.emit(ctx.session, frame)

      assert %{task: "d4", revision: 2, status: "completed", in_chat: true} =
               AccessoryCase.await_received(ctx.sim, "task.event")

      detached = %{
        type: "task",
        delegation_id: "d5",
        revision: 1,
        status: "running",
        detached: true
      }

      :ok = AccessoryEngine.emit(ctx.session, detached)
      _ = Link.status(ctx.link)
      refute_received {:sim, _sim, {:received, %{type: "task.event", task: "d5"}}}
    end
  end

  defp robot_counters do
    %{
      uptime_s: 61,
      frames_rx: 812,
      frames_tx: 940,
      crc_errors: 0,
      resync_bytes: 0,
      pcm_seq_gaps: 0,
      mic_overflows: 0,
      spk_underflows: 3
    }
  end

  defp duplicate_ack do
    %{
      type: "hello_ack",
      wire: 1,
      kind: "stackchan",
      accessory_id: nil,
      firmware: "0.1.0",
      pack: nil,
      caps: 3,
      accessory_nonce: :crypto.strong_rand_bytes(32),
      sig: nil
    }
  end

  # The Mac's own call, from a process of its own as the Unix socket's
  # handler would make it: it tells the test how its start went and holds the
  # call until the test ends. With `hold: true` it starts only on `:go`.
  defp desktop_call(ctx, opts \\ []) do
    test = self()

    pid =
      spawn_link(fn ->
        if Keyword.get(opts, :hold, false), do: receive(do: (:go -> :ok))
        client = desktop_client(ctx, test)

        case CallClient.call_start(client) do
          {:cont, _client} -> send(test, {:desktop, self(), :started})
          {:stop, _client} -> send(test, {:desktop, self(), {:refused, desktop_error()}})
        end

        receive(do: (:stop -> :ok))
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp desktop_error do
    receive do
      {:desktop_emitted, %{type: "error"} = error} -> error
    after
      2_000 -> :no_error
    end
  end

  defp desktop_client(ctx, test) do
    me = self()

    CallClient.new(
      endpoint: :desktop,
      protocol_version: 3,
      config: Config.normalize(enabled: true, engine: "openai_realtime"),
      emit: fn event ->
        send(me, {:desktop_emitted, event})
        :ok
      end,
      session_module: AccessoryEngine,
      session_starter: AccessoryEngine.starter(test, lease: ctx.lease),
      session_guard: ctx.guard,
      task_supervisor: ctx.tasks
    )
  end
end
