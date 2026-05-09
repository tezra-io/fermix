defmodule FermixChannels.DispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Dispatcher
  alias FermixChannels.Message

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule ReplyChannel do
    def build_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
      send_opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

      fn text -> send_message(reply_target, text, send_opts) end
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
    def build_reply(%Message{id: id, reply_target: reply_target}) do
      test_pid = self()

      fn text ->
        send(test_pid, {:reply_built_and_sent, id, reply_target, text})
        :ok
      end
    end
  end

  defmodule TypingChannel do
    def build_reply(%Message{reply_target: reply_target}) do
      fn text ->
        send(self(), {:reply_sent, reply_target, text, []})
        :ok
      end
    end

    def start_typing(reply_target) do
      send(self(), {:typing_started, reply_target})
      :ok
    end
  end

  defmodule AudioChannel do
    def build_reply(%Message{reply_target: reply_target}) do
      fn text -> send_message(reply_target, text, []) end
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

  test "routes normalized inbound messages into the configured agent with reply runtime" do
    message = %Message{
      id: "42",
      content: "hello",
      sender: "alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      thread_ts: 77,
      metadata: %{update_id: 100},
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
    assert agent_message.metadata == %{update_id: 100}
    assert agent_message.attachments == [%{type: :photo, id: "file-1"}]

    assert :ok = agent_message.reply_fn.("reply")
    assert_received {:reply_sent, "123", "reply", reply_opts}
    assert reply_opts[:message_thread_id] == 77

    log =
      capture_log(fn ->
        assert {:error, :telegram_down} = agent_message.reply_fn.("fail")
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
        reply_target: "chat-1"
      })

    assert :ok =
             Dispatcher.dispatch([message],
               channel: BuildReplyChannel,
               agent: CapturingAgent,
               agent_server: self()
             )

    assert_receive {:agent_message, agent_message}
    assert :ok = agent_message.reply_fn.("reply")
    assert_received {:reply_built_and_sent, "message-1", "chat-1", "reply"}
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
               reply_fn: fn text ->
                 send(test_pid, {:captured_reply, text})
                 :ok
               end
             )

    assert_receive {:agent_message, agent_message}
    assert agent_message.content == "hello"
    assert is_function(agent_message.reply_fn, 1)

    assert :ok = agent_message.reply_fn.("reply")
    assert_receive {:captured_reply, "reply"}
  end

  test "adds channel typing runtime when the channel supports typing indicators" do
    message =
      Message.new!(%{
        id: "message-1",
        content: "hello",
        sender: "alice",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1"
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
      metadata: %{message_type: "audio"},
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
end
