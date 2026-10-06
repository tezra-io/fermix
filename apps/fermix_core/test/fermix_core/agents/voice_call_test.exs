defmodule FermixCore.Agents.VoiceCallTest do
  @moduledoc """
  The trust gate every voice seam reads (M41 §7). `voice_call` carries
  persistence, correlation and cancellation context that only trusted code may
  construct, so a map arriving on any other channel — or on a turn that is not
  the operator's — is not a voice call at all.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Agents.VoiceCall

  defp voice_call(overrides \\ %{}) do
    Map.merge(
      %{
        call_id: "voice_live_1",
        call_uuid: "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab",
        conversation: "chat",
        conversation_key: {"companion", "main", :root},
        delegation_id: "d-1",
        revision: 1,
        turn_session_id: "voice_delegation_1",
        conversation_store: FermixCore.Memory.ConversationStore,
        prompt_addendum: "backend addendum",
        persist?: false
      },
      overrides
    )
  end

  defp message(overrides \\ %{}) do
    Map.merge(
      %{
        channel: "voice",
        chat_id: "voice_live_1",
        content: "what is on my calendar",
        sender: "voice",
        source_trust: :operator,
        metadata: %{source: :voice, user_id: "voice", voice_call: voice_call()}
      },
      overrides
    )
  end

  describe "from_message/1" do
    test "returns the voice_call on a trusted operator turn from the voice channel" do
      assert {:ok, call} = VoiceCall.from_message(message())
      assert call.call_id == "voice_live_1"
      assert call.turn_session_id == "voice_delegation_1"
      assert call.persist? == false
      assert call.call_uuid == "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
      assert call.conversation_key == {"companion", "main", :root}
      assert call.conversation == "chat"
    end

    test "returns :none for a voice_call map on a non-operator message" do
      for trust <- [:guest, nil, :unattended] do
        assert VoiceCall.from_message(message(%{source_trust: trust})) == :none
      end
    end

    test "returns :none for a voice_call map on a non-voice channel" do
      # The forgery that matters: a remote chat message carrying a crafted
      # `voice_call` must never redirect history, correlation, or the prompt.
      for channel <- ["telegram", "cli", "acp", "background"] do
        assert VoiceCall.from_message(message(%{channel: channel})) == :none
      end
    end

    test "returns :none for an ordinary message with no voice_call metadata" do
      assert VoiceCall.from_message(%{channel: "telegram", metadata: %{}}) == :none
      assert VoiceCall.from_message(%{channel: "voice", source_trust: :operator}) == :none
      assert VoiceCall.from_message(%{}) == :none
    end

    test "raises on a malformed voice_call that cleared the trust gate" do
      malformed = [
        %{call_id: ""},
        %{delegation_id: ""},
        %{revision: 0},
        %{revision: "1"},
        %{turn_session_id: ""},
        %{conversation_store: nil},
        %{prompt_addendum: ""},
        %{persist?: "no"},
        %{call_uuid: ""},
        %{conversation_key: nil},
        %{conversation_key: {"companion", "", :root}},
        %{conversation_key: {"companion", "main", :thread}},
        %{conversation_key: "companion:main"},
        %{conversation: "shared"},
        %{conversation: nil}
      ]

      for override <- malformed do
        msg = message(%{metadata: %{voice_call: voice_call(override)}})

        assert_raise ArgumentError, ~r/malformed voice_call/, fn ->
          VoiceCall.from_message(msg)
        end
      end
    end

    test "raises when a required key is missing from a trusted voice_call" do
      for key <- [:turn_session_id, :call_uuid, :conversation_key, :conversation] do
        msg = message(%{metadata: %{voice_call: Map.delete(voice_call(), key)}})

        assert_raise ArgumentError, ~r/malformed voice_call/, fn ->
          VoiceCall.from_message(msg)
        end
      end
    end

    test "accepts a pid conversation store (the ephemeral call-owned store)" do
      store = self()
      msg = message(%{metadata: %{voice_call: voice_call(%{conversation_store: store})}})

      assert {:ok, %{conversation_store: ^store}} = VoiceCall.from_message(msg)
    end
  end

  # M56 §4.7: one list per mode, read by both surfaces (`LivePrompt` and
  # `TurnRunner`). A call in the chat may launch a coding run, whose outcome
  # re-enters the chat it was launched from; a private call's conversation
  # ends with the call, so it never may.
  describe "excluded_categories/1" do
    test "a call in the chat excludes channel sends, media and fan-out, not coding runs" do
      assert VoiceCall.excluded_categories("chat") == [:channel, :media, :delegation]
    end

    test "a private call excludes coding runs too" do
      assert VoiceCall.excluded_categories("private") == [
               :channel,
               :media,
               :delegation,
               :harness
             ]
    end

    test "no other mode has a list" do
      assert_raise FunctionClauseError, fn -> VoiceCall.excluded_categories("shared") end
    end
  end
end
