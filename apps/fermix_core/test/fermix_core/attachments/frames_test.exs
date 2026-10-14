defmodule FermixCore.Attachments.FramesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Attachments.Frames
  alias FermixTestSupport.FakeFfmpeg
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("attachment-frames")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    input = Path.join(dir, "fermix-telegram-download.mp4")
    File.write!(input, "not really a video")
    %{dir: dir, input: input}
  end

  # The output directory of the cut run: where its first frame was written.
  defp output_dir(dir) do
    dir
    |> FakeFfmpeg.runs()
    |> List.last()
    |> String.split(" ")
    |> Enum.find(&String.ends_with?(&1, "frame1.jpg"))
    |> Path.dirname()
  end

  defp bytes(frames), do: Enum.map(frames, & &1.bytes)

  describe "ffmpeg/1" do
    test "an option names it, or says there is none" do
      assert Frames.ffmpeg(ffmpeg: "/opt/tools/ffmpeg") == {:ok, "/opt/tools/ffmpeg"}
      assert Frames.ffmpeg(ffmpeg: :missing) == :missing
    end

    test "the suite's own configuration has no ffmpeg, whatever this machine has" do
      assert Frames.ffmpeg([]) == :missing
    end
  end

  test "ffmpeg reads a GIF or a video, never an animated WebP or a sticker" do
    assert Frames.reads?("image/gif")
    assert Frames.reads?("video/mp4")
    assert Frames.reads?("video/quicktime")
    refute Frames.reads?("image/webp")
    refute Frames.reads?("application/x-tgsticker")
  end

  describe "extract/3" do
    test "four JPEG frames from the middle of four equal spans of the clip", %{
      dir: dir,
      input: input
    } do
      ffmpeg = FakeFfmpeg.write!(dir, duration: "00:00:04.00")

      assert {:ok, %{frames: frames, audio?: false}} = Frames.extract(input, ffmpeg)
      assert bytes(frames) == ~w(JPEG-frame1.jpg JPEG-frame2.jpg JPEG-frame3.jpg JPEG-frame4.jpg)
      assert Enum.all?(frames, &(&1.mime_type == "image/jpeg"))

      [probe, cut] = FakeFfmpeg.runs(dir)
      assert probe =~ "-nostdin -hide_banner -protocol_whitelist file"
      assert probe =~ "-format_whitelist mov,matroska,gif -i #{input} -t 0 -f null -"

      for seconds <- ~w(0.500 1.500 2.500 3.500) do
        assert cut =~
                 "-protocol_whitelist file -format_whitelist mov,matroska,gif " <>
                   "-noaccurate_seek -ss #{seconds} -i #{input}"
      end

      assert cut =~ "-nostdin"
      assert cut =~ "scale=w='min(1024,iw)':h='min(1024,ih)':force_original_aspect_ratio=decrease"
      # The only file ffmpeg reads is the download it was handed.
      inputs =
        cut
        |> String.split(" ")
        |> Enum.chunk_every(2, 1)
        |> Enum.filter(&match?(["-i", _], &1))

      assert Enum.uniq(inputs) == [["-i", input]]
      refute File.exists?(output_dir(dir))
    end

    # Review fix 1: an accurate seek past the clip's last frame fails ffmpeg's
    # whole run, so a short GIF must seek to the frame before the point.
    test "a clip whose last frame starts before the later points still gives its frames", %{
      dir: dir,
      input: input
    } do
      ffmpeg = FakeFfmpeg.write!(dir, duration: "00:00:01.00", frames: {:first, 2})

      assert {:ok, %{frames: frames}} = Frames.extract(input, ffmpeg)
      assert bytes(frames) == ~w(JPEG-frame1.jpg JPEG-frame2.jpg)
    end

    test "a clip with a sound track says so", %{dir: dir, input: input} do
      ffmpeg = FakeFfmpeg.write!(dir, audio: true)
      assert {:ok, %{audio?: true}} = Frames.extract(input, ffmpeg)
    end

    test "only ffmpeg's own duration line counts, and an absurd one reads as unknown", %{
      dir: dir,
      input: input
    } do
      titled = FakeFfmpeg.write!(dir, title: "Duration: 99:00:00.00", duration: "00:00:04.00")
      assert {:ok, %{frames: [_, _, _, _]}} = Frames.extract(input, titled)
      assert dir |> FakeFfmpeg.runs() |> List.last() =~ "-ss 3.500 -i"

      absurd = FakeFfmpeg.write!(dir, duration: String.duplicate("9", 40) <> ":00:00.00")
      assert {:ok, %{frames: [_]}} = Frames.extract(input, absurd)
      assert dir |> FakeFfmpeg.runs() |> List.last() =~ "-ss 0.000 -i"
    end

    test "a clip whose length ffmpeg cannot tell gives its first frame", %{
      dir: dir,
      input: input
    } do
      ffmpeg = FakeFfmpeg.write!(dir, duration: "N/A")

      assert {:ok, %{frames: [%{bytes: "JPEG-frame1.jpg"}]}} = Frames.extract(input, ffmpeg)
      assert dir |> FakeFfmpeg.runs() |> List.last() =~ "-ss 0.000 -i #{input}"
    end

    test "frames that come out identical are kept once", %{dir: dir, input: input} do
      ffmpeg = FakeFfmpeg.write!(dir, frames: :same)
      assert {:ok, %{frames: [%{bytes: "JPEG-same"}]}} = Frames.extract(input, ffmpeg)
    end

    test "an ffmpeg that fails is named with its exit and its words", %{dir: dir, input: input} do
      ffmpeg = FakeFfmpeg.write!(dir, exit_code: 183)

      assert {:error, {:ffmpeg_exit, 183, words}} = Frames.extract(input, ffmpeg)
      assert words =~ "Invalid data found when processing input"
    end

    test "an ffmpeg that claims success and writes no frame is named", %{
      dir: dir,
      input: input
    } do
      ffmpeg = FakeFfmpeg.write!(dir, frames: :claims_success)

      assert Frames.extract(input, ffmpeg) == {:error, :no_frames}
      refute File.exists?(output_dir(dir))
    end

    test "an ffmpeg that prints more than Fermix reads is named for that", %{
      dir: dir,
      input: input
    } do
      ffmpeg = FakeFfmpeg.write!(dir, flood: 300_000)
      assert {:error, {:output_overflow, _bytes}} = Frames.extract(input, ffmpeg)
    end

    test "an ffmpeg that outlives the budget is stopped and named", %{dir: dir, input: input} do
      ffmpeg = FakeFfmpeg.write!(dir, sleep: 5)

      {elapsed_us, result} = :timer.tc(fn -> Frames.extract(input, ffmpeg, timeout_ms: 300) end)

      assert {:error, {:timeout, _ms}} = result
      assert elapsed_us < 4_000_000
    end
  end
end
