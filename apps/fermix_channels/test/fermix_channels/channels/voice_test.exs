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
  alias FermixChannels.Voice.Detached

  @call_uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"

  defp register(call_id, delegation_id, revision),
    do: register_route({call_id, delegation_id}, revision, :session)

  # A detached task's route, as `Voice.Detached` holds it once the session has
  # handed the task over (M56 §4.6).
  defp register_detached(delegation_id, revision),
    do: register_route(Detached.route(@call_uuid, delegation_id), revision, :detached)

  defp register_route(key, revision, owner) do
    test_pid = self()

    callbacks = %{
      progress: fn text -> send(test_pid, {:progress, text}) && :ok end,
      activity: fn event -> send(test_pid, {:activity, event}) && :ok end,
      history_tainted: fn -> send(test_pid, {owner, :history_tainted}) && :ok end,
      result: fn outcome -> send(test_pid, {owner, {:result, outcome}}) && :ok end
    }

    {:ok, _owner} =
      Registry.register(Voice.registry(), key, %{revision: revision, callbacks: callbacks})

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
        voice_call: %{call_uuid: @call_uuid, delegation_id: delegation_id, revision: revision}
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
      refute_receive {_owner, {:result, _outcome}}, 100
    end

    # M56 §9: the one thing the stream carries to the session, told by the
    # runner before the reply: the reply is drawn from Computer History.
    test "the raw stream callback tells the session a reply is drawn from Computer History" do
      id = call_id()
      :ok = register(id, "d-1", 1)
      callback = Voice.build_raw_stream_callback(message(id, "d-1", 1))

      assert callback.(:history_tainted) == :ok
      assert_receive {:session, :history_tainted}, 1_000

      superseded = call_id()
      :ok = register(superseded, "d-1", 2)
      stale = Voice.build_raw_stream_callback(message(superseded, "d-1", 1))

      assert stale.(:history_tainted) == {:error, :superseded_revision}
      refute_receive {:session, :history_tainted}, 100
    end
  end

  # The chat's timeline, as the companion channel writes it: reports each row
  # to the test by name.
  defmodule ChatStore do
    def append(profile, attrs, _opts) do
      send(:voice_media_test, {:chat_row, profile, attrs})

      {:ok,
       Map.merge(attrs, %{profile_id: profile, server_seq: 7, created_at: DateTime.utc_now()})}
    end
  end

  # A picture or file a delegation sends goes to the owner's chat, whichever
  # mode the call is in, under the same fence as its answer.
  describe "media" do
    setup do
      env = ~w(companion_store mobile_media_resolver mobile_event_sink)a
      previous = Map.new(env, &{&1, Application.fetch_env(:fermix_channels, &1)})
      Process.register(self(), :voice_media_test)

      dir = FermixTestSupport.SafeRm.make_tmp_dir!("voice-media")
      path = Path.join(dir, "dog.png")
      File.write!(path, "image")

      Application.put_env(:fermix_channels, :companion_store, ChatStore)
      Application.put_env(:fermix_channels, :mobile_event_sink, fn _profile, _event -> :ok end)

      Application.put_env(:fermix_channels, :mobile_media_resolver, fn media ->
        {:ok,
         %{
           "ref" => String.duplicate("b", 64),
           "kind" => Atom.to_string(media.kind),
           "mime" => media.mime_type,
           "size_bytes" => 5,
           "path" => media.path
         }}
      end)

      on_exit(fn ->
        FermixTestSupport.SafeRm.rm_rf!(dir)

        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:fermix_channels, key, value)
          {key, :error} -> Application.delete_env(:fermix_channels, key)
        end)
      end)

      {:ok, media: %{kind: :image, path: path, mime_type: "image/png", caption: "A dog"}}
    end

    test "a delegation's attachment is written to the owner's chat", %{media: media} do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_media_reply(message(id, "d-1", 1)).(media) == :ok

      assert_receive {:chat_row, "main",
                      %{role: "assistant", kind: "media", content: "A dog", media_refs: [_ref]}}
    end

    test "a task that outlived its call still sends its attachment to the chat", %{media: media} do
      id = call_id()
      :ok = register_detached("d-1", 1)

      assert Voice.build_media_reply(message(id, "d-1", 1)).(media) == :ok
      assert_receive {:chat_row, "main", %{kind: "media"}}
    end

    test "a superseded revision's or a closed call's attachment is dropped", %{media: media} do
      id = call_id()
      :ok = register(id, "d-1", 2)

      assert Voice.build_media_reply(message(id, "d-1", 1)).(media) ==
               {:error, :superseded_revision}

      assert Voice.build_media_reply(message(call_id(), "d-9", 1)).(media) ==
               {:error, :call_closed}

      refute_received {:chat_row, _profile, _attrs}
    end

    test "a send with no delegation fence is refused", %{media: media} do
      log =
        capture_log(fn ->
          assert Voice.send_media(call_id(), media) == {:error, :missing_delegation_fence}
        end)

      assert log =~ "no delegation fence"
      refute_received {:chat_row, _profile, _attrs}
    end
  end

  describe "fenced routing" do
    test "an answer reaches the delegation's result callback" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("the calendar is clear") == :ok
      assert_receive {:session, {:result, {:ok, "the calendar is clear"}}}, 1_000
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
      assert_receive {:session, {:result, {:cancelled}}}, 1_000
    end

    test "a failed turn reaches the session as Core's own sentence" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_turn_result(message(id, "d-1", 1)).({:failed, :context_length_exceeded}) ==
               :ok

      assert_receive {:session, {:result, {:error, message}}}, 1_000
      assert message =~ "context window"
    end

    test "a completed turn adds nothing: the delivered answer already reported it" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      assert Voice.build_turn_result(message(id, "d-1", 1)).({:completed}) == :ok
      refute_receive {_owner, {:result, _outcome}}, 100
    end

    test "an event for a superseded revision is dropped" do
      id = call_id()
      :ok = register(id, "d-1", 2)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("stale answer") ==
               {:error, :superseded_revision}

      refute_receive {_owner, {:result, _outcome}}, 100
    end

    test "an event for a call with no routing entry is dropped" do
      id = call_id()

      assert Voice.build_text_reply(message(id, "d-1", 1)).("orphan answer") ==
               {:error, :call_closed}

      refute_receive {_owner, {:result, _outcome}}, 100
    end

    # M56 §4.6: the session's route first, then the route of the task's
    # detached owner, so a reply never falls between the two.
    test "a reply with no session route reaches the task's detached owner" do
      id = call_id()
      :ok = register_detached("d-1", 1)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("the venue has parking") == :ok
      assert_receive {:detached, {:result, {:ok, "the venue has parking"}}}, 1_000

      assert Voice.build_turn_result(message(id, "d-1", 1)).({:cancelled}) == :ok
      assert_receive {:detached, {:result, {:cancelled}}}, 1_000
    end

    test "the session's route is read before the detached one" do
      id = call_id()
      :ok = register(id, "d-1", 1)
      :ok = register_detached("d-1", 1)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("said on the call") == :ok
      assert_receive {:session, {:result, {:ok, "said on the call"}}}, 1_000
      refute_receive {:detached, _event}, 100
    end

    test "the detached owner fences its task's revision as the session does" do
      id = call_id()
      :ok = register_detached("d-1", 2)

      assert Voice.build_text_reply(message(id, "d-1", 1)).("stale answer") ==
               {:error, :superseded_revision}

      refute_receive {_owner, {:result, _outcome}}, 100
    end

    test "a delivery with no fence is refused loudly" do
      id = call_id()
      :ok = register(id, "d-1", 1)

      log =
        capture_log(fn ->
          assert Voice.send_message(id, "unfenced") == {:error, :missing_delegation_fence}
        end)

      assert log =~ "no delegation fence"
      refute_receive {_owner, {:result, _outcome}}, 100
    end
  end
end
