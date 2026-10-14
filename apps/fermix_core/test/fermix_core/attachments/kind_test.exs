defmodule FermixCore.Attachments.KindTest do
  use ExUnit.Case, async: true

  alias FermixCore.Attachments.Kind
  alias FermixTestSupport.AttachmentFixtures, as: Fixtures

  describe "the bytes decide first" do
    test "a picture's signature beats the mime the platform declared" do
      assert Kind.classify(%{mime_type: "image/jpeg", hint: :photo}, Fixtures.png()) ==
               {:still, "image/png"}

      assert Kind.classify(%{}, Fixtures.jpeg()) == {:still, "image/jpeg"}
    end

    test "a GIF is a still with one frame and an animation with more" do
      assert Kind.classify(%{}, Fixtures.still_gif()) == {:still, "image/gif"}

      assert Kind.classify(%{mime_type: "image/gif"}, Fixtures.animated_gif()) ==
               {:animation, "image/gif"}
    end

    test "a WebP is a still unless its extended header marks it animated" do
      still = <<"RIFF", 0::32, "WEBP", "VP8 ", 0::32>>
      animated = <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0x02, 0::24>>

      assert Kind.classify(%{}, still) == {:still, "image/webp"}
      assert Kind.classify(%{}, animated) == {:animation, "image/webp"}
    end

    test "ISO media names a video, an M4A, a HEIC picture by its brand" do
      assert Kind.classify(%{}, Fixtures.mp4()) == {:video, "video/mp4"}
      assert Kind.classify(%{}, <<0, 0, 0, 24, "ftypM4A ", 0::64>>) == {:audio, "audio/mp4"}
      assert Kind.classify(%{}, <<0, 0, 0, 24, "ftypheic", 0::64>>) == {:still, "image/heic"}
      assert Kind.classify(%{}, <<0, 0, 0, 24, "ftypqt  ", 0::64>>) == {:video, "video/quicktime"}
    end

    test "a PDF and the audio containers are named by their signatures" do
      assert Kind.classify(%{mime_type: "application/octet-stream"}, Fixtures.pdf()) ==
               {:document, "application/pdf"}

      assert Kind.classify(%{}, Fixtures.ogg()) == {:audio, "audio/ogg"}
      assert Kind.classify(%{}, "ID3" <> <<4, 0>>) == {:audio, "audio/mpeg"}
      assert Kind.classify(%{}, <<"RIFF", 0::32, "WAVE">>) == {:audio, "audio/wav"}
    end

    test "WebM is sound when the platform says audio, a video otherwise" do
      webm = <<0x1A, 0x45, 0xDF, 0xA3, 0::32>>
      assert Kind.classify(%{mime_type: "audio/webm"}, webm) == {:audio, "audio/webm"}
      assert Kind.classify(%{}, webm) == {:video, "video/webm"}
    end
  end

  describe "without a signature" do
    test "the declared mime decides, parameters and case aside" do
      assert Kind.classify(%{mime_type: "Audio/AAC"}, <<0xFF, 0xF1, 0x50>>) ==
               {:audio, "audio/aac"}

      assert Kind.classify(%{mime_type: "text/plain; charset=utf-8"}, "hello") ==
               {:text, "text/plain"}

      assert Kind.classify(%{mime_type: "application/json"}, ~s({"a": 1})) ==
               {:text, "application/json"}
    end

    test "UTF-8 with no NUL is text when nothing else names it" do
      assert Kind.classify(%{file_name: "notes.md"}, "# Notes\nDELTA 55 — parking") ==
               {:text, "text/plain"}
    end

    test "a long file cut inside a multi-byte character at the inline cap is still text" do
      text = String.duplicate("é", 20_000)
      assert Kind.classify(%{}, text) == {:text, "text/plain"}
    end

    test "a declared text mime over binary bytes is not text" do
      assert Kind.classify(%{mime_type: "text/plain"}, <<0, 1, 2, 255>>) ==
               {:unknown, "text/plain"}
    end

    test "the platform's hint names what neither bytes nor mime did" do
      tgs = <<0x1F, 0x8B, 8, 0, 0xFF>>

      assert Kind.classify(%{mime_type: "application/x-tgsticker", hint: :sticker}, tgs) ==
               {:animation, "application/x-tgsticker"}

      assert Kind.classify(%{hint: :voice}, <<0xFF, 0xF1>>) ==
               {:audio, "application/octet-stream"}
    end

    test "what nothing names is unknown under its declared mime" do
      zip = <<"PK", 3, 4, 0, 0, 255>>
      docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

      assert Kind.classify(%{mime_type: docx, hint: :document}, zip) == {:unknown, docx}
      assert Kind.classify(%{}, <<0, 1, 2, 255>>) == {:unknown, "application/octet-stream"}
    end
  end

  test "an MP4 the platform calls an animation is an animation (Telegram's GIF)" do
    assert Kind.classify(%{mime_type: "video/mp4", hint: :animation}, Fixtures.mp4()) ==
             {:animation, "video/mp4"}
  end

  describe "declared/1: an attachment no byte of which arrived" do
    test "is named from its declared mime, then its hint" do
      assert Kind.declared(%{mime_type: "video/quicktime"}) == {:video, "video/quicktime"}
      assert Kind.declared(%{mime_type: "image/png"}) == {:still, "image/png"}
      assert Kind.declared(%{hint: :photo}) == {:still, "image/jpeg"}

      assert Kind.declared(%{hint: :animation, mime_type: "video/mp4"}) ==
               {:animation, "video/mp4"}

      assert Kind.declared(%{}) == {:unknown, "application/octet-stream"}
    end
  end

  # Review fix 1: the manifest inlines up to 32 KiB, so the text test covers
  # exactly those bytes; a Windows-1252 byte inside them is not text.
  describe "text covers every byte the manifest inlines" do
    test "an invalid byte past 8 KiB, inside the inline cap, is not text" do
      csv = String.duplicate("a,b\n", 2_500) <> <<0xE9>> <> "tail"
      assert byte_size(csv) > 8 * 1024
      assert Kind.classify(%{mime_type: "text/csv"}, csv) == {:unknown, "text/csv"}
      assert Kind.classify(%{}, csv) == {:unknown, "application/octet-stream"}
    end

    test "an invalid byte past the inline cap is never inlined, so the file is text" do
      text = String.duplicate("x", 40 * 1024) <> <<0xE9>>
      assert Kind.classify(%{}, text) == {:text, "text/plain"}
    end

    test "a file that ends inside the cap must end on a whole character" do
      assert Kind.classify(%{}, "caf" <> <<0xC3>>) == {:unknown, "application/octet-stream"}
      assert Kind.classify(%{}, "café") == {:text, "text/plain"}
    end
  end

  # Review fix 2: a phone's voice recording sits in an MP4 or 3GP container.
  describe "a container the platform calls audio is audio" do
    test "by its declared mime" do
      m4a = <<0, 0, 0, 24, "ftypmp42", 0::64>>
      assert Kind.classify(%{mime_type: "audio/mp4"}, m4a) == {:audio, "audio/mp4"}

      assert Kind.classify(%{mime_type: "audio/3gpp"}, <<0, 0, 0, 24, "ftyp3gp4", 0::64>>) ==
               {:audio, "audio/3gpp"}
    end

    test "by its hint, when the mime says nothing" do
      assert Kind.classify(%{hint: :voice}, <<0, 0, 0, 24, "ftyp3gp4", 0::64>>) ==
               {:audio, "audio/mp4"}

      assert Kind.classify(%{hint: :audio}, <<0x1A, 0x45, 0xDF, 0xA3, 0::32>>) ==
               {:audio, "audio/webm"}
    end

    test "a video stays a video" do
      assert Kind.classify(%{mime_type: "video/mp4", hint: :video}, Fixtures.mp4()) ==
               {:video, "video/mp4"}
    end
  end

  # Review fix 5: a declared picture or PDF is believed only with its signature.
  describe "a signed format without its signature is not what was declared" do
    test "an HTML sign-in page declared as a PNG, and a PDF without %PDF" do
      html = "<!doctype html><html><body>Sign in to Slack</body></html>"

      assert Kind.classify(%{mime_type: "image/png", hint: :photo}, html) ==
               {:unknown, "image/png"}

      assert Kind.classify(%{mime_type: "application/pdf"}, "not a pdf") ==
               {:unknown, "application/pdf"}

      assert Kind.classify(%{mime_type: "image/jpeg"}, "") == {:unknown, "image/jpeg"}
    end

    test "signed?/1 names the formats Fermix knows by signature" do
      assert Kind.signed?("image/png")
      assert Kind.signed?("application/pdf")
      refute Kind.signed?("image/heic")
      refute Kind.signed?("application/zip")
    end
  end
end
