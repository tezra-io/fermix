defmodule FermixChannels.Gateway.ForwardedAttachmentTest do
  # The channel's `forwarded?` flag rides the gateway pipeline into the
  # attachment the turn reads, and changes nothing about processing: a forwarded
  # video note is still transcription-only, exactly as the owner's own is. Only
  # the label its transcript arrives under says whose words they are.
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Attachments
  alias FermixChannels.Gateway.Message
  alias FermixCore.Attachments, as: Attachment
  alias FermixTestSupport.AttachmentFixtures, as: Fixtures
  alias FermixTestSupport.SafeRm

  # Writes each declared attachment's bytes into the test's own directory.
  defmodule FileChannel do
    def download_attachment(_message, %{dir: dir, file_id: file_id, bytes: bytes}) do
      path = Path.join(dir, file_id)
      File.write!(path, bytes)
      {:ok, path}
    end
  end

  defmodule FakeBackend do
    def name, do: :fake
    def transcribe(_path, _opts), do: {:ok, "book the ferry for the eleventh"}
  end

  setup do
    dir = SafeRm.make_tmp_dir!("gateway-forwarded")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp ingest(declared) do
    message =
      Message.new!(%{
        id: "1",
        content: "",
        sender: "alice",
        channel: "telegram",
        chat_id: "123",
        reply_target: "123",
        attachments: [declared]
      })

    Attachments.ingest(FileChannel, message, backend: FakeBackend, ffmpeg: :missing)
  end

  defp video_note(dir, extra) do
    Map.merge(
      %{dir: dir, file_id: "note", bytes: Fixtures.mp4(), url: nil, mime_type: "video/mp4"},
      Map.put(extra, :hint, :video_note)
    )
  end

  test "a forwarded video note is transcribed only, and marked forwarded", %{dir: dir} do
    assert {:ok, msg} = ingest(video_note(dir, %{forwarded?: true}))

    assert msg.content == "[forwarded voice note transcript]\nbook the ferry for the eleventh"

    assert [%Attachment{kind: :video, status: :transcribed, frames: [], forwarded?: true}] =
             msg.inbound_attachments
  end

  test "the owner's own video note is processed the same way, not marked", %{dir: dir} do
    assert {:ok, msg} = ingest(video_note(dir, %{}))

    assert msg.content == "book the ferry for the eleventh"

    assert [%Attachment{kind: :video, status: :transcribed, frames: [], forwarded?: false}] =
             msg.inbound_attachments
  end
end
