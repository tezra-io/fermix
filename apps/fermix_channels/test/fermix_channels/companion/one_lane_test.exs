defmodule FermixChannels.Companion.OneLaneTest do
  @moduledoc """
  M56 D9: the phone's turns run in the Mac's chat, so the two transports'
  turns wait for each other in the chat's one queue lane, and a `cancel` from
  either names its own turn's message id there, so it never stops the
  other's. `Companion.Turns` hands each turn to a real queue and sends each
  stop, as it does in production; only the runner is a stand-in, announcing
  each turn and holding it until the test lets it end. Each message is the
  one the gateway hands the agent: a phone message carries the chat's key,
  which the gateway named on it from the phone's adapter.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Realtime.CallRegistry

  # Stands in for `MainAgent.checkout_turn_state/2`: the snapshot only carries
  # the process the runner reports to.
  defmodule StubAgent do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, opts),
      do: {:reply, {:ok, %{test_pid: opts.test_pid}, :hit}, opts}
  end

  defmodule HeldRunner do
    def run(msg, turn_state, _deliver) do
      send(turn_state.test_pid, {:running, msg.id, msg.channel, self()})

      receive do
        :finish -> {:ok, "done", 0}
      after
        5_000 -> {:ok, "done", 0}
      end
    end

    def commit(_msg, _turn_state, _response, _context_tokens), do: :ok
    def error_reply(reason), do: inspect(reason)
  end

  setup do
    start_supervised!({CallRegistry, name: CallRegistry})
    start_supervised!(Turns)
    store = start_supervised!({ConversationStore, name: nil, repo: nil})
    task_supervisor = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Queue,
         name: :"one_lane_queue_#{System.unique_integer([:positive])}",
         main_agent: start_supervised!({StubAgent, test_pid: self()}),
         turn_runner: HeldRunner,
         conversation_store: store,
         task_supervisor: task_supervisor}
      )

    %{queue: queue}
  end

  test "a phone turn waits for the Mac's, and the Mac's for the phone's", ctx do
    hand_off(phone("p-1"), ctx)
    assert_receive {:running, "p-1", "mobile", phone_turn}
    hand_off(mac("m-1"), ctx)
    refute_receive {:running, "m-1", _channel, _turn}, 200

    assert %{active_conversations: 1, pending_requests: 1} = Queue.status(ctx.queue)
    send(phone_turn, :finish)
    assert_receive {:running, "m-1", "companion", mac_turn}

    hand_off(phone("p-2"), ctx)
    refute_receive {:running, "p-2", _channel, _turn}, 200
    send(mac_turn, :finish)
    assert_receive {:running, "p-2", "mobile", last}
    send(last, :finish)
  end

  # The stage's own gate: a phone message during a call in the chat waits its
  # turn behind the call's running task, which runs in the chat's lane.
  test "a phone turn waits for a running hand-off of a call in the chat", ctx do
    :ok = Queue.handle_message(hand_off_message("d-1"), ctx.queue)
    assert_receive {:running, "voice-delegation-d-1-1", "voice", task}
    hand_off(phone("p-1"), ctx)
    refute_receive {:running, "p-1", _channel, _turn}, 200

    send(task, :finish)
    assert_receive {:running, "p-1", "mobile", phone_turn}
    send(phone_turn, :finish)
  end

  test "the Mac's cancel of its waiting turn leaves the phone's running turn alone", ctx do
    hand_off(phone("p-1"), ctx)
    assert_receive {:running, "p-1", "mobile", phone_turn}
    hand_off(mac("m-1"), ctx)
    watched = Process.monitor(phone_turn)

    assert :ok = Turns.cancel(Turns, "main", "m-1")

    refute_receive {:DOWN, ^watched, :process, _pid, _reason}, 200
    send(phone_turn, :finish)
    assert_receive {:DOWN, ^watched, :process, _pid, :normal}
    refute_receive {:running, "m-1", _channel, _turn}, 200
  end

  test "the phone's cancel of its waiting turn leaves the Mac's running turn alone", ctx do
    hand_off(mac("m-1"), ctx)
    assert_receive {:running, "m-1", "companion", mac_turn}
    hand_off(phone("p-1"), ctx)
    watched = Process.monitor(mac_turn)

    assert :ok = Turns.cancel(Turns, "main", "p-1")

    refute_receive {:DOWN, ^watched, :process, _pid, _reason}, 200
    send(mac_turn, :finish)
    assert_receive {:DOWN, ^watched, :process, _pid, :normal}
    refute_receive {:running, "p-1", _channel, _turn}, 200
  end

  test "the phone's cancel of its running turn hands the lane to the Mac's", ctx do
    hand_off(phone("p-1"), ctx)
    assert_receive {:running, "p-1", "mobile", phone_turn}
    hand_off(mac("m-1"), ctx)
    watched = Process.monitor(phone_turn)

    assert :ok = Turns.cancel(Turns, "main", "p-1")

    assert_receive {:DOWN, ^watched, :process, _pid, _killed}
    assert_receive {:running, "m-1", "companion", mac_turn}
    send(mac_turn, :finish)
  end

  # Turns hands a turn to the queue in its own mailbox order; once it has
  # answered, the hand-off has reached the queue.
  defp hand_off(message, ctx) do
    :ok = Turns.handle_message(message, ctx.queue)
    _state = :sys.get_state(Turns)
    :ok
  end

  # The conversation the gateway names on a phone message, from the phone's
  # own adapter.
  defp phone(id) do
    parsed =
      Message.new!(%{
        id: id,
        content: "",
        sender: "owner",
        channel: Mobile.channel(),
        chat_id: "main",
        reply_target: "main"
      })

    %{agent_message(id, Mobile.channel()) | conversation_key: Mobile.joined_conversation(parsed)}
  end

  defp mac(id), do: agent_message(id, Companion.channel())

  # A Live call's task as `Voice.Bridge` ingests it: a voice message whose
  # trusted `voice_call` names the chat's conversation.
  defp hand_off_message(delegation_id) do
    voice_call = %{
      call_id: "voice_live_1",
      call_uuid: "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab",
      conversation: "chat",
      conversation_key: Companion.chat_conversation_key(),
      delegation_id: delegation_id,
      revision: 1,
      turn_session_id: "voice_delegation_1",
      conversation_store: ConversationStore,
      prompt_addendum: "backend addendum",
      persist?: false
    }

    %{
      agent_message("voice-delegation-#{delegation_id}-1", "voice")
      | chat_id: "voice_live_1",
        reply_target: "voice_live_1",
        metadata: %{voice_call: voice_call}
    }
  end

  defp agent_message(id, channel) do
    %{
      id: id,
      content: "#{channel} says #{id}",
      sender: "owner",
      channel: channel,
      chat_id: "main",
      reply_target: "main",
      thread_ts: nil,
      conversation_key: nil,
      source_trust: :operator,
      metadata: %{client_msg_id: id, turn_id: "turn-" <> id},
      reply_fn: fn _part -> :ok end
    }
  end
end
