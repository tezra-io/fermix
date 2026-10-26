defmodule FermixChannels.Gateway.TranscriptionTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Transcription
  alias FermixTestSupport.SafeRm

  defmodule FakeBackend do
    def name, do: :fake

    def transcribe(path, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:transcribed_file, path, File.read!(path), Keyword.fetch!(opts, :metadata)}
      )

      {:ok, "  transcribed voice note \n"}
    end
  end

  defmodule SilentBackend do
    def name, do: :silent
    def transcribe(_path, _opts), do: {:ok, "   "}
  end

  defmodule ErrorBackend do
    def name, do: :error
    def transcribe(_path, _opts), do: {:error, :not_configured}
  end

  setup do
    dir = SafeRm.make_tmp_dir!("gateway-transcription")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    path = Path.join(dir, "voice.ogg")
    File.write!(path, "audio-bytes")
    %{path: path}
  end

  defp message(content) do
    %{
      id: "wamid.audio",
      content: content,
      sender: "Alice",
      channel: "whatsapp",
      chat_id: "15551234567",
      reply_target: "15551234567",
      metadata: %{message_type: "audio"}
    }
  end

  defp attachment do
    %{hint: :voice, file_id: "audio-media-id", mime_type: "audio/ogg", url: nil, size_bytes: nil}
  end

  test "transcribes the downloaded file, trims the text and names the backend", %{path: path} do
    test_pid = self()
    handler_id = "test-transcription-message-#{System.unique_integer()}"

    # A :telemetry handler is process-global and other async tests emit this
    # event too; the code under test emits in this process, so scoping to
    # `self() == test_pid` forwards only this test's own event.
    :telemetry.attach(
      handler_id,
      [:fermix, :transcription, :message],
      fn event, measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, transcript} =
             Transcription.transcribe(message(""), attachment(), path,
               backend: FakeBackend,
               test_pid: self()
             )

    assert transcript == %{
             text: "transcribed voice note",
             backend: :fake,
             attachment: %{
               hint: :voice,
               file_id: "audio-media-id",
               mime_type: "audio/ogg",
               size_bytes: nil,
               url: nil,
               forwarded?: false
             }
           }

    assert_receive {:transcribed_file, ^path, "audio-bytes", metadata}
    assert metadata[:channel] == "whatsapp"
    assert metadata[:chat_id] == "15551234567"
    assert metadata[:attachment][:file_id] == "audio-media-id"

    assert_receive {:telemetry, [:fermix, :transcription, :message], measurements,
                    telemetry_metadata}

    assert measurements.duration_us >= 0
    assert telemetry_metadata.channel == "whatsapp"
    assert telemetry_metadata.status == :ok
    assert telemetry_metadata.transcribed? == true
  end

  test "the caller owns the file: transcription leaves it in place", %{path: path} do
    assert {:ok, _transcript} =
             Transcription.transcribe(message(""), attachment(), path,
               backend: FakeBackend,
               test_pid: self()
             )

    assert File.exists?(path)
  end

  test "a transcript stands alone without a caption, and keeps the metadata", %{path: path} do
    {:ok, transcript} =
      Transcription.transcribe(message(""), attachment(), path,
        backend: FakeBackend,
        test_pid: self()
      )

    updated = Transcription.put_transcript(message(""), transcript)

    assert updated.content == "transcribed voice note"
    assert updated.metadata.message_type == "audio"
    assert updated.metadata.transcription == %{attachment: transcript.attachment, backend: :fake}
  end

  # Someone else recorded a forwarded one, so the model reads its words under a
  # label that says so, caption or not; the owner's own stay as they were.
  test "a forwarded recording's transcript is labelled forwarded, with or without a caption",
       %{path: path} do
    forwarded = Map.put(attachment(), :forwarded?, true)

    {:ok, transcript} =
      Transcription.transcribe(message(""), forwarded, path,
        backend: FakeBackend,
        test_pid: self()
      )

    assert transcript.attachment.forwarded? == true

    assert Transcription.put_transcript(message(""), transcript).content ==
             "[forwarded voice note transcript]\ntranscribed voice note"

    assert Transcription.put_transcript(message("what does she want?"), transcript).content ==
             "what does she want?\n\n[forwarded voice note transcript]\ntranscribed voice note"
  end

  test "a caption stays first and the transcript follows under its label (D15)", %{path: path} do
    {:ok, transcript} =
      Transcription.transcribe(message("please summarize the call"), attachment(), path,
        backend: FakeBackend,
        test_pid: self()
      )

    updated = Transcription.put_transcript(message("please summarize the call"), transcript)

    assert updated.content ==
             "please summarize the call\n\n[voice note transcript]\ntranscribed voice note"
  end

  test "a recording with no speech in it is a named failure", %{path: path} do
    assert {:error, {:transcription_failed, :empty_transcription}} =
             Transcription.transcribe(message(""), attachment(), path, backend: SilentBackend)
  end

  test "a backend failure is wrapped for the gateway's reply", %{path: path} do
    assert {:error, {:transcription_failed, :not_configured}} =
             Transcription.transcribe(message(""), attachment(), path, backend: ErrorBackend)
  end

  test "a file past the transcription cap is refused before the backend runs", %{path: path} do
    File.write!(path, :binary.copy("x", 1_200_000))

    assert {:error, {:transcription_failed, {:file_too_large, size_mb, 1}}} =
             Transcription.transcribe(message(""), attachment(), path,
               backend: FakeBackend,
               test_pid: self(),
               max_file_mb: 1
             )

    assert size_mb > 1
    refute_received {:transcribed_file, _path, _bytes, _metadata}
  end
end
