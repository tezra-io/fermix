defmodule FermixCore.Realtime.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol for the local Realtime voice socket.
  """

  alias FermixCore.Realtime.Config

  @client_events ~w(client_hello call_start audio_chunk interrupt mute call_stop)
  @server_events ~w(state audio_delta transcript_delta assistant_text_delta tool_event usage error playback_stop)

  @type event :: %{type: String.t(), payload: map()}

  @spec decode_client_event(String.t(), Config.t()) :: {:ok, event()} | {:error, term()}
  def decode_client_event(line, %Config{} = config) when is_binary(line) do
    with {:ok, decoded} <- decode_json(line),
         {:ok, type} <- fetch_type(decoded),
         :ok <- validate_client_type(type),
         {:ok, payload} <- payload_for(type, decoded, config) do
      {:ok, %{type: type, payload: payload}}
    end
  end

  @spec encode_server_event(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_server_event(type, payload) when is_binary(type) and is_map(payload) do
    if type in @server_events do
      {:ok, Jason.encode!(Map.put(payload, "type", type)) <> "\n"}
    else
      {:error, {:unknown_server_event, type}}
    end
  end

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :invalid_event}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp fetch_type(%{"type" => type}) when is_binary(type) and type != "", do: {:ok, type}
  defp fetch_type(_decoded), do: {:error, :missing_type}

  defp validate_client_type(type) do
    if type in @client_events do
      :ok
    else
      {:error, {:unknown_event, type}}
    end
  end

  defp payload_for("audio_chunk", decoded, config) do
    with {:ok, encoded} <- fetch_audio(decoded),
         {:ok, audio} <- decode_audio(encoded),
         :ok <- validate_audio_size(audio, config.max_chunk_bytes) do
      {:ok, %{"audio" => audio}}
    end
  end

  defp payload_for("interrupt", decoded, _config) do
    case Map.get(decoded, "audio_end_ms") do
      nil -> {:ok, Map.delete(decoded, "type")}
      value when is_integer(value) and value >= 0 -> {:ok, Map.delete(decoded, "type")}
      _other -> {:error, :invalid_audio_end_ms}
    end
  end

  defp payload_for(_type, decoded, _config), do: {:ok, Map.delete(decoded, "type")}

  defp fetch_audio(%{"audio" => audio}) when is_binary(audio) and audio != "", do: {:ok, audio}
  defp fetch_audio(_decoded), do: {:error, :missing_audio}

  defp decode_audio(encoded) do
    case Base.decode64(encoded) do
      {:ok, audio} -> {:ok, audio}
      :error -> {:error, :invalid_audio_base64}
    end
  end

  defp validate_audio_size(audio, max_bytes) do
    size = byte_size(audio)

    if size <= max_bytes do
      :ok
    else
      {:error, {:chunk_too_large, size, max_bytes}}
    end
  end
end
