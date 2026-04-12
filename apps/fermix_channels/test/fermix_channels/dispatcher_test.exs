defmodule FermixChannels.DispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Dispatcher
  alias FermixChannels.Message

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule ReplyChannel do
    def send_message(reply_target, text, opts) do
      send(self(), {:reply_sent, reply_target, text, opts})

      case text do
        "fail" -> {:error, :telegram_down}
        _text -> :ok
      end
    end
  end

  test "routes normalized inbound messages into the configured agent with reply runtime" do
    message = %Message{
      id: "42",
      content: "hello",
      sender: "alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      thread_ts: "77",
      metadata: %{update_id: 100},
      attachments: [%{type: :photo, id: "file-1"}]
    }

    assert :ok =
             Dispatcher.dispatch([message],
               channel: ReplyChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}
    assert agent_message.content == "hello"
    assert agent_message.sender == "alice"
    assert agent_message.channel == "telegram"
    assert agent_message.chat_id == "123"
    assert agent_message.thread_ts == "77"
    assert agent_message.metadata == %{update_id: 100}
    assert agent_message.attachments == [%{type: :photo, id: "file-1"}]

    assert :ok = agent_message.reply_fn.("reply")
    assert_received {:reply_sent, "123", "reply", reply_opts}
    assert reply_opts[:message_thread_id] == "77"

    log =
      capture_log(fn ->
        assert {:error, :telegram_down} = agent_message.reply_fn.("fail")
      end)

    assert log =~ "Channel reply delivery failed"
  end
end
