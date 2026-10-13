defmodule FermixCore.AttachmentsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Attachments

  defp att(fields), do: struct!(Attachments, Map.merge(%{status: :ready}, Map.new(fields)))

  describe "parts/1" do
    test "a picture, a moving picture's still and a PDF become parts, in attachment order" do
      attachments = [
        att(kind: :document, mime_type: "application/pdf", name: "lease.pdf", bytes: "%PDF"),
        att(kind: :still, mime_type: "image/png", bytes: "png"),
        att(
          kind: :video,
          mime_type: "video/mp4",
          bytes: "mp4",
          poster: %{mime_type: "image/jpeg", bytes: "jpg"}
        )
      ]

      assert Attachments.parts(attachments) == [
               %{type: :document, mime_type: "application/pdf", data: "%PDF", name: "lease.pdf"},
               %{type: :image, mime_type: "image/png", data: "png"},
               %{type: :image, mime_type: "image/jpeg", data: "jpg"}
             ]
    end

    test "a GIF or video ffmpeg read rides as each of its frames, in order" do
      clip =
        att(
          kind: :video,
          mime_type: "video/mp4",
          bytes: "mp4",
          frames: [
            %{mime_type: "image/jpeg", bytes: "f1"},
            %{mime_type: "image/jpeg", bytes: "f2"}
          ]
        )

      assert Attachments.parts([clip]) == [
               %{type: :image, mime_type: "image/jpeg", data: "f1"},
               %{type: :image, mime_type: "image/jpeg", data: "f2"}
             ]
    end

    test "text rides the manifest, a transcript the text, and nothing unusable rides at all" do
      attachments = [
        att(kind: :text, mime_type: "text/plain", bytes: "notes"),
        att(kind: :audio, mime_type: "audio/ogg", bytes: "ogg", status: :transcribed),
        att(
          kind: :still,
          mime_type: "image/heic",
          bytes: "heic",
          status: {:unusable, {:still_unsupported, "image/heic"}}
        )
      ]

      assert Attachments.parts(attachments) == []
    end

    test "a nameless PDF still carries a file name for the wire" do
      assert [%{name: "document.pdf"}] =
               Attachments.parts([
                 att(kind: :document, mime_type: "application/pdf", bytes: "%PDF")
               ])
    end
  end

  test "inspect never prints the bytes, the frames or a transcript" do
    inspected =
      inspect(
        att(
          kind: :video,
          mime_type: "video/mp4",
          bytes: "SECRET-BYTES",
          frames: [%{mime_type: "image/jpeg", bytes: "SECRET-FRAME"}],
          sound: {:transcript, "SECRET-WORDS"}
        )
      )

    refute inspected =~ "SECRET"
    assert inspected =~ "video/mp4"
  end
end
