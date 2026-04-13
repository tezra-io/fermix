defmodule FermixChannels.MessageTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Message

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
  end
end
