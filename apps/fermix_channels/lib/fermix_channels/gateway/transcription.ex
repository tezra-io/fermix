defmodule FermixChannels.Gateway.Transcription do
  @moduledoc """
  Ingress speech-to-text routing for inbound audio attachments.

  Channels opt in by exposing `download_attachment/2`. When an inbound message
  has no text content but does carry an audio attachment, this downloads the
  attachment, transcribes it through `FermixCore.Transcription`, and forwards
  the normalized text message to the agent while preserving the original
  attachment metadata. The speech-to-text engine itself lives in
  `FermixCore.Transcription`; this module owns the *when/how* of ingress.
  """

  require Logger

  alias FermixCore.Telemetry
  alias FermixCore.Transcription

  @type attachment :: map()
  @type message :: map()

  @spec maybe_transcribe_message(module(), message(), keyword()) ::
          {:ok, message()} | {:error, term()}
  def maybe_transcribe_message(channel, message, opts \\ [])
      when is_atom(channel) and is_map(message) do
    case {present?(message_value(message, :content)), audio_attachment(message),
          downloader?(channel)} do
      {true, _attachment, _downloader?} ->
        {:ok, message}

      {false, nil, _downloader?} ->
        {:ok, message}

      {false, _attachment, false} ->
        {:ok, message}

      {false, attachment, true} ->
        transcribe_message(channel, message, normalize_attachment(attachment), opts)
    end
  end

  defp transcribe_message(channel, message, attachment, opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> do_transcribe_message(channel, message, attachment, opts) end)

    emit_transcription_telemetry(message, result, duration_us)
    result
  end

  defp do_transcribe_message(channel, message, attachment, opts) do
    with {:ok, path} <- channel.download_attachment(message, attachment) do
      try do
        metadata = transcription_metadata(message, attachment)

        case Transcription.transcribe(path, Keyword.put(opts, :metadata, metadata)) do
          {:ok, text} ->
            handle_transcription_text(message, text, attachment, backend(opts))

          {:error, reason} ->
            {:error, {:transcription_failed, reason}}
        end
      after
        cleanup_download(path)
      end
    else
      {:error, reason} -> {:error, {:attachment_download_failed, reason}}
    end
  end

  defp backend(opts), do: Keyword.get(opts, :backend, Transcription.default_backend())

  defp put_transcription(message, text, attachment, backend) do
    transcription = %{attachment: attachment, backend: backend}
    metadata = normalize_metadata(message_value(message, :metadata))

    metadata = Map.put(metadata, map_key(metadata, :transcription), transcription)

    message
    |> Map.put(map_key(message, :content), text)
    |> Map.put(map_key(message, :metadata), metadata)
  end

  defp handle_transcription_text(message, text, attachment, backend) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, {:transcription_failed, :empty_transcription}}
    else
      {:ok, put_transcription(message, trimmed, attachment, backend)}
    end
  end

  defp transcription_metadata(message, attachment) do
    %{
      channel: message_value(message, :channel),
      chat_id: message_value(message, :chat_id),
      sender: message_value(message, :sender),
      message_id: message_value(message, :id),
      attachment: attachment
    }
  end

  defp audio_attachment(message) do
    message
    |> message_value(:attachments)
    |> normalize_attachments()
    |> Enum.find(&audio_attachment?/1)
  end

  defp audio_attachment?(attachment) do
    kind = attachment_value(attachment, :kind)
    kind == :audio or kind == "audio"
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp downloader?(channel), do: function_exported?(channel, :download_attachment, 2)

  defp cleanup_download(path) when is_binary(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Transcription temp file cleanup failed: #{inspect(path)} - #{inspect(reason)}"
        )

        :ok
    end
  end

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_value), do: %{}

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

  defp emit_transcription_telemetry(message, result, duration_us) do
    :telemetry.execute(
      [:fermix, :transcription, :message],
      %{duration_us: duration_us},
      %{
        channel: message_value(message, :channel),
        status: transcription_status(result),
        transcribed?: match?({:ok, _message}, result)
      }
    )
  end

  defp transcription_status({:ok, _message}), do: :ok
  defp transcription_status({:error, _reason}), do: :error
end
