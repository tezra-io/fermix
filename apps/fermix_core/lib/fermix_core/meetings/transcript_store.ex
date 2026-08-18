defmodule FermixCore.Meetings.TranscriptStore do
  @moduledoc """
  Owns one meeting's artifact directory and the files inside it.

  Layout under `<FERMIX_HOME>/workspace/meetings/<meeting_id>/` — inside the
  workspace sandbox floor, so the agent's own file tools can read the notes back:

    * `transcript.jsonl` — one attributed segment per line, appended live
    * `audio.raw` — 16 kHz mono s16le, written ONLY when `retain_audio: true`
    * `transcript.md` + `meta.json` — rendered once, by `finalize/2`

  `summary.md` is written by the Session after the summarizer returns, not here.

  The file descriptors belong to the calling process (the Session). `finalize/2`
  closes them on every path, its own errors included; `close/1` is the abort path
  that closes without rendering. The directory is `0700` and every file `0600` —
  a meeting transcript is as sensitive as a harness run artifact.
  """

  alias FermixCore.Setup.ConfigStore

  @dir_mode 0o700
  @file_mode 0o600
  @meeting_id_regex ~r/\A[A-Za-z0-9_-]+\z/

  defstruct [:dir, :jsonl, :audio, segments: 0, words: 0]

  @opaque t :: %__MODULE__{
            dir: Path.t(),
            jsonl: :file.io_device(),
            audio: :file.io_device() | nil,
            segments: non_neg_integer(),
            words: non_neg_integer()
          }

  @doc """
  Creates the meeting's artifact directory and opens `transcript.jsonl` for append.

  Options: `:retain_audio` (only the literal `true` opens `audio.raw`) and `:root`
  — the workspace root, injected by tests; production resolves it from
  `ConfigStore.workspace_paths/0`. Any filesystem error fails loud.
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(meeting_id, opts \\ []) when is_binary(meeting_id) and is_list(opts) do
    with :ok <- validate_meeting_id(meeting_id),
         dir = Path.join([root(opts), "meetings", meeting_id]),
         :ok <- ensure_dir(dir),
         {:ok, jsonl} <- open_append(Path.join(dir, "transcript.jsonl")),
         {:ok, audio} <- open_audio(dir, retain_audio?(opts), jsonl) do
      {:ok, %__MODULE__{dir: dir, jsonl: jsonl, audio: audio}}
    end
  end

  @doc "The meeting's artifact directory (the Session records it on the meetings row)."
  @spec dir(t()) :: Path.t()
  def dir(%__MODULE__{dir: dir}), do: dir

  @doc """
  Appends one attributed segment as a JSON line and advances the counters.
  """
  @spec append(t(), map()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = store, %{t0_ms: t0_ms, t1_ms: t1_ms, speaker: speaker, text: text})
      when is_integer(t0_ms) and t0_ms >= 0 and is_integer(t1_ms) and t1_ms >= 0 and
             is_binary(speaker) and is_binary(text) do
    entry = %{t0_ms: t0_ms, t1_ms: t1_ms, speaker: speaker, text: text}

    # `:file.write/2`, not `IO.binwrite/2`: the latter RAISES on a closed device,
    # and a write that lost its descriptor must reach the Session as an error it
    # can record, not as a crash of the meeting.
    with {:ok, json} <- Jason.encode_to_iodata(entry),
         :ok <- :file.write(store.jsonl, [json, "\n"]) do
      {:ok, %{store | segments: store.segments + 1, words: store.words + word_count(text)}}
    end
  end

  @doc "Appends raw capture audio; a no-op when `retain_audio` was not requested."
  @spec append_audio(t(), binary()) :: {:ok, t()} | {:error, term()}
  def append_audio(%__MODULE__{audio: nil} = store, pcm) when is_binary(pcm), do: {:ok, store}

  def append_audio(%__MODULE__{} = store, pcm) when is_binary(pcm) do
    case :file.write(store.audio, pcm) do
      :ok -> {:ok, store}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Closes the descriptors and renders `transcript.md` + `meta.json`.

  `meta` is written through verbatim with `segments`/`words` merged in. The
  descriptors close on every path, including a render failure.
  """
  @spec finalize(t(), map()) ::
          {:ok, %{dir: Path.t(), segments: non_neg_integer(), words: non_neg_integer()}}
          | {:error, term()}
  def finalize(%__MODULE__{} = store, meta) when is_map(meta) do
    # Closed up front so the appended JSONL is flushed before it is read back for
    # the markdown render; the `after` is the guarantee for a raising render.
    close_devices(store)

    with {:ok, entries} <- read_entries(store.dir),
         :ok <- write_markdown(store.dir, meta, entries),
         :ok <- write_meta(store.dir, meta, store) do
      {:ok, %{dir: store.dir, segments: store.segments, words: store.words}}
    end
  after
    close_devices(store)
  end

  @doc "Abort path: closes the descriptors without rendering anything."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = store), do: close_devices(store)

  # --- Private ---

  defp root(opts) do
    Keyword.get_lazy(opts, :root, fn -> ConfigStore.workspace_paths().workspace end)
  end

  defp retain_audio?(opts), do: Keyword.get(opts, :retain_audio, false) == true

  defp validate_meeting_id(meeting_id) do
    if Regex.match?(@meeting_id_regex, meeting_id) do
      :ok
    else
      {:error, {:invalid_meeting_id, meeting_id}}
    end
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, @dir_mode)
    end
  end

  defp open_append(path) do
    case File.open(path, [:append, :binary]) do
      {:ok, io} -> chmod_or_close(path, io)
      {:error, reason} -> {:error, {:transcript_open_failed, path, reason}}
    end
  end

  defp chmod_or_close(path, io) do
    case File.chmod(path, @file_mode) do
      :ok ->
        {:ok, io}

      {:error, reason} ->
        File.close(io)
        {:error, {:transcript_open_failed, path, reason}}
    end
  end

  defp open_audio(_dir, false, _jsonl), do: {:ok, nil}

  defp open_audio(dir, true, jsonl) do
    case open_append(Path.join(dir, "audio.raw")) do
      {:ok, io} ->
        {:ok, io}

      {:error, reason} ->
        File.close(jsonl)
        {:error, reason}
    end
  end

  defp close_devices(store) do
    Enum.each([store.jsonl, store.audio], fn
      nil -> :ok
      io -> File.close(io)
    end)
  end

  defp read_entries(dir) do
    path = Path.join(dir, "transcript.jsonl")

    case File.read(path) do
      {:ok, content} -> decode_lines(content)
      {:error, reason} -> {:error, {:transcript_read_failed, path, reason}}
    end
  end

  defp decode_lines(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} -> {:halt, {:error, {:invalid_transcript_line, line}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_markdown(dir, meta, entries) do
    body = Enum.map(entries, &segment_line/1)
    write_file(Path.join(dir, "transcript.md"), ["# ", heading(meta), "\n\n" | body])
  end

  defp segment_line(%{"t0_ms" => t0_ms, "speaker" => speaker, "text" => text}) do
    ["**[", clock(t0_ms), "] ", speaker, ":** ", text, "\n"]
  end

  defp heading(meta) do
    case blank_to_nil(Map.get(meta, :title)) do
      nil -> to_string(Map.get(meta, :url, ""))
      title -> title
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp write_meta(dir, meta, store) do
    counted = Map.merge(meta, %{segments: store.segments, words: store.words})

    case Jason.encode(counted, pretty: true) do
      {:ok, json} -> write_file(Path.join(dir, "meta.json"), [json, "\n"])
      {:error, reason} -> {:error, {:meta_encode_failed, reason}}
    end
  end

  defp write_file(path, iodata) do
    with :ok <- File.write(path, iodata) do
      File.chmod(path, @file_mode)
    end
  end

  defp clock(t0_ms) do
    seconds = div(t0_ms, 1_000)

    [div(seconds, 3_600), rem(div(seconds, 60), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  defp word_count(text), do: length(String.split(text))
end
