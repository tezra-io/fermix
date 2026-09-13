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
        %{persist?: "no"}
      ]

      for override <- malformed do
        msg = message(%{metadata: %{voice_call: voice_call(override)}})

        assert_raise ArgumentError, ~r/malformed voice_call/, fn ->
          VoiceCall.from_message(msg)
        end
      end
    end

    test "raises when a required key is missing from a trusted voice_call" do
      msg = message(%{metadata: %{voice_call: Map.delete(voice_call(), :turn_session_id)}})

      assert_raise ArgumentError, ~r/malformed voice_call/, fn ->
        VoiceCall.from_message(msg)
      end
    end

    test "accepts a pid conversation store (the ephemeral call-owned store)" do
      store = self()
      msg = message(%{metadata: %{voice_call: voice_call(%{conversation_store: store})}})

      assert {:ok, %{conversation_store: ^store}} = VoiceCall.from_message(msg)
    end
  end
end
