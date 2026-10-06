defmodule FermixCore.Agents.ConversationKeyTest do
  @moduledoc """
  Conversation identity, and the one override it takes, with its two users
  (M56 §4.1, D9): a trusted Live hand-off runs in the conversation its
  `voice_call` names, and a message whose channel joins another transport's
  conversation runs in the one the gateway named on it, so the queue lane,
  the history read, the commit and context tracking, which all derive the key
  here, agree without each caller knowing about voice or the phone.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Agents.ConversationKey

  @chat_key {"companion", "main", :root}

  defp hand_off(overrides \\ %{}) do
    Map.merge(
      %{
        channel: "voice",
        chat_id: "voice_live_1",
        source_trust: :operator,
        metadata: %{
          voice_call: %{
            call_id: "voice_live_1",
            call_uuid: "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab",
            conversation: "chat",
            conversation_key: @chat_key,
            delegation_id: "d-1",
            revision: 1,
            turn_session_id: "voice_delegation_1",
            conversation_store: FermixCore.Memory.ConversationStore,
            prompt_addendum: "backend addendum",
            persist?: false
          }
        }
      },
      overrides
    )
  end

  test "a trusted hand-off runs in the conversation its voice_call names" do
    assert ConversationKey.from(hand_off()) == @chat_key
  end

  # The bridge names its task's key itself for this reason: before ingest a
  # message has no trust level, so nothing in it is believed yet.
  test "the same message before ingest keeps its own channel key" do
    assert ConversationKey.from(hand_off(%{source_trust: nil})) ==
             {"voice", "voice_live_1", :root}
  end

  test "a voice_call map on any other channel or trust moves nothing" do
    assert ConversationKey.from(hand_off(%{channel: "telegram"})) ==
             {"telegram", "voice_live_1", :root}

    assert ConversationKey.from(hand_off(%{source_trust: :guest})) ==
             {"voice", "voice_live_1", :root}
  end

  # M56 D9: the gateway names the chat's conversation on every phone message,
  # so the phone's turns and the Mac's share one history.
  test "a message that names its conversation runs in it, whatever its channel" do
    phone = %{channel: "mobile", chat_id: "main", conversation_key: @chat_key}

    assert ConversationKey.from(phone) == @chat_key
  end

  # Only the gateway puts it there, so it is believed from ingest on: the
  # command path, which derives the key before the message has a trust level,
  # keys the conversation the turn runs in.
  test "a named conversation is believed before the message has a trust level" do
    phone = %{channel: "mobile", chat_id: "main", conversation_key: @chat_key}

    assert ConversationKey.from(Map.put(phone, :source_trust, nil)) == @chat_key
    assert ConversationKey.from(Map.put(phone, :source_trust, :operator)) == @chat_key
  end

  test "a message that names no conversation keys on its own" do
    assert ConversationKey.from(%{channel: "mobile", chat_id: "main", conversation_key: nil}) ==
             {"mobile", "main", :root}
  end

  test "a malformed named conversation is a defect in the code that named it, and raises" do
    for malformed <- [{"companion", "", :root}, {"companion", "main"}, "companion:main"] do
      assert_raise ArgumentError, ~r/malformed conversation_key/, fn ->
        ConversationKey.from(%{channel: "mobile", chat_id: "main", conversation_key: malformed})
      end
    end
  end

  test "an ordinary message keys on its channel, chat and thread" do
    assert ConversationKey.from(%{channel: "slack", chat_id: "C1", thread_ts: "171.2"}) ==
             {"slack", "C1", "171.2"}

    assert ConversationKey.from(%{channel: "companion", chat_id: "main"}) == @chat_key
  end
end
