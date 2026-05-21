defmodule FermixChannels.DispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Dispatcher
  alias FermixChannels.Message
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope
  alias FermixCore.Resource.Registry

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule ReplyChannel do
    def build_text_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
      send_opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

      fn text -> send_message(reply_target, text, send_opts) end
    end

    def build_media_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
      send_opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

      fn media_part ->
        send(self(), {:media_sent, reply_target, media_part, send_opts})
        :ok
      end
    end

    def send_message(reply_target, text, opts) do
      send(self(), {:reply_sent, reply_target, text, opts})

      case text do
        "fail" -> {:error, :telegram_down}
        _text -> :ok
      end
    end
  end

  defmodule BuildReplyChannel do
    def build_text_reply(%Message{id: id, reply_target: reply_target}) do
      test_pid = self()

      fn text ->
        send(test_pid, {:reply_built_and_sent, id, reply_target, text})
        :ok
      end
    end

    def build_media_reply(%Message{}) do
      fn _media_part -> {:error, :media_unsupported} end
    end
  end

  defmodule TypingChannel do
    def build_text_reply(%Message{reply_target: reply_target}) do
      fn text ->
        send(self(), {:reply_sent, reply_target, text, []})
        :ok
      end
    end

    def build_media_reply(%Message{}) do
      fn _media_part -> {:error, :media_unsupported} end
    end

    def start_typing(reply_target) do
      send(self(), {:typing_started, reply_target})
      :ok
    end
  end

  defmodule AudioChannel do
    def build_text_reply(%Message{reply_target: reply_target}) do
      fn text -> send_message(reply_target, text, []) end
    end

    def build_media_reply(%Message{}) do
      fn _media_part -> {:error, :media_unsupported} end
    end

    def send_message(reply_target, text, opts) do
      send(self(), {:reply_sent, reply_target, text, opts})
      :ok
    end

    def download_attachment(_message, attachment) do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-dispatcher-audio-#{attachment.file_id}-#{System.unique_integer([:positive])}.ogg"
        )

      File.write!(path, "audio-bytes:#{attachment.file_id}")
      {:ok, path}
    end
  end

  defmodule FakeTranscriptionBackend do
    def transcribe(path, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:dispatcher_transcription, path, File.read!(path), Keyword.fetch!(opts, :metadata)}
      )

      {:ok, "voice note text"}
    end
  end

  # The dispatcher now resolves source trust through
  # `FermixChannels.Ingress.Authorizer` before delivering to the agent, so
  # tests that exercise the agent-delivery path need a configured owner for
  # whichever remote channel they pretend to come from. The CLI channel
  # path stays auto-authorized as `:local`.
  setup do
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
    previous_whatsapp = Application.get_env(:fermix_channels, :whatsapp, [])
    Application.put_env(:fermix_channels, :telegram, owner_user_id: "test-sender")
    Application.put_env(:fermix_channels, :whatsapp, owner_user_id: "test-sender")

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, previous_telegram)
      Application.put_env(:fermix_channels, :whatsapp, previous_whatsapp)
    end)

    :ok
  end

  test "routes normalized inbound messages into the configured agent with reply runtime" do
    test_pid = self()
    handler_id = "test-dispatcher-stage-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:fermix, :dispatcher, :normalize],
        [:fermix, :ingress, :authorize],
        [:fermix, :dispatcher, :agent_delivery],
        [:fermix, :channel, :reply]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    message = %Message{
      id: "42",
      content: "hello",
      sender: "alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      thread_ts: 77,
      metadata: %{update_id: 100, user_id: "test-sender"},
      attachments: [%{type: :photo, id: "file-1"}]
    }

    assert :ok =
             Dispatcher.dispatch([message],
               channel: ReplyChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}
    refute Map.has_key?(agent_message, :__struct__)
    assert agent_message.content == "hello"
    assert agent_message.sender == "alice"
    assert agent_message.channel == "telegram"
    assert agent_message.chat_id == "123"
    assert agent_message.thread_ts == 77
    assert agent_message.metadata == %{update_id: 100, user_id: "test-sender"}
    assert agent_message.attachments == [%{type: :photo, id: "file-1"}]

    assert :ok = agent_message.reply_fn.({:text, "reply"})
    assert_received {:reply_sent, "123", "reply", reply_opts}
    assert reply_opts[:message_thread_id] == 77

    assert_receive {:telemetry, [:fermix, :dispatcher, :normalize], normalize_measurements,
                    normalize_metadata}

    assert normalize_measurements.duration_us >= 0
    assert normalize_metadata.channel == "telegram"
    assert normalize_metadata.status == :ok

    assert_receive {:telemetry, [:fermix, :ingress, :authorize], authorize_measurements,
                    authorize_metadata}

    assert authorize_measurements.duration_us >= 0
    assert authorize_metadata.channel == "telegram"
    assert authorize_metadata.status == :ok
    assert authorize_metadata.trust == :operator

    assert_receive {:telemetry, [:fermix, :dispatcher, :agent_delivery], delivery_measurements,
                    delivery_metadata}

    assert delivery_measurements.duration_us >= 0
    assert delivery_metadata.channel == "telegram"
    assert delivery_metadata.status == :ok

    assert_receive {:telemetry, [:fermix, :channel, :reply], reply_measurements, reply_metadata}
    assert reply_measurements.duration_us >= 0
    assert reply_metadata.channel == "telegram"
    assert reply_metadata.reply_type == :text
    assert reply_metadata.status == :ok

    media_part = %{kind: :document, path: "/tmp/report.txt", filename: "report.txt"}
    assert :ok = agent_message.reply_fn.({:media, media_part})
    assert_received {:media_sent, "123", ^media_part, media_opts}
    assert media_opts[:message_thread_id] == 77

    log =
      capture_log(fn ->
        assert {:error, :telegram_down} = agent_message.reply_fn.({:text, "fail"})
      end)

    assert log =~ "Channel reply delivery failed"
  end

  test "uses the channel-owned reply builder for outbound replies" do
    message =
      Message.new!(%{
        id: "message-1",
        content: "hello",
        sender: "alice",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1",
        metadata: %{user_id: "test-sender"}
      })

    assert :ok =
             Dispatcher.dispatch([message],
               channel: BuildReplyChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}
    assert :ok = agent_message.reply_fn.({:text, "reply"})
    assert_received {:reply_built_and_sent, "message-1", "chat-1", "reply"}
  end

  test "rejects invalid reply tuples before channel delivery" do
    message =
      Message.new!(%{
        id: "message-invalid-reply",
        content: "hello",
        sender: "alice",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1",
        metadata: %{user_id: "test-sender"}
      })

    assert :ok =
             Dispatcher.dispatch([message],
               channel: ReplyChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}

    assert {:error, {:invalid_reply_part, {:invalid, "tuple"}}} =
             agent_message.reply_fn.({:invalid, "tuple"})

    refute_received {:reply_sent, _, _, _}
    refute_received {:media_sent, _, _, _}
  end

  test "uses explicit reply_fn override when provided" do
    message =
      Message.new!(%{
        id: "message-override",
        content: "hello",
        sender: "operator",
        channel: "cli",
        chat_id: "cli",
        reply_target: "cli"
      })

    test_pid = self()

    assert :ok =
             Dispatcher.dispatch([message],
               channel: ReplyChannel,
               agent: CapturingAgent,
               agent_server: test_pid,
               reply_fn: fn part ->
                 send(test_pid, {:captured_reply, part})
                 :ok
               end
             )

    assert_receive {:agent_message, agent_message}
    assert agent_message.content == "hello"
    assert is_function(agent_message.reply_fn, 1)

    assert :ok = agent_message.reply_fn.({:text, "reply"})
    assert_receive {:captured_reply, {:text, "reply"}}
  end

  test "intercepts built-in commands before agent delivery" do
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
    Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, previous_telegram)
    end)

    store = :"dispatcher_command_store_#{System.unique_integer([:positive])}"
    start_supervised!({ConversationStore, name: store, repo: nil})
    key = {"telegram", "chat-1", :root}
    ConversationStore.add_message(key, "user", "old message", server: store)

    message =
      Message.new!(%{
        id: "message-command",
        content: "/new",
        sender: "alice",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1",
        metadata: %{user_id: "owner-1"}
      })

    assert :ok =
             Dispatcher.dispatch([message],
               channel: ReplyChannel,
               agent: CapturingAgent,
               agent_server: self(),
               conversation_store: store
             )

    assert_receive {:reply_sent, "chat-1",
                    "Started a fresh session. Long-term memory is preserved.", []}

    refute_receive {:agent_message, _message}, 100
    assert ConversationStore.get_history(key, server: store) == []
  end

  test "threads memory context into manual compact commands" do
    Req.Test.set_req_test_to_shared()
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
    Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-dispatcher-compact-#{unique}.db")
    repo = :"dispatcher_compact_repo_#{unique}"
    store = :"dispatcher_compact_store_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({ConversationStore, name: store, repo: nil})

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, previous_telegram)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, summary_response_body("manual dispatcher summary"))
    end)

    chat_id = "compact-chat-#{unique}"
    key = {"telegram", chat_id, :root}

    ConversationStore.add_message(key, "user", String.duplicate("old user ", 25_000),
      server: store
    )

    ConversationStore.add_message(key, "assistant", "old assistant", server: store)

    message =
      Message.new!(%{
        id: "message-compact",
        content: "/compact",
        sender: "alice",
        channel: "telegram",
        chat_id: chat_id,
        reply_target: chat_id,
        metadata: %{user_id: "owner-1"}
      })

    assert :ok =
             Dispatcher.dispatch([message],
               channel: ReplyChannel,
               agent: CapturingAgent,
               agent_server: self(),
               conversation_store: store,
               route: route(),
               context_window: 100_000,
               memory_repo: repo,
               memory_agent_id: "main",
               memory_owner_id: "default"
             )

    assert_receive {:reply_sent, ^chat_id, "Compacted: " <> _rest, []}

    scope_id = Scope.conversation_scope_id("telegram", chat_id, :root)
    assert {:ok, [revision]} = Registry.list_revisions("main", "checkpoint", scope_id, repo: repo)
    assert revision.content == "manual dispatcher summary"
    assert revision.mutation_source == "compaction"
  end

  test "adds channel typing runtime when the channel supports typing indicators" do
    message =
      Message.new!(%{
        id: "message-1",
        content: "hello",
        sender: "alice",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1",
        metadata: %{user_id: "test-sender"}
      })

    assert :ok =
             Dispatcher.dispatch([message],
               channel: TypingChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}
    assert is_function(agent_message.typing_fn, 0)
    assert :ok = agent_message.typing_fn.()
    assert_received {:typing_started, "chat-1"}
  end

  test "transcribes audio attachments before delivering them to the agent" do
    message = %Message{
      id: "voice-1",
      content: "",
      sender: "alice",
      channel: "whatsapp",
      chat_id: "123",
      reply_target: "123",
      metadata: %{message_type: "audio", user_id: "test-sender"},
      attachments: [%{kind: :audio, file_id: "audio-1", mime_type: "audio/ogg"}]
    }

    assert :ok =
             Dispatcher.dispatch([message],
               channel: AudioChannel,
               agent: CapturingAgent,
               agent_server: self(),
               transcription: [backend: FakeTranscriptionBackend, test_pid: self()]
             )

    assert_receive {:dispatcher_transcription, path, "audio-bytes:audio-1", metadata}
    assert metadata[:attachment][:file_id] == "audio-1"
    refute File.exists?(path)

    assert_receive {:agent_message, agent_message}
    assert agent_message.content == "voice note text"
    assert agent_message.metadata.transcription.backend == FakeTranscriptionBackend
  end

  describe "ingress trust resolution" do
    test "owner remote message gets :source_trust :operator on the agent message" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous_telegram) end)

      message =
        Message.new!(%{
          id: "trust-owner",
          content: "hello",
          sender: "alice",
          channel: "telegram",
          chat_id: "chat-1",
          reply_target: "chat-1",
          metadata: %{user_id: "owner-1"}
        })

      assert :ok =
               Dispatcher.dispatch([message],
                 channel: ReplyChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}
      assert agent_message.source_trust == :operator
    end

    test "allowed non-owner gets :source_trust :guest (read-only)" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])

      Application.put_env(:fermix_channels, :telegram,
        owner_user_id: "owner-1",
        allowed_user_ids: ["owner-1", "helper-1"]
      )

      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous_telegram) end)

      message =
        Message.new!(%{
          id: "trust-helper",
          content: "hello",
          sender: "helper",
          channel: "telegram",
          chat_id: "chat-1",
          reply_target: "chat-1",
          metadata: %{user_id: "helper-1"}
        })

      assert :ok =
               Dispatcher.dispatch([message],
                 channel: ReplyChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}
      assert agent_message.source_trust == :guest
    end

    test "unauthorized sender is dropped without reaching the agent" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous_telegram) end)

      message =
        Message.new!(%{
          id: "trust-stranger",
          content: "hello",
          sender: "stranger",
          channel: "telegram",
          chat_id: "chat-1",
          reply_target: "chat-1",
          metadata: %{user_id: "stranger"}
        })

      log =
        capture_log(fn ->
          assert :ok =
                   Dispatcher.dispatch([message],
                     channel: ReplyChannel,
                     agent: CapturingAgent,
                     agent_server: self()
                   )
        end)

      refute_receive {:agent_message, _agent_message}, 100
      assert log =~ "Dispatcher ingress denied"
    end

    test "transcription is skipped when the sender is denied" do
      previous_whatsapp = Application.get_env(:fermix_channels, :whatsapp, [])
      Application.put_env(:fermix_channels, :whatsapp, owner_user_id: "owner-1")
      on_exit(fn -> Application.put_env(:fermix_channels, :whatsapp, previous_whatsapp) end)

      message = %Message{
        id: "deny-audio",
        content: "",
        sender: "stranger",
        channel: "whatsapp",
        chat_id: "123",
        reply_target: "123",
        metadata: %{message_type: "audio", user_id: "stranger"},
        attachments: [%{kind: :audio, file_id: "audio-deny", mime_type: "audio/ogg"}]
      }

      log =
        capture_log(fn ->
          assert :ok =
                   Dispatcher.dispatch([message],
                     channel: AudioChannel,
                     agent: CapturingAgent,
                     agent_server: self(),
                     transcription: [backend: FakeTranscriptionBackend, test_pid: self()]
                   )
        end)

      refute_received {:dispatcher_transcription, _path, _content, _metadata}
      refute_receive {:agent_message, _agent_message}, 100
      assert log =~ "Dispatcher ingress denied"
    end

    test "surfaces a restart reply when the agent server name is not registered" do
      message =
        Message.new!(%{
          id: "restart-1",
          content: "hello",
          sender: "operator",
          channel: "cli",
          chat_id: "cli",
          reply_target: "cli"
        })

      test_pid = self()

      reply_fn = fn
        {:text, text} ->
          send(test_pid, {:restart_reply, text})
          :ok

        _other ->
          :ok
      end

      log =
        capture_log(fn ->
          assert :ok =
                   Dispatcher.dispatch([message],
                     channel: ReplyChannel,
                     agent: CapturingAgent,
                     agent_server: :nonexistent_agent_server_no_pid,
                     reply_fn: reply_fn
                   )
        end)

      assert_receive {:restart_reply, "I'm restarting" <> _rest}
      refute_received {:agent_message, _agent_message}
      assert log =~ "agent server"
      assert log =~ "unavailable"
    end

    test "surfaces a restart reply when the agent server pid is dead" do
      message =
        Message.new!(%{
          id: "restart-2",
          content: "hello",
          sender: "operator",
          channel: "cli",
          chat_id: "cli",
          reply_target: "cli"
        })

      dead_pid =
        spawn(fn -> :ok end)

      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}, 1_000
      refute Process.alive?(dead_pid)

      test_pid = self()

      reply_fn = fn
        {:text, text} ->
          send(test_pid, {:restart_reply, text})
          :ok

        _other ->
          :ok
      end

      capture_log(fn ->
        assert :ok =
                 Dispatcher.dispatch([message],
                   channel: ReplyChannel,
                   agent: CapturingAgent,
                   agent_server: dead_pid,
                   reply_fn: reply_fn
                 )
      end)

      assert_receive {:restart_reply, "I'm restarting" <> _rest}
    end

    test "cli channel auto-authorizes as :operator" do
      message =
        Message.new!(%{
          id: "trust-cli",
          content: "hello",
          sender: "operator",
          channel: "cli",
          chat_id: "cli",
          reply_target: "cli"
        })

      assert :ok =
               Dispatcher.dispatch([message],
                 channel: ReplyChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}
      assert agent_message.source_trust == :operator
    end
  end

  test "accepts normalized plain maps without crashing the agent delivery path" do
    message = %{
      "id" => "message-1",
      "content" => "hello from map",
      "sender" => "alice",
      "channel" => "cli",
      "chat_id" => "chat-1",
      "reply_target" => "chat-1",
      "metadata" => %{"source" => "map"},
      "attachments" => []
    }

    assert :ok =
             Dispatcher.dispatch([message],
               channel: AudioChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}
    assert agent_message.content == "hello from map"
    assert agent_message.metadata == %{"source" => "map"}
  end

  defp route do
    route_key = %{
      provider: :openai,
      model: "gpt-5.4-mini",
      auth_mode: :api_key,
      base_url: "https://api.openai.com/v1"
    }

    adapter_opts = [
      api_key: "sk-test",
      model: route_key.model,
      base_url: route_key.base_url,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    {route_key, adapter_opts}
  end

  defp summary_response_body(summary) do
    %{
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_summary",
          "content" => [%{"type" => "output_text", "text" => summary}]
        }
      ],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
    }
  end
end
