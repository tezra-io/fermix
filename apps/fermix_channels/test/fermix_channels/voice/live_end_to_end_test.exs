defmodule FermixChannels.Voice.LiveEndToEndTest do
  @moduledoc """
  One Live call, end to end across both applications
  (MILESTONE_41_OPENAI_LIVE_VOICE.md §5 — the whole rail):

      fake GPT-Live wire
        ↕ FermixCore.Realtime.LiveSessionServer
        ↕ FermixChannels.Voice.Bridge          (the real bridge)
        ↕ FermixChannels.Gateway.ingest → Gateway.Queue → a turn
        ↕ FermixChannels.Channels.Voice        (the real adapter)
        ↕ back to the session as commentary + a task frame

  Every unit on that path has its own suite; this proves they are actually
  wired to each other — that a spoken sentence becomes an agent turn and the
  turn's answer becomes speech, with the call's history and routing released
  when the call ends.

  Hermetic: no network (a fake Live client), no provider (a fake turn runner),
  no keychain, no real FERMIX_HOME. The only global it touches is the
  `:voice_bridge` app env, established and restored here.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Voice.Bridge
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Agents.VoiceCall
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LiveSessionServer
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.SessionSupervisor

  @moduletag :capture_log

  @answer "Your calendar is clear today."
  @closed_seconds 12.0
  @spoken "what is on my calendar today"
  # This module's own call registry: the daemon's is under the realtime
  # supervisor, which the suite never starts.
  @call_registry Module.concat(__MODULE__, CallRegistry)

  # Records what the session put on the Live wire and answers `session.close`
  # from inside the send — which runs in the session's own process, so the
  # reply is already in the mailbox when the close handshake's selective
  # receive runs. The recorder is a named agent the TEST owns, so the wire is
  # still readable after the call has ended.
  defmodule FakeLiveClient do
    @name __MODULE__.State

    def start_agent(test_pid) do
      Agent.start_link(fn -> %{test_pid: test_pid, events: []} end, name: @name)
    end

    def start_link(opts) do
      Agent.update(@name, &Map.put(&1, :parent, Keyword.fetch!(opts, :parent)))
      {:ok, Process.whereis(@name)}
    end

    def send_event(_pid, %{type: "session.close"} = event) do
      record(event)
      parent = Agent.get(@name, & &1.parent)
      send(parent, {:openai_live_event, {:session_closed, "close_requested", 12.0}})
      :ok
    end

    def send_event(_pid, event), do: record(event)

    def close(_pid), do: :ok
    def events, do: Agent.get(@name, & &1.events)

    defp record(event) do
      Agent.update(@name, fn state -> %{state | events: state.events ++ [event]} end)
      :ok
    end
  end

  # The REAL bridge, pointed at this test's queue.
  #
  # `LiveSessionServer` builds the §6 `call` map itself, so it has no way to
  # name a scheduler — in production there is only one. This shim adds the
  # `agent_server` the bridge already accepts and delegates every callback
  # unchanged, so `open_call/submit/cancel/close_call` are the shipped code
  # paths; only the queue they reach is the test's.
  defmodule QueueBoundBridge do
    @behaviour FermixCore.Realtime.VoiceBridge

    @name __MODULE__.State

    # Unlinked: a session settles its call in `terminate/2`, which runs while
    # the test process is already exiting, and a binding that died first would
    # make every test log a close failure the product does not have.
    def bind(queue), do: Agent.start(fn -> queue end, name: @name)

    def unbind do
      case Process.whereis(@name) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end

    @impl true
    def open_call(call),
      do: Bridge.open_call(Map.put(call, :agent_server, Agent.get(@name, & &1)))

    @impl true
    def submit(handle, request, callbacks), do: Bridge.submit(handle, request, callbacks)

    @impl true
    def cancel(handle, task_ref), do: Bridge.cancel(handle, task_ref)

    @impl true
    def close_call(handle), do: Bridge.close_call(handle)
  end

  defmodule StubAgent do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, opts) do
      {:reply, {:ok, %{test_pid: opts.test_pid}, :hit}, opts}
    end
  end

  # Hands the whole ingested message back to the test — the one place the core
  # seams are observable on a REAL delegation — then blocks until told how the
  # turn ends, so a cancel has something to stop.
  defmodule FakeRunner do
    def run(msg, turn_state, deliver), do: run(msg, turn_state, deliver, nil, nil)

    def run(msg, turn_state, deliver, stream_callback),
      do: run(msg, turn_state, deliver, stream_callback, nil)

    def run(msg, turn_state, _deliver, _stream_callback, _activity_callback) do
      send(turn_state.test_pid, {:turn_started, msg, self()})

      receive do
        {:proceed, answer} -> {:ok, answer, 0}
      after
        15_000 -> {:ok, "timed out", 0}
      end
    end

    def commit(_msg, _turn_state, _response, _context_tokens), do: :ok
    def error_reply(reason), do: "error reply: #{inspect(reason)}"
  end

  setup do
    previous_bridge = Application.get_env(:fermix_core, :voice_bridge)
    previous_realtime = Application.get_env(:fermix_core, :realtime)

    Application.put_env(:fermix_core, :voice_bridge, QueueBoundBridge)
    Application.put_env(:fermix_core, :realtime, Config.to_keyword(live_config()))

    on_exit(fn ->
      restore(:voice_bridge, previous_bridge)
      restore(:realtime, previous_realtime)
    end)

    task_supervisor = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Queue,
         name: :"voice_e2e_queue_#{System.unique_integer([:positive])}",
         main_agent: start_supervised!({StubAgent, test_pid: self()}, id: :voice_e2e_agent),
         turn_runner: FakeRunner,
         task_supervisor: task_supervisor},
        id: :voice_e2e_queue
      )

    {:ok, _binding} = QueueBoundBridge.bind(queue)
    on_exit(&QueueBoundBridge.unbind/0)
    start_supervised!(%{id: :fake_live_client, start: {FakeLiveClient, :start_agent, [self()]}})
    start_supervised!({CallRegistry, name: @call_registry})

    %{queue: queue}
  end

  test "a spoken request becomes an agent turn and its answer becomes speech" do
    Process.flag(:trap_exit, true)
    session = start_session()

    assert :ok = SessionControl.call_start(session)
    assert [%{type: "session.start"}] = FakeLiveClient.events()

    open_provider_session(session)

    assert_receive {:realtime, %{type: "call_ready", engine: "openai_live", call_id: call_id}}
    assert_receive {:realtime, %{type: "state", state: "listening"}}

    speak(session, @spoken, 1_000, 4_000)
    delegate(session, "dg_1", 4_200)

    # --- The delegation really did become an agent turn ---
    assert_receive {:turn_started, msg, turn_pid}, 5_000
    assert msg.channel == "voice"
    assert msg.chat_id == call_id
    assert msg.content =~ @spoken
    assert msg.source_trust == :operator

    assert {:ok, voice_call} = VoiceCall.from_message(msg)
    assert voice_call.call_id == call_id
    assert voice_call.delegation_id == "dg_1"
    assert voice_call.revision == 1
    assert voice_call.turn_session_id =~ ~r/^voice_delegation_\d+$/
    assert voice_call.persist? == false
    assert is_pid(voice_call.conversation_store)
    # The correlation the trace nests on, and the attended-origin label, both
    # derived by Core from this real message.
    assert TurnRunner.computer_use_origin(msg) == :voice

    store = voice_call.conversation_store

    # --- The turn's answer really did become speech ---
    send(turn_pid, {:proceed, @answer})

    assert_receive {:realtime,
                    %{
                      type: "task",
                      delegation_id: "dg_1",
                      status: "completed",
                      summary: @answer
                    }},
                   5_000

    assert eventually(fn ->
             Enum.any?(FakeLiveClient.events(), fn event ->
               event.type == "session.commentary.append" and
                 event.delegation_id == "dg_1" and event.content == @answer
             end)
           end)

    # --- Teardown releases the call's history and its routing ---
    assert :ok = SessionControl.call_stop(session)

    assert_receive {:realtime, %{type: "state", state: "idle"}}

    assert_receive {:realtime,
                    %{
                      type: "usage",
                      accounting: "complete",
                      voice_seconds: @closed_seconds,
                      backend_cost: "unknown"
                    }},
                   5_000

    assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

    refute Process.alive?(store), "the ephemeral call store must be released on call stop"
    assert Registry.lookup(Voice.registry(), call_id) == []
    assert Registry.lookup(Voice.registry(), {call_id, "dg_1"}) == []
  end

  test "cancelling a task stops the running turn and reports it to the call" do
    Process.flag(:trap_exit, true)
    session = start_session()

    :ok = SessionControl.call_start(session)
    open_provider_session(session)
    assert_receive {:realtime, %{type: "call_ready", call_id: call_id}}

    speak(session, @spoken, 1_000, 4_000)
    delegate(session, "dg_1", 4_200)

    # The runner blocks: the turn is genuinely in flight when the cancel lands.
    assert_receive {:turn_started, _msg, turn_pid}, 5_000
    assert Process.alive?(turn_pid)

    assert :ok = SessionControl.cancel_task(session, "dg_1")

    assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "cancelled"}}, 5_000
    assert eventually(fn -> not Process.alive?(turn_pid) end)

    # The cancelled turn never speaks: no commentary was ever appended for it.
    refute Enum.any?(FakeLiveClient.events(), &(&1.type == "session.commentary.append"))

    assert :ok = SessionControl.call_stop(session)
    assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000
    assert Registry.lookup(Voice.registry(), call_id) == []
  end

  # The companion's connection (`LocalVoiceSocket`'s handler) drives the session
  # through `SessionControl`, and on this rail a cancel or a hang-up reaches the
  # Queue's conversation stop, which answers only once the Queue is free. The
  # Queue is held suspended only until the session's stop is seen waiting in its
  # mailbox: no test waits out a production call budget. What tells a wait with
  # no budget from a budget not used up yet is the call itself, so each test
  # traces the handler's call and reads the timeout it carries.
  describe "a voice connection whose Queue is busy" do
    setup :start_voice_socket

    test "a cancel waits for the Queue's stop and the connection keeps the call", ctx do
      %{conn: conn, session: session, handler: handler} = open_call(ctx)
      trace_calls(call_trace(), handler)

      :ok = :sys.suspend(ctx.queue)
      send_line(conn, %{type: "task_cancel", delegation_id: "dg_1"})
      assert eventually(fn -> queued_stop?(ctx.queue, session) end, 250)
      :ok = :sys.resume(ctx.queue)

      assert recv_frame(conn, &task_frame?(&1, "dg_1", "cancelled"))
      assert Process.alive?(handler)

      # The same connection still carries the call.
      send_line(conn, %{type: "mute", enabled: true})
      assert recv_frame(conn, &(&1 == %{"type" => "state", "state" => "muted"}))

      assert call_timeout(handler, :cancel_task) == :infinity
      hang_up(conn, session)
    end

    test "a hang-up waits for the Queue's stop and idle is the call's last frame", ctx do
      %{conn: conn, session: session, handler: handler} = open_call(ctx)
      trace_calls(call_trace(), handler)

      :ok = :sys.suspend(ctx.queue)
      send_line(conn, %{type: "call_stop"})
      assert eventually(fn -> queued_stop?(ctx.queue, session) end, 250)
      :ok = :sys.resume(ctx.queue)

      # The session's own frames come first. The handler's idle follows them,
      # written once `call_stop` returned and the session was gone.
      assert recv_frame(conn, &task_frame?(&1, "dg_1", "cancelled"))
      assert recv_frame(conn, &match?(%{"type" => "usage", "accounting" => "complete"}, &1))
      assert recv_frame(conn, &(&1 == %{"type" => "state", "state" => "idle"}), 1)
      refute Process.alive?(session), "the connection said idle while the call was settling"
      assert Process.alive?(handler)

      assert call_timeout(handler, :call_stop) == :infinity
      :ok = :gen_tcp.close(conn)
    end

    # The provider drops the call, and the session's settle waits on the Queue.
    # A cancel the companion sends meanwhile waits behind that settle, and the
    # session stops instead of answering it.
    test "a session that ends while a cancel waits closes the connection cleanly", ctx do
      %{conn: conn, session: session, handler: handler} = open_call(ctx)
      handler_ref = Process.monitor(handler)

      :ok = :sys.suspend(ctx.queue)
      send(session, {:openai_live_event, {:session_closed, "gone", @closed_seconds}})
      assert eventually(fn -> queued_stop?(ctx.queue, session) end, 250)
      send_line(conn, %{type: "task_cancel", delegation_id: "dg_1"})
      assert eventually(fn -> queued_call?(session, handler, {:cancel_task, "dg_1"}) end, 250)
      :ok = :sys.resume(ctx.queue)

      # What the session said before it stopped still reaches the companion,
      # then the connection's own error, then the close.
      assert recv_frame(conn, &match?(%{"type" => "usage", "accounting" => "complete"}, &1))
      assert %{"reason" => reason} = recv_frame(conn, &match?(%{"type" => "error"}, &1))
      assert reason =~ "session_down"
      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 5_000)
      assert_receive {:DOWN, ^handler_ref, :process, ^handler, :normal}, 5_000
    end
  end

  # --- Helpers ---

  defp start_session do
    {:ok, session} = LiveSessionServer.start_link([companion: self()] ++ live_session_opts())

    # Registered AFTER the bridge binding's cleanup, so it runs BEFORE it
    # (on_exit is LIFO): the fakes outlive the call they served.
    on_exit(fn -> await_down(session) end)
    session
  end

  defp live_session_opts do
    [
      config: live_config(),
      api_key: "sk-test",
      device_id: "device-1",
      session_scope: "voice_live:#{System.unique_integer([:positive, :monotonic])}",
      live_client: FakeLiveClient,
      voice_bridge: QueueBoundBridge,
      call_registry: @call_registry,
      prompt: "# LIVE.md\n\nBackend tools:\n- Web: web_search",
      clock: fn -> 0 end,
      unix_clock: fn -> 1_000 end,
      usage_tick_ms: 60_000
    ]
  end

  # The production listener, starting each call's session under a
  # `SessionSupervisor` as the default starter does, with this module's fakes.
  defp start_voice_socket(_ctx) do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-voice-e2e-#{unique}.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)
    test_pid = self()

    starter = fn opts ->
      {:ok, session} =
        SessionSupervisor.start_session(
          Keyword.fetch!(opts, :session_supervisor),
          Keyword.put(opts, :engine_module, LiveSessionServer)
        )

      send(test_pid, {:session_started, session, Keyword.fetch!(opts, :companion)})
      {:ok, session}
    end

    start_supervised!(
      {LocalVoiceSocket,
       socket_path: socket_path,
       name: :"voice_e2e_socket_#{unique}",
       task_supervisor: start_supervised!({Task.Supervisor, []}, id: :voice_e2e_socket_tasks),
       session_supervisor:
         start_supervised!({SessionSupervisor, name: :"voice_e2e_sessions_#{unique}"}),
       session_starter: starter,
       session_opts: live_session_opts()}
    )

    %{socket_path: socket_path}
  end

  # A companion connection with one delegation running as an agent turn.
  defp open_call(ctx) do
    {:ok, conn} =
      :gen_tcp.connect(
        {:local, String.to_charlist(ctx.socket_path)},
        0,
        [:binary, active: false, packet: :line],
        1_000
      )

    send_line(conn, %{type: "client_hello", protocol_version: 2})
    assert recv_frame(conn, &match?(%{"type" => "server_hello"}, &1))
    send_line(conn, %{type: "call_start"})
    assert_receive {:session_started, session, handler}, 5_000
    # `call_start` has been handled once the session holds its provider socket.
    assert eventually(fn -> LiveSessionServer.live_pid(session) != nil end, 250)

    open_provider_session(session)
    assert recv_frame(conn, &match?(%{"type" => "call_ready"}, &1))
    speak(session, @spoken, 1_000, 4_000)
    delegate(session, "dg_1", 4_200)
    assert_receive {:turn_started, _msg, _turn_pid}, 5_000
    assert recv_frame(conn, &task_frame?(&1, "dg_1", "running"))

    %{conn: conn, session: session, handler: handler}
  end

  defp hang_up(conn, session) do
    ref = Process.monitor(session)
    send_line(conn, %{type: "call_stop"})
    assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :call_stop}}, 5_000
    :ok = :gen_tcp.close(conn)
  end

  defp send_line(conn, event), do: :ok = :gen_tcp.send(conn, Jason.encode!(event) <> "\n")

  # The next frame on `conn` that `wanted?` accepts, skipping the ones before it.
  defp recv_frame(conn, wanted?, skips \\ 50)
  defp recv_frame(_conn, _wanted?, 0), do: flunk("no matching frame on the voice connection")

  defp recv_frame(conn, wanted?, skips) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, line} ->
        frame = Jason.decode!(line)
        if wanted?.(frame), do: frame, else: recv_frame(conn, wanted?, skips - 1)

      {:error, reason} ->
        flunk("the voice connection ended: #{inspect(reason)}")
    end
  end

  defp task_frame?(frame, id, status),
    do: match?(%{"type" => "task", "delegation_id" => ^id, "status" => ^status}, frame)

  # The session's conversation stop is in the Queue's mailbox, waiting.
  defp queued_stop?(queue, session) do
    {:messages, messages} = Process.info(queue, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^session, _}, {:stop_conversation, _key}}, &1))
  end

  # `from`'s call carrying `request` is in `pid`'s mailbox, waiting.
  defp queued_call?(pid, from, request) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^from, _}, ^request}, &1))
  end

  # A trace session of this test's own on `GenServer.call/3`, local calls
  # included, so `call/2`'s default timeout shows too. No other tracer sees
  # it, and it ends with the test.
  defp call_trace do
    session = :trace.session_create(:voice_e2e_calls, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)
    1 = :trace.function(session, {GenServer, :call, 3}, true, [:local])
    session
  end

  defp trace_calls(session, pid), do: 1 = :trace.process(session, pid, true, [:call])

  # The timeout `pid`'s traced call carried, for the request `tag` or tagged
  # `tag`.
  defp call_timeout(pid, tag) do
    receive do
      {:trace, ^pid, :call, {GenServer, :call, [_server, request, timeout]}}
      when request == tag or (is_tuple(request) and elem(request, 0) == tag) ->
        timeout
    after
      5_000 -> flunk("#{inspect(pid)} made no traced #{inspect(tag)} call")
    end
  end

  defp live_config do
    Config.normalize(
      enabled: true,
      engine: "openai_live",
      model: "gpt-live-1",
      voice: "marin",
      max_session_minutes: 15,
      max_estimated_cost_cents_per_session: 100,
      persist_transcripts: false
    )
  end

  defp open_provider_session(session) do
    send(
      session,
      {:openai_live_event, {:session_started, %{id: "sess_live_e2e", expires_at: 1_000_000}}}
    )

    sync(session)
  end

  defp speak(session, text, start_ms, end_ms) do
    send(session, {:openai_live_event, {:transcript_delta, :user, text, start_ms, end_ms}})
    sync(session)
  end

  defp delegate(session, delegation_id, offset_ms) do
    send(session, {:openai_live_event, {:delegation_created, delegation_id, offset_ms}})
    sync(session)
  end

  # A synchronous round trip through the session's own mailbox: everything sent
  # before it has been handled by the time it returns. No sleeps.
  defp sync(session), do: :sys.get_state(session)

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> raise "the live session never stopped"
    end
  end

  # Bounded poll for a fact that lands through another process (the turn task's
  # delivery, the queue's terminate). Never a bare sleep.
  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
