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

  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Voice.Bridge
  alias FermixCore.Memory.ConversationStore
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

  defp open(ctx, opts \\ []) do
    call_id = Keyword.get(opts, :call_id, "voice_live_#{System.unique_integer([:positive])}")

    {:ok, handle} =
      Bridge.open_call(%{
        call_id: call_id,
        device_id: "device-1",
        persist?: Keyword.get(opts, :persist?, false),
        session_scope: "voice_live:1",
        agent_server: ctx.queue
      })

    handle
  end

  defp callbacks do
    test_pid = self()

    %{
      progress: fn text -> send(test_pid, {:progress, text}) && :ok end,
      activity: fn event -> send(test_pid, {:activity, event}) && :ok end,
      result: fn outcome -> send(test_pid, {:result, outcome}) && :ok end
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
               Bridge.open_call(%{
                 call_id: "voice_live_dup",
                 device_id: "device-2",
                 persist?: false,
                 session_scope: "voice_live:2",
                 agent_server: ctx.queue
               })

      Bridge.close_call(handle)
    end
  end

  describe "submit/3" do
    test "the delegation reaches the queue as a trusted operator voice turn", ctx do
      handle = open(ctx)

      assert {:ok, {conversation_key, "d-1"}} = Bridge.submit(handle, request(), callbacks())
      assert conversation_key == {"voice", handle.call_id, :root}

      assert_receive {:turn_started, msg, _pid}, 5_000
      assert msg.channel == "voice"
      assert msg.chat_id == handle.call_id
      assert msg.source_trust == :operator
      assert msg.content == "user: what is on my calendar"

      voice_call = msg.metadata.voice_call
      assert voice_call.call_id == handle.call_id
      assert voice_call.turn_session_id == "voice_delegation_1"
      assert voice_call.conversation_store == handle.store
      assert voice_call.persist? == false
      assert voice_call.prompt_addendum == LivePrompt.backend_addendum()

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

      assert :ok = Bridge.cancel(handle, {Bridge.conversation_key(handle.call_id), "d-1"})

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

  describe "conversation isolation" do
    test "a concurrent text conversation shares no history with the call", ctx do
      handle = open(ctx)
      global = Process.whereis(ConversationStore)
      chat_key = {"telegram", "chat-voice-isolation", :root}
      call_key = Bridge.conversation_key(handle.call_id)

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
