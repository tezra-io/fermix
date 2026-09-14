defmodule FermixChannels.Channels.VoiceTest do
  @moduledoc """
  The voice channel adapter's own surface
  (MILESTONE_41_OPENAI_LIVE_VOICE.md §7): what it refuses, what tier it takes,
  and how it fences a delegation's events.

  Registry entries are written here directly (the bridge's job in production) so
  the routing rules are provable without a queue or a turn.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway.Message

  defp register(call_id, delegation_id, revision) do
    test_pid = self()

    callbacks = %{
      progress: fn text -> send(test_pid, {:progress, text}) && :ok end,
      activity: fn event -> send(test_pid, {:activity, event}) && :ok end,
      result: fn outcome -> send(test_pid, {:result, outcome}) && :ok end
    }

    {:ok, _owner} =
      Registry.register(Voice.registry(), {call_id, delegation_id}, %{
        revision: revision,
        callbacks: callbacks
      })

    # The test process owns the entry, so ERTS releases it when the test ends —
    # the same lifetime a Live session's entries have.
    :ok
  end

  defp message(call_id, delegation_id, revision) do
    Message.new!(%{
      id: "voice-delegation-#{delegation_id}-#{revision}",
      content: "user: what is on my calendar",
      sender: "voice",
      channel: "voice",
      chat_id: call_id,
      reply_target: call_id,
      metadata: %{
        source: :voice,
        user_id: "voice",
        voice_call: %{delegation_id: delegation_id, revision: revision}
      }
    })
  end

  defp call_id, do: "voice_live_#{System.unique_integer([:positive])}"

  describe "transport surface" do
    test "there is no webhook transport" do
      assert Voice.parse_webhook(%{}) == {:error, :unsupported_transport}
      assert Voice.verify_webhook(%Plug.Conn{}) == {:error, :unsupported_transport}
    end

    test "the channel string and registry are stable" do
      assert Voice.channel() == "voice"
      assert Voice.registry() == FermixChannels.Voice.Registry
    end

    test "the stream tier is :raw and the terminal error owner is the turn result" do
      assert Voice.stream_capability() == :raw
      assert Voice.terminal_error_capability() == :turn_result
    end

    test "the raw stream callback delivers nothing to the session" do
      id = call_id()
      :ok = register(id, "d-1", 1)
      callback = Voice.build_raw_stream_callback(message(id, "d-1", 1))

      assert callback.({:text_delta, "half a sen"}) == :ok
      assert callback.({:reasoning_delta, "thinking"}) == :ok

      refute_receive {:progress, _text}, 100
      refute_receive {:result, _outcome}, 100
    end
  end

  describe "media" do
    test "an attachment is refused rather than dropped" do
      id = call_id()

      log =
        capture_log(fn ->
          assert Voice.send_media(id, %{kind: :image, data: "bytes"}) ==
                   {:error, :unsupported_in_voice}
        end)

      assert log =~ "the Live wire carries no media"
    end

    test "the media reply closure refuses the same way" do
      id = call_id()
      reply = Voice.build_media_reply(message(id, "d-1", 1))

      capture_log(fn ->
        assert reply.(%{kind: :image, data: "bytes"}) == {:error, :unsupported_in_voice}
      end)
    end
  end

  describe "fenced routing" do
    test "an answer reaches the delegation's result callback" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("the calendar is clear") == :ok
      assert_receive {:result, {:ok, "the calendar is clear"}}, 1_000
    end

    test "activity reaches the delegation's activity callback" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_activity_callback(message(id, "d-1", 1)).({:tool_start, "list_events"}) ==
               :ok

      assert_receive {:activity, {:tool_start, "list_events"}}, 1_000
    end

    test "a cancelled turn reaches the session as {:cancelled}" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_turn_result(message(id, "d-1", 1)).({:cancelled}) == :ok
      assert_receive {:result, {:cancelled}}, 1_000
    end

    test "a failed turn reaches the session as Core's own sentence" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_turn_result(message(id, "d-1", 1)).({:failed, :context_length_exceeded}) ==
               :ok

      assert_receive {:result, {:error, message}}, 1_000
      assert message =~ "context window"
    end

    test "a completed turn adds nothing: the delivered answer already reported it" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_turn_result(message(id, "d-1", 1)).({:completed}) == :ok
      refute_receive {:result, _outcome}, 100
    end

    test "an event for a superseded revision is dropped" do
      id = call_id()
      :ok = register(id, "d-1", 2)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("stale answer") ==
               {:error, :superseded_revision}

      refute_receive {:result, _outcome}, 100
    end

    test "an event for a call with no routing entry is dropped" do
      id = call_id()

      assert Voice.build_text_reply(message(id, "d-1", 1)).("orphan answer") ==
               {:error, :call_closed}

      refute_receive {:result, _outcome}, 100
    end

    test "a delivery with no fence is refused loudly" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      log =
        capture_log(fn ->
          assert Voice.send_message(id, "unfenced") == {:error, :missing_delegation_fence}
        end)

      assert log =~ "no delegation fence"
      refute_receive {:result, _outcome}, 100
    end
  end
end
