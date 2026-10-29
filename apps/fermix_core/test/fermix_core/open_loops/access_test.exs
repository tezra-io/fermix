defmodule FermixCore.OpenLoops.AccessTest do
  use ExUnit.Case, async: true

  alias FermixCore.OpenLoops.Access

  # An attended, top-level owner turn in a private chat. Every value is invented.
  @attended %{
    source_trust: :operator,
    computer_use_origin: :interactive,
    channel: "telegram",
    conversation_key: {"telegram", "40001", :root},
    chat_type: "private"
  }

  # The owner's paired phone, which sets no chat type: private by its channel.
  @phone Map.merge(Map.delete(@attended, :chat_type), %{
           channel: "mobile",
           conversation_key: {"mobile", "device_4d2a", :root}
         })

  # The owner's realtime voice call, whose tool context names no channel and no
  # chat type.
  @voice_call %{source_trust: :operator, computer_use_origin: :voice}

  describe "mutate?/1" do
    test "the owner's private turn may note and settle: a direct message, the phone, a call" do
      assert Access.mutate?(@attended)
      assert Access.mutate?(%{@attended | chat_type: "im"})
      assert Access.mutate?(@phone)
      assert Access.mutate?(@voice_call)
    end

    test "a shared room never records or settles a loop, whoever speaks in it" do
      for chat_type <- ~w(group supergroup channel guild mpim) do
        refute Access.mutate?(%{@attended | chat_type: chat_type}), chat_type
      end
    end

    # A Slack channel mention carries no chat type of its own: a chat with no
    # label is shared unless its channel is one of the owner's paired devices.
    test "an unlabelled chat is shared" do
      refute Access.mutate?(Map.delete(@attended, :chat_type))
    end

    test "a guest, a detached run and a check-in still may not" do
      refute Access.mutate?(%{@attended | source_trust: :guest})
      refute Access.mutate?(Map.delete(@attended, :computer_use_origin))
      refute Access.mutate?(Map.put(@attended, :open_loop_checkin, %{id: "loop_AbCdEfGhIjK"}))
    end
  end

  describe "read?/1" do
    test "the owner's private turn, and a check-in run, may read" do
      assert Access.read?(@attended)
      assert Access.read?(@phone)
      assert Access.read?(@voice_call)

      assert Access.read?(%{
               source_trust: :operator,
               open_loop_checkin: %{id: "loop_QwErTyUiOp1"}
             })
    end

    # MILESTONE_78 §08: a group chat never sees a loop, so listing is refused
    # there as noting and settling are.
    test "a shared room never sees a loop" do
      for chat_type <- ~w(group supergroup channel guild mpim) do
        refute Access.read?(%{@attended | chat_type: chat_type}), chat_type
      end

      refute Access.read?(Map.delete(@attended, :chat_type))
    end

    test "a guest and a detached run still may not" do
      refute Access.read?(%{@attended | source_trust: :guest})
      refute Access.read?(Map.delete(@attended, :computer_use_origin))
    end
  end

  test "the refusal names private chats" do
    assert Access.refusal("open_loop_note", :not_attended) =~ "in a private chat"
    assert Access.refusal("open_loop_note", :not_attended) =~ "group chats"
    assert Access.refusal("open_loop_list", :not_readable) =~ "in a private chat"
    assert Access.refusal("open_loop_list", :not_readable) =~ "group chats"
  end
end
