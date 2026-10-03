defmodule FermixChannels.Voice.BridgeTest do
  @moduledoc """
  The Live voice engine's seam into the agent
  (MILESTONE_41_OPENAI_LIVE_VOICE.md §5.2/§7).

  Drives the bridge against a test-owned `Gateway.Queue` with the queue suite's
  own doubles (a stub MainAgent and a controllable runner), so a delegation
  really is ingested, authorized, queued and answered — with no provider, no
  network, and no dependency on the daemon's live queue.
  """

  use ExUnit.Case, async: false

  @call_started_at ~U[2026-10-03 14:05:00Z]

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Voice.Bridge
  alias FermixChannels.Voice.Detached
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.LivePrompt

  # Stands in for `MainAgent.checkout_turn_state/2`: the snapshot only has to
  # carry the pid the fake runner reports to.
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

  # Announces each turn, then blocks until the test says how it ends. The voice
  # channel resolves a raw stream callback and an activity callback, so the
  # queue calls run/5 — the arity a real voice turn actually takes.
  defmodule FakeRunner do
    def run(msg, turn_state, deliver), do: run(msg, turn_state, deliver, nil, nil)

    def run(msg, turn_state, deliver, stream_callback),
      do: run(msg, turn_state, deliver, stream_callback, nil)

    def run(msg, turn_state, _deliver, stream_callback, activity_callback) do
      if is_function(stream_callback, 1), do: stream_callback.({:text_delta, "partial"})
      if is_function(activity_callback, 1), do: activity_callback.({:tool_start, "list_events"})
      send(turn_state.test_pid, {:turn_started, msg, self()})

      receive do
        {:proceed, :reply} -> {:ok, "reply:" <> msg.content, 0}
        {:proceed, {:error, reason}} -> {:error, reason}
      after
        15_000 -> {:ok, "reply:" <> msg.content, 0}
      end
    end

    def commit(_msg, _turn_state, _response, _context_tokens), do: :ok
    def error_reply(reason), do: "error reply: #{inspect(reason)}"
  end

  # A companion timeline that tells the test what a call row handed it, and
  # answers the row as written.
  defmodule RecordingTimeline do
    def append_proactive(profile, key, attrs, _opts) do
      send(:voice_bridge_show_test, {:append_proactive, profile, key, attrs})

      row =
        Map.merge(attrs, %{
          profile_id: profile,
          server_seq: 77,
          proactive_key: key,
          created_at: ~U[2026-10-03 14:06:00Z]
        })

      {:ok, {:created, row}}
    end
  end

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Queue,
         name: :"voice_bridge_queue_#{System.unique_integer([:positive])}",
         main_agent: start_supervised!({StubAgent, test_pid: self()}, id: :voice_stub_agent),
         turn_runner: FakeRunner,
         task_supervisor: task_supervisor},
        id: :voice_bridge_queue
      )

    %{queue: queue}
  end

  # Private unless a test says otherwise: most of what this suite pins (the
  # store's lifetime, routing, cancels) is the same in both modes, and the
  # private mode is the one with a store of its own to watch.
  defp open(ctx, opts \\ []) do
    {:ok, handle} = Bridge.open_call(call(ctx, opts))
    handle
  end

  defp call(ctx, opts) do
    call = %{
      call_id: Keyword.get(opts, :call_id, "voice_live_#{System.unique_integer([:positive])}"),
      call_uuid: Keyword.get(opts, :call_uuid, uuid()),
      conversation: Keyword.get(opts, :conversation, "private"),
      device_id: "device-1",
      persist?: Keyword.get(opts, :persist?, false),
      session_scope: "voice_live:1",
      agent_server: ctx.queue
    }

    case Keyword.fetch(opts, :detached) do
      {:ok, detached} -> Map.put(call, :detached, detached)
      :error -> call
    end
  end

  defp uuid, do: DeviceIdentity.generate_uuid()

  defp add(key, role, content, opts \\ []),
    do: :ok = ConversationStore.add_message(key, role, content, opts)

  defp callbacks do
    test_pid = self()

    %{
      progress: fn text -> send(test_pid, {:progress, text}) && :ok end,
      activity: fn event -> send(test_pid, {:activity, event}) && :ok end,
      result: fn outcome -> send(test_pid, {:result, outcome}) && :ok end
    }
  end

  # The same, each result tagged with the delegation it answers, for a test
  # that holds two delegations at once.
  defp callbacks(delegation_id) do
    test_pid = self()

    %{
      progress: fn _text -> :ok end,
      activity: fn _event -> :ok end,
      result: fn outcome -> send(test_pid, {:result, delegation_id, outcome}) && :ok end
    }
  end

  # A turn that is not the call's own, queued in the conversation the call's
  # hand-offs run in.
  defp other_turn(handle, id) do
    {channel, chat_id, :root} = handle.conversation_key

    %{
      id: id,
      channel: channel,
      chat_id: chat_id,
      sender: "owner",
      content: "typed",
      source_trust: :operator,
      metadata: %{},
      reply_fn: fn _part -> :ok end
    }
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        call_id: "unused",
        delegation_id: "d-1",
        revision: 1,
        turn_session_id: "voice_delegation_1",
        text: "user: what is on my calendar",
        screen_frame: nil
      },
      overrides
    )
  end

  describe "open_call/1" do
    test "a non-persisting call gets its own in-memory store", ctx do
      handle = open(ctx)

      assert is_pid(handle.store)
      assert handle.store != Process.whereis(ConversationStore)
      # `repo: nil` is what keeps a spoken fragment off disk: the store performs
      # no durable write at all, so there is nothing to suppress later.
      assert :sys.get_state(handle.store).repo == nil
      assert :sys.get_state(handle.store).max_messages == 128

      Bridge.close_call(handle)
    end

    test "a persisting call uses the global store", ctx do
      handle = open(ctx, persist?: true)

      assert handle.store == ConversationStore

      Bridge.close_call(handle)
    end

    test "closing a non-persisting call releases its store", ctx do
      handle = open(ctx)
      store = handle.store

      Bridge.close_call(handle)

      refute Process.alive?(store)
    end

    test "closing a persisting call leaves the global store running", ctx do
      handle = open(ctx, persist?: true)

      Bridge.close_call(handle)

      assert Process.alive?(Process.whereis(ConversationStore))
    end

    test "a second open of the same call id is refused", ctx do
      handle = open(ctx, call_id: "voice_live_dup")

      assert {:error, {:call_already_open, _pid}} =
               Bridge.open_call(call(ctx, call_id: "voice_live_dup"))

      Bridge.close_call(handle)
    end

    # M56 §4.1: the call joins the chat. It opens no store; its hand-offs run on
    # the durable store, in the conversation the Mac app's turns run in.
    test "a chat call opens no store and runs in the chat's conversation", ctx do
      handle = open(ctx, conversation: "chat")

      assert handle.store == ConversationStore
      assert handle.conversation_key == Companion.chat_conversation_key()
      assert handle.conversation_key == {"companion", "main", :root}

      Bridge.close_call(handle)
      assert Process.alive?(Process.whereis(ConversationStore))
    end

    # The call id is a counter that restarts with the daemon, so a private
    # call's conversation is keyed by its UUID: a later call that reuses the id
    # never inherits the earlier call's history (M56 §15).
    test "a private call's conversation is keyed by its UUID, not its call id", ctx do
      first = open(ctx, call_id: "voice_live:1", persist?: true)
      Bridge.close_call(first)
      second = open(ctx, call_id: "voice_live:1", persist?: true)

      assert first.conversation_key == {"voice", first.call_uuid, :root}
      assert second.conversation_key == {"voice", second.call_uuid, :root}
      refute first.conversation_key == second.conversation_key

      Bridge.close_call(second)
    end
  end

  describe "submit/3" do
    test "the delegation reaches the queue as a trusted operator voice turn", ctx do
      handle = open(ctx)

      assert {:ok, {conversation_key, "voice-delegation-d-1-1"}} =
               Bridge.submit(handle, request(), callbacks())

      assert conversation_key == {"voice", handle.call_uuid, :root}

      assert_receive {:turn_started, msg, _pid}, 5_000
      assert msg.channel == "voice"
      assert msg.chat_id == handle.call_id
      assert msg.source_trust == :operator
      assert msg.content == "user: what is on my calendar"

      voice_call = msg.metadata.voice_call
      assert voice_call.call_id == handle.call_id
      assert voice_call.call_uuid == handle.call_uuid
      assert voice_call.conversation_key == {"voice", handle.call_uuid, :root}
      assert voice_call.turn_session_id == "voice_delegation_1"
      assert voice_call.conversation_store == handle.store
      assert voice_call.persist? == false
      # A private call shows nothing in the chat, so its addendum is today's.
      assert voice_call.prompt_addendum == LivePrompt.backend_addendum("private")
      # The mode the turn's capability boundary is read for (M56 §4.7).
      assert voice_call.conversation == "private"
      assert ConversationKey.from(msg) == {"voice", handle.call_uuid, :root}
      assert conversation_key == ConversationKey.from(msg)

      Bridge.close_call(handle)
    end

    # The message stays on the voice channel with the call as its chat, so the
    # trust gate, the voice adapter and commands-off are unchanged; only the
    # conversation the trusted map names moves (M56 §4.1, option B).
    test "a chat call's hand-off is a trusted voice turn in the chat's conversation", ctx do
      handle = open(ctx, conversation: "chat")

      assert {:ok, {task_key, "voice-delegation-d-1-1"}} =
               Bridge.submit(handle, request(), callbacks())

      assert_receive {:turn_started, msg, turn_pid}, 5_000
      assert msg.channel == "voice"
      assert msg.chat_id == handle.call_id
      assert msg.source_trust == :operator
      assert msg.metadata.voice_call.conversation_key == Companion.chat_conversation_key()
      assert msg.metadata.voice_call.conversation_store == ConversationStore
      # The reply may part into a line said and a result shown (M56 §4.5).
      assert msg.metadata.voice_call.prompt_addendum == LivePrompt.backend_addendum("chat")
      assert msg.metadata.voice_call.conversation == "chat"
      assert ConversationKey.from(msg) == Companion.chat_conversation_key()
      assert task_key == Companion.chat_conversation_key()

      send(turn_pid, {:proceed, :reply})
      assert_receive {:result, {:ok, _text}}, 5_000

      Bridge.close_call(handle)
    end

    test "the answer reaches the session's result callback exactly once", ctx do
      handle = open(ctx)
      {:ok, _ref} = Bridge.submit(handle, request(), callbacks())

      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:result, {:ok, "reply:user: what is on my calendar"}}, 5_000
      refute_receive {:result, _other}, 200

      Bridge.close_call(handle)
    end

    test "a failed turn reaches the session as a stringified error, with no chat text", ctx do
      handle = open(ctx)
      {:ok, _ref} = Bridge.submit(handle, request(), callbacks())

      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      send(turn_pid, {:proceed, {:error, :boom}})

      assert_receive {:result, {:error, message}}, 5_000
      assert is_binary(message)
      # `terminal_error_capability/0` is `:turn_result`, so the queue delivers
      # NO canned chat sentence as if it were the delegation's answer.
      refute_receive {:result, {:ok, _text}}, 200

      Bridge.close_call(handle)
    end

    test "a correction keeps the delegation id and supersedes the old revision", ctx do
      handle = open(ctx)
      {:ok, _first} = Bridge.submit(handle, request(), callbacks())
      assert_receive {:turn_started, _msg, first_pid}, 5_000

      {:ok, _second} = Bridge.submit(handle, request(%{revision: 2}), callbacks())

      # The first turn's answer now names a superseded revision and is dropped.
      send(first_pid, {:proceed, :reply})
      refute_receive {:result, {:ok, _text}}, 300

      Bridge.close_call(handle)
    end

    test "tool activity reaches the session, partial text never does", ctx do
      handle = open(ctx)
      {:ok, _ref} = Bridge.submit(handle, request(), callbacks())

      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      # The runner pushed one stream delta and one tool start before announcing
      # itself, so both have already been routed by now.
      assert_receive {:activity, {:tool_start, "list_events"}}, 5_000
      refute_receive {:progress, _text}, 200

      send(turn_pid, {:proceed, :reply})
      assert_receive {:result, {:ok, _text}}, 5_000

      Bridge.close_call(handle)
    end

    test "a screen frame rides the turn as transient media", ctx do
      handle = open(ctx)
      frame = %{mime_type: "image/png", data: "bytes"}

      {:ok, _ref} = Bridge.submit(handle, request(%{screen_frame: frame}), callbacks())

      assert_receive {:turn_started, msg, _pid}, 5_000
      assert msg.media_parts == [frame]

      Bridge.close_call(handle)
    end

    test "a submit from a process that does not own the call is refused", ctx do
      handle = open(ctx)
      test_pid = self()

      spawn(fn ->
        send(test_pid, {:submitted, Bridge.submit(handle, request(), callbacks())})
      end)

      assert_receive {:submitted, {:error, :not_call_owner}}, 5_000

      Bridge.close_call(handle)
    end
  end

  describe "cancel/2" do
    test "stops the turn and hands the session {:cancelled}", ctx do
      handle = open(ctx)
      {:ok, task_ref} = Bridge.submit(handle, request(), callbacks())

      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      assert :ok = Bridge.cancel(handle, task_ref)

      assert_receive {:result, {:cancelled}}, 5_000
      refute Process.alive?(turn_pid)

      Bridge.close_call(handle)
    end

    test "a cancel with nothing running is reported, not an error", ctx do
      handle = open(ctx)
      {:ok, task_ref} = Bridge.submit(handle, request(), callbacks())
      assert_receive {:turn_started, _msg, turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})
      assert_receive {:result, {:ok, _text}}, 5_000

      assert :ok = Bridge.cancel(handle, task_ref)

      Bridge.close_call(handle)
    end

    # M56 §4.1: a cancel names the one queue turn the hand-off runs as
    # (`voice-delegation-<id>-<rev>`), so it can never end another turn of the
    # conversation it runs in or clear what waits there.
    test "a cancel stops the named hand-off and leaves the turn waiting behind it", ctx do
      handle = open(ctx)
      {:ok, first} = Bridge.submit(handle, request(), callbacks("d-1"))
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, first_pid}, 5_000

      {:ok, second} =
        Bridge.submit(handle, request(%{delegation_id: "d-2"}), callbacks("d-2"))

      assert {_key, "voice-delegation-d-1-1"} = first
      assert {_key, "voice-delegation-d-2-1"} = second

      assert :ok = Bridge.cancel(handle, first)

      assert_receive {:result, "d-1", {:cancelled}}, 5_000
      refute Process.alive?(first_pid)

      # The waiting hand-off was not cleared: it starts and answers.
      assert_receive {:turn_started, %{id: "voice-delegation-d-2-1"}, second_pid}, 5_000
      send(second_pid, {:proceed, :reply})
      assert_receive {:result, "d-2", {:ok, _text}}, 5_000

      Bridge.close_call(handle)
    end

    test "a cancel of a waiting hand-off leaves the running one alone", ctx do
      handle = open(ctx)
      {:ok, _first} = Bridge.submit(handle, request(), callbacks("d-1"))
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, first_pid}, 5_000

      {:ok, second} =
        Bridge.submit(handle, request(%{delegation_id: "d-2"}), callbacks("d-2"))

      assert :ok = Bridge.cancel(handle, second)

      assert_receive {:result, "d-2", {:cancelled}}, 5_000
      assert Process.alive?(first_pid)

      send(first_pid, {:proceed, :reply})
      assert_receive {:result, "d-1", {:ok, _text}}, 5_000
      refute_receive {:turn_started, %{id: "voice-delegation-d-2-1"}, _pid}, 200

      Bridge.close_call(handle)
    end
  end

  describe "close_call/1" do
    test "a result arriving after the call closed is dropped", ctx do
      handle = open(ctx)
      {:ok, _ref} = Bridge.submit(handle, request(), callbacks())
      assert_receive {:turn_started, _msg, turn_pid}, 5_000

      # Close while the turn is still in flight, then let it answer.
      Bridge.close_call(handle)
      send(turn_pid, {:proceed, :reply})

      refute_receive {:result, _outcome}, 300
    end

    # M56 §4.1: the close stops the turns the call registered, by name, never
    # the conversation they run in, so another turn waiting there still runs.
    test "closing the call stops its hand-offs and nothing else waiting beside them", ctx do
      handle = open(ctx)
      {:ok, _ref} = Bridge.submit(handle, request(), callbacks())
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, hand_off_pid}, 5_000

      :ok = Queue.enqueue(ctx.queue, other_turn(handle, "other-1"))

      Bridge.close_call(handle)

      refute Process.alive?(hand_off_pid)
      assert_receive {:turn_started, %{id: "other-1"}, other_pid}, 5_000
      send(other_pid, {:proceed, :reply})
    end

    test "every routing entry for the call is released", ctx do
      handle = open(ctx)
      {:ok, _ref} = Bridge.submit(handle, request(), callbacks())
      {:ok, _ref} = Bridge.submit(handle, request(%{delegation_id: "d-2"}), callbacks())

      assert Registry.lookup(Voice.registry(), {handle.call_id, "d-1"}) != []

      Bridge.close_call(handle)

      assert Registry.lookup(Voice.registry(), handle.call_id) == []
      assert Registry.lookup(Voice.registry(), {handle.call_id, "d-1"}) == []
      assert Registry.lookup(Voice.registry(), {handle.call_id, "d-2"}) == []
    end

    test "a second call's entries survive the first call's close", ctx do
      first = open(ctx)
      second = open(ctx)
      {:ok, _ref} = Bridge.submit(second, request(), callbacks())

      Bridge.close_call(first)

      assert Registry.lookup(Voice.registry(), second.call_id) != []
      assert Registry.lookup(Voice.registry(), {second.call_id, "d-1"}) != []

      Bridge.close_call(second)
    end
  end

  # M56 §4.1: a chat call's hand-offs and the owner's typed turns share one
  # conversation, so one queue lane: they never run at once, and a stop of
  # either names its own turn and leaves the other running or waiting.
  describe "a hand-off in the chat's lane" do
    test "waits behind a typed turn, and its cancel leaves that turn running", ctx do
      handle = open(ctx, conversation: "chat")
      :ok = Queue.enqueue(ctx.queue, other_turn(handle, "typed-1"))
      assert_receive {:turn_started, %{id: "typed-1"}, typed_pid}, 5_000

      {:ok, hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))
      refute_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, _pid}, 200

      assert :ok = Bridge.cancel(handle, hand_off)
      assert_receive {:result, "d-1", {:cancelled}}, 5_000
      assert Process.alive?(typed_pid)

      send(typed_pid, {:proceed, :reply})
      refute_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, _pid}, 200
      Bridge.close_call(handle)
    end

    test "a typed turn's own stop leaves the running hand-off to answer", ctx do
      handle = open(ctx, conversation: "chat")
      {:ok, _hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, hand_off_pid}, 5_000

      :ok = Queue.enqueue(ctx.queue, other_turn(handle, "typed-1"))

      assert {:ok, :dequeued} =
               Queue.stop_turn(Companion.chat_conversation_key(), "typed-1", ctx.queue)

      assert Process.alive?(hand_off_pid)
      send(hand_off_pid, {:proceed, :reply})
      assert_receive {:result, "d-1", {:ok, _text}}, 5_000

      Bridge.close_call(handle)
    end

    test "a cancelled hand-off hands the lane to the typed turn behind it", ctx do
      handle = open(ctx, conversation: "chat")
      {:ok, hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, hand_off_pid}, 5_000
      :ok = Queue.enqueue(ctx.queue, other_turn(handle, "typed-1"))

      assert :ok = Bridge.cancel(handle, hand_off)

      assert_receive {:result, "d-1", {:cancelled}}, 5_000
      refute Process.alive?(hand_off_pid)
      assert_receive {:turn_started, %{id: "typed-1"}, typed_pid}, 5_000
      send(typed_pid, {:proceed, :reply})

      Bridge.close_call(handle)
    end

    test "closing the call leaves the chat's queued messages to run", ctx do
      handle = open(ctx, conversation: "chat")
      {:ok, _hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, hand_off_pid}, 5_000
      :ok = Queue.enqueue(ctx.queue, other_turn(handle, "typed-1"))
      :ok = Queue.enqueue(ctx.queue, other_turn(handle, "typed-2"))

      Bridge.close_call(handle)

      refute Process.alive?(hand_off_pid)
      assert_receive {:turn_started, %{id: "typed-1"}, typed_pid}, 5_000
      send(typed_pid, {:proceed, :reply})
      assert_receive {:turn_started, %{id: "typed-2"}, second_pid}, 5_000
      send(second_pid, {:proceed, :reply})
    end
  end

  # M56 §4.6: a task still running as a call in the chat ends is handed to an
  # owner that outlives the session; the owner's route is taken before the
  # session's is released, and the call's close then leaves its turn running.
  describe "detach/3" do
    setup do
      previous = Application.fetch_env(:fermix_channels, :companion_store)
      Application.put_env(:fermix_channels, :companion_store, RecordingTimeline)
      Process.register(self(), :voice_bridge_show_test)

      on_exit(fn ->
        case previous do
          {:ok, store} -> Application.put_env(:fermix_channels, :companion_store, store)
          :error -> Application.delete_env(:fermix_channels, :companion_store)
        end
      end)

      name = :"voice_bridge_detached_#{System.unique_integer([:positive])}"
      start_supervised!({Detached, name: name, mobile_running?: fn -> false end})
      records = :"voice_bridge_records_#{System.unique_integer([:positive])}"
      start_supervised!({Repo, name: records, enabled: false}, id: records)
      %{detached: name, record_opts: CallRecord.repo_opts(records)}
    end

    # The owner writes a task's end once the session that handed it over is
    # gone, so the session's part runs in a process of its own here.
    test "the owner takes the route, then the call's is released and its close spares the turn",
         ctx do
      test_pid = self()

      session =
        Task.async(fn ->
          handle = open(ctx, conversation: "chat", detached: ctx.detached)
          {:ok, hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))
          {:ok, forward} = Bridge.detach(handle, hand_off, detached_task(ctx))
          send(test_pid, {:routes, Registry.lookup(Voice.registry(), {handle.call_id, "d-1"})})
          Bridge.close_call(handle)
          {handle, forward}
        end)

      {handle, forward} = Task.await(session, 5_000)
      assert is_function(forward, 1)
      assert_receive {:routes, []}
      assert_receive {:turn_started, %{id: "voice-delegation-d-1-1"}, hand_off_pid}, 5_000
      assert Process.alive?(hand_off_pid)

      assert [{_owner, %{revision: 1}}] =
               Registry.lookup(Voice.registry(), Detached.route(handle.call_uuid, "d-1"))

      assert_receive {:append_proactive, "main", running_key, _attrs}
      assert running_key == "voice:#{handle.call_uuid}:d-1:1:running"

      # Its answer reaches the owner, not the closed call, and lands as a row.
      send(hand_off_pid, {:proceed, :reply})
      assert_receive {:append_proactive, "main", done_key, %{content: content}}, 5_000
      assert done_key == "voice:#{handle.call_uuid}:d-1:1:done"
      assert content == "reply:user: what is on my calendar"
    end

    test "an owner that cannot take the task moves nothing", ctx do
      handle = open(ctx, conversation: "chat", detached: :no_such_detached_owner)
      {:ok, hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))
      assert_receive {:turn_started, _msg, hand_off_pid}, 5_000

      assert catch_exit(Bridge.detach(handle, hand_off, detached_task(ctx)))
      assert Registry.lookup(Voice.registry(), {handle.call_id, "d-1"}) != []

      Bridge.close_call(handle)
      refute Process.alive?(hand_off_pid)
    end

    test "a private call's tasks are never handed over", ctx do
      handle = open(ctx, detached: ctx.detached)
      {:ok, hand_off} = Bridge.submit(handle, request(), callbacks("d-1"))

      assert_raise FunctionClauseError, fn ->
        Bridge.detach(handle, hand_off, detached_task(ctx))
      end

      Bridge.close_call(handle)
    end

    defp detached_task(ctx) do
      %{
        delegation_id: "d-1",
        revision: 1,
        request: "user: what is on my calendar",
        turn_session_id: "voice_delegation_1",
        elapsed_ms: 1_000,
        record_opts: ctx.record_opts
      }
    end
  end

  # M56 §4.3 (D6): what a call in the chat starts with, read before the call
  # has a handle. The chat's own store, never a tool result or a summary.
  describe "conversation_window/1" do
    setup do
      chat_key = Companion.chat_conversation_key()
      :ok = ConversationStore.clear(chat_key)
      on_exit(fn -> ConversationStore.clear(chat_key) end)
      %{chat_key: chat_key}
    end

    test "reads the chat's newest user and assistant messages, oldest first", %{
      chat_key: chat_key
    } do
      tainted = [metadata: %{history_tainted: true}]

      add(chat_key, "system", "Conversation checkpoint summary:\nthe Q3 report", tainted)
      add(chat_key, "user", "first")
      add(chat_key, "assistant", "first answer")
      add(chat_key, "user", "what was I reading")
      add(chat_key, "assistant", "You were reading the Q3 report.", tainted)
      add(chat_key, "tool", "raw tool output")
      add(chat_key, "user", "send me the lease")
      add(chat_key, "system", "Conversation checkpoint summary:\nlater")

      assert {:ok, %{messages: messages, gists: []}} =
               Bridge.conversation_window(%{messages: 3, gists: 3})

      assert Enum.map(messages, &{&1.role, &1.content}) == [
               {"user", "what was I reading"},
               {"assistant", "You were reading the Q3 report."},
               {"user", "send me the lease"}
             ]

      # The marker rides along, for Core to mask against the voice provider.
      assert [false, true, false] == Enum.map(messages, &Map.get(&1, :history_tainted, false))
    end

    test "an empty chat is an empty window" do
      assert {:ok, %{messages: [], gists: []}} =
               Bridge.conversation_window(%{messages: 6, gists: 0})
    end

    test "another conversation is never read" do
      elsewhere = {"telegram", "voice-window-elsewhere", :root}
      on_exit(fn -> ConversationStore.clear(elsewhere) end)
      add(elsewhere, "user", "a telegram message")

      assert {:ok, %{messages: []}} = Bridge.conversation_window(%{messages: 6, gists: 3})
    end
  end

  # M56 §4.5: a result the voice cannot say is written to the chat's own
  # timeline through the companion's call-row write, which answers its row.
  # The write itself, through the real timeline, is the companion channel's
  # suite; here the timeline only records what it was handed.
  describe "show/2" do
    setup do
      previous = Application.fetch_env(:fermix_channels, :companion_store)
      Application.put_env(:fermix_channels, :companion_store, RecordingTimeline)
      Process.register(self(), :voice_bridge_show_test)

      on_exit(fn ->
        case previous do
          {:ok, store} -> Application.put_env(:fermix_channels, :companion_store, store)
          :error -> Application.delete_env(:fermix_channels, :companion_store)
        end
      end)

      %{
        call: %{
          "uuid" => DeviceIdentity.generate_uuid(),
          "event" => "shared",
          "task_id" => "dg_1",
          "revision" => 1
        }
      }
    end

    test "writes the result as a row of the chat carrying its call and answers the row", %{
      call: call
    } do
      assert {:ok, 77} = Bridge.show(call, "See https://x.test/form")

      expected_key = "voice:#{call["uuid"]}:dg_1:1"

      assert_received {:append_proactive, "main", ^expected_key,
                       %{role: "assistant", kind: "text", content: "See https://x.test/form"} =
                         attrs}

      assert attrs.metadata == %{"call" => call}
    end

    test "a call map in another shape writes nothing", %{call: call} do
      assert {:error, {:invalid_field, "call.revision"}} =
               Bridge.show(%{call | "revision" => 0}, "x")

      refute_received {:append_proactive, _profile, _key, _attrs}
    end
  end

  # M56 §4.4: whether a call in the chat is up, and how a typed turn of the
  # chat is told of it, answered from Core's call registry and the companion
  # clients attached. This test process holds the call's claim in its
  # session's stead, and stands in for the companion clients it registers.
  describe "a call in the chat" do
    setup do
      start_supervised!({CallRegistry, name: CallRegistry})
      :ok
    end

    test "with no call up, there is none to tell" do
      refute Bridge.call_active?()
      assert Bridge.chat_call(Companion.chat_conversation_key(), "companion") == :none
    end

    test "a call in the chat is up, and the chat's turn is told when it started" do
      :ok = CallRegistry.claim(CallRegistry, claim("chat"))

      assert Bridge.call_active?()

      assert Bridge.chat_call(Companion.chat_conversation_key(), "companion") ==
               {:ok, %{started_at: @call_started_at, silence_allowed?: true}}
    end

    test "another conversation's turn is never told of the call" do
      :ok = CallRegistry.claim(CallRegistry, claim("chat"))

      assert Bridge.chat_call({"telegram", "chat-1", :root}, "telegram") == :none
      assert Bridge.chat_call({"mobile", "main", :root}, "mobile") == :none
    end

    # The chat does not know a private call exists (M56 §4.4).
    test "a private call is no call in the chat" do
      :ok = CallRegistry.claim(CallRegistry, claim("private"))

      refute Bridge.call_active?()
      assert Bridge.chat_call(Companion.chat_conversation_key(), "companion") == :none
    end

    # M56 §6: a version 1 client clears a turn only on text_done or
    # turn_error, so a turn may end with no reply only while every client
    # attached reads turn_done.
    test "silence is allowed while every companion client speaks version 2" do
      :ok = CallRegistry.claim(CallRegistry, claim("chat"))
      {:ok, _owner} = Registry.register(Companion.registry(), "main", 2)

      assert {:ok, %{silence_allowed?: true}} =
               Bridge.chat_call(Companion.chat_conversation_key(), "companion")
    end

    test "one version 1 client attached is enough to forbid silence" do
      :ok = CallRegistry.claim(CallRegistry, claim("chat"))
      {:ok, _owner} = Registry.register(Companion.registry(), "main", 2)
      attach_client(1)

      assert {:ok, %{silence_allowed?: false}} =
               Bridge.chat_call(Companion.chat_conversation_key(), "companion")
    end

    # M56 D9: a phone turn runs in the chat's conversation, so it is told of
    # the call; the phone's wire has no turn_done, so a turn it runs never
    # ends without a reply, whatever the Mac's clients read.
    test "a turn the phone runs in the chat is told of the call and never offered silence" do
      :ok = CallRegistry.claim(CallRegistry, claim("chat"))
      {:ok, _owner} = Registry.register(Companion.registry(), "main", 2)

      assert Bridge.chat_call(Companion.chat_conversation_key(), "mobile") ==
               {:ok, %{started_at: @call_started_at, silence_allowed?: false}}
    end
  end

  describe "conversation isolation" do
    test "a concurrent text conversation shares no history with the call", ctx do
      handle = open(ctx)
      global = Process.whereis(ConversationStore)
      chat_key = {"telegram", "chat-voice-isolation", :root}
      call_key = handle.conversation_key

      ConversationStore.add_message(chat_key, "user", "text conversation", server: global)

      ConversationStore.add_message(call_key, "user", "spoken delegation",
        server: handle.store,
        sender: "voice"
      )

      assert [%{content: "spoken delegation"}] =
               ConversationStore.get_history(call_key, server: handle.store)

      assert ConversationStore.get_history(call_key, server: global) == []
      assert ConversationStore.get_history(chat_key, server: handle.store) == []

      Bridge.close_call(handle)
    end
  end

  defp claim(conversation),
    do: %{
      call_uuid: DeviceIdentity.generate_uuid(),
      conversation: conversation,
      started_at: @call_started_at
    }

  # A companion client that has said hello at `version`, joined as a
  # `Companion.Connection` joins, for as long as the test runs.
  defp attach_client(version) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _owner} = Registry.register(Companion.registry(), "main", version)
      send(test_pid, :attached)

      receive do
        :never -> :ok
      after
        10_000 -> :ok
      end
    end)

    assert_receive :attached
  end
end
