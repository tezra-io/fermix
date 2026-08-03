defmodule FermixChannels.Gateway.ProposalButtonTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.ProposalButton

  test "payloads namespace the token with the action verb" do
    assert ProposalButton.approve_payload("TOK12345") == "skillcur:a:TOK12345"
    assert ProposalButton.deny_payload("TOK12345") == "skillcur:d:TOK12345"
  end

  test "parse_payload round-trips both verbs" do
    assert {:ok, :approve, "TOK12345"} = ProposalButton.parse_payload("skillcur:a:TOK12345")
    assert {:ok, :deny, "TOK12345"} = ProposalButton.parse_payload("skillcur:d:TOK12345")
  end

  test "foreign payloads are ignored, never treated as proposal taps" do
    assert :ignore = ProposalButton.parse_payload("TOK12345")
    assert :ignore = ProposalButton.parse_payload("grant:TOK12345")
    assert :ignore = ProposalButton.parse_payload("skillcur:x:TOK12345")
    assert :ignore = ProposalButton.parse_payload("skillcur:a:")
    assert :ignore = ProposalButton.parse_payload(nil)
  end

  test "action_message synthesizes the typed /skills command with origin fields" do
    message =
      ProposalButton.action_message(%{
        id: "callback-1",
        sender: "sujeeth",
        channel: "telegram",
        chat_id: "42",
        thread_ts: 9,
        user_id: 111,
        action: :approve,
        token: "TOK12345"
      })

    assert message.content == "/skills approve TOK12345"
    assert message.channel == "telegram"
    assert message.chat_id == "42"
    assert message.reply_target == "42"
    assert message.thread_ts == 9
    assert message.metadata == %{user_id: "111"}
  end

  test "a deny tap types the deny command" do
    message =
      ProposalButton.action_message(%{
        id: "callback-2",
        sender: "sujeeth",
        channel: "discord",
        chat_id: "chan-1",
        thread_ts: nil,
        user_id: "222",
        action: :deny,
        token: "TOK12345"
      })

    assert message.content == "/skills deny TOK12345"
  end
end
