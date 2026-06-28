defmodule FermixChannels.Gateway.MediaIngestTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.MediaIngest
  alias FermixChannels.Gateway.Message

  # A channel that downloads to a temp file and reports the path to the test
  # process so cleanup can be asserted (everything runs synchronously here).
  defmodule OkChannel do
    def download_attachment(_message, attachment) do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-mediaingest-test-#{System.unique_integer([:positive])}.png"
        )

      File.write!(path, "BYTES-" <> attachment.file_id)
      send(self(), {:downloaded_path, path})
      {:ok, path}
    end
  end

  defmodule FailChannel do
    def download_attachment(_message, _attachment), do: {:error, :boom}
  end

  defmodule NoDownloaderChannel do
    # Deliberately no download_attachment/2 — models a channel that parses image
    # refs but has no byte path yet (its images are left unmaterialized).
  end

  defp message(attachments) do
    Message.new!(%{
      id: "1",
      content: "look",
      sender: "alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      attachments: attachments
    })
  end

  defp image_ref(file_id), do: %{kind: :image, file_id: file_id, mime_type: "image/png", url: nil}

  test "materializes image attachments into neutral parts and cleans up temp files" do
    msg = message([image_ref("abc")])

    assert {:ok, %{media_parts: [part]}} = MediaIngest.maybe_attach_images(OkChannel, msg)
    assert part == %{type: :image, mime_type: "image/png", data: "BYTES-abc"}

    assert_received {:downloaded_path, path}
    refute File.exists?(path), "media-ingest must delete the temp file after reading it"
  end

  test "fails loud when a download errors (no degraded image-less turn)" do
    msg = message([image_ref("abc")])

    assert {:error, {:attachment_download_failed, :boom}} =
             MediaIngest.maybe_attach_images(FailChannel, msg)
  end

  test "leaves the message unchanged when the channel has no download_attachment/2" do
    msg = message([image_ref("abc")])

    assert {:ok, returned} = MediaIngest.maybe_attach_images(NoDownloaderChannel, msg)
    assert returned.media_parts == []
  end

  test "leaves a text-only message unchanged" do
    msg = message([])

    assert {:ok, returned} = MediaIngest.maybe_attach_images(OkChannel, msg)
    assert returned.media_parts == []
  end
end
