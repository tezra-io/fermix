defmodule FermixChannels.Gateway.AlbumBufferIngressTest do
  @moduledoc """
  The album buffer with its production dispatch, the real `Gateway.ingest/2`:
  while one chat's attachment download is held at the adapter, another chat's
  message reaches the agent, and the held chat's album and trailing text reach
  it afterwards, in order.
  """

  # async: false — the Authorizer reads the global `:fermix_channels, :whatsapp`
  # env this module sets.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.Message
  alias FermixCore.Attachments, as: Attachment
  alias FermixTestSupport.AttachmentFixtures, as: Fixtures
  alias FermixTestSupport.SafeRm

  # WhatsApp's album policy, with a download that tells the test it started and
  # holds until the test releases it, then writes the picture into the test's
  # own directory. Replies go nowhere.
  defmodule HeldDownloadChannel do
    defdelegate album_classify(message), to: WhatsApp

    def download_attachment(_message, %{gate: gate, dir: dir, file_id: file_id, bytes: bytes}) do
      send(gate, {:download_held, file_id, self()})

      receive do
        :release_download -> :ok
      end

      path = Path.join(dir, file_id)
      File.write!(path, bytes)
      {:ok, path}
    end

    def build_text_reply(%Message{}), do: fn _text -> :ok end
    def build_media_reply(%Message{}), do: fn _media -> :ok end
  end

  # Stands in for the queue: every turn ingest hands over comes to the test.
  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:fermix_channels, :whatsapp)
    Application.put_env(:fermix_channels, :whatsapp, owner_user_id: "test-sender")
    dir = SafeRm.make_tmp_dir!("album-buffer-ingress")

    on_exit(fn ->
      SafeRm.rm_rf!(dir)

      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :whatsapp, value)
        :error -> Application.delete_env(:fermix_channels, :whatsapp)
      end
    end)

    %{dir: dir}
  end

  defp message(id, wa_id, content, attachments) do
    Message.new!(%{
      id: id,
      content: content,
      sender: "alice",
      channel: "whatsapp",
      chat_id: wa_id,
      reply_target: wa_id,
      metadata: %{phone_number_id: "biz-1", sender_id: wa_id, user_id: "test-sender"},
      attachments: attachments
    })
  end

  defp picture(id, wa_id, dir) do
    message(id, wa_id, "", [
      %{
        hint: :photo,
        file_id: "#{id}.png",
        mime_type: "image/png",
        url: nil,
        gate: self(),
        dir: dir,
        bytes: Fixtures.png()
      }
    ])
  end

  test "a held download holds neither another chat's turn nor its own chat's order", %{dir: dir} do
    buffer =
      start_supervised!(
        {AlbumBuffer,
         channel: HeldDownloadChannel,
         name: :"album_buffer_#{System.unique_integer([:positive])}",
         debounce_ms: 10_000,
         agent: CapturingAgent,
         agent_server: self()}
      )

    # Chat A: an album, then a text that flushes it and waits behind it.
    AlbumBuffer.ingest(picture("a1", "wa-a", dir), buffer)
    AlbumBuffer.ingest(picture("a2", "wa-a", dir), buffer)
    AlbumBuffer.ingest(message("a3", "wa-a", "which one is sharper?", []), buffer)
    assert_receive {:download_held, "a1.png", first_download}
    assert_receive {:download_held, "a2.png", second_download}

    # Chat B reaches the agent while A's downloads are held.
    AlbumBuffer.ingest(message("b1", "wa-b", "and the ferry times?", []), buffer)
    assert_receive {:agent_message, %{id: "b1", content: "and the ferry times?"}}
    # A's text still waits behind its held album (which cannot end before the
    # downloads are released), so nothing of A can be in flight to the agent.
    assert :sys.get_state(buffer).lanes.waiting_count == 1
    refute_received {:agent_message, _message}

    send(first_download, :release_download)
    send(second_download, :release_download)

    assert_receive {:agent_message, album}
    assert album.id == "a1"

    assert [%Attachment{kind: :still, status: :ready}, %Attachment{kind: :still, status: :ready}] =
             album.inbound_attachments

    assert_receive {:agent_message, trailing}
    assert trailing.id == "a3"
    assert trailing.content == "which one is sharper?"

    # Every download's temp file went with its rendering.
    assert File.ls!(dir) -- [".fermix-test-root"] == []
  end
end
