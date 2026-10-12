defmodule FermixCore.Attachments.ManifestTest do
  use ExUnit.Case, async: true

  alias FermixCore.Attachments
  alias FermixCore.Attachments.Manifest

  defp att(fields), do: struct!(Attachments, Map.merge(%{status: :ready}, Map.new(fields)))

  describe "compose/3" do
    test "a turn with no attachments keeps its text byte-identical" do
      assert Manifest.compose("hello", []) == "hello"
      assert Manifest.compose("", []) == ""
    end

    test "a voice note's transcript already stands in the text, so it is not listed" do
      voice = att(kind: :audio, mime_type: "audio/ogg", size_bytes: 4_000, status: :transcribed)
      assert Manifest.compose("the transcript", [voice]) == "the transcript"
    end

    test "lists each attachment with its kind, size and what reached the model" do
      attachments = [
        att(
          kind: :animation,
          mime_type: "video/mp4",
          name: "holiday.mp4",
          size_bytes: 1_153_434,
          duration_s: 3,
          poster: %{mime_type: "image/jpeg", bytes: "jpg"}
        ),
        att(
          kind: :document,
          mime_type: "application/pdf",
          name: "lease.pdf",
          size_bytes: 317_440
        ),
        att(kind: :still, mime_type: "image/png", size_bytes: 512),
        att(
          kind: :text,
          mime_type: "text/plain",
          name: "notes.txt",
          bytes: "DELTA 55",
          size_bytes: 8
        )
      ]

      assert Manifest.compose("what is this one?", attachments) == """
             what is this one?

             [attachments]
             1. holiday.mp4 · animation · 3 s · 1.1 MB · one still frame of it attached as image 1
             2. lease.pdf · PDF · 310 KB · attached as document 1
             3. image · 512 bytes · attached as image 2
             4. notes.txt · text · 8 bytes · inlined below

             [notes.txt]
             DELTA 55\
             """
    end

    test "an attachment-only turn opens on the manifest" do
      still = att(kind: :still, mime_type: "image/jpeg", size_bytes: 2_048)
      assert Manifest.compose("  ", [still]) =~ ~r/\A  \n\n\[attachments\]/

      assert Manifest.compose("", [still]) ==
               "[attachments]\n1. image · 2 KB · attached as image 1"
    end

    test "an unreadable attachment says why, with the install hint for this OS" do
      clip =
        att(
          kind: :video,
          mime_type: "video/quicktime",
          name: "clip.mov",
          size_bytes: 9 * 1024 * 1024,
          status: {:unusable, {:needs_ffmpeg, :video}}
        )

      mac = Manifest.compose("thoughts?", [clip], os: :macos)
      linux = Manifest.compose("thoughts?", [clip], os: :linux)

      assert mac =~ "1. clip.mov · video · 9.0 MB · not readable: it is a video"
      assert mac =~ "install it with brew install ffmpeg"
      assert linux =~ "install the ffmpeg package (for example sudo apt install ffmpeg)"
    end

    test "a sender's file name stays on one line" do
      still = att(kind: :still, mime_type: "image/png", name: "a\nb\r\n.png", size_bytes: 2_048)

      assert Manifest.compose("", [still]) ==
               "[attachments]\n1. a b .png · image · 2 KB · attached as image 1"
    end

    test "a text file past 32 KiB is cut on a character boundary, and the manifest says so" do
      text = String.duplicate("é", 20_000)

      file =
        att(
          kind: :text,
          mime_type: "text/plain",
          name: "long.txt",
          bytes: text,
          size_bytes: byte_size(text)
        )

      composed = Manifest.compose("", [file])
      [_manifest, inlined] = String.split(composed, "[long.txt]\n")

      assert composed =~ "the first 32 KB inlined below; the rest is cut"
      assert byte_size(inlined) == 32 * 1024
      assert String.valid?(inlined)
    end
  end

  # Review fix 7: the 32 KiB of inlined text is one budget for the message.
  test "every text file of a message shares one 32 KiB inline budget, in order" do
    files =
      for {name, size} <- [{"a.txt", 30 * 1024}, {"b.txt", 10 * 1024}, {"c.txt", 100}] do
        text = String.duplicate("x", size)
        att(kind: :text, mime_type: "text/plain", name: name, bytes: text, size_bytes: size)
      end

    composed = Manifest.compose("", files)

    assert composed =~ "1. a.txt · text · 30 KB · inlined below"
    assert composed =~ "2. b.txt · text · 10 KB · the first 2 KB inlined below; the rest is cut"
    assert composed =~ "3. c.txt · text · 100 bytes · not inlined: the text files before it"
    refute composed =~ "[c.txt]"

    [_manifest | blocks] = String.split(composed, ~r/\n\n\[(a|b)\.txt\]\n/)
    assert blocks |> Enum.map(&byte_size/1) |> Enum.sum() == 32 * 1024
  end

  describe "unusable_reply/2" do
    test "one attachment: one sentence naming it and its reason, never 'looks empty'" do
      bin =
        att(
          kind: :unknown,
          mime_type: "application/octet-stream",
          name: "payload.bin",
          status: {:unusable, {:unknown_type, "application/octet-stream"}}
        )

      reply = Manifest.unusable_reply([bin])

      assert reply ==
               "I couldn't read payload.bin: Fermix can't read this type of file " <>
                 "(application/octet-stream); send it as a PDF, a picture or plain text."

      refute reply =~ "empty"
    end

    test "several: one line each, a nameless one by its kind" do
      reply =
        Manifest.unusable_reply([
          att(
            kind: :still,
            mime_type: "image/heic",
            status: {:unusable, {:still_unsupported, "image/heic"}}
          ),
          att(
            kind: :video,
            mime_type: "video/mp4",
            name: "big.mp4",
            size_bytes: 25 * 1024 * 1024,
            status: {:unusable, {:too_large, 25 * 1024 * 1024, 20 * 1024 * 1024}}
          )
        ])

      assert reply ==
               "I couldn't read anything you attached:\n" <>
                 "- the image you sent: it is a image/heic picture, which the models do not " <>
                 "take; send it as a JPEG or PNG.\n" <>
                 "- big.mp4: it is 25.0 MB, over the 20 MB limit."
    end

    test "each reason says what is true of it: a lone attachment, a still that failed, a channel" do
      reply = fn reason ->
        Manifest.unusable_reply([
          att(kind: :video, mime_type: "video/mp4", status: {:unusable, reason})
        ])
      end

      assert reply.({:turn_full, 20 * 1024 * 1024}) =~
               "it would take what one message carries past 20 MB"

      assert reply.({:poster_unavailable, :video, :boom}) =~
               "the still the channel made of it could not be fetched"

      refute reply.({:poster_unavailable, :video, :boom}) =~ "send it again"

      assert reply.({:channel_cannot_fetch, "acp"}) =~
               "the acp channel gives Fermix no way to fetch"

      refute reply.({:no_still, "image/webp"}) =~ "ffmpeg"

      assert reply.({:not_as_declared, "image/png"}) =~
               "the channel called it image/png, but what arrived is not one"
    end

    test "every unusable reason has a sentence" do
      reasons = [
        {:too_large, 30 * 1024 * 1024, 20 * 1024 * 1024},
        {:too_many, 10},
        {:turn_full, 20 * 1024 * 1024},
        {:needs_ffmpeg, :animation},
        {:needs_ffmpeg, :video},
        {:no_still, "image/webp"},
        {:poster_unavailable, :video, {:download_failed, 404}},
        {:still_unsupported, "image/tiff"},
        {:unknown_type, "application/zip"},
        {:not_as_declared, "image/png"},
        {:download_failed, :timeout},
        {:channel_cannot_fetch, "acp"}
      ]

      for reason <- reasons do
        reply =
          Manifest.unusable_reply(
            [att(kind: :unknown, mime_type: "x/y", status: {:unusable, reason})],
            os: :linux
          )

        assert reply =~ ~r/\AI couldn't read the file you sent: \S/
      end
    end
  end
end
