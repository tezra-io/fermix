defmodule FermixChannels.Gateway.TranscriptionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.Transcription

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
    def name, do: :fake

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
    def name, do: :silent
    def transcribe(_path, _opts), do: {:ok, "directory transcript"}
  end

  # Sends a marker before writing the file so a test can assert the size-cap
  # preflight short-circuits BEFORE any download happens.
  defmodule MarkerChannel do
    def download_attachment(_message, attachment) do
      send(self(), {:downloaded, attachment.file_id})

      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-transcription-marker-#{System.unique_integer([:positive])}.ogg"
        )

      File.write!(path, "audio-bytes")
      {:ok, path}
    end
  end

  # Writes a file larger than a 1 MB cap so the post-download size check fires
  # when the declared size is unknown (size_bytes nil).
  defmodule LargeDownloadChannel do
    def download_attachment(_message, _attachment) do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-transcription-large-#{System.unique_integer([:positive])}.ogg"
        )

      File.write!(path, :binary.copy("x", 1_200_000))
      {:ok, path}
    end
  end

  test "downloads audio, transcribes it, preserves attachments, and annotates metadata" do
    test_pid = self()
    handler_id = "test-transcription-message-#{System.unique_integer()}"

    # This file is `async: true`, and a :telemetry handler is process-global: it
    # fires for events emitted by ANY concurrent test, not just this one.
    # dispatcher_test.exs (also async, also channel "whatsapp") emits this same
    # event with `status: :error` on its transcription-failure cases, which would
    # land in this mailbox and make `assert_receive` below grab a foreign event.
    # `:telemetry.execute/3` runs handlers in the *emitting* process, and this
    # test's code-under-test emits synchronously in-process, so scoping to
    # `self() == test_pid` forwards only this test's own event.
    :telemetry.attach(
      handler_id,
      [:fermix, :transcription, :message],
      fn event, measurements, metadata, _config ->
        if self() == test_pid do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
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
             backend: :fake
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

  test "composes caption and transcript when audio arrives with a caption (D15)" do
    message = %{
      id: "voice-caption",
      content: "please summarize the call",
      sender: "Alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      metadata: %{},
      attachments: [
        %{kind: :audio, file_id: "audio-cap", mime_type: "audio/ogg", url: nil, size_bytes: nil}
      ]
    }

    assert {:ok, updated} =
             Transcription.maybe_transcribe_message(DownloadChannel, message,
               backend: FakeBackend,
               test_pid: self()
             )

    assert updated.content ==
             "please summarize the call\n\n[voice note transcript]\ntranscribed voice note"

    assert updated.metadata.transcription.attachment.file_id == "audio-cap"
    assert updated.metadata.transcription.backend == :fake
  end

  test "composes caption and transcript for string-key messages" do
    message = %{
      "id" => "voice-caption-strkey",
      "content" => "notes please",
      "sender" => "Alice",
      "channel" => "telegram",
      "chat_id" => "123",
      "reply_target" => "123",
      "metadata" => %{},
      "attachments" => [
        %{
          "kind" => "audio",
          "file_id" => "audio-cap2",
          "mime_type" => "audio/ogg",
          "url" => nil,
          "size_bytes" => nil
        }
      ]
    }

    assert {:ok, updated} =
             Transcription.maybe_transcribe_message(DownloadChannel, message,
               backend: FakeBackend,
               test_pid: self()
             )

    assert updated["content"] ==
             "notes please\n\n[voice note transcript]\ntranscribed voice note"
  end

  test "refuses an oversize audio attachment by declared size without downloading" do
    message = %{
      id: "voice-big",
      content: "",
      sender: "Alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      metadata: %{},
      attachments: [
        %{
          kind: :audio,
          file_id: "big",
          mime_type: "audio/ogg",
          url: nil,
          size_bytes: 25 * 1_024 * 1_024
        }
      ]
    }

    # Establish the cap via the `max_file_mb` opt seam (this module is async: true
    # and can't safely `put_env` the `:transcription` baseline) so the assertion
    # doesn't depend on un-isolated global app env — the documented order-flake class.
    assert {:error, {:transcription_failed, {:file_too_large, size_mb, cap_mb}}} =
             Transcription.maybe_transcribe_message(MarkerChannel, message,
               backend: FakeBackend,
               test_pid: self(),
               max_file_mb: 20
             )

    assert cap_mb == 20
    assert size_mb > 20
    refute_received {:downloaded, _file_id}
    refute_received {:transcribed_file, _path, _bytes, _metadata}
  end

  test "refuses an oversize downloaded file when the declared size is unknown" do
    message = %{
      id: "voice-unknown",
      content: "",
      sender: "Alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      metadata: %{},
      attachments: [
        %{kind: :audio, file_id: "unknown", mime_type: "audio/ogg", url: nil, size_bytes: nil}
      ]
    }

    assert {:error, {:transcription_failed, {:file_too_large, size_mb, 1}}} =
             Transcription.maybe_transcribe_message(LargeDownloadChannel, message,
               backend: FakeBackend,
               test_pid: self(),
               max_file_mb: 1
             )

    assert size_mb > 1
    refute_received {:transcribed_file, _path, _bytes, _metadata}
  end
end
