defmodule FermixChannels.Gateway.MediaIngestTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.MediaIngest
  alias FermixChannels.Gateway.Message

  # A channel that downloads to a DETERMINISTIC per-file_id temp path. Album
  # downloads now run in parallel tasks, so `download_attachment` no longer runs
  # in the test process — a deterministic path lets the test assert cleanup
  # without cross-process messaging. Each test uses distinct file_ids.
  defmodule OkChannel do
    def download_attachment(_message, attachment) do
      path = temp_path(attachment.file_id)
      File.write!(path, "BYTES-" <> attachment.file_id)
      {:ok, path}
    end

    def temp_path(file_id) do
      Path.join(System.tmp_dir!(), "fermix-mediaingest-test-#{file_id}.png")
    end
  end

  defmodule FailChannel do
    def download_attachment(_message, _attachment), do: {:error, :boom}
  end

  # Fails only for file_id "bad"; writes+returns a real temp file for every other
  # id, so a test can assert those temp files are still cleaned up on failure.
  defmodule PartialFailChannel do
    def download_attachment(_message, %{file_id: "bad"}), do: {:error, :boom}

    def download_attachment(_message, attachment) do
      path = OkChannel.temp_path(attachment.file_id)
      File.write!(path, "BYTES-" <> attachment.file_id)
      {:ok, path}
    end
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

  test "materializes a single image into a neutral part and cleans up its temp file" do
    msg = message([image_ref("abc")])

    assert {:ok, %{media_parts: [part]}} = MediaIngest.maybe_attach_images(OkChannel, msg)
    assert part == %{type: :image, mime_type: "image/png", data: "BYTES-abc"}

    refute File.exists?(OkChannel.temp_path("abc")),
           "media-ingest must delete the temp file after reading it"
  end

  test "materializes album images in input order and cleans up every temp file" do
    msg = message([image_ref("m1"), image_ref("m2"), image_ref("m3")])

    assert {:ok, %{media_parts: parts}} = MediaIngest.maybe_attach_images(OkChannel, msg)

    # Parallel downloads may finish out of order; `ordered: true` must keep parts
    # in album order (matching the old serial `Enum.reverse`).
    assert Enum.map(parts, & &1.data) == ["BYTES-m1", "BYTES-m2", "BYTES-m3"]

    for id <- ["m1", "m2", "m3"] do
      refute File.exists?(OkChannel.temp_path(id)), "temp file for #{id} must be cleaned up"
    end
  end

  test "fails loud when a download errors (no degraded image-less turn)" do
    msg = message([image_ref("abc")])

    assert {:error, {:attachment_download_failed, :boom}} =
             MediaIngest.maybe_attach_images(FailChannel, msg)
  end

  test "fails loud and still cleans up every downloaded temp file when one album image fails" do
    # Good, failing, good. Even though downloads run in parallel and out of order,
    # draining the whole stream guarantees each successful task ran its
    # `after cleanup_download`, so nothing leaks despite the all-or-nothing error.
    msg = message([image_ref("pf1"), image_ref("bad"), image_ref("pf2")])

    assert {:error, {:attachment_download_failed, :boom}} =
             MediaIngest.maybe_attach_images(PartialFailChannel, msg)

    refute File.exists?(OkChannel.temp_path("pf1")), "temp file for pf1 must be cleaned up"
    refute File.exists?(OkChannel.temp_path("pf2")), "temp file for pf2 must be cleaned up"
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
