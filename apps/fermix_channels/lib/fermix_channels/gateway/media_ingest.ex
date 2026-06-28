defmodule FermixChannels.Gateway.MediaIngest do
  @moduledoc """
  Ingress materialization for inbound image attachments.

  Sibling to `FermixChannels.Gateway.Transcription` (audio → text): when an
  inbound message carries image attachments and the channel exposes
  `download_attachment/2`, this downloads each image, reads its bytes, and
  attaches neutral `%{type: :image, mime_type, data}` content parts to the
  message's transient `media_parts` field. The core turn runner combines those
  parts with the text caption into the provider request; nothing is persisted
  (turn-local, M14).

  Fail-loud (Code Rule #12): a download/read error returns `{:error, reason}`
  and the turn does not proceed — no degraded, image-less turn is forwarded. A
  channel without a `download_attachment/2` byte path leaves the message
  unchanged (its images are simply not materialized yet — they will be once that
  channel implements the callback).

  This module is `fermix_channels`-side on purpose: byte acquisition calls a
  channel adapter's `download_attachment/2`, and `fermix_core` must not depend on
  `fermix_channels`. Core only ever receives already-materialized parts.
  """

  require Logger

  alias FermixCore.Telemetry

  @type attachment :: map()
  @type message :: map()

  @spec maybe_attach_images(module(), message(), keyword()) ::
          {:ok, message()} | {:error, term()}
  def maybe_attach_images(channel, message, opts \\ [])
      when is_atom(channel) and is_map(message) do
    case {image_attachments(message), downloader?(channel)} do
      {[], _downloader?} ->
        {:ok, message}

      {_images, false} ->
        {:ok, message}

      {images, true} ->
        attach_images(channel, message, images, opts)
    end
  end

  defp attach_images(channel, message, images, opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> do_attach_images(channel, message, images, opts) end)

    emit_media_telemetry(message, result, duration_us, length(images))
    result
  end

  defp do_attach_images(channel, message, images, _opts) do
    images
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
      case materialize_image(channel, message, normalize_attachment(attachment)) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, put_media_parts(message, Enum.reverse(parts))}
      {:error, reason} -> {:error, {:attachment_download_failed, reason}}
    end
  end

  defp materialize_image(channel, message, attachment) do
    with {:ok, path} <- channel.download_attachment(message, attachment) do
      try do
        read_image_part(path, attachment)
      after
        cleanup_download(path)
      end
    end
  end

  defp read_image_part(path, attachment) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, %{type: :image, mime_type: image_mime(attachment), data: bytes}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp image_mime(attachment) do
    case attachment_value(attachment, :mime_type) do
      mime when is_binary(mime) and mime != "" -> mime
      _ -> "application/octet-stream"
    end
  end

  defp image_attachments(message) do
    message
    |> message_value(:attachments)
    |> normalize_attachments()
    |> Enum.filter(&image_attachment?/1)
  end

  defp image_attachment?(attachment) do
    kind = attachment_value(attachment, :kind)
    kind == :image or kind == "image"
  end

  defp downloader?(channel), do: function_exported?(channel, :download_attachment, 2)

  defp put_media_parts(message, parts) do
    Map.put(message, map_key(message, :media_parts), parts)
  end

  defp cleanup_download(path) when is_binary(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Media ingest temp cleanup failed: #{inspect(path)} - #{inspect(reason)}")
        :ok
    end
  end

  defp normalize_attachments(value) when is_list(value), do: value
  defp normalize_attachments(_value), do: []

  defp normalize_attachment(attachment) when is_map(attachment) do
    %{
      kind: attachment_value(attachment, :kind),
      url: attachment_value(attachment, :url),
      mime_type: attachment_value(attachment, :mime_type),
      file_id: attachment_value(attachment, :file_id),
      size_bytes: attachment_value(attachment, :size_bytes)
    }
  end

  defp message_value(message, key) do
    Map.get(message, key) || Map.get(message, Atom.to_string(key))
  end

  defp attachment_value(attachment, key) do
    Map.get(attachment, key) || Map.get(attachment, Atom.to_string(key))
  end

  defp map_key(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> key
      Map.has_key?(map, Atom.to_string(key)) -> Atom.to_string(key)
      map != %{} and Enum.all?(Map.keys(map), &is_binary/1) -> Atom.to_string(key)
      true -> key
    end
  end

  defp emit_media_telemetry(message, result, duration_us, image_count) do
    :telemetry.execute(
      [:fermix, :media_ingest, :message],
      %{duration_us: duration_us, image_count: image_count},
      %{
        channel: message_value(message, :channel),
        status: media_status(result),
        attached?: match?({:ok, _message}, result)
      }
    )
  end

  defp media_status({:ok, _message}), do: :ok
  defp media_status({:error, _reason}), do: :error
end
