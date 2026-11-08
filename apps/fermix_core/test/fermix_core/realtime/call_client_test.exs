defmodule FermixCore.Realtime.CallClientTest do
  @moduledoc """
  The transport-independent half of a voice connection, driven with no socket:
  what it hands a session, and what it says through the adapter's `emit`.
  The Unix wire end to end is `LocalVoiceSocketTest`.
  """

  # Reads and writes the global realtime and providers app env.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Realtime.CallClient
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.SessionGuard
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.CallLeases

  @robot {:accessory, "desk-robot"}
  @phone {:phone, "0d7f6a52-91c3-4b8e-a1f0-5e2d9c4b7a13"}

  # A session double. `call_start` queues a frame for the adapter, then answers
  # what the test scripted; `call_stop` tells the test and ends the session; a
  # forwarded verb tells the test. Given a lease, it takes the home's call in
  # `init/1` as an engine session does. Unlinked, as a supervised session is to
  # its adapter, and it ends with the test that started it.
  defmodule ScriptedSession do
    use GenServer

    alias FermixCore.Realtime.CallLease

    def start(spec), do: GenServer.start(__MODULE__, spec)

    def call_start(pid), do: GenServer.call(pid, :call_start)
    def call_stop(pid), do: GenServer.call(pid, :call_stop)
    def cancel_task(pid, id), do: GenServer.call(pid, {:forwarded, {:cancel_task, id}})
    def mute(pid, enabled?), do: GenServer.call(pid, {:forwarded, {:mute, enabled?}})

    def playback_progress(pid, id, played_ms, drained?),
      do: GenServer.call(pid, {:forwarded, {:playback_progress, id, played_ms, drained?}})

    @impl true
    def init(%{observer: observer, opts: opts, lease: lease} = spec) do
      Process.monitor(observer)

      case take_lease(lease, Keyword.fetch!(opts, :endpoint)) do
        :ok -> {:ok, spec}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_call(:call_start, _from, state) do
      companion = Keyword.fetch!(state.opts, :companion)
      send(companion, {:realtime, %{type: "state", state: "listening"}})

      case state.answer do
        {:die, reason} -> {:stop, reason, state}
        answer -> {:reply, answer, state}
      end
    end

    # A session stuck settling (a busy Queue under a hand-off's stop) answers
    # no `call_stop`; it has been told, and ends when the test does.
    def handle_call(:call_stop, _from, %{stop: :stuck} = state) do
      send(state.observer, {:call_stop, self()})
      {:noreply, state}
    end

    def handle_call(:call_stop, _from, state) do
      send(state.observer, {:call_stop, self()})
      {:stop, :normal, :ok, state}
    end

    def handle_call({:forwarded, {:cancel_task, "stuck"} = verb}, _from, state) do
      send(state.observer, {:forwarded, verb})
      {:noreply, state}
    end

    def handle_call({:forwarded, verb}, _from, state) do
      send(state.observer, {:forwarded, verb})
      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, observer, _reason}, %{observer: observer} = state),
      do: {:stop, :normal, state}

    defp take_lease(nil, _endpoint), do: :ok
    defp take_lease(lease, endpoint), do: CallLease.acquire(lease, endpoint, "openai_realtime")
  end

  setup do
    put_realtime_env(engine: "openai_realtime")
    unique = System.unique_integer([:positive])
    tasks = start_supervised!({Task.Supervisor, name: :"call_client_tasks_#{unique}"})
    guard = :"call_client_guard_#{unique}"
    start_supervised!({SessionGuard, name: guard, task_supervisor: tasks})
    %{guard: guard, tasks: tasks}
  end

  describe "the session a call starts" do
    test "carries the endpoint and the adapter as its companion, guarded", ctx do
      client = new_client(ctx, endpoint: @robot, answer: :ok)

      assert {:cont, client} = CallClient.call_start(client)
      assert_receive {:session_started, session, opts}

      assert Keyword.fetch!(opts, :endpoint) == @robot
      assert Keyword.fetch!(opts, :companion) == self()
      assert client.session == session
      assert %{session: ^session} = :sys.get_state(ctx.guard).bindings[self()]
      # A started call's frames stay queued for the adapter's own loop to write.
      assert_receive {:realtime, %{type: "state", state: "listening"}}
      refute_received {:emitted, _frame}
    end

    # The session pushed its frames to this process while `call_start` was
    # blocked; they reach the adapter, in order, before the refusal's own word.
    test "a refused start flushes what the session queued, then the refusal", ctx do
      client = new_client(ctx, answer: {:error, :provider_refused})

      assert {:stop, _client} = CallClient.call_start(client)

      assert_receive {:emitted, %{type: "state", state: "listening"}}
      assert_receive {:emitted, %{type: "error", reason: "provider_refused"}}
    end

    test "a lease refusal says the call is in progress and where", ctx do
      starter = fn _opts -> {:error, {:call_in_progress, "accessory:desk-robot"}} end
      client = new_client(ctx, session_starter: starter)

      assert {:stop, %CallClient{session: nil}} = CallClient.call_start(client)

      assert_receive {:emitted,
                      %{
                        type: "error",
                        reason: "call_in_progress",
                        held_by: "accessory:desk-robot"
                      }}
    end

    test "below the engine's minimum version, no session starts", ctx do
      put_realtime_env(engine: "openai_live")
      config = Config.current()
      client = new_client(ctx, config: config, protocol_version: 1, answer: :ok)

      assert {:stop, _client} = CallClient.call_start(client)

      assert_receive {:emitted,
                      %{
                        type: "error",
                        reason: "unsupported_protocol_version",
                        kind: "update_required",
                        min_version: 2,
                        required_for: "openai_live"
                      }}

      refute_received {:session_started, _session, _opts}
    end

    # A session nothing would guard is never started.
    test "with no guard running, no session starts", ctx do
      missing = :"call_client_missing_guard_#{System.unique_integer([:positive])}"
      client = new_client(ctx, session_guard: missing, answer: :ok)

      {result, _log} = ExUnit.CaptureLog.with_log(fn -> CallClient.call_start(client) end)

      assert {:stop, %CallClient{session: nil}} = result
      refute_received {:session_started, _session, _opts}
      assert_receive {:emitted, %{type: "error", reason: "session_guard_unavailable"}}
    end

    # The one point a session exists, holds the home's call and is not yet the
    # guard's: its start has made it and not returned. An adapter killed there
    # (a serial link unplugged, a phone's call revoked) leaves no session
    # running and the call free for the next.
    test "an adapter that dies while its session starts leaves no session and no call", ctx do
      lease = CallLeases.own!()
      test_pid = self()

      starter = fn session_opts ->
        spec = %{observer: test_pid, opts: session_opts, answer: :ok, lease: lease}
        {:ok, session} = ScriptedSession.start(spec)
        send(test_pid, {:session_up, session, self()})
        hold_start(session)
      end

      client = new_client(ctx, session_starter: starter)
      adapter = spawn(fn -> CallClient.call_start(client) end)
      assert_receive {:session_up, session, start}
      assert {:ok, %{endpoint: "desktop"}} = CallLease.holder(lease)
      session_ref = Process.monitor(session)

      adapter_ref = Process.monitor(adapter)
      Process.exit(adapter, :kill)
      assert_receive {:DOWN, ^adapter_ref, :process, ^adapter, :killed}
      # The guard has seen the adapter go before the start hands it the session.
      await_guard(ctx.guard, &(&1.bindings == %{}), 1_000)
      send(start, :finish_start)

      assert_receive {:call_stop, ^session}
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
      assert CallLease.holder(lease) == :none
    end

    # The wire carries the code alone; the guard's log keeps the crash.
    @tag :capture_log
    test "a start that crashes says session_start_failed and nothing more", ctx do
      client = new_client(ctx, session_starter: fn _opts -> raise "engine init blew up" end)

      assert {:stop, %CallClient{session: nil}} = CallClient.call_start(client)
      assert_receive {:emitted, frame}
      assert frame == %{type: "error", reason: "session_start_failed"}
    end

    # The session died inside `call_start`: the peer gets what it queued, then
    # the death, instead of a closed connection with no word.
    @tag :capture_log
    test "a session that dies inside call_start is told as session_down", ctx do
      client = new_client(ctx, answer: {:die, :engine_crashed})

      assert {:stop, _client} = CallClient.call_start(client)

      assert_receive {:emitted, %{type: "state", state: "listening"}}
      assert_receive {:emitted, %{type: "error", reason: "{:session_down, :engine_crashed}"}}
    end

    test "a verb reaching a session that just died is told as session_down", ctx do
      client = started_client(ctx, Config.normalize(enabled: true))
      %CallClient{session: session, session_ref: ref} = client
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}

      assert {:stop, _client} = CallClient.mute(client, true)
      assert_receive {:emitted, %{type: "error", reason: "{:session_down, :noproc}"}}
    end

    test "call_stop tears the session down, releases it and says idle", ctx do
      client = new_client(ctx, answer: :ok)
      {:cont, client} = CallClient.call_start(client)
      session = client.session

      assert {:cont, %CallClient{session: nil}} = CallClient.call_stop(client)

      assert_receive {:call_stop, ^session}
      assert :sys.get_state(ctx.guard).bindings == %{}
      assert_receive {:emitted, %{type: "state", state: "listening"}}
      assert_receive {:emitted, %{type: "state", state: "idle"}}
    end

    # The adapter learnt of the death from its monitor; the guard must not keep
    # a session that is gone bound to an adapter that lives on.
    test "a session that dies mid-call is told to the peer, and the guard lets it go", ctx do
      client = new_client(ctx, answer: :ok)
      {:cont, client} = CallClient.call_start(client)
      %CallClient{session: session, session_ref: ref} = client

      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}

      assert {:stop, %CallClient{session: nil}} = CallClient.session_down(client, :killed)
      assert_receive {:emitted, %{type: "error", reason: "{:session_down, :killed}"}}
      assert :sys.get_state(ctx.guard).bindings == %{}
    end
  end

  # The verbs only some engines have are refused under the others before the
  # session hears them, so no session ever gets a verb it has no clause for.
  describe "verbs one engine has" do
    test "task_cancel is refused under OpenAI Realtime", ctx do
      client = started_client(ctx, Config.normalize(enabled: true))

      assert {:stop, _client} = CallClient.task_cancel(client, "delegation-1")

      assert_receive {:emitted, %{type: "error", reason: "unsupported_by_engine"}}
      refute_received {:forwarded, _verb}
    end

    test "task_cancel reaches a task engine's session", ctx do
      client = started_client(ctx, live_config())

      assert {:cont, _client} = CallClient.task_cancel(client, "delegation-1")
      assert_receive {:forwarded, {:cancel_task, "delegation-1"}}
    end

    test "playback_progress is refused off Grok", ctx do
      client = started_client(ctx, live_config())

      assert {:stop, _client} = CallClient.playback_progress(client, "playback-1", 120, false)

      assert_receive {:emitted, %{type: "error", reason: "unsupported_by_engine"}}
      refute_received {:forwarded, _verb}
    end

    test "playback_progress reaches a Grok session", ctx do
      grok = Config.normalize(enabled: true, engine: "xai_realtime", model: "grok-voice-3.0")
      client = started_client(ctx, grok)

      assert {:cont, _client} = CallClient.playback_progress(client, "playback-1", 120, true)
      assert_receive {:forwarded, {:playback_progress, "playback-1", 120, true}}
    end
  end

  describe "a phone's call" do
    # M87 D2: the Realtime engine joins no chat and offers a screen-share tool
    # for a Mac the caller is away from, so a phone is refused before any
    # session exists.
    test "is refused under OpenAI Realtime before any session starts", ctx do
      client = new_client(ctx, endpoint: @phone, answer: :ok)

      assert {:stop, %CallClient{session: nil}} = CallClient.call_start(client)

      assert_receive {:emitted, %{type: "error", reason: "engine_not_for_phones"}}
      refute_received {:session_started, _session, _opts}
    end

    test "starts under a task engine, for the phone", ctx do
      client = new_client(ctx, endpoint: @phone, config: live_config(), answer: :ok)

      assert {:cont, _client} = CallClient.call_start(client)
      assert_receive {:session_started, _session, opts}
      assert Keyword.fetch!(opts, :endpoint) == @phone
    end

    test "is refused below its engine's floor, which caps.call publishes" do
      assert CallClient.engine_min_protocol_version(live_config()) == 2

      assert CallClient.engine_min_protocol_version(
               Config.normalize(enabled: true, engine: "xai_realtime", model: "grok-voice-3.0")
             ) == 3

      assert CallClient.engine_min_protocol_version(Config.normalize(enabled: true)) == 1
    end
  end

  # M91 E3: the owner's voice device is this Mac or a paired accessory, and
  # the engine holds it: while an accessory is chosen, this Mac's own call is
  # refused before any session, with its reason, the device and the daemon's
  # sentence. An accessory's own call, and a phone's, are not this Mac's.
  describe "the voice device" do
    @chosen_robot "accessory:" <> String.duplicate("4f", 32)

    test "a desktop call is refused while a paired accessory is the voice device", ctx do
      robot = fn -> {:ok, {:accessory, String.duplicate("4f", 32)}} end
      client = new_client(ctx, voice_device: robot)

      assert {:stop, %CallClient{session: nil}} = CallClient.call_start(client)

      assert_receive {:emitted,
                      %{
                        type: "error",
                        reason: "voice_device_elsewhere",
                        voice_device: @chosen_robot,
                        sentence: sentence
                      }}

      assert sentence =~ "voice device"
      refute_received {:session_started, _session, _opts}
    end

    test "an accessory's own call and a phone's are not refused for it", ctx do
      robot = fn -> {:ok, {:accessory, String.duplicate("4f", 32)}} end

      for endpoint <- [{:accessory, String.duplicate("4f", 32)}, @phone] do
        config = if endpoint == @phone, do: live_config(), else: Config.current()
        client = new_client(ctx, endpoint: endpoint, config: config, voice_device: robot)
        assert {:cont, client} = CallClient.call_start(client)
        CallClient.teardown(client)
      end
    end

    # Fable review 3: a choice that cannot be read is no choice of this Mac;
    # the call is refused with its own reason until the owner chooses again.
    test "a voice device that cannot be read refuses this Mac's call, and the log says why",
         ctx do
      unreadable = fn -> {:error, {:invalid_voice_device, "/invented/voice_device.json"}} end
      client = new_client(ctx, voice_device: unreadable)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:stop, %CallClient{session: nil}} = CallClient.call_start(client)
        end)

      assert_receive {:emitted,
                      %{
                        type: "error",
                        reason: "voice_device_unreadable",
                        sentence: "The voice device could not be read. Choose one in Pet."
                      } = frame}

      refute Map.has_key?(frame, :voice_device)
      refute_received {:session_started, _session, _opts}
      assert log =~ "voice device could not be read"
    end

    # Fable review 7: the robot stays chosen when accessories are turned off,
    # and the refusal says so rather than calling it the voice device in use.
    test "a robot still chosen with accessories off is refused in those words", ctx do
      robot = fn -> {:ok, {:accessory, String.duplicate("4f", 32)}} end
      client = new_client(ctx, voice_device: robot, accessories_enabled?: fn -> false end)

      assert {:stop, _client} = CallClient.call_start(client)

      assert_receive {:emitted,
                      %{
                        reason: "voice_device_elsewhere",
                        voice_device: @chosen_robot,
                        sentence:
                          "StackChan is off but is still your voice device. Choose This Mac in " <>
                            "Pet to talk here."
                      }}
    end
  end

  # The Realtime wire's events, decoded, as the call's verbs: the one mapping
  # every adapter speaking that wire shares.
  describe "the wire's events" do
    test "drive the verbs they name", ctx do
      client = started_client(ctx, live_config())

      assert {:cont, client} =
               CallClient.event(client, %{type: "mute", payload: %{"enabled" => false}})

      assert_receive {:forwarded, {:mute, false}}

      assert {:cont, _client} =
               CallClient.event(client, %{
                 type: "task_cancel",
                 payload: %{"delegation_id" => "delegation-1"}
               })

      assert_receive {:forwarded, {:cancel_task, "delegation-1"}}
    end

    test "call_start starts the call", ctx do
      client = new_client(ctx, answer: :ok)

      assert {:cont, %CallClient{session: session}} =
               CallClient.event(client, %{type: "call_start", payload: %{}})

      assert is_pid(session)
    end
  end

  # `cancel_task` and `call_stop` wait with no timeout of their own; an adapter
  # that must stay up for its peer (the phone's call) gives them a deadline.
  describe "the deadline on the unbounded verbs" do
    @tag :capture_log
    test "a cancel past it is given up and the call goes on", ctx do
      client = started_client(ctx, live_config(), deadline_ms: 50)

      assert {:cont, %CallClient{session: session}} = CallClient.task_cancel(client, "stuck")

      assert_receive {:forwarded, {:cancel_task, "stuck"}}
      assert Process.alive?(session)
      refute_received {:emitted, %{type: "error"}}
    end

    @tag :capture_log
    test "a stop past it lets the session go from the guard and still says idle", ctx do
      client = started_client(ctx, live_config(), deadline_ms: 50, stop: :stuck)
      session = client.session

      assert {:cont, %CallClient{session: nil}} = CallClient.call_stop(client)

      assert_receive {:call_stop, ^session}
      assert :sys.get_state(ctx.guard).bindings == %{}
      assert_receive {:emitted, %{type: "state", state: "idle"}}
    end

    test "is no deadline at all by default: the socket waits as SessionControl does", ctx do
      assert new_client(ctx, answer: :ok).deadline_ms == :infinity
    end
  end

  describe "the default starter's options" do
    test "derive the engine module and session scope from the engine" do
      put_openai_key()
      put_realtime_env(engine: "openai_live")

      assert {:ok, live_opts} = CallClient.session_opts(endpoint: :desktop)
      assert Keyword.fetch!(live_opts, :engine_module) == FermixCore.Realtime.LiveSessionServer
      assert "voice_live:" <> _minted = Keyword.fetch!(live_opts, :session_scope)
      assert Config.live?(Keyword.fetch!(live_opts, :config))

      put_realtime_env(engine: "openai_realtime")

      assert {:ok, realtime_opts} = CallClient.session_opts(endpoint: :desktop)
      assert Keyword.fetch!(realtime_opts, :engine_module) == SessionServer
      assert "session:" <> _minted = Keyword.fetch!(realtime_opts, :session_scope)
      refute Config.live?(Keyword.fetch!(realtime_opts, :config))
    end

    test "keep a caller-supplied session scope" do
      put_openai_key()
      put_realtime_env(engine: "openai_live")

      assert {:ok, opts} =
               CallClient.session_opts(endpoint: :desktop, session_scope: "voice_live:pinned")

      assert Keyword.fetch!(opts, :session_scope) == "voice_live:pinned"
    end

    # M70 §06: a call dials with the key `Realtime.Config.api_key/1` resolves
    # for the engine in force, so a Grok call carries the SpaceXAI key and never
    # the OpenAI one, and a missing key stops the start before any session
    # exists.
    test "carry the Grok engine's SpaceXAI key" do
      put_openai_key()
      providers = Application.get_env(:fermix_core, :providers, [])

      Application.put_env(
        :fermix_core,
        :providers,
        Keyword.put(providers, :xai, api_key: "xai-test-voice")
      )

      put_realtime_env(engine: "xai_realtime")

      assert {:ok, opts} = CallClient.session_opts(endpoint: :desktop)
      assert Keyword.fetch!(opts, :api_key) == "xai-test-voice"
      assert Keyword.fetch!(opts, :config).provider == "xai"
      assert "voice_live:" <> _minted = Keyword.fetch!(opts, :session_scope)
    end

    test "refuse a Grok call with no SpaceXAI key, naming the provider" do
      put_openai_key()
      put_realtime_env(engine: "xai_realtime")

      assert CallClient.session_opts(endpoint: :desktop) == {:error, {:missing_api_key, "xai"}}
    end

    # The desktop keeps the identifier its calls always carried; an accessory's
    # comes from the accessory, never from the Mac it is plugged into.
    test "carry the endpoint's safety identifier" do
      put_openai_key()
      {:ok, mac} = DeviceIdentity.ensure_device_id(ConfigStore.workspace_paths().realtime)
      owner = MemoryConfig.owner_id()

      assert {:ok, desktop} = CallClient.session_opts(endpoint: :desktop)
      assert {:ok, robot} = CallClient.session_opts(endpoint: @robot)

      assert Keyword.fetch!(desktop, :safety_identifier) ==
               DeviceIdentity.safety_identifier(owner, mac)

      assert Keyword.fetch!(robot, :safety_identifier) ==
               DeviceIdentity.safety_identifier(owner, "accessory:desk-robot")

      assert Keyword.fetch!(robot, :endpoint) == @robot
    end
  end

  defp new_client(ctx, opts) do
    test_pid = self()
    answer = Keyword.get(opts, :answer, :ok)

    stop = Keyword.get(opts, :stop, :ends)

    starter = fn session_opts ->
      spec = %{observer: test_pid, opts: session_opts, answer: answer, lease: nil, stop: stop}

      with {:ok, pid} <- ScriptedSession.start(spec) do
        send(test_pid, {:session_started, pid, session_opts})
        {:ok, pid}
      end
    end

    CallClient.new(
      endpoint: Keyword.get(opts, :endpoint, :desktop),
      protocol_version: Keyword.get(opts, :protocol_version, 3),
      config: Keyword.get(opts, :config, Config.current()),
      emit: fn frame ->
        send(test_pid, {:emitted, frame})
        :ok
      end,
      session_module: ScriptedSession,
      session_starter: Keyword.get(opts, :session_starter, starter),
      session_guard: Keyword.get(opts, :session_guard, ctx.guard),
      task_supervisor: ctx.tasks,
      deadline_ms: Keyword.get(opts, :deadline_ms, :infinity),
      voice_device: Keyword.get(opts, :voice_device, fn -> {:ok, :desktop} end),
      accessories_enabled?: Keyword.get(opts, :accessories_enabled?, fn -> true end)
    )
  end

  # A client whose call is up under `config`, its start's frames drained.
  defp started_client(ctx, config, opts \\ []) do
    client = new_client(ctx, [config: config, answer: :ok] ++ opts)
    {:cont, client} = CallClient.call_start(client)
    assert_receive {:realtime, %{type: "state", state: "listening"}}
    client
  end

  defp live_config,
    do: Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1")

  # The start stands still once its session exists, until the test lets it
  # hand the session over; bounded, so it never outlives its test for long.
  defp hold_start(session) do
    receive do
      :finish_start -> {:ok, session}
    after
      10_000 -> {:ok, session}
    end
  end

  # Bounded round trips through the guard's mailbox, not an event wait: the
  # guard handling an adapter's exit sends nothing a test could wait on.
  defp await_guard(guard, reached?, attempts_left) when attempts_left > 0 do
    if reached?.(:sys.get_state(guard)),
      do: :ok,
      else: await_guard(guard, reached?, attempts_left - 1)
  end

  defp await_guard(_guard, _reached?, 0), do: flunk("the session guard never reached the state")

  defp put_realtime_env(config) do
    previous = Application.get_env(:fermix_core, :realtime, [])
    Application.put_env(:fermix_core, :realtime, config)
    on_exit(fn -> Application.put_env(:fermix_core, :realtime, previous) end)
    :ok
  end

  defp put_openai_key do
    previous = Application.get_env(:fermix_core, :providers, [])

    Application.put_env(
      :fermix_core,
      :providers,
      Keyword.put(previous, :openai, api_key: "sk-test-voice")
    )

    on_exit(fn -> Application.put_env(:fermix_core, :providers, previous) end)
    :ok
  end
end
