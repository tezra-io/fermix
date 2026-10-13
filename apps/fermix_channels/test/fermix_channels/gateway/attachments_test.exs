defmodule FermixChannels.Gateway.AttachmentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.Attachments
  alias FermixChannels.Gateway.Message
  alias FermixCore.Attachments, as: Attachment
  alias FermixTestSupport.AttachmentFixtures, as: Fixtures
  alias FermixTestSupport.FakeFfmpeg
  alias FermixTestSupport.SafeRm

  @mib 1024 * 1024

  # Downloads run in tasks, so a channel writes each declared attachment's
  # `bytes` to `<dir>/<file_id>` in the test's own directory: cleanup is then
  # observable as an empty directory, with no cross-process messaging.
  defmodule FileChannel do
    def download_attachment(_message, %{file_id: "boom"}), do: {:error, :boom}

    def download_attachment(_message, %{file_id: "over-cap"}),
      do: {:error, {:byte_cap_exceeded, 21 * 1024 * 1024, 20 * 1024 * 1024}}

    def download_attachment(_message, %{file_id: "raise"}), do: raise("channel bug")

    # A channel that declares no size and caps above Fermix (WhatsApp, 25 MiB).
    def download_attachment(_message, %{dir: dir, file_id: "undeclared-big"}) do
      path = Path.join(dir, "undeclared-big")
      File.write!(path, :binary.copy(<<0>>, 22 * 1024 * 1024))
      {:ok, path}
    end

    def download_attachment(_message, %{dir: dir, file_id: file_id, bytes: bytes}) do
      path = Path.join(dir, file_id)
      File.write!(path, bytes)
      {:ok, path}
    end
  end

  defmodule NoDownloaderChannel do
    # Deliberately no download_attachment/2.
  end

  defmodule FakeBackend do
    def name, do: :fake

    def transcribe(path, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:transcribed, File.read!(path), Path.extname(path)})
      {:ok, "book the ferry for the eleventh"}
    end
  end

  defmodule CrashingBackend do
    def name, do: :crashing
    def transcribe(_path, _opts), do: raise("backend bug")
  end

  defmodule FailingBackend do
    def name, do: :failing
    def transcribe(_path, _opts), do: {:error, :not_configured}
  end

  # Reports the file name and the mime the backend would send the clip under.
  defmodule FormatBackend do
    def name, do: :format

    def transcribe(path, opts) do
      mime = opts |> Keyword.fetch!(:metadata) |> Map.fetch!(:attachment) |> Map.get(:mime_type)
      send(Keyword.fetch!(opts, :test_pid), {:sent_as, Path.extname(path), mime})
      {:ok, "cheers to the crew"}
    end
  end

  # A clip with nothing said in it: what a silent video gets from a backend.
  defmodule NoSpeechBackend do
    def name, do: :no_speech
    def transcribe(_path, _opts), do: {:ok, "  "}
  end

  setup do
    dir = SafeRm.make_tmp_dir!("gateway-attachments")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp message(declared, content \\ "look") do
    Message.new!(%{
      id: "1",
      content: content,
      sender: "alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      attachments: declared
    })
  end

  defp file(dir, file_id, bytes, extra \\ %{}),
    do: Map.merge(%{dir: dir, file_id: file_id, bytes: bytes, url: nil}, extra)

  # What a pipeline left in the test directory, its SafeRm marker aside.
  defp leftovers(dir), do: File.ls!(dir) -- [".fermix-test-root"]

  # No ffmpeg and a backend that hears nothing unless a test says otherwise, so
  # no test reaches this machine's ffmpeg or a real transcription backend.
  defp ingest(declared, opts \\ []) do
    opts = Keyword.merge([ffmpeg: :missing, backend: NoSpeechBackend], opts)
    Attachments.ingest(FileChannel, message(declared), opts)
  end

  # An ffmpeg stub in a directory of its own, so the download directory's
  # cleanup stays observable.
  defp stub_ffmpeg(stub_opts \\ []) do
    stub_dir = SafeRm.make_tmp_dir!("gateway-ffmpeg")
    on_exit(fn -> SafeRm.rm_rf!(stub_dir) end)
    {FakeFfmpeg.write!(stub_dir, stub_opts), stub_dir}
  end

  test "a message with no attachments comes back as it came" do
    msg = message([])
    assert Attachments.ingest(FileChannel, msg, []) == {:ok, msg}
  end

  test "pictures arrive as they came, in album order, and every temp file is removed", %{
    dir: dir
  } do
    declared = [
      file(dir, "m1", Fixtures.png(), %{mime_type: "image/png"}),
      file(dir, "m2", Fixtures.jpeg(), %{mime_type: "image/jpeg"}),
      file(dir, "m3", Fixtures.png(), %{mime_type: "image/png", file_name: "chart.png"})
    ]

    assert {:ok, %Message{inbound_attachments: [first, second, third]} = msg} = ingest(declared)

    assert %Attachment{kind: :still, mime_type: "image/png", status: :ready} = first
    assert first.bytes == Fixtures.png()
    assert second.mime_type == "image/jpeg"
    assert third.name == "chart.png"
    assert msg.content == "look"
    assert leftovers(dir) == []
  end

  test "the bytes beat the mime the platform declared", %{dir: dir} do
    assert {:ok, %{inbound_attachments: [still]}} =
             ingest([file(dir, "p", Fixtures.png(), %{mime_type: "image/jpeg", hint: :photo})])

    assert still.mime_type == "image/png"
  end

  test "an animated GIF reaches the model as its own first frame", %{dir: dir} do
    assert {:ok, %{inbound_attachments: [gif]}} =
             ingest([file(dir, "g", Fixtures.animated_gif(), %{file_name: "spinner.gif"})])

    assert %Attachment{kind: :animation, mime_type: "image/gif", status: :ready} = gif
    assert gif.poster == %{mime_type: "image/gif", bytes: Fixtures.animated_gif_first_frame()}
  end

  test "a video reaches the model as the still its sender made", %{dir: dir} do
    poster = file(dir, "thumb", Fixtures.jpeg(), %{mime_type: "image/jpeg"})

    assert {:ok, %{inbound_attachments: [video]}} =
             ingest([
               file(dir, "v", Fixtures.mp4(), %{
                 mime_type: "video/mp4",
                 hint: :animation,
                 duration_s: 3,
                 poster: poster
               })
             ])

    assert %Attachment{kind: :animation, status: :ready, duration_s: 3} = video
    assert video.poster == %{mime_type: "image/jpeg", bytes: Fixtures.jpeg()}
    assert leftovers(dir) == []
  end

  test "a video with no still is named: it needs ffmpeg", %{dir: dir} do
    assert {:ok, %{inbound_attachments: [video]}} =
             ingest([file(dir, "v", Fixtures.mp4(), %{file_name: "clip.mov"})])

    assert video.status == {:unusable, {:needs_ffmpeg, :video}}
    assert video.name == "clip.mov"
  end

  describe "with ffmpeg installed (D3)" do
    test "a GIF and a video reach the model as frames, read from their own download", %{
      dir: dir
    } do
      {ffmpeg, stub_dir} = stub_ffmpeg()
      poster = file(dir, "thumb", Fixtures.jpeg(), %{mime_type: "image/jpeg"})

      declared = [
        file(dir, "g", Fixtures.animated_gif(), %{file_name: "spinner.gif"}),
        file(dir, "v", Fixtures.mp4(), %{mime_type: "video/mp4", hint: :animation, poster: poster})
      ]

      assert {:ok, %{inbound_attachments: [gif, video]}} = ingest(declared, ffmpeg: ffmpeg)

      assert %Attachment{kind: :animation, status: :ready, poster: nil} = gif
      assert length(gif.frames) == 4
      assert Enum.all?(gif.frames, &(&1.mime_type == "image/jpeg"))
      # One rule per configuration: with ffmpeg, the sender's still is never fetched.
      assert %Attachment{kind: :animation, status: :ready, poster: nil} = video
      assert length(video.frames) == 4

      # A probe and a cut each, every one reading only the download it was handed.
      runs = FakeFfmpeg.runs(stub_dir)
      assert Enum.count(runs, &(&1 =~ " -i #{Path.join(dir, "g")} ")) == 2
      assert Enum.count(runs, &(&1 =~ " -i #{Path.join(dir, "v")} ")) == 2
      assert length(runs) == 4
      assert leftovers(dir) == []
    end

    test "an ffmpeg failure is named, never swapped for the still", %{dir: dir} do
      {ffmpeg, _stub_dir} = stub_ffmpeg(exit_code: 1)
      poster = file(dir, "thumb", Fixtures.jpeg(), %{mime_type: "image/jpeg"})

      capture_log(fn ->
        assert {:ok, %{inbound_attachments: [video]}} =
                 ingest(
                   [file(dir, "v", Fixtures.mp4(), %{hint: :animation, poster: poster})],
                   ffmpeg: ffmpeg
                 )

        assert {:unusable, {:render_failed, {:ffmpeg_exit, 1, words}}} = video.status
        assert words =~ "Invalid data"
        assert video.poster == nil
      end)
    end

    test "an animated WebP keeps the still path: ffmpeg never runs for it", %{dir: dir} do
      {ffmpeg, stub_dir} = stub_ffmpeg()
      webp = <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0x02, 0::24>>

      assert {:ok, %{inbound_attachments: [sticker]}} =
               ingest([file(dir, "s", webp, %{hint: :sticker})], ffmpeg: ffmpeg)

      assert sticker.status == {:unusable, {:no_still, "image/webp"}}
      assert FakeFfmpeg.runs(stub_dir) == []
    end

    test "frames count toward what one message carries inline", %{dir: dir} do
      {ffmpeg, _stub_dir} = stub_ffmpeg()
      pdf = Fixtures.pdf() <> :binary.copy(<<0>>, 20 * @mib - byte_size(Fixtures.pdf()) - 10)

      assert {:ok, %{inbound_attachments: [document, clip]}} =
               ingest(
                 [file(dir, "d", pdf), file(dir, "v", Fixtures.mp4(), %{hint: :animation})],
                 ffmpeg: ffmpeg
               )

      assert document.status == :ready
      assert clip.status == {:unusable, {:turn_full, 20 * @mib}}
    end
  end

  describe "a video's sound (D5)" do
    test "goes to the transcriber as MP4 when its container is MOV or 3GP", %{dir: dir} do
      mov = <<0, 0, 0, 20, "ftypqt  ", 0::32, "qt  ">>
      three_gp = <<0, 0, 0, 20, "ftyp3gp4", 0::32, "3gp4">>

      assert {:ok, %{inbound_attachments: [clip, phone]}} =
               Attachments.ingest(
                 FileChannel,
                 message([
                   file(dir, "m", mov, %{mime_type: "video/quicktime", file_name: "IMG_0042.MOV"}),
                   file(dir, "p", three_gp)
                 ]),
                 ffmpeg: :missing,
                 backend: FormatBackend,
                 test_pid: self()
               )

      assert clip.mime_type == "video/quicktime"
      assert phone.mime_type == "video/3gpp"
      assert_received {:sent_as, ".mp4", "video/mp4"}
      assert_received {:sent_as, ".mp4", "video/mp4"}
      assert clip.sound == {:transcript, "cheers to the crew"}
    end

    test "with ffmpeg, a clip with no sound track is noted and costs no transcription", %{
      dir: dir
    } do
      {ffmpeg, _stub_dir} = stub_ffmpeg(audio: false)

      assert {:ok, %{inbound_attachments: [clip]}} =
               Attachments.ingest(FileChannel, message([file(dir, "v", Fixtures.mp4())]),
                 ffmpeg: ffmpeg,
                 backend: FakeBackend,
                 test_pid: self()
               )

      refute_received {:transcribed, _bytes, _extension}
      assert length(clip.frames) == 4
      assert clip.sound == :no_sound
    end

    test "with ffmpeg, a clip with a sound track is transcribed beside its frames", %{
      dir: dir
    } do
      {ffmpeg, _stub_dir} = stub_ffmpeg(audio: true)

      assert {:ok, %{inbound_attachments: [clip]}} =
               Attachments.ingest(FileChannel, message([file(dir, "v", Fixtures.mp4())]),
                 ffmpeg: ffmpeg,
                 backend: FakeBackend,
                 test_pid: self()
               )

      assert_received {:transcribed, _bytes, ".mp4"}
      assert length(clip.frames) == 4
      assert clip.sound == {:transcript, "book the ferry for the eleventh"}
    end

    test "is transcribed beside its pictures; the caption stays the caption", %{dir: dir} do
      clip = file(dir, "v", Fixtures.mp4(), %{mime_type: "video/mp4", file_name: "toast.mp4"})

      assert {:ok, msg} =
               Attachments.ingest(FileChannel, message([clip], "which take?"),
                 ffmpeg: :missing,
                 backend: FakeBackend,
                 test_pid: self()
               )

      assert_received {:transcribed, _bytes, ".mp4"}
      assert msg.content == "which take?"

      assert [%Attachment{kind: :video, sound: {:transcript, "book the ferry for the eleventh"}}] =
               msg.inbound_attachments
    end

    test "with no speech in it, is a note, not the voice note's reply", %{dir: dir} do
      assert {:ok, %{inbound_attachments: [clip]}} = ingest([file(dir, "v", Fixtures.mp4())])
      assert clip.sound == :no_speech
    end

    test "that cannot be transcribed is named, and the message still runs", %{dir: dir} do
      log =
        capture_log(fn ->
          assert {:ok, %{inbound_attachments: [clip]}} =
                   ingest([file(dir, "v", Fixtures.mp4())], backend: FailingBackend)

          assert clip.sound == {:failed, :not_configured}
        end)

      assert log =~ "The sound of an inbound video could not be transcribed"
    end

    test "carries a message whose pictures could not be read", %{dir: dir} do
      assert {:ok, msg} =
               Attachments.ingest(FileChannel, message([file(dir, "v", Fixtures.mp4())], ""),
                 ffmpeg: :missing,
                 backend: FakeBackend,
                 test_pid: self()
               )

      assert [%Attachment{status: {:unusable, {:needs_ffmpeg, :video}}}] = msg.inbound_attachments
      assert Message.actionable?(msg)
    end

    test "an animation and a sticker are silent: no transcription runs", %{dir: dir} do
      declared = [
        file(dir, "a", Fixtures.mp4(), %{hint: :animation}),
        file(dir, "s", <<0x1A, 0x45, 0xDF, 0xA3, "webm">>, %{hint: :sticker})
      ]

      assert {:ok, %{inbound_attachments: [animation, sticker]}} =
               Attachments.ingest(FileChannel, message(declared),
                 ffmpeg: :missing,
                 backend: FakeBackend,
                 test_pid: self()
               )

      refute_received {:transcribed, _bytes, _extension}
      assert animation.sound == nil
      assert sticker.sound == nil
    end
  end

  test "a PDF and a text file ride as their bytes", %{dir: dir} do
    declared = [
      file(dir, "d", Fixtures.pdf(), %{file_name: "lease.pdf"}),
      file(dir, "t", "Picnic list: DELTA 55", %{file_name: "notes.txt"})
    ]

    assert {:ok, %{inbound_attachments: [pdf, text]}} = ingest(declared)
    assert %Attachment{kind: :document, mime_type: "application/pdf", status: :ready} = pdf
    assert %Attachment{kind: :text, status: :ready, bytes: "Picnic list: DELTA 55"} = text
  end

  test "a file nothing can read, and a picture format no model takes, are named", %{dir: dir} do
    zip = "application/zip"
    heic = <<0, 0, 0, 24, "ftypheic", 0::64>>

    assert {:ok, %{inbound_attachments: [bundle, photo]}} =
             ingest([
               file(dir, "z", <<"PK", 3, 4, 0, 255>>, %{mime_type: zip}),
               file(dir, "h", heic, %{mime_type: "image/heic"})
             ])

    assert bundle.status == {:unusable, {:unknown_type, zip}}
    assert photo.status == {:unusable, {:still_unsupported, "image/heic"}}
  end

  # Review fixes 5 and 13: what is not what it was declared, and moving
  # pictures ffmpeg would not help with, are named for what they are.
  test "an HTML page declared as a PNG is named as not what the channel declared", %{dir: dir} do
    html = "<!doctype html><html><body>Sign in</body></html>"

    assert {:ok, %{inbound_attachments: [page]}} =
             ingest([file(dir, "p", html, %{mime_type: "image/png", hint: :photo})])

    assert page.status == {:unusable, {:not_as_declared, "image/png"}}
  end

  test "an animated WebP with no still is named without pointing at ffmpeg", %{dir: dir} do
    webp = <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0x02, 0::24>>

    assert {:ok, %{inbound_attachments: [sticker]}} =
             ingest([file(dir, "s", webp, %{hint: :sticker})])

    assert sticker.status == {:unusable, {:no_still, "image/webp"}}
  end

  test "a video whose still could not be fetched is named for that", %{dir: dir} do
    video = file(dir, "v", Fixtures.mp4(), %{poster: %{file_id: "boom"}})

    capture_log(fn ->
      assert {:ok, %{inbound_attachments: [clip]}} = ingest([video])
      assert clip.status == {:unusable, {:poster_unavailable, :video, {:download_failed, :boom}}}
    end)
  end

  test "a phone's voice recording in an MP4 container is transcribed, under its own extension", %{
    dir: dir
  } do
    m4a = <<0, 0, 0, 24, "ftypmp42", 0::64>>
    voice = file(dir, "rec", m4a, %{mime_type: "application/octet-stream", hint: :voice})

    assert {:ok, msg} =
             Attachments.ingest(FileChannel, message([voice], ""),
               backend: FakeBackend,
               test_pid: self()
             )

    assert_received {:transcribed, ^m4a, ".mp4"}

    assert [%Attachment{kind: :audio, mime_type: "audio/mp4", status: :transcribed}] =
             msg.inbound_attachments
  end

  describe "caps" do
    test "a declared size past the download cap is refused before any download", %{dir: dir} do
      declared =
        file(dir, "big", "never written", %{size_bytes: 25 * @mib, mime_type: "audio/ogg"})

      assert {:ok, %{inbound_attachments: [big]}} = ingest([declared])
      assert big.status == {:unusable, {:too_large, 25 * @mib, 20 * @mib}}
      assert big.kind == :audio
      assert leftovers(dir) == []
    end

    test "a download with no declared size is measured against the cap", %{dir: dir} do
      assert {:ok, %{inbound_attachments: [big]}} = ingest([file(dir, "undeclared-big", "")])
      assert big.status == {:unusable, {:too_large, 22 * @mib, 20 * @mib}}
      assert leftovers(dir) == []
    end

    test "a channel's own byte cap is named as too large", %{dir: dir} do
      assert {:ok, %{inbound_attachments: [big]}} = ingest([file(dir, "over-cap", "")])
      assert big.status == {:unusable, {:too_large, 21 * @mib, 20 * @mib}}
    end

    test "a picture past 10 MiB is named", %{dir: dir} do
      png = Fixtures.png() <> :binary.copy(<<0>>, 10 * @mib)

      assert {:ok, %{inbound_attachments: [still]}} = ingest([file(dir, "p", png)])
      assert {:unusable, {:too_large, _size, cap}} = still.status
      assert cap == 10 * @mib
    end

    test "what one message carries inline is capped together", %{dir: dir} do
      pdf = Fixtures.pdf() <> :binary.copy(<<0>>, 11 * @mib)

      assert {:ok, %{inbound_attachments: [first, second]}} =
               ingest([file(dir, "a", pdf), file(dir, "b", pdf)])

      assert first.status == :ready
      assert second.status == {:unusable, {:turn_full, 20 * @mib}}
    end

    test "past ten attachments, the rest are named, never fetched", %{dir: dir} do
      declared = for n <- 1..12, do: file(dir, "p#{n}", Fixtures.png())

      assert {:ok, %{inbound_attachments: attachments}} = ingest(declared)
      assert Enum.count(attachments, &(&1.status == :ready)) == 10

      assert Enum.map(Enum.drop(attachments, 10), & &1.status) ==
               List.duplicate({:unusable, {:too_many, 10}}, 2)
    end
  end

  describe "download failures are named, never fail the message" do
    test "one failed download in an album: the others arrive, every temp file is removed", %{
      dir: dir
    } do
      declared = [
        file(dir, "ok1", Fixtures.png()),
        file(dir, "boom", ""),
        file(dir, "ok2", Fixtures.png())
      ]

      log =
        capture_log(fn ->
          assert {:ok, %{inbound_attachments: [ok1, failed, ok2]}} = ingest(declared)
          assert ok1.status == :ready
          assert failed.status == {:unusable, {:download_failed, :boom}}
          assert ok2.status == :ready
        end)

      assert log =~ "Inbound attachment download failed"
      assert leftovers(dir) == []
    end

    test "a download that crashes is named, and the caller lives", %{dir: dir} do
      log =
        capture_log(fn ->
          assert {:ok, %{inbound_attachments: [crashed]}} =
                   ingest([file(dir, "raise", "", %{mime_type: "image/png"})])

          assert crashed.status == {:unusable, {:download_failed, :crashed}}
          assert crashed.kind == :still
        end)

      assert log =~ "Inbound attachment fetch crashed"
    end

    test "a channel with no download_attachment/2 names what it declared" do
      msg = message([%{file_id: "x", mime_type: "image/png"}])

      assert {:ok, %{inbound_attachments: [still]}} =
               Attachments.ingest(NoDownloaderChannel, msg, [])

      assert still.status == {:unusable, {:channel_cannot_fetch, "telegram"}}
    end
  end

  describe "sound" do
    test "audio is transcribed into the content and marked transcribed", %{dir: dir} do
      voice = file(dir, "voice", Fixtures.ogg(), %{mime_type: "audio/ogg", hint: :voice})

      assert {:ok, msg} =
               Attachments.ingest(FileChannel, message([voice], "note this"),
                 backend: FakeBackend,
                 test_pid: self()
               )

      assert_received {:transcribed, bytes, ".ogg"}
      assert bytes == Fixtures.ogg()

      assert msg.content ==
               "note this\n\n[voice note transcript]\nbook the ferry for the eleventh"

      assert msg.metadata.transcription.backend == :fake
      assert [%Attachment{kind: :audio, status: :transcribed}] = msg.inbound_attachments
      assert leftovers(dir) == []
    end

    test "a Telegram video note is speech (M21 D17)", %{dir: dir} do
      note = file(dir, "note", Fixtures.mp4(), %{mime_type: "video/mp4", hint: :video_note})

      assert {:ok, msg} =
               Attachments.ingest(FileChannel, message([note], ""),
                 backend: FakeBackend,
                 test_pid: self()
               )

      assert msg.content == "book the ferry for the eleventh"
      assert [%Attachment{kind: :video, status: :transcribed}] = msg.inbound_attachments
    end

    # Review fix 6: transcription runs in the ingesting process, so its crash is
    # its own, never reported as a failed download.
    test "a crash in transcription is the caller's, never a failed download", %{dir: dir} do
      voice = file(dir, "voice", Fixtures.ogg(), %{mime_type: "audio/ogg"})

      assert_raise RuntimeError, "backend bug", fn ->
        ingest([voice], backend: CrashingBackend)
      end

      assert leftovers(dir) == []
    end

    test "a transcription failure fails the message, so the gateway replies (D14)", %{dir: dir} do
      voice = file(dir, "voice", Fixtures.ogg(), %{mime_type: "audio/ogg"})

      assert {:error, {:transcription_failed, :not_configured}} =
               ingest([voice, file(dir, "p", Fixtures.png())], backend: FailingBackend)

      assert leftovers(dir) == []
    end
  end

  test "one telemetry event per attachment, with its outcome and no bytes", %{dir: dir} do
    test_pid = self()
    handler_id = "attachments-ingest-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :attachment, :ingest],
      fn _event, measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:ingest, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _msg} =
             ingest([
               file(dir, "p", Fixtures.png()),
               file(dir, "boom", "", %{mime_type: "video/mp4"})
             ])

    assert_received {:ingest, %{bytes: png_bytes, rendered_bytes: png_bytes, parts: 1},
                     %{channel: "telegram", kind: :still, outcome: :image, reason: nil}}

    assert_received {:ingest, %{rendered_bytes: 0, parts: 0},
                     %{
                       kind: :video,
                       outcome: :unusable,
                       reason: :download_failed,
                       detail: "{:download_failed, :boom}"
                     }}
  end
end
