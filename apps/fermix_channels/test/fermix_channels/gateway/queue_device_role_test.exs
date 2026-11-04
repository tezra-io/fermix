defmodule FermixChannels.Gateway.QueueDeviceRoleTest do
  # A turn that reaches a device-role engine through the queue every channel
  # shares is refused by the real Main Agent's checkout, and the channel is told
  # the refusal's own sentence rather than a generic error.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.Queue
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.ConversationStore

  defmodule NoAdapter do
  end

  # The checkout refuses before a turn starts, so the runner must never run.
  defmodule UnreachableRunner do
    def run(_msg, _turn_state, _deliver), do: raise("a refused turn must not run")
    def commit(_msg, _turn_state, _response, _context_tokens), do: raise("nothing to commit")
    def error_reply(_reason), do: "generic error reply"
  end

  @sentence "This engine runs in the device role; the primary is aws i-0f3b1c."

  setup do
    unique = System.unique_integer([:positive])
    agent = :"queue_device_agent_#{unique}"

    start_supervised!(
      {MainAgent,
       name: agent, adapter: NoAdapter, engine_role: %{role: :device, primary: "aws i-0f3b1c"}},
      id: :device_agent
    )

    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :device_tasks)

    store =
      start_supervised!(
        {ConversationStore, name: :"queue_device_cs_#{unique}", max_messages: 16, repo: nil},
        id: :device_store
      )

    queue =
      start_supervised!(
        {Queue,
         name: :"queue_device_#{unique}",
         main_agent: agent,
         turn_runner: UnreachableRunner,
         task_supervisor: task_supervisor,
         conversation_store: store},
        id: :device_queue
      )

    %{queue: queue}
  end

  # A slash command sent to a desktop (`fermix ask "/history status"`) would
  # read the database the device does not open: it is refused like any message.
  test "a slash command hears the device-role sentence, and no command runs", %{queue: queue} do
    test_pid = self()

    message =
      struct!(FermixChannels.Gateway.Message,
        id: "device-command-1",
        content: "/history status",
        sender: "cli",
        channel: "cli",
        chat_id: "cli",
        reply_target: "cli",
        metadata: %{source: :cli, user_id: "cli", chat_type: "private"}
      )

    capture_log(fn ->
      assert :ok =
               FermixChannels.Gateway.ingest([message],
                 channel: FermixChannels.CLI,
                 agent: Queue,
                 agent_server: queue,
                 engine_role: %{role: :device, primary: "aws i-0f3b1c"},
                 reply_fn: fn
                   {:text, text} -> send(test_pid, {:reply, text})
                   _other -> :ok
                 end
               )

      assert_receive {:reply, @sentence}, 10_000
    end)
  end

  test "the channel hears the device-role sentence and the turn fails by name", %{queue: queue} do
    test_pid = self()

    msg = %{
      content: "hello",
      sender: "owner",
      channel: "companion",
      chat_id: "main",
      reply_fn: fn {:text, text} -> send(test_pid, {:reply, text}) end,
      turn_result_fn: fn outcome -> send(test_pid, {:turn_result, outcome}) end
    }

    capture_log(fn ->
      Queue.enqueue(queue, msg)
      assert_receive {:reply, @sentence}, 10_000
      assert_receive {:turn_result, {:failed, {:device_role, @sentence}}}, 10_000
    end)
  end
end
