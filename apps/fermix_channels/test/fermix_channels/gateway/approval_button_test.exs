defmodule FermixChannels.Gateway.ApprovalButtonTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.ApprovalButton
  alias FermixChannels.Gateway.Message

  describe "payload/1 and parse_payload/1 (grant: namespacing)" do
    test "payload namespaces the token" do
      assert ApprovalButton.payload("TOK12345") == "grant:TOK12345"
    end

    test "parse_payload strips the namespace back to the bare token" do
      assert {:ok, "TOK12345"} = ApprovalButton.parse_payload("grant:TOK12345")
    end

    test "payload round-trips through parse_payload" do
      assert {:ok, "AB12CD34"} = ApprovalButton.parse_payload(ApprovalButton.payload("AB12CD34"))
    end

    test "a bare (un-namespaced) token is ignored, not treated as a confirm" do
      assert :ignore = ApprovalButton.parse_payload("TOK12345")
    end

    test "an empty or non-binary payload is ignored" do
      assert :ignore = ApprovalButton.parse_payload("grant:")
      assert :ignore = ApprovalButton.parse_payload("")
      assert :ignore = ApprovalButton.parse_payload(nil)
    end
  end

  describe "approve and deny actions" do
    test "namespaces and parses both actions" do
      assert ApprovalButton.approve_payload("TOK12345") == "grant:TOK12345"
      assert ApprovalButton.deny_payload("TOK12345") == "deny:TOK12345"
      assert {:ok, :approve, "TOK12345"} = ApprovalButton.parse_action("grant:TOK12345")
      assert {:ok, :deny, "TOK12345"} = ApprovalButton.parse_action("deny:TOK12345")
    end

    test "rejects malformed and unrelated actions" do
      assert :ignore = ApprovalButton.parse_action("grant:")
      assert :ignore = ApprovalButton.parse_action("deny:")
      assert :ignore = ApprovalButton.parse_action("other:TOK12345")
      assert :ignore = ApprovalButton.parse_action(nil)
    end

    test "builds the exact synthesized /deny message" do
      message =
        ApprovalButton.action_message(%{
          id: "callback-9",
          sender: "alice",
          channel: "telegram",
          chat_id: "123",
          thread_ts: 9,
          user_id: 111,
          action: :deny,
          token: "TOK12345"
        })

      assert message.content == "/deny TOK12345"
      assert message.metadata == %{user_id: "111"}
    end
  end

  describe "confirm_message/1" do
    test "builds the exact synthesized /confirm message from the origin inputs" do
      message =
        ApprovalButton.confirm_message(%{
          id: "callback-9",
          sender: "alice",
          channel: "telegram",
          chat_id: "123",
          thread_ts: 9,
          user_id: 111,
          token: "TOK12345"
        })

      assert %Message{} = message
      assert message.id == "callback-9"
      assert message.content == "/confirm TOK12345"
      assert message.sender == "alice"
      assert message.channel == "telegram"
      assert message.chat_id == "123"
      assert message.reply_target == "123"
      assert message.thread_ts == 9
      assert message.metadata == %{user_id: "111"}
    end

    test "both adapters produce an identical message for the same origin inputs" do
      inputs = %{
        id: "tap-1",
        sender: "alice",
        channel: "discord",
        chat_id: "dm-1",
        thread_ts: nil,
        user_id: "111",
        token: "TOK12345"
      }

      assert ApprovalButton.confirm_message(inputs) == ApprovalButton.confirm_message(inputs)
    end
  end
end
