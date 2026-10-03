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

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Voice.Bridge
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Memory.ConversationStore
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
    %{
      call_id: Keyword.get(opts, :call_id, "voice_live_#{System.unique_integer([:positive])}"),
      call_uuid: Keyword.get(opts, :call_uuid, uuid()),
      conversation: Keyword.get(opts, :conversation, "private"),
      device_id: "device-1",
      persist?: Keyword.get(opts, :persist?, false),
      session_scope: "voice_live:1",
      agent_server: ctx.queue
    }
  end

  defp uuid, do: DeviceIdentity.generate_uuid()

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
      assert voice_call.prompt_addendum == LivePrompt.backend_addendum()
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
end
