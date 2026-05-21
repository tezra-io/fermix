defmodule FermixCore.TranscriptionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Transcription

  defmodule DownloadChannel do
    def download_attachment(_message, attachment) do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-transcription-#{attachment.file_id}-#{System.unique_integer([:positive])}.ogg"
        )

      File.write!(path, "audio-bytes:#{attachment.file_id}")
      {:ok, path}
    end
  end

  defmodule FakeBackend do
    def transcribe(path, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:transcribed_file, path, File.read!(path), Keyword.fetch!(opts, :metadata)}
      )

      {:ok, "transcribed voice note"}
    end
  end

  defmodule DirectoryChannel do
    def download_attachment(_message, _attachment) do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-transcription-dir-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(path)
      {:ok, path}
    end
  end

  defmodule SilentBackend do
    def transcribe(_path, _opts), do: {:ok, "directory transcript"}
  end

  test "downloads audio, transcribes it, preserves attachments, and annotates metadata" do
    test_pid = self()
    handler_id = "test-transcription-message-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:fermix, :transcription, :message],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    message = %{
      id: "wamid.audio",
      content: "",
      sender: "Alice",
      channel: "whatsapp",
      chat_id: "15551234567",
      reply_target: "15551234567",
      metadata: %{message_type: "audio"},
      attachments: [
        %{
          kind: :audio,
          file_id: "audio-media-id",
          mime_type: "audio/ogg",
          url: nil,
          size_bytes: nil
        }
      ]
    }

    assert {:ok, updated_message} =
             Transcription.maybe_transcribe_message(DownloadChannel, message,
               backend: FakeBackend,
               test_pid: self()
             )

    assert updated_message.content == "transcribed voice note"
    assert updated_message.attachments == message.attachments
    assert updated_message.metadata.message_type == "audio"

    assert updated_message.metadata.transcription == %{
             attachment: %{
               file_id: "audio-media-id",
               kind: :audio,
               mime_type: "audio/ogg",
               size_bytes: nil,
               url: nil
             },
             backend: FakeBackend
           }

    assert_receive {:transcribed_file, path, "audio-bytes:audio-media-id", metadata}
    assert metadata[:channel] == "whatsapp"
    assert metadata[:chat_id] == "15551234567"
    assert metadata[:attachment][:file_id] == "audio-media-id"
    refute File.exists?(path)

    assert_receive {:telemetry, [:fermix, :transcription, :message], measurements,
                    telemetry_metadata}

    assert measurements.duration_us >= 0
    assert telemetry_metadata.channel == "whatsapp"
    assert telemetry_metadata.status == :ok
    assert telemetry_metadata.transcribed? == true
  end

  test "leaves non-audio messages unchanged" do
    message = %{
      id: "message-1",
      content: "hello",
      sender: "Alice",
      channel: "whatsapp",
      chat_id: "15551234567",
      reply_target: "15551234567",
      metadata: %{},
      attachments: []
    }

    assert {:ok, ^message} = Transcription.maybe_transcribe_message(DownloadChannel, message)
  end

  test "handles string-key maps explicitly for content and attachments" do
    message = %{
      "id" => "wamid.audio",
      "content" => "",
      "sender" => "Alice",
      "channel" => "whatsapp",
      "chat_id" => "15551234567",
      "reply_target" => "15551234567",
      "metadata" => %{"message_type" => "audio"},
      "attachments" => [
        %{
          "kind" => "audio",
          "file_id" => "audio-media-id",
          "mime_type" => "audio/ogg",
          "url" => nil,
          "size_bytes" => nil
        }
      ]
    }

    assert {:ok, updated_message} =
             Transcription.maybe_transcribe_message(DownloadChannel, message,
               backend: FakeBackend,
               test_pid: self()
             )

    assert updated_message["content"] == "transcribed voice note"
    assert updated_message["metadata"]["transcription"].attachment.file_id == "audio-media-id"
  end

  test "logs temp file cleanup failures instead of swallowing them" do
    message = %{
      id: "wamid.audio",
      content: "",
      sender: "Alice",
      channel: "whatsapp",
      chat_id: "15551234567",
      reply_target: "15551234567",
      metadata: %{},
      attachments: [%{kind: :audio, file_id: "audio-media-id"}]
    }

    log =
      capture_log(fn ->
        assert {:ok, _updated_message} =
                 Transcription.maybe_transcribe_message(DirectoryChannel, message,
                   backend: SilentBackend
                 )
      end)

    assert log =~ "Transcription temp file cleanup failed"
  end
end
