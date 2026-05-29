defmodule FermixChannels.Gateway.MessageTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Message

  describe "new!/1" do
    test "normalizes the shared inbound shape and defaults root thread scope" do
      message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "ada",
          channel: "telegram",
          chat_id: "-1001",
          reply_target: "-1001",
          metadata: %{raw: %{"message_id" => 42}},
          attachments: [%{type: :photo, file_id: "abc"}]
        })

      assert %Message{} = message
      assert message.thread_scope == :root
      assert message.metadata == %{raw: %{"message_id" => 42}}
      assert message.attachments == [%{type: :photo, file_id: "abc"}]
    end

    test "derives thread scope from thread_ts" do
      root_message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "ada",
          channel: "telegram",
          chat_id: "-1001",
          reply_target: "-1001",
          thread_ts: nil
        })

      thread_message =
        Message.new!(%{
          id: "43",
          content: "hello thread",
          sender: "ada",
          channel: "telegram",
          chat_id: "-1001",
          reply_target: "-1001",
          thread_ts: 99
        })

      assert root_message.thread_scope == :root
      assert thread_message.thread_scope == :thread
    end
  end
end
