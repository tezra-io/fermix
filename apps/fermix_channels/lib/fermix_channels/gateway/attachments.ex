defmodule FermixChannels.Gateway.Attachments do
  @moduledoc """
  The one ingress pipeline for inbound attachments (M67).

  Every channel declares what its platform gave it (`t:FermixCore.Attachments.declared/0`)
  and nothing else. For each declared attachment this pipeline:

    1. fetches it through the channel's `download_attachment/2` — at most
       `@max_attachments` per message, `@download_concurrency` at a time, under
       the `@max_download_bytes` cap, declared or measured — into a temp file it
       removes on every path;
    2. names its kind from the bytes (`FermixCore.Attachments.Kind`);
    3. renders it by kind: a picture as it came; a GIF, animation or video as one
       still (a GIF file's first frame, else the still the sender made); a PDF
       and a text file as their bytes; anything else is named unusable;
    4. caps what rides the turn inline at `@max_inline_bytes`;
    5. transcribes audio and a Telegram video note (M21 D17) through
       `Gateway.Transcription`, one after another, in this process.

  The result is `Message.inbound_attachments`: turn-local, never persisted. The
  turn composes the manifest and the content parts from it. An attachment that
  cannot be read is never dropped: it stays in the list under
  `{:unusable, reason}`, and either the turn's manifest or the gateway's reply
  names it (D4). A transcription failure keeps its fail-loud reply (D14): the
  pipeline returns `{:error, {:transcription_failed, reason}}` and no turn runs.

  `fermix_channels`-side on purpose: fetching calls a channel adapter, and
  `fermix_core` must not depend on `fermix_channels`. Core only ever receives
  rendered attachments.
  """

  require Logger

  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Transcription
  alias FermixCore.Attachments, as: Attachment
  alias FermixCore.Attachments.GifFrame
  alias FermixCore.Attachments.Kind
  alias FermixCore.Attachments.Telemetry, as: AttachmentTelemetry
  alias FermixCore.Telemetry

  # An album's ceiling (`AlbumBuffer`'s default part count).
  @max_attachments 10
  # Telegram's getFile ceiling, and the phone's default upload cap.
  @max_download_bytes 20 * 1024 * 1024
  # Anthropic's per-picture limit; `view_image` keeps the same.
  @max_still_bytes 10 * 1024 * 1024
  # Every picture, still and PDF of one message together: base64 grows it by a
  # third, which keeps a request under Anthropic's 32 MB.
  @max_inline_bytes 20 * 1024 * 1024
  # Parallel enough to collapse an album's latency toward its slowest download,
  # capped so a channel's file API is never hammered.
  @download_concurrency 4
  # The picture formats every picture-reading model takes; Fermix converts none.
  @provider_stills ~w(image/jpeg image/png image/webp image/gif)

  @doc """
  Fetch, classify and render the message's declared attachments into
  `inbound_attachments`, composing any transcript into its content. A message
  that declares none is returned as it came.
  """
  @spec ingest(module(), Message.t(), keyword()) ::
          {:ok, Message.t()} | {:error, {:transcription_failed, term()}}
  def ingest(channel, %Message{attachments: []} = message, opts)
      when is_atom(channel) and is_list(opts),
      do: {:ok, message}

  def ingest(channel, %Message{attachments: declared} = message, opts)
      when is_atom(channel) and is_list(declared) and is_list(opts) do
    {taken, over} = Enum.split(declared, @max_attachments)
    over = Enum.map(over, &{undownloaded(&1, {:too_many, @max_attachments}), &1, 0})
    settled = fit_turn(fetch_all(channel, message, taken) ++ over)

    with {:ok, message, settled} <- transcribe_all(message, settled, opts) do
      Enum.each(settled, &emit_ingest(message.channel, &1))
      {:ok, %{message | inbound_attachments: Enum.map(settled, &elem(&1, 0))}}
    end
  end

  # Album downloads are independent fetches, so they run concurrently and
  # bounded. `async_stream_nolink` keeps a raise inside a channel's download from
  # taking the caller down (the AlbumBuffer holds other conversations' parts);
  # `timeout: :infinity` because each HTTP fetch is bounded by its client, and a
  # stream timeout would kill a slow download before its temp file is removed;
  # the stream is drained whole, so every task runs its own cleanup.
  defp fetch_all(channel, message, declared) do
    FermixCore.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      declared,
      fn one -> Telemetry.timed_us(fn -> fetch_and_render(channel, message, one) end) end,
      max_concurrency: @download_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.zip(declared)
    |> Enum.map(&settle/1)
  end

  defp settle({{:ok, {attachment, duration_us}}, declared}),
    do: {attachment, declared, duration_us}

  defp settle({{:exit, reason}, declared}) do
    Logger.error(
      "Inbound attachment fetch crashed: " <>
        inspect(reason, limit: 20, printable_limit: 200)
    )

    {undownloaded(declared, {:download_failed, :crashed}), declared, 0}
  end

  defp fetch_and_render(channel, message, declared) do
    ctx = %{channel: channel, message: message, declared: declared}

    with :ok <- preflight(declared),
         {:ok, path} <- download(ctx, declared) do
      try do
        render_download(ctx, path)
      after
        cleanup(path)
      end
    else
      {:unusable, reason} -> undownloaded(declared, reason)
    end
  end

  defp preflight(declared) do
    case MediaDownload.value(declared, :size_bytes) do
      size when is_integer(size) and size > @max_download_bytes ->
        {:unusable, {:too_large, size, @max_download_bytes}}

      _within_or_unknown ->
        :ok
    end
  end

  defp download(%{channel: channel, message: message}, declared) do
    if function_exported?(channel, :download_attachment, 2),
      do: downloaded(channel.download_attachment(message, declared), channel),
      else: {:unusable, {:channel_cannot_fetch, message.channel}}
  end

  defp downloaded({:ok, path}, _channel) when is_binary(path), do: {:ok, path}

  defp downloaded({:error, {:byte_cap_exceeded, size, cap}}, _channel),
    do: {:unusable, {:too_large, size, cap}}

  defp downloaded({:error, reason}, channel) do
    Logger.warning(
      "Inbound attachment download failed on #{inspect(channel)}: " <>
        inspect(reason, limit: 20, printable_limit: 200)
    )

    {:unusable, {:download_failed, reason}}
  end

  defp render_download(ctx, path) do
    case read_capped(path) do
      {:ok, bytes} -> ctx.declared |> downloaded_attachment(bytes) |> render(ctx)
      {:unusable, reason} -> undownloaded(ctx.declared, reason)
    end
  end

  # A channel's declared size can be absent (WhatsApp) and its own cap higher
  # than this one, so the downloaded file is measured before it is read.
  defp read_capped(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- within_download_cap(size),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:unusable, _reason} = unusable -> unusable
      {:error, reason} -> {:unusable, {:download_failed, {:read_failed, reason}}}
    end
  end

  defp within_download_cap(size) when size > @max_download_bytes,
    do: {:unusable, {:too_large, size, @max_download_bytes}}

  defp within_download_cap(_size), do: :ok

  # Audio and a Telegram video note are transcribed after every download, in
  # this process (see `transcribe_all/3`).
  defp render(%Attachment{} = att, ctx) do
    cond do
      transcribe?(att) -> att
      att.kind in [:animation, :video] -> still_without_ffmpeg(att, ctx)
      att.kind == :still -> still(att)
      att.kind in [:document, :text] -> att
      Kind.signed?(att.mime_type) -> unusable(att, {:not_as_declared, att.mime_type})
      true -> unusable(att, {:unknown_type, att.mime_type})
    end
  end

  # M21 D17: a Telegram video note is speech, transcribed whatever its container.
  # Stage 2 gives every video its sound too, beside its frames.
  defp transcribe?(%Attachment{status: :ready, hint: :video_note}), do: true
  defp transcribe?(%Attachment{status: :ready, kind: :audio}), do: true
  defp transcribe?(%Attachment{}), do: false

  # D2/D3: a moving picture reaches the model as one still. A GIF file gives its
  # own first frame, cut from its blocks; any other gives the still its sender
  # made (a channel thumbnail, the phone's `poster_of`); with neither, the
  # manifest or the reply names why. Stage 2 puts ffmpeg's frames ahead of this
  # when ffmpeg is installed.
  defp still_without_ffmpeg(%Attachment{mime_type: "image/gif"} = att, _ctx) do
    case GifFrame.first(att.bytes) do
      {:ok, frame} -> %{att | poster: %{mime_type: "image/gif", bytes: frame}}
      :error -> unusable(att, {:no_still, att.mime_type})
    end
  end

  defp still_without_ffmpeg(att, ctx) do
    case MediaDownload.value(ctx.declared, :poster) do
      %{} = poster -> fetch_poster(att, poster, ctx)
      _none -> unusable(att, no_still(att))
    end
  end

  # ffmpeg reads a video's frames; an animated picture (WebP, a TGS sticker)
  # it does not help with.
  defp no_still(%Attachment{mime_type: "video/" <> _container} = att),
    do: {:needs_ffmpeg, att.kind}

  defp no_still(%Attachment{mime_type: mime}), do: {:no_still, mime}

  defp fetch_poster(att, poster, ctx) do
    case poster_still(poster, ctx) do
      {:ok, still} -> %{att | poster: still}
      {:unusable, reason} -> unusable(att, {:poster_unavailable, att.kind, reason})
    end
  end

  defp poster_still(poster, ctx) do
    with {:ok, path} <- download(ctx, poster) do
      try do
        read_poster(path, poster)
      after
        cleanup(path)
      end
    end
  end

  defp read_poster(path, declared) do
    with {:ok, bytes} <- read_capped(path),
         %Attachment{status: :ready} = still <- still(downloaded_attachment(declared, bytes)) do
      {:ok, %{mime_type: still.mime_type, bytes: bytes}}
    else
      %Attachment{status: {:unusable, reason}} -> {:unusable, reason}
      {:unusable, _reason} = unusable -> unusable
    end
  end

  defp still(%Attachment{kind: :still, mime_type: mime} = att) when mime not in @provider_stills,
    do: unusable(att, {:still_unsupported, mime})

  defp still(%Attachment{kind: :still, size_bytes: size} = att) when size > @max_still_bytes,
    do: unusable(att, {:too_large, size, @max_still_bytes})

  defp still(%Attachment{kind: :still} = att), do: att

  defp still(%Attachment{} = att), do: unusable(att, {:still_unsupported, att.mime_type})

  # What rides the turn inline is capped as a whole: an attachment that would
  # pass the cap is named instead of sent.
  defp fit_turn(settled) do
    {fitted, _used} = Enum.map_reduce(settled, 0, &fit/2)
    fitted
  end

  defp fit({att, declared, duration_us}, used) do
    bytes = inline_bytes(att)

    if bytes > 0 and used + bytes > @max_inline_bytes,
      do: {{unusable(att, {:turn_full, @max_inline_bytes}), declared, duration_us}, used},
      else: {{att, declared, duration_us}, used + bytes}
  end

  defp inline_bytes(%Attachment{status: :ready, kind: kind, poster: %{bytes: bytes}})
       when kind in [:animation, :video],
       do: byte_size(bytes)

  defp inline_bytes(%Attachment{status: :ready, kind: kind, bytes: bytes})
       when kind in [:still, :document],
       do: byte_size(bytes)

  defp inline_bytes(%Attachment{}), do: 0

  # Transcription runs here, after the downloads, so its failure keeps its own
  # reply (D14): the first one, in attachment order, fails the message.
  defp transcribe_all(message, settled, opts) do
    settled
    |> Enum.reduce_while({:ok, message, []}, fn entry, {:ok, msg, acc} ->
      case transcribe_entry(msg, entry, opts) do
        {:ok, msg, entry} -> {:cont, {:ok, msg, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, message, settled} -> {:ok, message, Enum.reverse(settled)}
      error -> error
    end
  end

  defp transcribe_entry(message, {att, declared, duration_us} = entry, opts) do
    if transcribe?(att) do
      with {:ok, transcript} <- transcribe(message, att, declared, opts) do
        transcribed = {%{att | status: :transcribed}, declared, duration_us}
        {:ok, Transcription.put_transcript(message, transcript), transcribed}
      end
    else
      {:ok, message, entry}
    end
  end

  # The audio goes to the backend in a temp file named for the mime its bytes
  # were classified as, which is the format a hosted backend reads.
  defp transcribe(message, att, declared, opts) do
    case MediaDownload.write_temp(att.bytes, "transcription", %{mime_type: att.mime_type}) do
      {:ok, path} ->
        try do
          Transcription.transcribe(message, declared, path, opts)
        after
          cleanup(path)
        end

      {:error, reason} ->
        {:error, {:transcription_failed, reason}}
    end
  end

  defp emit_ingest(channel, {att, _declared, duration_us}),
    do: AttachmentTelemetry.emit_ingest(channel, att, duration_us)

  defp downloaded_attachment(declared, bytes) do
    {kind, mime} = Kind.classify(declared, bytes)
    %{attachment(declared, kind, mime) | size_bytes: byte_size(bytes), bytes: bytes}
  end

  # An attachment that never reached a byte: its kind and mime come from what
  # the channel declared, so the manifest and the reply can still name it.
  defp undownloaded(declared, reason) do
    {kind, mime} = Kind.declared(declared)
    unusable(attachment(declared, kind, mime), reason)
  end

  defp attachment(declared, kind, mime) do
    %Attachment{
      kind: kind,
      mime_type: mime,
      name: MediaDownload.value(declared, :file_name),
      size_bytes: MediaDownload.value(declared, :size_bytes),
      duration_s: MediaDownload.value(declared, :duration_s),
      hint: MediaDownload.value(declared, :hint)
    }
  end

  defp unusable(%Attachment{} = att, reason), do: %{att | status: {:unusable, reason}}

  defp cleanup(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Inbound attachment temp cleanup failed: #{inspect(path)} - #{inspect(reason)}"
        )

        :ok
    end
  end
end
