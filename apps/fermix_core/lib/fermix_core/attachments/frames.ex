defmodule FermixCore.Attachments.Frames do
  @moduledoc """
  A GIF's or a video's frames, read by an `ffmpeg` already installed (M67 D3).

  Fermix adds no package and bundles nothing. `ffmpeg/1` looks the binary up on
  the daemon's `PATH`, which carries Homebrew's folder (`Boot.PathBaseline`),
  once per message with attachments, so installing it works on the next
  message. Found, `extract/3` reads up to four frames spread over the clip,
  scaled down to a 1024 px long edge, as JPEG. Missing, the gateway gives the
  model the still the sender made or a GIF's first frame: that is the other
  configuration, not a fallback, and an ffmpeg failure is named rather than
  swapped for it (Rule 12).

  ffmpeg parses files from anyone who can message Fermix, so it runs bounded:
  `-nostdin`, its one input the attachment's own download in Fermix's temp
  folder, opened with `-protocol_whitelist file` and a demuxer allowlist
  (`-format_whitelist mov,matroska,gif`, so no playlist or concat file can open
  another file on the machine), its output a fresh temp directory removed on
  every path, through `FermixCore.CommandRunner` under one 20-second budget
  that kills the process group when it runs out.

  Two runs: one probe reads the clip's duration, and whether it has a sound
  track, from what ffmpeg prints about its input; then one run seeks to the
  middle of each of four equal spans and writes a frame from each. The seek
  lands on the frame showing at that point (`-noaccurate_seek`): an accurate
  seek past the start of a short clip's last frame finds nothing to decode, and
  ffmpeg then fails the whole run. A clip whose duration ffmpeg cannot tell
  gives its first frame. Frames that come out byte-identical (a two-frame GIF)
  are kept once.
  """

  require Logger

  alias FermixCore.Attachments
  alias FermixCore.CommandRunner

  @max_frames 4
  @long_edge 1024
  @timeout_ms 20_000
  @jpeg_quality "3"
  @max_detail 200
  # ffmpeg's description of a file is a few KB; past this its output is not
  # read, and the run is named for it.
  @max_output_bytes 256 * 1024

  @input_options ["-protocol_whitelist", "file", "-format_whitelist", "mov,matroska,gif"]
  @scale "scale=w='min(#{@long_edge},iw)':h='min(#{@long_edge},ih)':" <>
           "force_original_aspect_ratio=decrease"

  @typedoc """
  Where ffmpeg comes from: `:path` looks it up on `PATH` (the default), `:missing`
  says there is none. The `:fermix_core, :ffmpeg` app env takes only these two,
  and only the test config sets it (`:missing`), so no test depends on the
  machine having ffmpeg or not. The `:ffmpeg` option may also name a binary by
  its absolute path, which is how a test hands over its stub.
  """
  @type source :: :path | :missing | String.t()

  @typedoc "What `extract/3` read: the frames, and whether the clip has a sound track."
  @type extracted :: %{frames: [Attachments.still(), ...], audio?: boolean()}

  @doc "The ffmpeg this message uses, or `:missing`."
  @spec ffmpeg(keyword()) :: {:ok, String.t()} | :missing
  def ffmpeg(opts) when is_list(opts) do
    case Keyword.get_lazy(opts, :ffmpeg, &configured_source/0) do
      :path -> on_path(System.find_executable("ffmpeg"))
      :missing -> :missing
      path when is_binary(path) and path != "" -> {:ok, path}
    end
  end

  @doc """
  Whether ffmpeg reads this moving picture's frames: a GIF or a video container.
  An animated WebP or a TGS sticker keeps the still its sender made either way.
  """
  @spec reads?(String.t()) :: boolean()
  def reads?("image/gif"), do: true
  def reads?("video/" <> _container), do: true
  def reads?(mime) when is_binary(mime), do: false

  @doc """
  Up to four JPEG frames spread over the clip at `input`, read by the
  ffmpeg at `ffmpeg`. `timeout_ms:` overrides the whole run's budget.

  The input is a file in Fermix's own temp folder and the output a temp
  directory it makes, so ffmpeg touches no location macOS guards with a privacy
  prompt: it is spawned like the shell tool's commands, through CommandRunner,
  with no disclaim shim. A failure is `{:error, detail}`: `{:ffmpeg_exit, code,
  words}` (the exit code and the tail of what ffmpeg printed), `{:timeout, ms}`,
  `{:output_overflow, bytes}` (ffmpeg printed more than Fermix reads, so its
  answer is not trusted), or `:no_frames` (it claimed success and wrote none).
  """
  @spec extract(String.t(), String.t(), keyword()) :: {:ok, extracted()} | {:error, term()}
  def extract(input, ffmpeg, opts \\ [])
      when is_binary(input) and is_binary(ffmpeg) and is_list(opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @timeout_ms)

    case make_temp_dir() do
      {:ok, dir} -> extract_into(dir, input, ffmpeg, deadline)
      {:error, _reason} = error -> error
    end
  end

  defp extract_into(dir, input, ffmpeg, deadline) do
    with {:ok, described} <- probe(ffmpeg, input, deadline),
         points = seek_points(described.duration),
         {:ok, _output} <- run(ffmpeg, cut_args(input, dir, points), deadline),
         {:ok, frames} <- read_frames(dir, length(points)) do
      {:ok, %{frames: frames, audio?: described.audio?}}
    end
  after
    remove_temp_dir(dir)
  end

  defp configured_source do
    case Application.get_env(:fermix_core, :ffmpeg, :path) do
      source when source in [:path, :missing] ->
        source

      other ->
        raise ArgumentError,
              "config :fermix_core, :ffmpeg must be :path or :missing, got: #{inspect(other)}"
    end
  end

  defp on_path(nil), do: :missing
  defp on_path(path), do: {:ok, path}

  # ffmpeg prints the input's description, duration and streams included, and
  # writes nothing for an output of length zero.
  defp probe(ffmpeg, input, deadline) do
    args =
      ["-nostdin", "-hide_banner" | @input_options] ++
        ["-i", input, "-t", "0", "-f", "null", "-"]

    with {:ok, output} <- run(ffmpeg, args, deadline) do
      {:ok, %{duration: duration(output), audio?: audio?(output)}}
    end
  end

  # ffmpeg's own line, two spaces in, bounded: a file's tags print above it and
  # can say anything.
  defp duration(output) do
    case Regex.run(~r/^  Duration: (\d{1,6}):(\d{2}):(\d{2}(?:\.\d{1,6})?)/m, output) do
      [_line, hours, minutes, seconds] ->
        String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
          parse_seconds(seconds)

      nil ->
        :unknown
    end
  end

  defp parse_seconds(seconds) do
    {value, ""} = Float.parse(seconds)
    value
  end

  defp audio?(output), do: Regex.match?(~r/^  Stream #\d+:\d+\S*: Audio: /m, output)

  # The middle of each of the equal spans: never the black first
  # frame nor past the last one.
  defp seek_points(seconds) when is_number(seconds) and seconds > 0,
    do: for(span <- 0..(@max_frames - 1), do: seconds * (2 * span + 1) / (2 * @max_frames))

  defp seek_points(_unknown_or_zero), do: [0.0]

  defp cut_args(input, dir, points) do
    inputs =
      Enum.flat_map(points, fn point ->
        @input_options ++
          ["-noaccurate_seek", "-ss", :erlang.float_to_binary(point / 1, decimals: 3)] ++
          ["-i", input]
      end)

    outputs =
      points
      |> Enum.with_index()
      |> Enum.flat_map(fn {_point, index} ->
        ["-map", "#{index}:v:0", "-frames:v", "1", "-vf", @scale, "-q:v", @jpeg_quality] ++
          [frame_path(dir, index + 1)]
      end)

    ["-nostdin", "-hide_banner", "-loglevel", "error", "-n" | inputs] ++ outputs
  end

  defp run(ffmpeg, args, deadline) do
    case CommandRunner.run(ffmpeg, args,
           timeout_ms: remaining(deadline),
           max_output_bytes: @max_output_bytes
         ) do
      {:ok, %{truncated?: true}} -> {:error, {:output_overflow, @max_output_bytes}}
      {:ok, %{exit: 0, stdout: output}} -> {:ok, output}
      {:ok, %{exit: code, stdout: output}} -> {:error, {:ffmpeg_exit, code, tail(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  # The frames ffmpeg wrote, in span order; a run that exited 0 having written
  # none is named, never taken as success.
  defp read_frames(dir, count) do
    1..count
    |> Enum.map(&File.read(frame_path(dir, &1)))
    |> Enum.reduce_while({:ok, []}, &keep_frame/2)
    |> distinct_frames()
  end

  defp keep_frame({:ok, ""}, acc), do: {:cont, acc}

  defp keep_frame({:ok, bytes}, {:ok, frames}),
    do: {:cont, {:ok, [%{mime_type: "image/jpeg", bytes: bytes} | frames]}}

  defp keep_frame({:error, :enoent}, acc), do: {:cont, acc}
  defp keep_frame({:error, reason}, _acc), do: {:halt, {:error, {:frame_read_failed, reason}}}

  defp distinct_frames({:ok, []}), do: {:error, :no_frames}

  defp distinct_frames({:ok, frames}),
    do: {:ok, frames |> Enum.reverse() |> Enum.uniq_by(& &1.bytes)}

  defp distinct_frames({:error, _reason} = error), do: error

  defp frame_path(dir, number), do: Path.join(dir, "frame#{number}.jpg")

  # Owner-only, like every other inbound copy: the frames are the sender's.
  defp make_temp_dir do
    suffix = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "fermix-frames-" <> suffix)

    case File.mkdir(dir) do
      :ok -> owner_only(dir)
      {:error, reason} -> {:error, {:temp_dir_failed, reason}}
    end
  end

  defp owner_only(dir) do
    case File.chmod(dir, 0o700) do
      :ok ->
        {:ok, dir}

      {:error, reason} ->
        remove_temp_dir(dir)
        {:error, {:temp_dir_failed, reason}}
    end
  end

  defp remove_temp_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.error("Frames temp cleanup failed: #{inspect(path)} - #{inspect(reason)}")
        :ok
    end
  end

  defp tail(output) do
    output = String.trim(output)
    size = byte_size(output)
    binary_part(output, max(size - @max_detail, 0), min(size, @max_detail))
  end
end
