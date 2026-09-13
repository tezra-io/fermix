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
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LiveSessionServer
  alias FermixCore.Realtime.SessionControl

  @moduletag :capture_log

  @answer "Your calendar is clear today."
  @closed_seconds 12.0
  @spoken "what is on my calendar today"

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

  # --- Helpers ---

  defp start_session do
    {:ok, session} =
      LiveSessionServer.start_link(
        companion: self(),
        config: live_config(),
        api_key: "sk-test",
        device_id: "device-1",
        session_scope: "voice_live:#{System.unique_integer([:positive, :monotonic])}",
        live_client: FakeLiveClient,
        voice_bridge: QueueBoundBridge,
        prompt: "# LIVE.md\n\nBackend tools:\n- Web: web_search",
        clock: fn -> 0 end,
        unix_clock: fn -> 1_000 end,
        usage_tick_ms: 60_000
      )

    # Registered AFTER the bridge binding's cleanup, so it runs BEFORE it
    # (on_exit is LIFO): the fakes outlive the call they served.
    on_exit(fn -> await_down(session) end)
    session
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
