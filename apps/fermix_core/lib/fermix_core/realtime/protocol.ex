defmodule FermixCore.Realtime.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol for the local Realtime voice socket.

  This module is the single source of truth for the wire contract between the
  daemon and the FermixPet companion. The canonical, machine-readable export of
  the contract lives beside it under `priv/realtime/` (`PROTOCOL.md`,
  `protocol.schema.json`, and the golden `fixtures/*.jsonl`); a downstream
  consumer such as `fermix-macos` vendors those pinned by checksum instead of
  hand-copying the shapes. `protocol_contract_test.exs` asserts the exports
  never drift from the values below.

  ## Versioning

  A connection opens with a mandatory handshake: the client sends `client_hello`
  carrying its `protocol_version`; the daemon replies `server_hello` with the
  inclusive `{min_version, max_version}` range it supports (an N/N-1 window — the
  current version and the previous one). Each side connects only if its version
  falls inside the other's range; otherwise it refuses and reports which side
  must update. See `PROTOCOL.md` for the state machine and the rollout order.
  """

  alias FermixCore.Realtime.Config

  # Bumped in lockstep with any wire-shape change. The supported range is an
  # N/N-1 window derived from this single constant, so a bump automatically
  # keeps accepting the previous version for one release.
  @protocol_version 1
  @min_supported_version max(1, @protocol_version - 1)

  @client_events ~w(client_hello call_start audio_chunk interrupt mute call_stop)
  @server_events ~w(server_hello state audio_delta transcript_delta assistant_text_delta tool_event usage error playback_stop)

  @type event :: %{type: String.t(), payload: map()}

  @doc "The daemon's current wire protocol version."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Inclusive `{min, max}` protocol versions the daemon accepts (an N/N-1 window)."
  @spec supported_version_range() :: {pos_integer(), pos_integer()}
  def supported_version_range, do: {@min_supported_version, @protocol_version}

  @doc "The client event names this protocol accepts."
  @spec client_events() :: [String.t()]
  def client_events, do: @client_events

  @doc "The server event names this protocol emits."
  @spec server_events() :: [String.t()]
  def server_events, do: @server_events

  @doc """
  Negotiate a client's `protocol_version` against the daemon's supported range.

  Returns `:ok` when the client is in range, `{:error, :client_too_old}` when the
  client must update, and `{:error, :client_too_new}` when the daemon must update.
  """
  @spec negotiate(integer()) :: :ok | {:error, :client_too_old | :client_too_new}
  def negotiate(client_version) when is_integer(client_version) do
    {min, max} = supported_version_range()

    cond do
      client_version < min -> {:error, :client_too_old}
      client_version > max -> {:error, :client_too_new}
      true -> :ok
    end
  end

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

  defp payload_for("client_hello", decoded, _config) do
    case Map.get(decoded, "protocol_version") do
      version when is_integer(version) and version > 0 ->
        {:ok, %{"protocol_version" => version}}

      nil ->
        {:error, :missing_protocol_version}

      _other ->
        {:error, :invalid_protocol_version}
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
