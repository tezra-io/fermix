defmodule FermixChannels.Desktop.TwoEnginesVoiceTest do
  @moduledoc """
  A voice call from a computer's app on its server (M97 §9.2), end to end
  over the real link: the app on the computer's own `realtime.sock`
  (`LocalVoiceSocket` bridged by `Desktop.CallBridge`), the computer's real
  `Desktop.Relay`, the rail's Noise session to the server's real
  `Mobile.Session`, and there the phone's call path: `Mobile.Call`,
  `CallClient`, `SessionGuard` and the home's call lease, with a scripted
  voice session in place of a provider's. What is stood in for is the dial
  (the bridge socket), the trust store's row and the voice session.

  async: false: the relay's dial names are VM-wide.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias FermixChannels.Desktop.CallBridge
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Mobile.Call
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionGuard
  alias FermixTestSupport.SafeRm

  @arrival_ms 10_000
  @pcm :binary.copy(<<1, 0>>, 2_400)

  # A voice session in place of an engine's: it takes the home's call in
  # `init/1` as every engine does, tells the test each verb, and pushes to its
  # companion whatever the test hands it (`{:push, frame}`).
  defmodule Voice do
    @moduledoc false
    use GenServer

    def call_start(pid), do: GenServer.call(pid, :call_start)
    def audio_chunk(pid, audio), do: GenServer.cast(pid, {:verb, {:audio, audio}})
    def interrupt(pid, end_ms), do: GenServer.call(pid, {:verb, {:interrupt, end_ms}})
    def mute(pid, enabled?), do: GenServer.call(pid, {:verb, {:mute, enabled?}})
    def camera(pid, on?), do: GenServer.call(pid, {:verb, {:camera, on?}})
    def camera_frame(pid, frame), do: GenServer.cast(pid, {:verb, {:camera_frame, frame}})
    def cancel_task(pid, id), do: GenServer.call(pid, {:verb, {:cancel_task, id}})

    def playback_progress(pid, id, played, drained?),
      do: GenServer.call(pid, {:verb, {:playback_progress, id, played, drained?}})

    def call_stop(pid), do: GenServer.call(pid, :call_stop)

    @impl true
    def init(%{observer: observer, opts: opts, lease: lease}) do
      Process.monitor(observer)

      case CallLease.acquire(lease, Keyword.fetch!(opts, :endpoint), "openai_live") do
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
  end

  setup do
    server = server_calls!()

    primary =
      DesktopRail.primary!(
        calls: server.calls,
        call_supervisor: server.call_supervisor,
        call_options: server.call_options,
        call_caps: &Call.caps(server.config, true, &1)
      )

    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    socket = Path.join(System.tmp_dir!(), "fx-vb-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> SafeRm.rm(socket) end)
    tasks = start_supervised!({Task.Supervisor, name: nil}, id: :bridge_tasks)

    start_supervised!(
      {LocalVoiceSocket,
       socket_path: socket,
       task_supervisor: tasks,
       name: :"voice_bridge_#{System.unique_integer([:positive])}",
       bridge: {CallBridge, relay: relay}},
      id: :voice_bridge
    )

    Map.merge(server, %{primary: primary, relay: relay, socket: socket})
  end

  test "a call from the app runs on the server as computer:<id>, its audio both ways, and " <>
         "a hang-up keeps the connection for the next call",
       ctx do
    app = hello!(ctx.socket)
    {voice, opts} = call_up!(app)
    assert Keyword.fetch!(opts, :endpoint) == {:computer, DesktopRail.device_id()}

    assert {:ok, %{endpoint: "computer:" <> _id}} = CallLease.holder(ctx.lease)

    send_line(app, %{type: "audio_chunk", audio: Base.encode64(@pcm)})
    assert_receive {:voice, ^voice, {:audio, @pcm}}, @arrival_ms

    send(voice, {:push, %{type: "audio_delta", audio: Base.encode64(@pcm)}})

    assert %{"type" => "audio_delta", "playback_id" => "m1", "audio" => audio} = recv!(app)
    assert Base.decode64!(audio) == @pcm

    # The server's credit takes the app's report on every engine.
    send_line(app, %{type: "playback_progress", playback_id: "m1", played_ms: 100, drained: true})
    send_line(app, %{type: "mute", enabled: true})
    assert_receive {:voice, ^voice, {:mute, true}}, @arrival_ms

    voice_ref = Process.monitor(voice)
    send_line(app, %{type: "call_stop"})
    assert_receive {:voice, ^voice, :call_stop}, @arrival_ms
    assert recv!(app) == %{"type" => "state", "state" => "idle"}
    assert_receive {:DOWN, ^voice_ref, :process, ^voice, _reason}, @arrival_ms

    # The connection stays: a fresh call is a new one on the server.
    {second, _opts} = call_up!(app)
    refute second == voice
  end

  test "a dropped link holds the call, and the next session resumes it", ctx do
    app = hello!(ctx.socket)
    {voice, _opts} = call_up!(app)

    :ok = drop_session!(ctx.primary)
    await_detached!(ctx)

    # While away: the server's word waits for the computer, the app's control
    # waits for the link.
    send(voice, {:push, %{type: "state", state: "thinking"}})
    send_line(app, %{type: "mute", enabled: true})

    :ok = reconnect!(ctx.relay)

    assert recv!(app) == %{"type" => "state", "state" => "thinking"}
    assert_receive {:voice, ^voice, {:mute, true}}, @arrival_ms
    assert Process.alive?(voice)
    assert {:ok, %{endpoint: "computer:" <> _id}} = CallLease.holder(ctx.lease)
  end

  test "a call started while the link is down is refused with the engine's sentence", ctx do
    :ok = drop_session!(ctx.primary)
    app = hello!(ctx.socket)
    send_line(app, %{type: "call_start"})

    assert recv!(app) == %{
             "type" => "error",
             "reason" => "server_unreachable",
             "sentence" =>
               "Fermix cannot reach the server fermix-vm, so the call cannot start. " <>
                 "Try again once it is back."
           }

    assert {:error, :closed} = :gen_tcp.recv(app, 0, @arrival_ms)
    refute_received {:voice_started, _voice, _opts}
  end

  # M97 §9.2, the move back: the call bridged at that moment ends cleanly
  # before the role switch, hung up so the server settles it, the app told
  # why, and the lease free for the home the computer becomes.
  test "a move back ends the bridged call cleanly before it starts", ctx do
    app = hello!(ctx.socket)
    {voice, _opts} = call_up!(app)
    voice_ref = Process.monitor(voice)
    why = "This call ended: Fermix is moving back to this Mac. Call again once the move is done."

    ending = Task.async(fn -> Relay.end_calls(ctx.relay, why) end)

    assert_receive {:voice, ^voice, :call_stop}, @arrival_ms
    assert recv!(app) == %{"type" => "state", "state" => "idle"}
    assert recv!(app) == %{"type" => "error", "reason" => "call_ended", "sentence" => why}
    assert {:error, :closed} = :gen_tcp.recv(app, 0, @arrival_ms)

    assert Task.await(ending, @arrival_ms) == :ok
    assert_receive {:DOWN, ^voice_ref, :process, ^voice, _reason}, @arrival_ms
    assert CallLease.holder(ctx.lease) == :none

    # With no call left, a second ask answers at once.
    assert Relay.end_calls(ctx.relay, why) == :ok
  end

  # -- the server's call path --------------------------------------------------------

  defp server_calls! do
    suffix = System.unique_integer([:positive])
    name = &:"two_engines_voice_#{&1}_#{suffix}"
    tasks = start_supervised!({Task.Supervisor, name: name.(:tasks)}, id: :server_tasks)
    guard = name.(:guard)
    start_supervised!({SessionGuard, name: guard, task_supervisor: tasks})
    lease = name.(:lease)
    start_supervised!({CallLease, name: lease})
    calls = name.(:calls)
    start_supervised!({Registry, keys: :unique, name: calls})
    call_supervisor = name.(:call_supervisor)
    start_supervised!({DynamicSupervisor, name: call_supervisor, strategy: :one_for_one})
    config = Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1")
    test = self()

    starter = fn session_opts ->
      spec = %{observer: test, opts: session_opts, lease: lease}

      with {:ok, voice} <- GenServer.start(Voice, spec) do
        send(test, {:voice_started, voice, session_opts})
        {:ok, voice}
      end
    end

    %{
      lease: lease,
      calls: calls,
      call_supervisor: call_supervisor,
      config: config,
      call_options: [
        session_module: Voice,
        session_starter: starter,
        session_guard: guard,
        task_supervisor: tasks,
        config: fn -> config end,
        ready: fn _config -> :ok end
      ]
    }
  end

  defp await_detached!(ctx, attempts \\ 1_000) do
    [{call, _value}] = Registry.lookup(ctx.calls, DesktopRail.device_id())

    cond do
      :sys.get_state(call).attached == nil -> :ok
      attempts == 0 -> flunk("the server's call never let the session go")
      true -> await_detached!(ctx, attempts - 1)
    end
  end

  defp drop_session!(primary) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(primary.connections),
        is_pid(pid),
        do: :ok = DynamicSupervisor.terminate_child(primary.connections, pid)

    assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, _delay}, @arrival_ms
    Process.put({__MODULE__, :reconnect}, timer)
    :ok
  end

  defp reconnect!(relay) do
    send(Process.whereis(relay), Process.delete({__MODULE__, :reconnect}))
    DesktopRail.await_connected(relay)
    :ok
  end

  # -- the app -----------------------------------------------------------------------

  defp hello!(socket) do
    {:ok, app} =
      :gen_tcp.connect({:local, String.to_charlist(socket)}, 0, [
        :binary,
        {:active, false},
        {:packet, :line}
      ])

    send_line(app, %{type: "client_hello", protocol_version: 3})
    assert %{"type" => "server_hello", "min_version" => 1} = recv!(app)
    app
  end

  defp call_up!(app) do
    send_line(app, %{type: "call_start"})
    assert_receive {:voice_started, voice, opts}, @arrival_ms
    assert recv!(app) == %{"type" => "state", "state" => "listening"}
    {voice, opts}
  end

  defp send_line(app, frame), do: :ok = :gen_tcp.send(app, [Jason.encode!(frame), "\n"])

  defp recv!(app) do
    assert {:ok, line} = :gen_tcp.recv(app, 0, @arrival_ms)
    Jason.decode!(line)
  end
end
