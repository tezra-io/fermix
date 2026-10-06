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

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Voice
  alias FermixChannels.Companion.Requests
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Harness.ContinuationDispatcher
  alias FermixChannels.Voice.Bridge
  alias FermixChannels.Voice.CallRowSweep
  alias FermixChannels.Voice.Detached
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Agents.VoiceCall
  alias FermixCore.Companion.Timeline
  alias FermixCore.Harness.Continuation
  alias FermixCore.Harness.Delivery, as: HarnessDelivery
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
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
  @timeline_repo :voice_e2e_timeline_repo
  @timeline_env ~w(companion_store mobile_event_sink)a
  @gist_route %{
    provider: :openai,
    model: "gpt-test",
    auth_mode: :api_key,
    base_url: "https://api.openai.com/v1"
  }

  # The chat's timeline on this module's throwaway repo.
  defmodule E2ETimeline do
    @opts [repo: :voice_e2e_timeline_repo]

    def append(p, a, o), do: Timeline.append(p, a, o ++ @opts)
    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

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
  # `agent_server` the bridge already accepts (and the owner of the tasks that
  # outlive a call, the daemon's own unless a test names one) and delegates
  # every callback unchanged, so `conversation_window/call_active?/chat_call/
  # show/open_call/submit/cancel/detach/close_call` are the shipped code paths;
  # only the queue they reach is the test's.
  defmodule QueueBoundBridge do
    @behaviour FermixCore.Realtime.VoiceBridge

    @name __MODULE__.State

    # Unlinked: a session settles its call in `terminate/2`, which runs while
    # the test process is already exiting, and a binding that died first would
    # make every test log a close failure the product does not have.
    def bind(queue), do: Agent.start(fn -> %{queue: queue, detached: Detached} end, name: @name)

    @doc "The owner the next call hands its running tasks to."
    def bind_detached(detached), do: Agent.update(@name, &%{&1 | detached: detached})

    def unbind do
      case Process.whereis(@name) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end

    @doc "The queue this test bound the bridge to."
    def queue, do: Agent.get(@name, & &1.queue)

    @impl true
    def conversation_window(bounds), do: Bridge.conversation_window(bounds)

    @impl true
    def call_active?, do: Bridge.call_active?()

    @impl true
    def chat_call(key, channel), do: Bridge.chat_call(key, channel)

    @impl true
    def show(call, text), do: Bridge.show(call, text)

    @impl true
    def open_call(call) do
      %{queue: queue, detached: detached} = Agent.get(@name, & &1)
      Bridge.open_call(Map.merge(call, %{agent_server: queue, detached: detached}))
    end

    @impl true
    def submit(handle, request, callbacks), do: Bridge.submit(handle, request, callbacks)

    @impl true
    def cancel(handle, task_ref), do: Bridge.cancel(handle, task_ref)

    @impl true
    def detach(handle, task_ref, task), do: Bridge.detach(handle, task_ref, task)

    @impl true
    def close_call(handle), do: Bridge.close_call(handle)
  end

  # The REAL harness continuation dispatcher, pointed at this test's queue the
  # way `QueueBoundBridge` points the bridge at it: a run's outcome re-enters
  # its conversation through the shipped gateway path.
  defmodule QueueBoundDispatcher do
    @behaviour FermixCore.Harness.ContinuationDispatcher

    @impl true
    def dispatch(notice),
      do: ContinuationDispatcher.dispatch(notice, agent_server: QueueBoundBridge.queue())
  end

  # The provider a call's gist is made on, bound into the gist's route: no
  # real adapter is ever resolved.
  defmodule GistAdapter do
    def chat(_messages, _tools, opts) do
      case Keyword.fetch!(opts, :gist) do
        {:hold, test_pid} ->
          send(test_pid, {:gist_held, self()})
          Process.sleep(:infinity)

        gist ->
          {:ok, %{content: gist}}
      end
    end
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

    assert_receive {:realtime,
                    %{
                      type: "call_ready",
                      engine: "openai_live",
                      call_id: call_id,
                      call_uuid: call_uuid
                    }}

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
    assert voice_call.call_uuid == call_uuid
    assert voice_call.delegation_id == "dg_1"
    assert voice_call.revision == 1
    assert voice_call.turn_session_id =~ ~r/^voice_delegation_\d+$/
    assert voice_call.persist? == false
    # An unset `conversation` joins the chat (M56 §4.1): the turn runs in the
    # chat's conversation on the durable store, the queue lane a typed turn
    # takes.
    assert voice_call.conversation_store == ConversationStore
    assert voice_call.conversation_key == Companion.chat_conversation_key()
    assert ConversationKey.from(msg) == Companion.chat_conversation_key()
    # The correlation the trace nests on, and the attended-origin label, both
    # derived by Core from this real message.
    assert TurnRunner.computer_use_origin(msg) == :voice

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

    assert Registry.lookup(Voice.registry(), call_id) == []
    assert Registry.lookup(Voice.registry(), {call_id, "dg_1"}) == []
  end

  # `conversation = "private"` is the call's own conversation as before, keyed
  # by the call's UUID and released when the call ends.
  test "a private call runs in a conversation of its own, released when it ends" do
    Process.flag(:trap_exit, true)
    session = start_session(live_config(conversation: "private"))

    :ok = SessionControl.call_start(session)
    open_provider_session(session)
    assert_receive {:realtime, %{type: "call_ready", call_id: call_id, call_uuid: call_uuid}}

    speak(session, @spoken, 1_000, 4_000)
    delegate(session, "dg_1", 4_200)

    assert_receive {:turn_started, msg, turn_pid}, 5_000
    assert {:ok, voice_call} = VoiceCall.from_message(msg)
    assert is_pid(voice_call.conversation_store)
    assert ConversationKey.from(msg) == {"voice", call_uuid, :root}

    store = voice_call.conversation_store
    send(turn_pid, {:proceed, @answer})
    assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}}, 5_000

    assert :ok = SessionControl.call_stop(session)
    assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

    refute Process.alive?(store), "the ephemeral call store must be released on call stop"
    assert Registry.lookup(Voice.registry(), call_id) == []
  end

  # M56 §4.3: the stage's gate, through the real bridge: a call in the chat
  # starts knowing what was just typed there, told it is context, not a request.
  test "a call in the chat starts with what was typed there as session.input" do
    Process.flag(:trap_exit, true)
    chat_key = Companion.chat_conversation_key()
    :ok = ConversationStore.clear(chat_key)
    on_exit(fn -> ConversationStore.clear(chat_key) end)
    :ok = ConversationStore.add_message(chat_key, "user", "the lease: https://x.test/lease")
    :ok = ConversationStore.add_message(chat_key, "assistant", "Saved it.")
    session = start_session()

    :ok = SessionControl.call_start(session)

    [%{type: "session.start", session: payload}] = FakeLiveClient.events()

    assert [
             %{role: "user", content: [%{type: "input_text", text: "the lease: " <> _url}]},
             %{role: "assistant", content: [%{type: "output_text", text: "Saved it."}]},
             %{role: "developer", content: [%{text: closing}]}
           ] = payload.input

    assert closing =~ "not a request"

    assert :ok = SessionControl.call_stop(session)
    assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000
  end

  # M56 §4.5: the stage's gate, through the real bridge and the companion's
  # call-row write on a throwaway timeline: a reply carrying a link is said in
  # a sentence, shown whole in the chat once, and its task names the row.
  describe "a result shown in the chat" do
    setup :start_timeline

    test "a reply with a link is said in a sentence and shown whole, once" do
      Process.flag(:trap_exit, true)
      session = start_session()

      :ok = SessionControl.call_start(session)
      open_provider_session(session)
      assert_receive {:realtime, %{type: "call_ready", call_uuid: call_uuid}}

      speak(session, "find the sign-up form", 1_000, 4_000)
      delegate(session, "dg_1", 4_200)
      assert_receive {:turn_started, _msg, turn_pid}, 5_000

      shown = "It is at https://x.test/form. It asks for a name, a city and a dietary note."
      send(turn_pid, {:proceed, "I found the sign-up form.\n---shown---\n" <> shown})

      assert_receive {:realtime,
                      %{
                        type: "task",
                        delegation_id: "dg_1",
                        status: "completed",
                        summary: "I found the sign-up form.",
                        server_seq: seq
                      }},
                     5_000

      assert_receive {:companion_event,
                      %{"t" => "row", "server_seq" => ^seq, "text" => ^shown} = mac_row}

      assert mac_row["metadata"] == %{
               "call" => %{
                 "uuid" => call_uuid,
                 "event" => "shared",
                 "task_id" => "dg_1",
                 "revision" => 1
               }
             }

      assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^seq}}

      assert eventually(fn ->
               Enum.any?(FakeLiveClient.events(), fn event ->
                 event.type == "session.commentary.append" and event.delegation_id == "dg_1" and
                   event.content == "I found the sign-up form. The full result is in the chat."
               end)
             end)

      refute Enum.any?(FakeLiveClient.events(), &(inspect(&1) =~ "x.test"))
      assert :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

      assert {:ok, %{messages: [%{server_seq: ^seq}]}} =
               E2ETimeline.history_page("main", limit: 10)

      refute_received {:companion_event, %{"t" => "row"}}
    end
  end

  # M56 §4.2: the call's one row when it ends, written through the real bridge
  # and the companion channel once its gist is made, to the Mac and the phones.
  describe "the call's row when it ends" do
    setup :start_timeline

    test "the gist is made after the call and lands in the chat as the call's one row" do
      Process.flag(:trap_exit, true)
      gist = "You asked to book the room and it is booked for 10am."

      session =
        start_session(live_config(),
          record_repo: @timeline_repo,
          gist: [routes: [{@gist_route, [adapter: GistAdapter, gist: gist]}]]
        )

      :ok = SessionControl.call_start(session)
      open_provider_session(session)
      assert_receive {:realtime, %{type: "call_ready", call_uuid: call_uuid}}

      speak(session, "book the room", 1_000, 4_000)
      delegate(session, "dg_1", 4_200)
      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      send(turn_pid, {:proceed, "The room is booked for 10am."})

      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}},
                     5_000

      assert :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

      assert_receive {:companion_event, %{"t" => "row", "server_seq" => seq} = mac_row}, 5_000
      assert mac_row["text"] == "Voice call, under a minute\n\n" <> gist

      assert %{"uuid" => ^call_uuid, "event" => "ended", "gist_status" => "written"} =
               mac_row["metadata"]["call"]

      assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^seq}}

      assert {:ok, %{messages: [%{server_seq: ^seq, proactive_key: key}]}} =
               E2ETimeline.history_page("main", limit: 10)

      assert key == "voice:#{call_uuid}:ended"

      assert eventually(fn ->
               match?(
                 {:ok, %{row_state: "row_written", gist: ^gist}},
                 Repo.get_voice_call(call_uuid, server: @timeline_repo)
               )
             end)
    end
  end

  # M56 §4.2, §8: a daemon that dies after the call settled and before its
  # gist was made leaves the gist pending and the row owed; the next boot
  # writes the row, with the task list, through the same bridge.
  describe "a call whose gist the daemon never finished" do
    setup :start_timeline

    test "the next boot writes its row once, with its task list" do
      Process.flag(:trap_exit, true)

      session =
        start_session(live_config(),
          record_repo: @timeline_repo,
          gist: [routes: [{@gist_route, [adapter: GistAdapter, gist: {:hold, self()}]}]]
        )

      :ok = SessionControl.call_start(session)
      open_provider_session(session)
      assert_receive {:realtime, %{type: "call_ready", call_uuid: call_uuid}}
      speak(session, "book the room", 1_000, 4_000)
      delegate(session, "dg_1", 4_200)
      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      send(turn_pid, {:proceed, "The room is booked for 10am."})

      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}},
                     5_000

      assert :ok = SessionControl.call_stop(session)

      # The daemon dies with the gist in flight: its job and its summariser.
      assert_receive {:gist_held, summariser}, 5_000
      # The summariser's first caller is the job that waits on it.
      [job | _session] =
        Process.info(summariser, :dictionary) |> elem(1) |> Keyword.fetch!(:"$callers")

      Enum.each([job, summariser], &Process.exit(&1, :kill))

      assert {:ok, %{gist_status: "pending", row_state: "row_pending"}} =
               Repo.get_voice_call(call_uuid, server: @timeline_repo)

      refute_received {:companion_event, %{"t" => "row"}}

      {:ok, sweep} = CallRowSweep.start_link(record_repo: @timeline_repo)
      ref = Process.monitor(sweep)
      assert_receive {:DOWN, ^ref, :process, ^sweep, :normal}, 5_000

      assert_receive {:companion_event, %{"t" => "row"} = mac_row}

      assert mac_row["text"] ==
               "Voice call, under a minute\n\n- Completed: The room is booked for 10am."

      assert mac_row["metadata"]["call"]["gist_status"] == "failed"

      assert {:ok, %{gist_status: "failed", row_state: "row_written"}} =
               Repo.get_voice_call(call_uuid, server: @timeline_repo)
    end
  end

  # M56 §4.6: a task still running when a call in the chat ends finishes into
  # the chat. Its reply lands there exactly once, as the task's done row,
  # whichever side of the hand-over it arrives on: before the call ends it is
  # said, as the session settles it is forwarded by the session, after the
  # call it finds the new owner's route.
  describe "a task that outlives its call" do
    setup :start_timeline

    test "a reply after the call ended lands in the chat once, as the task's done row" do
      Process.flag(:trap_exit, true)
      session = start_session(live_config(), record_repo: @timeline_repo, gist: gist("Parking."))
      %{call_uuid: call_uuid, turn_pid: turn_pid} = task_running(session)

      assert :ok = SessionControl.call_stop(session)

      assert_receive {:realtime,
                      %{type: "task", delegation_id: "dg_1", status: "running", detached: true}}

      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000
      assert Process.alive?(turn_pid), "the call's end stopped the task it handed over"

      running = call_row("task_running")
      assert running["text"] == "Still working on: user: #{@spoken}"
      assert running["metadata"]["call"]["uuid"] == call_uuid

      send(turn_pid, {:proceed, @answer})

      done = call_row("task_done")
      assert done["text"] == @answer
      assert done["metadata"]["call"]["state"] == "completed"
      done_seq = done["server_seq"]
      assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^done_seq}}

      refute_receive {:companion_event, %{"metadata" => %{"call" => %{"event" => "task_done"}}}},
                     200

      assert eventually(fn -> record_task(call_uuid) == {"completed", @answer} end)
      assert done_rows(call_uuid) == 1
    end

    test "a reply that reaches the call as it settles lands in the chat once, never said" do
      Process.flag(:trap_exit, true)
      session = start_session(live_config(), record_repo: @timeline_repo, gist: gist("Parking."))
      %{call_uuid: call_uuid, turn_pid: turn_pid} = task_running(session)

      # The reply reaches the session behind its stop, before the session has
      # handed the task over and released its route.
      :ok = :sys.suspend(session)
      stop = Task.async(fn -> SessionControl.call_stop(session) end)
      assert eventually(fn -> queued_call?(session, stop.pid, :call_stop) end, 250)
      send(turn_pid, {:proceed, @answer})
      assert eventually(fn -> delegation_event_queued?(session) end, 250)
      :ok = :sys.resume(session)

      assert :ok = Task.await(stop, 5_000)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

      done = call_row("task_done")
      assert done["text"] == @answer

      refute_receive {:companion_event, %{"metadata" => %{"call" => %{"event" => "task_done"}}}},
                     200

      refute_received {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}}

      refute Enum.any?(
               FakeLiveClient.events(),
               &(&1.type == "session.commentary.append" and &1.delegation_id == "dg_1")
             )

      assert eventually(fn -> record_task(call_uuid) == {"completed", @answer} end)
      assert done_rows(call_uuid) == 1
    end

    test "a reply before the call ends is said, and nothing is handed over" do
      Process.flag(:trap_exit, true)
      session = start_session(live_config(), record_repo: @timeline_repo, gist: gist("Parking."))
      %{call_uuid: call_uuid, turn_pid: turn_pid} = task_running(session)

      send(turn_pid, {:proceed, @answer})

      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}},
                     5_000

      assert :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

      refute_received {:realtime, %{type: "task", detached: true}}
      assert done_rows(call_uuid) == 0
    end

    # The companion `cancel.task_ref` (M56 §4.6, §6): only the task those ids
    # name is stopped, and its done row says it was cancelled.
    test "a cancel from the chat by the task's ids stops that turn alone", ctx do
      Process.flag(:trap_exit, true)
      session = start_session(live_config(), record_repo: @timeline_repo, gist: gist("Parking."))
      %{call_uuid: call_uuid, turn_pid: turn_pid} = task_running(session)
      :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000
      call_row("task_running")

      # The owner types while the task runs: the turn waits in the chat's lane.
      :ok = Queue.enqueue(ctx.queue, typed_turn("typed-1"))
      refute_receive {:turn_started, %{id: "typed-1"}, _pid}, 200

      task_ref = %{"call_uuid" => call_uuid, "task_id" => "dg_1", "revision" => 2}
      cancel = %{"profile_id" => "main", "client_msg_id" => "mac-9", "task_ref" => task_ref}

      assert {:error, :task_not_running} = Requests.cancel(cancel, [])
      assert Process.alive?(turn_pid)

      assert :ok = Requests.cancel(put_in(cancel, ["task_ref", "revision"], 1), [])

      done = call_row("task_done")
      assert done["text"] == "The task was cancelled."
      assert done["metadata"]["call"]["state"] == "cancelled"
      refute Process.alive?(turn_pid)

      assert_receive {:turn_started, %{id: "typed-1"}, typed_pid}, 5_000
      send(typed_pid, {:proceed, "Noted."})
      assert eventually(fn -> record_task(call_uuid) == {"cancelled", "cancelled"} end)
    end

    test "/stop ends a task that outlived its call with its row", ctx do
      Process.flag(:trap_exit, true)
      session = start_session(live_config(), record_repo: @timeline_repo, gist: gist("Parking."))
      %{call_uuid: call_uuid, turn_pid: turn_pid} = task_running(session)
      :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000

      assert %{active_stopped: 1} = Queue.stop_all(ctx.queue)

      done = call_row("task_done")
      assert done["metadata"]["call"]["state"] == "cancelled"
      refute Process.alive?(turn_pid)
      assert eventually(fn -> record_task(call_uuid) == {"cancelled", "cancelled"} end)
    end

    # M56 §4.6, §8: the owner dies with the daemon while the task runs; the
    # next boot's pass writes the task's done row and fails it in the record.
    test "a daemon that dies while the task runs leaves its done row to the next boot" do
      Process.flag(:trap_exit, true)
      owner = :"voice_e2e_detached_#{System.unique_integer([:positive])}"
      start_supervised!({Detached, name: owner, mobile_running?: fn -> false end}, id: owner)
      :ok = QueueBoundBridge.bind_detached(owner)

      session = start_session(live_config(), record_repo: @timeline_repo, gist: gist("Parking."))
      %{call_uuid: call_uuid, turn_pid: turn_pid} = task_running(session)
      :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000
      call_row("task_running")
      # The call's own row is written: what dies with the daemon is the task.
      call_row("ended")

      Enum.each([Process.whereis(owner), turn_pid], &Process.exit(&1, :kill))
      assert eventually(fn -> record_task(call_uuid) |> elem(0) == "detached" end)

      {:ok, sweep} = CallRowSweep.start_link(record_repo: @timeline_repo)
      ref = Process.monitor(sweep)
      assert_receive {:DOWN, ^ref, :process, ^sweep, :normal}, 5_000

      done = call_row("task_done")
      assert done["text"] == "The task stopped when Fermix restarted."
      assert done["metadata"]["call"]["state"] == "failed"
      assert record_task(call_uuid) == {"failed", "daemon_restarted"}
      assert done_rows(call_uuid) == 1
    end
  end

  # M56 §4.7: a coding run a call in the chat launches is a chat-origin run of
  # the chat, since the hand-off that launched it ran in the chat's own
  # conversation. Long after the call it ends: its outcome re-enters the chat
  # as a companion turn (the harness continuation), is answered there and lands
  # as a row of the chat. No delegation answers it and no voice route is
  # needed, which is what kept coding runs off a call before.
  describe "a coding run a call in the chat launches" do
    setup :start_timeline

    test "reports back into the chat after the call, answered as a chat turn" do
      Process.flag(:trap_exit, true)
      start_supervised!(Turns)
      session = start_session()

      :ok = SessionControl.call_start(session)
      open_provider_session(session)
      assert_receive {:realtime, %{type: "call_ready", call_id: call_id}}
      speak(session, @spoken, 1_000, 4_000)
      delegate(session, "dg_1", 4_200)
      assert_receive {:turn_started, hand_off, turn_pid}, 5_000

      # The snapshot the run tool freezes at launch, from the hand-off's key.
      assert {:ok, snapshot} =
               HarnessDelivery.resolve_snapshot(%{
                 conversation_key: ConversationKey.from(hand_off)
               })

      assert %{origin_kind: "chat", platform: "companion", destination: "main"} = snapshot

      send(turn_pid, {:proceed, "Started a coding run on it."})

      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}},
                     5_000

      assert :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}, 5_000
      assert Registry.lookup(Voice.registry(), call_id) == []

      run =
        Map.merge(snapshot, %{
          id: "hr_voice1",
          vendor: "codex",
          status: "completed",
          cwd: "/repo",
          continuation_depth: 0
        })

      assert Continuation.continuable?(run)
      assert :ok = Continuation.dispatch(QueueBoundDispatcher, run, "The flaky test is fixed.")

      assert_receive {:turn_started, notice, notice_pid}, 5_000
      assert notice.channel == "companion"
      assert notice.source_trust == :operator
      assert ConversationKey.from(notice) == Companion.chat_conversation_key()
      assert VoiceCall.from_message(notice) == :none
      assert notice.content =~ "[coding run hr_voice1 finished]"
      assert notice.metadata.harness_continuation == true

      send(notice_pid, {:proceed, "The flaky test is fixed, and the suite passes."})

      assert_receive {:companion_event,
                      %{
                        "t" => "row",
                        "role" => "assistant",
                        "text" => "The flaky test is fixed, and the suite passes."
                      }},
                     5_000
    end
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
  # Queue's stop of the hand-off's turn, which answers only once the Queue is
  # free. A hang-up stops the turn of a private call; a call in the chat hands
  # it over instead (above), so these calls are private. The Queue is held
  # suspended only until the session's stop is seen waiting in its mailbox: no
  # test waits out a production call budget. What
  # tells a wait with no budget from a budget not used up yet is the call
  # itself, so each test traces the handler's call and reads the timeout it
  # carries.
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

  # A call in the chat with one hand-off running as an agent turn.
  defp task_running(session) do
    :ok = SessionControl.call_start(session)
    open_provider_session(session)

    assert_receive {:realtime,
                    %{type: "call_ready", call_uuid: call_uuid, tasks_outlive_call: true}}

    speak(session, @spoken, 1_000, 4_000)
    delegate(session, "dg_1", 4_200)
    assert_receive {:turn_started, _msg, turn_pid}, 5_000
    assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "running"}}
    %{call_uuid: call_uuid, turn_pid: turn_pid}
  end

  defp gist(text), do: [routes: [{@gist_route, [adapter: GistAdapter, gist: text]}]]

  # The next row of the call with this `event` the Mac is told of.
  defp call_row(event) do
    assert_receive {:companion_event,
                    %{"t" => "row", "metadata" => %{"call" => %{"event" => ^event}}} = row},
                   5_000

    row
  end

  defp record_task(call_uuid) do
    {:ok, %{tasks: [task]}} = Repo.get_voice_call(call_uuid, server: @timeline_repo)
    {task["state"], task["summary"]}
  end

  defp done_rows(call_uuid) do
    {:ok, %{messages: rows}} = E2ETimeline.history_page("main", limit: 50)
    Enum.count(rows, &(&1.proactive_key == "voice:#{call_uuid}:dg_1:1:done"))
  end

  # A message the owner typed in the chat, queued in the lane a call in the
  # chat's hand-offs share.
  defp typed_turn(id) do
    %{
      id: id,
      channel: "companion",
      chat_id: "main",
      sender: "owner",
      content: "typed while the task runs",
      source_trust: :operator,
      metadata: %{},
      reply_fn: fn _part -> :ok end
    }
  end

  defp delegation_event_queued?(session) do
    {:messages, messages} = Process.info(session, :messages)
    Enum.any?(messages, &match?({:delegation_event, "dg_1", {:result, _result}}, &1))
  end

  # The chat's timeline on a throwaway repo, a companion connection's place in
  # the registry, and the phones' sink, all this test's.
  defp start_timeline(_ctx) do
    test_pid = self()
    previous = Map.new(@timeline_env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore_channels_env/1) end)
    Application.put_env(:fermix_channels, :companion_store, E2ETimeline)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:mobile_event, profile, event})
      :ok
    end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("voice-e2e-timeline")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @timeline_repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    :ok
  end

  defp restore_channels_env({key, {:ok, value}}),
    do: Application.put_env(:fermix_channels, key, value)

  defp restore_channels_env({key, :error}), do: Application.delete_env(:fermix_channels, key)

  defp start_session(config \\ live_config(), extra \\ []) do
    opts = live_session_opts() |> Keyword.put(:config, config) |> Keyword.merge(extra)
    {:ok, session} = LiveSessionServer.start_link([companion: self()] ++ opts)

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
       session_opts:
         Keyword.put(live_session_opts(), :config, live_config(conversation: "private"))}
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

  # The session's stop of a hand-off's turn is in the Queue's mailbox, waiting.
  defp queued_stop?(queue, session) do
    {:messages, messages} = Process.info(queue, :messages)
    Enum.any?(messages, &match?({:"$gen_call", {^session, _}, {:stop_turn, _key, _id}}, &1))
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

  defp live_config(extra \\ []) do
    Config.normalize(
      [
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1",
        voice: "marin",
        max_session_minutes: 15,
        max_estimated_cost_cents_per_session: 100,
        persist_transcripts: false
      ] ++ extra
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
