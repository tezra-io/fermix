defmodule FermixChannels.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FermixChannels.CLI
  alias FermixChannels.Message

  defmodule TestAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:handled_message, message})
      :ok
    end
  end

  defmodule ReplyAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:sync_agent_message, message})
      message.reply_fn.("reply: #{message.content}")
      :ok
    end
  end

  defmodule SilentAgent do
    def handle_message(_message, _test_pid), do: :ok
  end

  describe "parse_input/2" do
    test "normalizes CLI input into a channel message" do
      assert {:ok, [%Message{} = message]} = CLI.parse_input("hello", sender: "operator")

      assert message.id
      assert message.content == "hello"
      assert message.sender == "operator"
      assert message.channel == "cli"
      assert message.chat_id == "cli"
      assert message.reply_target == "cli"
      assert message.metadata == %{source: :cli}
    end

    test "accepts a custom session id" do
      assert {:ok, [%Message{} = message]} =
               CLI.parse_input("hello", sender: "operator", session_id: "scenario-1")

      assert message.content == "hello"
      assert message.channel == "cli"
      assert message.chat_id == "scenario-1"
      assert message.reply_target == "scenario-1"
      assert message.metadata == %{source: :cli}
    end

    test "rejects blank input" do
      assert {:error, :empty_input} = CLI.parse_input("  ")
    end

    test "emits inbound channel telemetry" do
      handler_id = attach_channel_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, [_message]} = CLI.parse_input("hello", sender: "operator")

      assert_receive {:telemetry, [:fermix, :channel, :message], %{count: 1},
                      %{channel: :cli, direction: :inbound}}
    end
  end

  describe "dispatch_input/2" do
    test "dispatches normalized CLI messages through the configured agent" do
      assert :ok =
               CLI.dispatch_input("hello",
                 sender: "operator",
                 agent: TestAgent,
                 agent_server: self()
               )

      assert_receive {:handled_message, message}
      assert message.content == "hello"
      assert message.sender == "operator"
      assert message.channel == "cli"
      assert is_function(message.reply_fn, 1)
    end

    test "returns parse errors without dispatching" do
      assert {:error, :empty_input} =
               CLI.dispatch_input("  ",
                 agent: TestAgent,
                 agent_server: self()
               )

      refute_received {:handled_message, _message}
    end
  end

  describe "dispatch_input_sync/2" do
    test "reuses the CLI channel and captures one reply" do
      assert {:ok, %{response: "reply: hello", session_id: "scenario-1"}} =
               CLI.dispatch_input_sync("hello",
                 sender: "operator",
                 session_id: "scenario-1",
                 timeout_ms: 1_000,
                 agent: ReplyAgent,
                 agent_server: self()
               )

      assert_receive {:sync_agent_message, message}
      assert message.content == "hello"
      assert message.sender == "operator"
      assert message.channel == "cli"
      assert message.chat_id == "scenario-1"
      assert message.metadata == %{source: :cli}
    end

    test "returns parser and timeout errors" do
      assert {:error, :empty_input} =
               CLI.dispatch_input_sync("   ",
                 agent: ReplyAgent,
                 agent_server: self(),
                 timeout_ms: 1_000
               )

      assert {:error, :timeout} =
               CLI.dispatch_input_sync("hello",
                 agent: SilentAgent,
                 agent_server: self(),
                 timeout_ms: 10
               )
    end
  end

  describe "send_message/3" do
    test "prints the reply and emits outbound channel telemetry" do
      handler_id = attach_channel_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert capture_io(fn ->
               assert :ok = CLI.send_message("cli", "hello back")
             end) == "hello back\n"

      assert_receive {:telemetry, [:fermix, :channel, :message], %{count: 1},
                      %{channel: :cli, direction: :outbound}}
    end
  end

  describe "build_reply/1" do
    test "builds a reply function backed by CLI send_message/3" do
      message =
        Message.new!(%{
          id: "cli-1",
          content: "hello",
          sender: "operator",
          channel: "cli",
          chat_id: "cli",
          reply_target: "cli"
        })

      reply = CLI.build_reply(message)

      assert capture_io(fn ->
               assert :ok = reply.("hello back")
             end) == "hello back\n"
    end
  end

  describe "unsupported transports" do
    test "rejects webhook parsing and verification" do
      assert {:error, :unsupported_transport} = CLI.parse_webhook(%{})
      assert {:error, :unsupported_transport} = CLI.verify_webhook(:conn)
    end
  end

  defp attach_channel_telemetry(test_pid) do
    handler_id = "cli-channel-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :message],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end
end
