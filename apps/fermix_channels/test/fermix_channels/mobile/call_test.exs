defmodule FermixChannels.Mobile.CallTest do
  @moduledoc """
  A phone's voice call (M87) end to end through `Mobile.Session`: the real
  Noise session and codec, the real `Mobile.Call`, `CallClient`,
  `SessionGuard` and call lease, and a scripted voice session in place of a
  provider's.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Call
  alias FermixChannels.Mobile.CallAudio
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionGuard
  alias FermixTestSupport.TelemetryCapture

  @phone_id "0d7f6a52-91c3-4b8e-a1f0-5e2d9c4b7a13"
  @desktop_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @call "c-9f1e"
  @seen ~U[2026-11-07 08:00:00Z]
  @pcm :binary.copy(<<1, 0>>, 2_400)

  # A voice session in place of an engine's: it takes the home's call in
  # `init/1` as every engine does, tells the test each verb, and pushes to its
  # companion whatever the test hands it (`{:push, frame}`).
  defmodule Voice do
    use GenServer

    def call_start(pid), do: GenServer.call(pid, :call_start)
    def audio_chunk(pid, audio), do: GenServer.cast(pid, {:verb, {:audio, audio}})
    def interrupt(pid, end_ms), do: GenServer.call(pid, {:verb, {:interrupt, end_ms}})
    def mute(pid, enabled?), do: GenServer.call(pid, {:verb, {:mute, enabled?}})
    def cancel_task(pid, id), do: GenServer.call(pid, {:verb, {:cancel_task, id}})

    def playback_progress(pid, id, played, drained?),
      do: GenServer.call(pid, {:verb, {:playback_progress, id, played, drained?}})

    def call_stop(pid), do: GenServer.call(pid, :call_stop)

    @impl true
    def init(%{observer: observer, opts: opts, lease: lease, engine: engine}) do
      Process.monitor(observer)

      case CallLease.acquire(lease, Keyword.fetch!(opts, :endpoint), engine) do
        :ok -> {:ok, %{observer: observer, companion: Keyword.fetch!(opts, :companion)}}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_call(:call_start, _from, state) do
      send(state.companion, {:realtime, %{type: "state", state: "listening"}})
      {:reply, :ok, state}
    end

    def handle_call(:call_stop, _from, state) do
      send(state.observer, {:voice, self(), :call_stop})
      {:stop, {:shutdown, :call_stop}, :ok, state}
    end

    def handle_call({:verb, {:cancel_task, id} = verb}, _from, state) do
      send(state.observer, {:voice, self(), verb})
      send(state.companion, {:realtime, task(id, "cancelled")})
      {:reply, :ok, state}
    end

    def handle_call({:verb, verb}, _from, state) do
      send(state.observer, {:voice, self(), verb})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:verb, verb}, state) do
      send(state.observer, {:voice, self(), verb})
      {:noreply, state}
    end

    @impl true
    def handle_info({:push, frame}, state) do
      send(state.companion, {:realtime, frame})
      {:noreply, state}
    end

    def handle_info({:DOWN, _ref, :process, observer, _reason}, %{observer: observer} = state),
      do: {:stop, :normal, state}

    def task(id, status),
      do: %{type: "task", call_uuid: "u-1", delegation_id: id, revision: 1, status: status}
  end

  setup do
    suffix = System.unique_integer([:positive])
    name = &Module.concat(__MODULE__, "#{&1}#{suffix}")
    tasks = start_supervised!({Task.Supervisor, name: name.("Tasks")})
    guard = name.("Guard")
    start_supervised!({SessionGuard, name: guard, task_supervisor: tasks})
    lease = name.("Lease")
    start_supervised!({CallLease, name: lease})
    calls = name.("Calls")
    start_supervised!({Registry, keys: :unique, name: calls})
    call_supervisor = name.("CallSupervisor")
    start_supervised!({DynamicSupervisor, name: call_supervisor, strategy: :one_for_one})

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: name.("Devices"),
         authorize_device: fn _store, id -> {:ok, row(id)} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end,
         relays_changed: fn -> :ok end,
         end_call: &Call.notify(calls, &1, &2)}
      )

    %{
      gateway: Noise.generate_keypair(),
      phone: Noise.generate_keypair(),
      desktop: Noise.generate_keypair(),
      tasks: tasks,
      guard: guard,
      lease: lease,
      calls: calls,
      call_supervisor: call_supervisor,
      registry: registry,
      engine: "openai_live"
    }
  end

  describe "a whole call" do
    test "opens, carries audio both ways and a control, detaches and resumes reconciled", ctx do
      {driver, client} = ready_phone!(ctx)
      {client, voice} = call_up!(driver, client, 2)

      # Up: raw PCM reaches the session as the bytes it is.
      client = Driver.client_send(driver, client, "call_audio", %{"call_id" => @call}, 5, @pcm)
      assert_receive {:voice, ^voice, {:audio, @pcm}}

      # Down: the session's base64 reaches the phone as raw PCM, under a
      # playback id the primary minted for a GPT-Live call.
      send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(@pcm)}})
      {[audio], client} = Driver.client_receive(driver, client)

      assert {%{"t" => "call_audio", "call_id" => @call, "playback_id" => "m1"}, @pcm} = audio

      # A numbered control.
      client = send_line(driver, client, %{type: "mute", enabled: true}, 6, 2)
      assert_receive {:voice, ^voice, {:mute, true}}

      # The phone's session closes: the call waits for it.
      close_session(driver)
      call = call_pid!(ctx)
      await(call, &(&1.attached == nil and &1.window != nil))
      _ = client

      # Lines the session sends meanwhile wait for the phone.
      send(voice, {:push, %{type: "state", state: "thinking"}})

      {driver, client} = ready_phone!(ctx)
      client = Driver.client_send(driver, client, "call_open", open(true), 2)
      {events, client} = receive_events(driver, client, 2)

      assert [
               {%{
                  "t" => "call_attached",
                  "resumed" => true,
                  "muted" => true,
                  "camera" => false,
                  "control_seq" => 2
                }, <<>>},
               {%{"t" => "call_line"}, held}
             ] = events

      assert Jason.decode!(held) == %{"type" => "state", "state" => "thinking"}

      # A control the phone re-sends after that seq is a repeat, dropped; a new
      # one is applied.
      client = send_line(driver, client, %{type: "mute", enabled: true}, 3, 2)
      client = send_line(driver, client, %{type: "mute", enabled: false}, 4, 3)
      assert_receive {:voice, ^voice, {:mute, false}}
      refute_received {:voice, ^voice, {:mute, true}}

      # The call is the call that was: same session, same lease.
      assert Process.alive?(voice)
      assert {:ok, %{endpoint: "phone:" <> @phone_id}} = CallLease.holder(ctx.lease)

      hang_up!(driver, client, voice, 5)
    end

    test "a closed session, then a new one, resumes without ending the call", ctx do
      {driver, client} = ready_phone!(ctx)
      {_client, voice} = call_up!(driver, client, 2)

      # The planned successor: the old session closes first, then the new one
      # says hello and resumes.
      send(driver, {:mobile_replaced, self()})
      assert {:replaced, {4001, _text}, [], _client} = Driver.client_closed(driver, client)

      {driver, client} = ready_phone!(ctx)
      client = Driver.client_send(driver, client, "call_open", open(true), 2)
      {[{attached, <<>>}], client} = Driver.client_receive(driver, client)
      assert %{"t" => "call_attached", "resumed" => true, "control_seq" => 1} = attached

      send(voice, {:push, %{type: "state", state: "speaking"}})
      {[{%{"t" => "call_line"}, line}], client} = Driver.client_receive(driver, client)
      assert Jason.decode!(line) == %{"type" => "state", "state" => "speaking"}
      refute_received {:voice, ^voice, :call_stop}

      hang_up!(driver, client, voice, 3)
    end

    test "a window that runs out ends the call lost and frees the home's call", ctx do
      {driver, client} = ready_phone!(ctx)
      {_client, voice} = call_up!(driver, client, 2)
      voice_ref = Process.monitor(voice)

      close_session(driver)
      call = call_pid!(ctx)
      %{window: %{token: token}} = await(call, &(&1.window != nil))
      call_ref = Process.monitor(call)
      send(call, {:window_expired, token})

      assert_receive {:voice, ^voice, :call_stop}
      assert_receive {:DOWN, ^voice_ref, :process, ^voice, _reason}
      assert_receive {:DOWN, ^call_ref, :process, ^call, :normal}
      assert CallLease.holder(ctx.lease) == :none

      # Its resume is a call this primary no longer holds.
      {driver, client} = ready_phone!(ctx)
      client = Driver.client_send(driver, client, "call_open", open(true), 2)
      {[{close, <<>>}], _client} = Driver.client_receive(driver, client)
      assert %{"t" => "call_close", "call_id" => @call, "reason" => "unknown_call"} = close
    end

    test "revoking the phone cancels its unsettled hand-offs and ends the call", ctx do
      {driver, client} = ready_phone!(ctx)
      {client, voice} = call_up!(driver, client, 2)

      send(voice, {:push, Voice.task("d-done", "running")})
      send(voice, {:push, Voice.task("d-done", "completed")})
      send(voice, {:push, Voice.task("d-run", "running")})
      send(voice, {:push, Voice.task("d-wait", "pending")})
      {_lines, client} = receive_events(driver, client, 4)

      voice_ref = Process.monitor(voice)
      :ok = DeviceRegistry.revoke(ctx.registry, @phone_id)

      assert_receive {:voice, ^voice, {:mute, true}}
      assert_receive {:voice, ^voice, {:cancel_task, "d-wait"}}
      assert_receive {:voice, ^voice, {:cancel_task, "d-run"}}
      assert_receive {:voice, ^voice, :call_stop}
      refute_received {:voice, ^voice, {:cancel_task, "d-done"}}
      assert_receive {:DOWN, ^voice_ref, :process, ^voice, _reason}
      assert CallLease.holder(ctx.lease) == :none
      _ = client
    end

    test "while the phone holds the call, another endpoint is refused naming it", ctx do
      {driver, client} = ready_phone!(ctx)
      {client, _voice} = call_up!(driver, client, 2)

      lease = ctx.lease
      task = Task.async(fn -> CallLease.acquire(lease, :desktop, "openai_live") end)
      assert Task.await(task) == {:error, {:call_in_progress, "phone:" <> @phone_id}}
      _ = client
    end

    test "a phone is refused a call another endpoint holds, the session staying up", ctx do
      test = self()

      holder =
        spawn_link(fn ->
          :ok = CallLease.acquire(ctx.lease, :desktop, "openai_live")
          send(test, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held
      {driver, client} = ready_phone!(ctx)
      client = open_new!(driver, client, 2)
      client = send_line(driver, client, %{type: "client_hello", protocol_version: 3}, 3, nil)
      {_hello, client} = Driver.client_receive(driver, client)
      client = send_line(driver, client, %{type: "call_start"}, 4, 1)

      {events, client} = receive_events(driver, client, 2)

      assert [{%{"t" => "call_line"}, refusal}, {%{"t" => "call_close", "reason" => "ended"}, _}] =
               events

      assert Jason.decode!(refusal) == %{
               "type" => "error",
               "reason" => "call_in_progress",
               "held_by" => "desktop"
             }

      client = Driver.client_send(driver, client, "ping", %{}, 5)
      assert {[{%{"t" => "pong"}, <<>>}], _client} = Driver.client_receive(driver, client)
      Process.unlink(holder)
      Process.exit(holder, :kill)
    end
  end

  describe "what keeps a call honest" do
    # The guard answers for a session whatever ends its adapter.
    test "killing the call mid-call leaves no session and frees the home's call", ctx do
      {driver, client} = ready_phone!(ctx)
      {_client, voice} = call_up!(driver, client, 2)
      voice_ref = Process.monitor(voice)
      call = call_pid!(ctx)

      Process.exit(call, :kill)

      assert_receive {:voice, ^voice, :call_stop}
      assert_receive {:DOWN, ^voice_ref, :process, ^voice, _reason}
      assert CallLease.holder(ctx.lease) == :none
    end

    test "Talk to Fermix turned off since hello_ack refuses the open, the session staying up",
         ctx do
      {driver, client} = ready_phone!(ctx, ready: fn _config -> {:error, :voice_off} end)
      client = Driver.client_send(driver, client, "call_open", open(false), 2)
      {events, client} = receive_events(driver, client, 2)

      assert [{%{"t" => "call_line"}, refusal}, {%{"t" => "call_close", "reason" => "ended"}, _}] =
               events

      assert Jason.decode!(refusal) == %{"type" => "error", "reason" => "voice_off"}

      client = Driver.client_send(driver, client, "ping", %{}, 3)
      assert {[{%{"t" => "pong"}, <<>>}], _client} = Driver.client_receive(driver, client)
    end

    test "a desktop's session is refused every call event, open", ctx do
      {driver, client} = ready!(ctx, ctx.desktop, @desktop_id, [])
      client = Driver.client_send(driver, client, "call_open", open(false), 2)
      {[{refusal, <<>>}], client} = Driver.client_receive(driver, client)
      assert %{"t" => "error", "code" => "unsupported_event"} = refusal

      client = Driver.client_send(driver, client, "ping", %{}, 3)
      assert {[{%{"t" => "pong"}, <<>>}], _client} = Driver.client_receive(driver, client)
    end

    test "frames from a session the call is not attached to are dropped", ctx do
      {driver, client} = ready_phone!(ctx)
      {_client, voice} = call_up!(driver, client, 2)
      call = call_pid!(ctx)
      stranger = spawn(fn -> Process.sleep(:infinity) end)

      send(call, {:call_frame, stranger, "call_audio", %{"call_id" => @call}, @pcm, 0})

      send(
        call,
        {:call_frame, stranger, "call_line", %{"call_id" => @call}, ~s({"type":"call_stop"}), 0}
      )

      _ = :sys.get_state(call)

      refute_received {:voice, ^voice, _verb}
      assert Process.alive?(voice)
      Process.exit(stranger, :kill)
    end

    test "a resume for a call never held is unknown_call; so is a close for one", ctx do
      {driver, client} = ready_phone!(ctx)
      client = Driver.client_send(driver, client, "call_open", open(true), 2)
      {[{close, <<>>}], client} = Driver.client_receive(driver, client)
      assert %{"t" => "call_close", "reason" => "unknown_call"} = close

      client = Driver.client_send(driver, client, "call_close", %{"call_id" => @call}, 3)
      {[{close, <<>>}], _client} = Driver.client_receive(driver, client)
      assert %{"t" => "call_close", "reason" => "unknown_call"} = close
    end

    # The registry forgets an exited call a moment later; until it does, the
    # entry is held here by keeping its partition from reading the exit.
    test "an exited call still registered is no call to resume or close; a new call starts",
         ctx do
      partition = Module.concat(ctx.calls, "PIDPartition0")
      test = self()

      gone =
        spawn(fn ->
          {:ok, _owner} = Registry.register(ctx.calls, @phone_id, nil)
          send(test, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      :ok = :sys.suspend(partition)
      gone_ref = Process.monitor(gone)
      Process.exit(gone, :kill)
      assert_receive {:DOWN, ^gone_ref, :process, ^gone, :killed}
      assert Registry.lookup(ctx.calls, @phone_id) == [{gone, nil}]

      relay = spawn_link(fn -> relay(test) end)

      assert Call.open(@phone_id, relay, @call, true, calls: ctx.calls) ==
               {:close, "unknown_call"}

      assert Call.deliver(@phone_id, relay, "call_close", %{"call_id" => @call}, <<>>,
               calls: ctx.calls
             ) == {:close, "unknown_call"}

      opts = call_options(ctx, [])
      call_opts = [calls: ctx.calls, call_supervisor: ctx.call_supervisor, call_options: opts]
      assert Call.open(@phone_id, relay, @call, false, call_opts) == :ok
      assert_receive {:from_call, :control, %{"t" => "call_attached", "resumed" => false}}
      :ok = :sys.resume(partition)
    end

    test "End pressed while away: the next session's first call frame closes the call", ctx do
      {driver, client} = ready_phone!(ctx)
      {_client, voice} = call_up!(driver, client, 2)
      close_session(driver)
      await(call_pid!(ctx), &(&1.attached == nil))

      {driver, client} = ready_phone!(ctx)
      client = Driver.client_send(driver, client, "call_close", %{"call_id" => @call}, 2)
      assert_receive {:voice, ^voice, :call_stop}

      {events, _client} = receive_until_close(driver, client)
      assert {%{"t" => "call_close", "reason" => "ended"}, <<>>} = List.last(events)
    end

    test "a GPT-Live call's playback_progress is credit, never the session's", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "openai_live")
      push_audio(voice, 1)
      assert [%{"playback_id" => "m1"}] = audio_frames(1)

      progress = %{type: "playback_progress", playback_id: "m1", played_ms: 100, drained: true}
      send(call, line_frame(relay, progress, nil, 0))

      assert CallAudio.outstanding_ms(:sys.get_state(call).audio) == 0
      refute_received {:voice, ^voice, {:playback_progress, _id, _played, _drained}}
    end
  end

  describe "the session writes a call's frames first" do
    test "control lines, then audio, ahead of queued frames, and media waits for the call",
         ctx do
      {driver, client} = ready_phone!(ctx)
      {client, voice} = call_up!(driver, client, 2)
      call = call_pid!(ctx)

      # Everything below lands in the session's mailbox in this order before it
      # reads any of it: a media push, a text row, call audio, a call line.
      hold = Driver.hold(driver)

      media = %{
        "t" => "media_begin",
        "ref" => "r1",
        "server_seq" => 3,
        "kind" => "image",
        "mime" => "image/png",
        "size_bytes" => 1,
        "sha256" => String.duplicate("a", 64)
      }

      row = %{"t" => "notice", "kind" => "info", "text" => "hello"}
      send(driver, {:mobile_event, media})
      send(driver, {:mobile_event, row})

      send(
        driver,
        {:mobile_call, call, :audio,
         %{"t" => "call_audio", "call_id" => @call, "playback_id" => "m1", "bytes" => @pcm}}
      )

      send(
        driver,
        {:mobile_call, call, :control,
         %{
           "t" => "call_line",
           "call_id" => @call,
           "bytes" => ~s({"type":"state","state":"speaking"})
         }}
      )

      Driver.release(driver, hold)

      {first, client} = Driver.client_receive(driver, client)
      types = Enum.map(first, fn {header, _bytes} -> header["t"] end)
      assert types == ["call_line", "call_audio"]

      # The media push waits while the call is attached; text still flows.
      {[{%{"t" => "notice"}, <<>>}], client} = Driver.client_receive(driver, client)
      refute_received {:driver_out, _driver, _frames}

      {events, _client} = hang_up_events(driver, client, voice, 5)
      types = Enum.map(events, fn {header, _bytes} -> header["t"] end)
      assert Enum.take(types, -2) == ["call_close", "media_begin"]
    end

    # Written first, the stop would overtake the audio queued before it.
    test "a playback stop drops its call's audio queued before it", ctx do
      {driver, client} = ready_phone!(ctx)
      {client, _voice} = call_up!(driver, client, 2)
      call = call_pid!(ctx)
      stop = %{"t" => "call_line", "call_id" => @call, "bytes" => ~s({"type":"playback_stop"})}

      hold = Driver.hold(driver)
      send(driver, {:mobile_call, call, :audio, call_audio("m1")})
      send(driver, {:mobile_call, call, :audio, call_audio("m1")})
      send(driver, {:mobile_call, call, :stop, stop})
      send(driver, {:mobile_call, call, :audio, call_audio("m2")})
      Driver.release(driver, hold)

      {[{line, line_bytes}, {after_stop, _pcm}], _client} = Driver.client_receive(driver, client)
      assert {line["t"], line_bytes} == {"call_line", ~s({"type":"playback_stop"})}
      assert {after_stop["t"], after_stop["playback_id"]} == {"call_audio", "m2"}
    end

    # The call found the session silent mid-stream and let it go: the session
    # closes, so a phone whose link is in fact alive reconnects and resumes.
    test "a session its call found silent closes 1000; another call's word is ignored", ctx do
      {driver, client} = ready_phone!(ctx)
      {client, _voice} = call_up!(driver, client, 2)
      call = call_pid!(ctx)

      stranger = spawn(fn -> Process.sleep(:infinity) end)
      send(driver, {:mobile_call_silent, stranger})
      client = Driver.client_send(driver, client, "ping", %{}, 5)
      assert {[{%{"t" => "pong"}, <<>>}], _client} = Driver.client_receive(driver, client)
      Process.exit(stranger, :kill)

      send(driver, {:mobile_call_silent, call})
      assert_receive {:driver_closed, ^driver, :call_link_silent, {1000, "call link silent"}, _}
    end

    # A crash writes nothing of its own: the session closes the call for it.
    test "a call that exits without its close is closed ended, its media after", ctx do
      {driver, client} = ready_phone!(ctx)
      {client, voice} = call_up!(driver, client, 2)
      call = call_pid!(ctx)

      hold = Driver.hold(driver)
      send(driver, {:mobile_event, media_begin("r1")})
      call_ref = Process.monitor(call)
      Process.exit(call, :kill)
      assert_receive {:DOWN, ^call_ref, :process, ^call, :killed}
      Driver.release(driver, hold)

      {events, _client} = Driver.client_receive(driver, client)

      assert [{%{"t" => "call_close"} = close, <<>>}, {%{"t" => "media_begin"}, _bytes}] =
               events

      assert Map.take(close, ~w(call_id reason)) == %{"call_id" => @call, "reason" => "ended"}
      assert_receive {:voice, ^voice, :call_stop}
    end
  end

  # The call driven alone: the test plays the phone's session (a relay that
  # hands the test whatever the call sends it) and holds the call's clock.
  describe "the media path" do
    # Reports keep coming, so the link is up; they free nothing, so the phone
    # is not playing: 5 s of that ends the call, and the session stays.
    test "a phone that keeps reporting but plays nothing for 5 s ends link_too_slow", ctx do
      %{call: call, voice: voice, relay: relay, clock: clock} =
        call_alone!(ctx, "openai_live", quiet_ms: 200)

      push_audio(voice, 6)
      assert length(audio_frames(5)) == 5
      call_ref = Process.monitor(call)
      stuck = %{type: "playback_progress", playback_id: "m1", played_ms: 0, drained: false}

      # 100 ms at a time, a report and more audio each step: 4.9 s behind, and
      # the call goes on.
      for _step <- 1..49, do: stuck_step(call, voice, relay, clock, stuck)
      assert :sys.get_state(call).attached != nil

      # The 5 s.
      Agent.update(clock, &(&1 + 100))
      send(call, line_frame(relay, stuck, nil, 0))

      assert_receive {:voice, ^voice, :call_stop}
      assert_receive {:from_call, :control, %{"t" => "call_line", "bytes" => why}}
      assert Jason.decode!(why) == %{"type" => "error", "reason" => "link_too_slow"}
      assert_receive {:from_call, :control, %{"t" => "call_line", "bytes" => idle}}
      assert Jason.decode!(idle) == %{"type" => "state", "state" => "idle"}

      assert_receive {:from_call, :control,
                      %{"t" => "call_close", "call_id" => @call, "reason" => "link_too_slow"}}

      assert_receive {:DOWN, ^call_ref, :process, ^call, :normal}
      refute_received {:call_silent, _call}
    end

    # A link that dies without closing (Wi-Fi off under a relay stream) leaves
    # the session open and silent: nothing reports the audio the phone holds.
    test "a session that goes quiet mid-stream on Live detaches; a resume carries on", ctx do
      %{call: call, voice: voice, clock: clock} = call_alone!(ctx, "openai_live", quiet_ms: 200)
      trace = "voice_live:#{System.unique_integer([:positive])}"
      TelemetryCapture.attach([[:fermix, :voice_live, :phone_detached]], session_id: trace)
      ready = %{type: "call_ready", engine: "openai_live", call_id: trace, call_uuid: "u-2"}
      send(voice, {:push, Map.put(ready, :conversation, "chat")})
      assert_receive {:from_call, :control, %{"t" => "call_line"}}

      push_audio(voice, 5)
      assert length(audio_frames(5)) == 5

      # Quiet for less than the bound: still attached.
      Agent.update(clock, &(&1 + 199))
      push_audio(voice, 1)
      _ = :sys.get_state(call)
      refute_received {:call_silent, _call}
      assert :sys.get_state(call).attached != nil

      Agent.update(clock, &(&1 + 1))
      assert_receive {:call_silent, ^call}
      assert_receive {:telemetry, [:fermix, :voice_live, :phone_detached], %{}, detached}
      assert detached.endpoint == "phone:#{@phone_id}"
      await(call, &(&1.attached == nil and &1.window != nil))

      # The silent session is no longer the call's: nothing more is written to it.
      push_audio(voice, 1)
      _ = :sys.get_state(call)
      refute_received {:from_call, :audio, _frame}

      test = self()
      relay = spawn_link(fn -> relay(test) end)
      :ok = Call.open(@phone_id, relay, @call, true, calls: ctx.calls)
      assert_receive {:from_call, :control, %{"t" => "call_attached", "resumed" => true}}

      push_audio(voice, 3)
      assert [%{"playback_id" => "m1"}, _second, _third] = audio_frames(3)
    end

    # Under Grok's 2 s unreported-audio stall, so the reply is cut where it was
    # heard and the call waits for the phone, rather than Grok ending it.
    test "a Grok session gone quiet mid-reply detaches, its reply interrupted", ctx do
      %{call: call, voice: voice, clock: clock} = call_alone!(ctx, "xai_realtime", quiet_ms: 200)
      send(voice, {:push, %{type: "audio_delta", audio: grok_audio(2), playback_id: "p1"}})
      assert length(audio_frames(2)) == 2

      Agent.update(clock, &(&1 + 200))
      assert_receive {:call_silent, ^call}
      assert_receive {:voice, ^voice, {:interrupt, nil}}
      assert Process.alive?(call)
    end

    # Listening, or muted, a phone has nothing to report: no watch, however long.
    test "a quiet session with no audio outstanding is not watched", ctx do
      %{call: call, voice: voice, relay: relay, clock: clock} =
        call_alone!(ctx, "openai_live", quiet_ms: 200)

      assert :sys.get_state(call).link_watch == nil
      push_audio(voice, 1)
      assert [_frame] = audio_frames(1)
      assert :sys.get_state(call).link_watch != nil

      drained = %{type: "playback_progress", playback_id: "m1", played_ms: 100, drained: true}
      send(call, line_frame(relay, drained, nil, 0))
      assert :sys.get_state(call).link_watch == nil

      Agent.update(clock, &(&1 + 10_000))
      assert :sys.get_state(call).attached != nil
      refute_received {:call_silent, _call}
    end

    test "revocation says why ahead of every frame its ending makes", ctx do
      %{call: call, voice: voice} = call_alone!(ctx, "openai_live")
      call_ref = Process.monitor(call)
      send(call, {:mobile_revoked, @phone_id})
      assert_receive {:voice, ^voice, :call_stop}
      assert_receive {:DOWN, ^call_ref, :process, ^call, :normal}

      [%{"bytes" => why} | rest] = controls_until_close()
      assert Jason.decode!(why) == %{"type" => "error", "reason" => "revoked"}
      assert %{"t" => "call_close", "reason" => "revoked"} = List.last(rest)

      assert %{"type" => "state", "state" => "idle"} in for(
               %{"t" => "call_line", "bytes" => line} <- rest,
               do: Jason.decode!(line)
             )
    end

    test "Grok's playback_progress is credit and the session's too", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "xai_realtime")

      send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(@pcm), playback_id: "p1"}})
      assert [%{"playback_id" => "p1"}] = audio_frames(1)

      progress = %{type: "playback_progress", playback_id: "p1", played_ms: 50, drained: false}
      send(call, line_frame(relay, progress, nil, 0))

      assert_receive {:voice, ^voice, {:playback_progress, "p1", 50, false}}
    end

    test "Grok audio a detached phone never heard is interrupted once", ctx do
      %{call: call, voice: voice, relay: relay, clock: clock} = call_alone!(ctx, "xai_realtime")

      Process.unlink(relay)
      Process.exit(relay, :kill)
      await(call, &(&1.attached == nil))
      send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(@pcm), playback_id: "p1"}})
      await(call, &(&1.audio.queued == 1))
      Agent.update(clock, &(&1 + 300))
      send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(@pcm), playback_id: "p1"}})

      assert_receive {:voice, ^voice, {:interrupt, nil}}

      await(call, &(&1.audio.queued == 1))
      Agent.update(clock, &(&1 + 300))
      send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(@pcm), playback_id: "p1"}})
      _ = :sys.get_state(call)
      refute_received {:voice, ^voice, {:interrupt, nil}}
    end

    # Paced in a 300 ms window, a Grok reply has little waiting here to age out
    # while the phone is away: what it was sent and never reported is unheard
    # already, so the session is not left awaiting reports for it (2 s ends
    # the call), and the phone's resume finds the call up.
    test "a Grok reply in flight when the phone goes is interrupted at once", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "xai_realtime")
      send(voice, {:push, %{type: "audio_delta", audio: grok_audio(2), playback_id: "p1"}})
      assert length(audio_frames(2)) == 2

      Process.unlink(relay)
      Process.exit(relay, :kill)
      assert_receive {:voice, ^voice, {:interrupt, nil}}
      await(call, &(&1.attached == nil))
    end

    test "a Grok phone that goes with nothing unheard is not interrupted", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "xai_realtime")
      Process.unlink(relay)
      Process.exit(relay, :kill)
      await(call, &(&1.attached == nil))
      refute_received {:voice, ^voice, {:interrupt, nil}}
    end

    test "a Live phone that goes mid-reply is not interrupted", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "openai_live")
      push_audio(voice, 2)
      assert length(audio_frames(2)) == 2

      Process.unlink(relay)
      Process.exit(relay, :kill)
      await(call, &(&1.attached == nil))
      refute_received {:voice, ^voice, {:interrupt, nil}}
    end

    # What was in flight when the link went is never reported; the resume
    # frees its credit, so the stream goes on.
    test "a resume mid-stream on Live keeps the audio flowing", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "openai_live")
      push_audio(voice, 5)
      assert length(audio_frames(5)) == 5

      Process.unlink(relay)
      Process.exit(relay, :kill)
      await(call, &(&1.attached == nil))
      test = self()
      relay = spawn_link(fn -> relay(test) end)
      :ok = Call.open(@phone_id, relay, @call, true, calls: ctx.calls)
      assert_receive {:from_call, :control, %{"t" => "call_attached", "resumed" => true}}

      push_audio(voice, 3)
      assert [%{"playback_id" => "m1"}, _second, _third] = audio_frames(3)
    end

    # Each barge-in's stop leaves frames the phone drops unreported.
    test "three barge-ins on Grok, each with a reply unheard, leave the call speaking", ctx do
      %{call: call, voice: voice} = call_alone!(ctx, "xai_realtime")

      for n <- 1..3 do
        id = "p#{n}"
        send(voice, {:push, %{type: "audio_delta", audio: grok_audio(5), playback_id: id}})
        assert length(audio_frames(5)) == 5
        send(voice, {:push, %{type: "playback_stop"}})
        assert_receive {:from_call, :stop, %{"t" => "call_line"}}
      end

      send(voice, {:push, %{type: "audio_delta", audio: grok_audio(2), playback_id: "p4"}})
      assert [%{"playback_id" => "p4"}, %{"playback_id" => "p4"}] = audio_frames(2)
      assert Process.alive?(call)
    end

    # The phone reports per id on every engine; a report it could not have
    # made is refused as the session refuses it, and ends the call.
    for {label, reports, reason} <- [
          {"an id never sent", [{"m9", 0}], "unknown_playback"},
          {"a regression", [{"m1", 80}, {"m1", 40}], "playback_regressed"},
          {"a report beyond what was sent", [{"m1", 101}], "playback_beyond_sent"}
        ] do
      test "#{label} is refused #{reason}, ending the call", ctx do
        %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "openai_live")
        push_audio(voice, 1)
        assert [%{"playback_id" => "m1"}] = audio_frames(1)
        call_ref = Process.monitor(call)

        for {id, played} <- unquote(Macro.escape(reports)) do
          progress = %{type: "playback_progress", playback_id: id, played_ms: played}
          send(call, line_frame(relay, Map.put(progress, :drained, false), nil, 0))
        end

        assert_receive {:from_call, :control, %{"t" => "call_line", "bytes" => refusal}}
        assert Jason.decode!(refusal) == %{"type" => "error", "reason" => unquote(reason)}
        assert_receive {:from_call, :control, %{"t" => "call_close", "reason" => "ended"}}
        assert_receive {:DOWN, ^call_ref, :process, ^call, :normal}
        refute_received {:voice, ^voice, {:playback_progress, _id, _played, _drained}}
      end
    end

    # A link can drop with the handshake in flight: the phone sends its
    # `client_hello` again on resume when it never saw `server_hello`.
    test "a repeated client_hello at the negotiated version is answered again", ctx do
      %{call: call, voice: voice, relay: relay} = call_alone!(ctx, "openai_live")

      send(call, line_frame(relay, %{type: "client_hello", protocol_version: 3}, nil, 0))
      assert_receive {:from_call, :control, %{"t" => "call_line", "bytes" => hello}}
      assert %{"type" => "server_hello", "max_version" => 3} = Jason.decode!(hello)

      send(call, line_frame(relay, %{type: "mute", enabled: true}, 2, 0))
      assert_receive {:voice, ^voice, {:mute, true}}
      call_ref = Process.monitor(call)

      send(call, line_frame(relay, %{type: "client_hello", protocol_version: 2}, nil, 0))
      assert_receive {:from_call, :control, %{"t" => "call_line", "bytes" => refusal}}
      assert Jason.decode!(refusal) == %{"type" => "error", "reason" => "unexpected_client_hello"}
      assert_receive {:from_call, :control, %{"t" => "call_close", "reason" => "ended"}}
      assert_receive {:DOWN, ^call_ref, :process, ^call, :normal}
    end

    test "a call resumed before its handshake completed takes client_hello as the first", ctx do
      test = self()
      relay = spawn_link(fn -> relay(test) end)
      opts = call_options(ctx, [])
      call_opts = [calls: ctx.calls, call_supervisor: ctx.call_supervisor, call_options: opts]
      :ok = Call.open(@phone_id, relay, @call, false, call_opts)
      assert_receive {:from_call, :control, %{"t" => "call_attached", "resumed" => false}}
      call = call_pid!(ctx)

      Process.unlink(relay)
      Process.exit(relay, :kill)
      await(call, &(&1.attached == nil))
      relay = spawn_link(fn -> relay(test) end)
      :ok = Call.open(@phone_id, relay, @call, true, calls: ctx.calls)
      assert_receive {:from_call, :control, %{"t" => "call_attached", "resumed" => true}}

      send(call, line_frame(relay, %{type: "client_hello", protocol_version: 3}, nil, 0))
      assert_receive {:from_call, :control, %{"t" => "call_line", "bytes" => hello}}
      assert %{"type" => "server_hello"} = Jason.decode!(hello)
    end

    test "a reconnect's gap and its resume are on the call's trace", ctx do
      %{call: call, voice: voice, relay: relay, clock: clock} = call_alone!(ctx, "openai_live")
      trace = "voice_live:#{System.unique_integer([:positive])}"
      phases = [[:fermix, :voice_live, :phone_detached], [:fermix, :voice_live, :phone_resumed]]
      TelemetryCapture.attach(phases, session_id: trace)

      ready = %{type: "call_ready", engine: "openai_live", call_id: trace, call_uuid: "u-1"}
      send(voice, {:push, Map.put(ready, :conversation, "chat")})
      assert_receive {:from_call, :control, %{"t" => "call_line"}}

      Process.unlink(relay)
      Process.exit(relay, :kill)
      assert_receive {:telemetry, [:fermix, :voice_live, :phone_detached], %{}, detached}
      assert detached.endpoint == "phone:#{@phone_id}"
      assert detached.engine == "openai_live"

      Agent.update(clock, &(&1 + 1_250))
      test = self()
      relay = spawn_link(fn -> relay(test) end)
      :ok = Call.open(@phone_id, relay, @call, true, calls: ctx.calls)
      assert_receive {:from_call, :control, %{"t" => "call_attached", "resumed" => true}}

      assert_receive {:telemetry, [:fermix, :voice_live, :phone_resumed], %{duration_ms: 1_250},
                      resumed}

      assert resumed.call_uuid == "u-1"
      assert resumed.endpoint == "phone:#{@phone_id}"
      _ = :sys.get_state(call)
    end

    test "phone audio that waited 300 ms is dropped before the session", ctx do
      %{call: call, voice: voice, relay: relay, clock: clock} = call_alone!(ctx, "openai_live")
      now = Agent.get(clock, & &1)

      send(call, {:call_frame, relay, "call_audio", %{"call_id" => @call}, @pcm, now - 300})
      send(call, {:call_frame, relay, "call_audio", %{"call_id" => @call}, <<2, 0>>, now - 299})

      assert_receive {:voice, ^voice, {:audio, <<2, 0>>}}
      refute_received {:voice, ^voice, {:audio, @pcm}}
    end
  end

  # -- helpers ------------------------------------------------------------------

  # A call up with the test as its phone's session, behind a relay process.
  defp call_alone!(ctx, engine, overrides \\ []) do
    test = self()
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    relay = spawn_link(fn -> relay(test) end)
    model = if engine == "xai_realtime", do: "grok-voice-3.0", else: "gpt-live-1"

    opts =
      call_options(
        %{ctx | engine: engine},
        [
          clock: fn -> Agent.get(clock, & &1) end,
          config: fn -> Config.normalize(enabled: true, engine: engine, model: model) end
        ] ++ overrides
      )

    call_opts = [calls: ctx.calls, call_supervisor: ctx.call_supervisor, call_options: opts]
    :ok = Call.open(@phone_id, relay, @call, false, call_opts)
    assert_receive {:from_call, :control, %{"t" => "call_attached"}}
    call = call_pid!(ctx)

    send(call, line_frame(relay, %{type: "client_hello", protocol_version: 3}, nil, 0))
    assert_receive {:from_call, :control, %{"t" => "call_line"}}
    send(call, line_frame(relay, %{type: "call_start"}, 1, 0))
    assert_receive {:voice_started, voice, _opts}
    assert_receive {:from_call, :control, %{"t" => "call_line"}}
    %{call: call, voice: voice, relay: relay, clock: clock}
  end

  defp relay(test) do
    receive do
      {:mobile_call, _call, class, event} -> send(test, {:from_call, class, event})
      {:mobile_call_silent, call} -> send(test, {:call_silent, call})
    end

    relay(test)
  end

  defp line_frame(relay, line, control_seq, at) do
    header =
      if control_seq,
        do: %{"call_id" => @call, "control_seq" => control_seq},
        else: %{"call_id" => @call}

    {:call_frame, relay, "call_line", header, Jason.encode!(line), at}
  end

  defp push_audio(voice, frames) do
    send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(:binary.copy(@pcm, frames))}})
  end

  defp grok_audio(frames), do: Base.encode64(:binary.copy(@pcm, frames))

  # 100 ms later, the same report again and 100 ms more audio, both applied
  # (the voice session has passed the audio on, and the call has taken it): the
  # newest frame waiting is this step's.
  defp stuck_step(call, voice, relay, clock, stuck) do
    now = Agent.get_and_update(clock, &{&1 + 100, &1 + 100})
    send(call, line_frame(relay, stuck, nil, 0))
    push_audio(voice, 1)
    _ = :sys.get_state(voice)
    assert {:value, {^now, _id, _pcm}} = :queue.peek_r(:sys.get_state(call).audio.queue)
  end

  defp call_audio(playback_id),
    do: %{"t" => "call_audio", "call_id" => @call, "playback_id" => playback_id, "bytes" => @pcm}

  defp media_begin(ref) do
    %{
      "t" => "media_begin",
      "ref" => ref,
      "server_seq" => 3,
      "kind" => "image",
      "mime" => "image/png",
      "size_bytes" => 1,
      "sha256" => String.duplicate("a", 64)
    }
  end

  # What the call sent its session, in order, up to its close.
  defp controls_until_close(acc \\ [], left \\ 64)
  defp controls_until_close(_acc, 0), do: flunk("the call never closed")

  defp controls_until_close(acc, left) do
    assert_receive {:from_call, :control, event}

    if event["t"] == "call_close",
      do: Enum.reverse([event | acc]),
      else: controls_until_close([event | acc], left - 1)
  end

  defp audio_frames(count) do
    for _n <- 1..count do
      assert_receive {:from_call, :audio, %{"t" => "call_audio"} = frame}
      frame
    end
  end

  defp open(resume?), do: %{"call_id" => @call, "resume" => resume?}

  # A new call through the handshake and its start; the voice session is up.
  defp call_up!(driver, client, seq) do
    client = open_new!(driver, client, seq)
    client = send_line(driver, client, %{type: "client_hello", protocol_version: 3}, seq + 1, nil)
    {[{%{"t" => "call_line"}, hello}], client} = Driver.client_receive(driver, client)
    assert %{"type" => "server_hello", "max_version" => 3} = Jason.decode!(hello)

    client = send_line(driver, client, %{type: "call_start"}, seq + 2, 1)
    assert_receive {:voice_started, voice, opts}
    assert Keyword.fetch!(opts, :endpoint) == {:phone, @phone_id}
    {[{%{"t" => "call_line"}, listening}], client} = Driver.client_receive(driver, client)
    assert Jason.decode!(listening) == %{"type" => "state", "state" => "listening"}
    {client, voice}
  end

  defp open_new!(driver, client, seq) do
    client = Driver.client_send(driver, client, "call_open", open(false), seq)
    {[{attached, <<>>}], client} = Driver.client_receive(driver, client)

    assert attached["t"] == "call_attached"

    assert Map.take(attached, ~w(call_id resumed muted camera control_seq)) == %{
             "call_id" => @call,
             "resumed" => false,
             "muted" => false,
             "camera" => false,
             "control_seq" => 0
           }

    client
  end

  defp send_line(driver, client, line, seq, control_seq) do
    header =
      if control_seq,
        do: %{"call_id" => @call, "control_seq" => control_seq},
        else: %{"call_id" => @call}

    Driver.client_send(driver, client, "call_line", header, seq, Jason.encode!(line))
  end

  defp hang_up!(driver, client, voice, seq) do
    {events, _client} = hang_up_events(driver, client, voice, seq)
    assert {%{"t" => "call_close", "reason" => "ended"}, <<>>} = List.last(events)
  end

  defp hang_up_events(driver, client, voice, seq) do
    client = Driver.client_send(driver, client, "call_close", %{"call_id" => @call}, seq)
    assert_receive {:voice, ^voice, :call_stop}
    receive_until_close(driver, client)
  end

  # Every run the session pushes until one carries the call's close.
  defp receive_until_close(driver, client, acc \\ [], runs \\ 8)

  defp receive_until_close(_driver, client, acc, 0), do: {acc, client}

  defp receive_until_close(driver, client, acc, runs) do
    {events, client} = Driver.client_receive(driver, client)
    acc = acc ++ events

    if Enum.any?(events, fn {header, _bytes} -> header["t"] == "call_close" end),
      do: {acc, client},
      else: receive_until_close(driver, client, acc, runs - 1)
  end

  defp receive_events(driver, client, count, acc \\ [])
  defp receive_events(_driver, client, count, acc) when length(acc) >= count, do: {acc, client}

  defp receive_events(driver, client, count, acc) do
    {events, client} = Driver.client_receive(driver, client)
    receive_events(driver, client, count, acc ++ events)
  end

  defp close_session(driver) do
    ref = Process.monitor(driver)
    send(driver, {:mobile_replaced, self()})
    assert_receive {:driver_closed, ^driver, :replaced, _close, _frames}
    assert_receive {:DOWN, ^ref, :process, ^driver, _reason}
  end

  defp call_pid!(ctx) do
    assert [{call, _value}] = Registry.lookup(ctx.calls, @phone_id)
    call
  end

  # Bounded round trips through the call's mailbox, never a sleep.
  defp await(call, ready?, rounds \\ 200)
  defp await(_call, _ready?, 0), do: flunk("the call never reached the state awaited")

  defp await(call, ready?, rounds) do
    state = :sys.get_state(call)
    if ready?.(state), do: state, else: await(call, ready?, rounds - 1)
  end

  defp ready_phone!(ctx, call_options \\ []),
    do: ready!(ctx, ctx.phone, @phone_id, call_options: call_options(ctx, call_options))

  defp call_options(ctx, overrides) do
    test = self()
    lease = ctx.lease
    engine = ctx.engine

    starter = fn session_opts ->
      spec = %{observer: test, opts: session_opts, lease: lease, engine: engine}

      with {:ok, voice} <- GenServer.start(Voice, spec) do
        send(test, {:voice_started, voice, session_opts})
        {:ok, voice}
      end
    end

    Keyword.merge(
      [
        session_module: Voice,
        session_starter: starter,
        session_guard: ctx.guard,
        task_supervisor: ctx.tasks,
        config: fn -> Config.normalize(enabled: true, engine: engine, model: "gpt-live-1") end,
        ready: fn _config -> :ok end
      ],
      overrides
    )
  end

  defp ready!(ctx, keypair, device_id, opts) do
    keys = %{ctx.desktop.public => @desktop_id, ctx.phone.public => @phone_id}

    driver =
      Driver.start!(
        [
          peer: {127, 0, 0, 1},
          gateway_keypair: ctx.gateway,
          primary_epoch: 4,
          device_store: :store,
          device_registry: ctx.registry,
          calls: ctx.calls,
          call_supervisor: ctx.call_supervisor,
          start_desktop_peer: fn _opts -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end,
          record_engine_version: fn _id, _version, _at -> :ok end,
          find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
          update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
          wall_clock: fn -> @seen end,
          hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
          pending_approvals: fn "main" -> [] end
        ] ++ opts
      )

    {:ok, client} =
      Noise.initialize(:initiator, :ik,
        static_keypair: keypair,
        remote_static: ctx.gateway.public
      )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => device_id,
      "app_version" => "0.18.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    client = Driver.client_send(driver, client, "hello", hello, 1)

    assert {[{%{"t" => "hello_ack", "seq" => 1}, <<>>}], client} =
             Driver.client_receive(driver, client)

    {driver, client}
  end

  defp row(@desktop_id), do: %{device_id: @desktop_id, name: "Studio Mac", kind: :desktop}
  defp row(id), do: %{device_id: id, name: "Garden phone", kind: :phone}

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "s-1",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 1},
      "primary_epoch" => 4
    }
  end
end
