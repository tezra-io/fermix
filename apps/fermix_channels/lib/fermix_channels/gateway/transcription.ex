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

  @bytes_per_mb 1_024 * 1_024

  # D15: an `:audio` attachment is transcribed whenever the channel can fetch it,
  # regardless of whether the message also carries a caption — the caption is
  # composed with the transcript afterwards (see `compose_content/2`). The old
  # blank-content-only guard is gone.
  @spec maybe_transcribe_message(module(), message(), keyword()) ::
          {:ok, message()} | {:error, term()}
  def maybe_transcribe_message(channel, message, opts \\ [])
      when is_atom(channel) and is_map(message) do
    case {audio_attachment(message), downloader?(channel)} do
      {nil, _downloader?} ->
        {:ok, message}

      {_attachment, false} ->
        {:ok, message}

      {attachment, true} ->
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
    case preflight_cap(attachment, opts) do
      :ok -> download_and_transcribe(channel, message, attachment, opts)
      {:error, reason} -> {:error, {:transcription_failed, reason}}
    end
  end

  defp download_and_transcribe(channel, message, attachment, opts) do
    case channel.download_attachment(message, attachment) do
      {:ok, path} ->
        try do
          transcribe_capped(message, attachment, path, opts)
        after
          cleanup_download(path)
        end

      {:error, reason} ->
        {:error, {:attachment_download_failed, reason}}
    end
  end

  defp transcribe_capped(message, attachment, path, opts) do
    case postflight_cap(path, attachment, opts) do
      :ok -> run_transcription(message, attachment, path, opts)
      {:error, reason} -> {:error, {:transcription_failed, reason}}
    end
  end

  defp run_transcription(message, attachment, path, opts) do
    metadata = transcription_metadata(message, attachment)

    case Transcription.transcribe(path, Keyword.put(opts, :metadata, metadata)) do
      {:ok, text} -> handle_transcription_text(message, text, attachment, backend_name(opts))
      {:error, reason} -> {:error, {:transcription_failed, reason}}
    end
  end

  # File-size cap (M21 §5.2/D-caps; Code Rule #2 — cap behavior is an explicit
  # reply upstream): enforced against the declared size before download when the
  # attachment carries one, otherwise against the written file after download.
  defp preflight_cap(attachment, opts) do
    case attachment_value(attachment, :size_bytes) do
      size when is_integer(size) -> enforce_cap(size, opts)
      _ -> :ok
    end
  end

  defp postflight_cap(path, attachment, opts) do
    case attachment_value(attachment, :size_bytes) do
      size when is_integer(size) -> :ok
      _ -> stat_cap(path, opts)
    end
  end

  defp stat_cap(path, opts) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> enforce_cap(size, opts)
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  defp enforce_cap(size_bytes, opts) do
    cap_mb = max_file_mb(opts)

    if size_bytes > cap_mb * @bytes_per_mb do
      {:error, {:file_too_large, size_mb(size_bytes), cap_mb}}
    else
      :ok
    end
  end

  # The `max_file_mb` opt is a test/DI seam mirroring `backend/1`; production
  # ingress passes `[]`, so `[fermix_core.transcription] max_file_mb` (config) is
  # the single source of truth — not a config overlay (Rule #12).
  defp max_file_mb(opts) do
    Keyword.get_lazy(opts, :max_file_mb, fn ->
      :fermix_core
      |> Application.get_env(:transcription, [])
      |> Keyword.get(:max_file_mb, 20)
    end)
  end

  defp size_mb(bytes), do: Float.round(bytes / @bytes_per_mb, 1)

  # The backend that produced the transcript, recorded as its name atom in
  # provenance. `opts[:backend]` (a module) is the test/DI dispatch seam and
  # reports its own `name/0`; production ingress records the configured active
  # backend name. We reach here only after a successful transcription, so the
  # configured backend resolves — the strict match fails loud otherwise.
  defp backend_name(opts) do
    case Keyword.get(opts, :backend) do
      nil -> configured_backend_name()
      module when is_atom(module) -> module.name()
    end
  end

  defp configured_backend_name do
    {:ok, {name, _module}} = Transcription.active_backend()
    name
  end

  defp put_transcription(message, transcript, attachment, backend) do
    transcription = %{attachment: attachment, backend: backend}
    metadata = normalize_metadata(message_value(message, :metadata))
    metadata = Map.put(metadata, map_key(metadata, :transcription), transcription)
    content = compose_content(message_value(message, :content), transcript)

    message
    |> Map.put(map_key(message, :content), content)
    |> Map.put(map_key(message, :metadata), metadata)
  end

  # D15: the transcript stands alone when the audio arrived without a caption;
  # when a caption accompanied it, the caption stays first and the transcript
  # follows under a labeled delimiter so the model sees both.
  defp compose_content(caption, transcript) do
    if present?(caption) do
      "#{caption}\n\n[voice note transcript]\n#{transcript}"
    else
      transcript
    end
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
