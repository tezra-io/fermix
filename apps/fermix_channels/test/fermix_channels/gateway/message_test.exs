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

  describe "actionable?/1" do
    test "non-blank text is actionable" do
      assert Message.actionable?(message(content: "hello", media_parts: []))
    end

    test "blank or whitespace-only text with no media is NOT actionable" do
      refute Message.actionable?(message(content: "", media_parts: []))
      refute Message.actionable?(message(content: "   \n  ", media_parts: []))
    end

    test "blank text WITH media (captionless image) IS actionable" do
      assert Message.actionable?(
               message(content: "", media_parts: [%{type: :image, data: "PNG"}])
             )
    end
  end

  defp message(fields) do
    Message.new!(
      Enum.into(fields, %{
        id: "i",
        content: "",
        sender: "u",
        channel: "telegram",
        chat_id: "c",
        reply_target: "c"
      })
    )
  end
end
