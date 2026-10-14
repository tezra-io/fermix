defmodule FermixTestSupport.FakeFfmpeg do
  @moduledoc """
  Test-only `sh` stub standing in for ffmpeg (M67 D3), so no test depends on
  whether the machine has ffmpeg, either way. Every behaviour is baked into the
  script as a shell literal, and each one follows what the real ffmpeg does.

  `write!/2` writes the stub under `dir` (a SafeRm tmp dir the caller owns) and
  returns its absolute path. Each run appends its argv, one line, to
  `argv_log/1`. The probe run (`-f null`) describes its input the way ffmpeg
  does; the cut run writes each `.jpg` output it is given. Options:

    * `:duration` — what follows `Duration:` (default `"00:00:04.00"`);
    * `:title` — a metadata title printed above the duration line, the way
      ffmpeg lists a file's tags first (default none);
    * `:audio` — whether the input lists an audio stream (default `false`);
    * `:frames` — `:distinct` (each output its own bytes, the default), `:same`
      (every output the same bytes), `{:first, n}` (a clip whose last frame
      starts before the later seek points: an accurate seek past it gets no
      frame, and like ffmpeg the whole run then fails with exit 234; with
      `-noaccurate_seek` those outputs get the last frame), or
      `:claims_success` (exits 0 and writes nothing);
    * `:exit_code` — every run's exit code (default `0`); non-zero prints an
      ffmpeg-like error first;
    * `:flood` — bytes of output the probe prints before its description
      (default `0`);
    * `:sleep` — seconds every run waits before answering (default `0`).
  """

  @spec write!(String.t(), keyword()) :: String.t()
  def write!(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    path = Path.join(dir, "ffmpeg-stub-#{System.unique_integer([:positive])}")
    File.write!(path, script(dir, opts))
    File.chmod!(path, 0o755)
    path
  end

  @doc "Each run's argv, in order, one string per run."
  @spec runs(String.t()) :: [String.t()]
  def runs(dir) when is_binary(dir) do
    case File.read(argv_log(dir)) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  @spec argv_log(String.t()) :: String.t()
  def argv_log(dir) when is_binary(dir), do: Path.join(dir, "ffmpeg-argv.log")

  defp script(dir, opts) do
    exit_code = Keyword.get(opts, :exit_code, 0)

    """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{argv_log(dir)}'
    sleep #{Keyword.get(opts, :sleep, 0)}
    if [ #{exit_code} -ne 0 ]; then
      echo 'stub: Invalid data found when processing input' >&2
      exit #{exit_code}
    fi
    case " $* " in
      *" -f null "*)
    #{probe(opts)}
        exit 0 ;;
    esac
    noaccurate=0
    case " $* " in *" -noaccurate_seek "*) noaccurate=1 ;; esac
    index=0
    for arg in "$@"; do
      case "$arg" in
        *.jpg)
          index=$((index + 1))
    #{frame(Keyword.get(opts, :frames, :distinct))} ;;
      esac
    done
    exit 0
    """
  end

  defp probe(opts) do
    flood = Keyword.get(opts, :flood, 0)
    title = Keyword.get(opts, :title)
    duration = Keyword.get(opts, :duration, "00:00:04.00")

    [
      if(flood > 0, do: "    yes x | head -c #{flood} >&2"),
      "    printf 'Input #0, mov,mp4,m4a,3gp,3g2,mj2, from x:\\n  Metadata:\\n' >&2",
      if(title, do: "    printf '    title           : #{title}\\n' >&2"),
      "    printf '  Duration: #{duration}, start: 0.000000, bitrate: 9 kb/s\\n' >&2",
      "    printf '  Stream #0:0[0x1](und): Video: h264 (High), yuv420p, 640x320\\n' >&2",
      if(Keyword.get(opts, :audio, false),
        do: "    printf '  Stream #0:1[0x2](und): Audio: aac (LC), 44100 Hz, mono\\n' >&2"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp frame(:distinct), do: ~S|      printf 'JPEG-%s' "${arg##*/}" > "$arg"|
  defp frame(:same), do: ~S|      printf 'JPEG-same' > "$arg"|
  defp frame(:claims_success), do: "      :"

  defp frame({:first, count}) when is_integer(count) and count >= 1 do
    """
          if [ $index -le #{count} ]; then
            printf 'JPEG-%s' "${arg##*/}" > "$arg"
          elif [ $noaccurate -eq 1 ]; then
            printf 'JPEG-frame#{count}.jpg' > "$arg"
          else
            echo "[out#$index/image2] Nothing was written into output file, because at least one of its streams received no packets." >&2
            exit 234
          fi\
    """
  end
end
