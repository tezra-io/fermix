defmodule FermixChannels.Voice.TypedTurnTest do
  @moduledoc """
  M56 §4.4: a message typed in the chat is judged against the Live call when
  its turn runs, not when it was typed. The real queue checks the turn out of a
  real `MainAgent`, which asks the registered `Voice.Bridge`, which reads Core's
  call registry; only the runner is a stand-in, reporting the snapshot it was
  handed and holding its turn until the test lets it end. This test process
  holds the call's claim in a Live session's stead.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.DeviceIdentity

  defmodule HeldRunner do
    def run(msg, turn_state, _deliver) do
      send(msg.metadata.test_pid, {:running, msg.content, turn_state.live_call, self()})

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
    agent = :"typed_turn_main_agent_#{System.unique_integer([:positive])}"
    start_supervised!({MainAgent, name: agent})
    task_supervisor = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Queue,
         name: :"typed_turn_queue_#{System.unique_integer([:positive])}",
         main_agent: agent,
         turn_runner: HeldRunner,
         task_supervisor: task_supervisor}
      )

    %{queue: queue}
  end

  test "a message queued before the call starts and run during it is told of the call", ctx do
    :ok = Queue.handle_message(typed("first"), ctx.queue)
    assert_receive {:running, "first", nil, first}, 5_000

    :ok = Queue.handle_message(typed("queued before the call"), ctx.queue)
    holder = hold_call()
    send(first, :finish)

    assert_receive {:running, "queued before the call", %{started_at: _started_at} = call,
                    second},
                   5_000

    assert call.silence_allowed? == true
    send(second, :finish)
    send(holder, :release)
  end

  test "a message queued during the call and run after it ended is told of none", ctx do
    holder = hold_call()
    :ok = Queue.handle_message(typed("during"), ctx.queue)
    assert_receive {:running, "during", %{started_at: _started_at}, first}, 5_000

    :ok = Queue.handle_message(typed("queued during the call"), ctx.queue)
    end_call(holder)
    send(first, :finish)

    assert_receive {:running, "queued during the call", nil, second}, 5_000
    send(second, :finish)
  end

  defp typed(content) do
    {channel, chat_id, :root} = Companion.chat_conversation_key()

    %{
      id: "typed-#{System.unique_integer([:positive])}",
      content: content,
      sender: "Companion owner",
      channel: channel,
      chat_id: chat_id,
      source_trust: :operator,
      metadata: %{test_pid: self()},
      reply_fn: fn _part -> :ok end
    }
  end

  # A Live session's stand-in: claims a call in the chat until released.
  defp hold_call do
    test_pid = self()

    holder =
      spawn(fn ->
        call = %{
          call_uuid: DeviceIdentity.generate_uuid(),
          conversation: "chat",
          started_at: DateTime.utc_now()
        }

        :ok = CallRegistry.claim(CallRegistry, call)
        send(test_pid, :claimed)

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end
      end)

    assert_receive :claimed
    holder
  end

  # The registry skips an owner that has exited, so the call is over once its
  # holder is down.
  defp end_call(holder) do
    ref = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}
    assert CallRegistry.active(CallRegistry) == :none
  end
end
