defmodule FermixCore.Meetings.Sidecar.Frame do
  @moduledoc """
  Wire codec for the meetbot sidecar protocol v1.

  The transport is an Erlang Port in `{:packet, 4}` mode, so the length prefix
  is the runtime's business and a frame here is always exactly
  `<<type::8, payload::binary>>`:

  - `0x01` control — a UTF-8 JSON object carrying a `"type"` string.
  - `0x02` audio — raw PCM s16le, 16 kHz mono, sidecar → daemon only.

  Pure module, no process and no state. The caps are hard: an oversized,
  odd-length, or unparseable frame is a protocol error the caller must turn
  into a teardown, never a skipped frame — a silently dropped frame desyncs
  the sample clock that speaker attribution is built on.

  Decoding is direction-agnostic (it accepts any known control type in either
  direction) because the direction a message is *legal* in is the consumer's
  invariant, not the codec's; `known_types/1` is what pins that per side.

  The human-readable contract is `priv/meetbot/PROTOCOL.md`, and
  `protocol_contract_test.exs` holds the two together.
  """

  @protocol_version 1

  @control_type 0x01
  @audio_type 0x02

  # 64 KiB of JSON is far past any legitimate control frame (the largest is a
  # 200-entry roster) and 32 KiB of PCM is 1.024 s of audio — both exist so a
  # confused or hostile sidecar cannot make the daemon allocate without bound.
  @max_control_bytes 65_536
  @max_audio_bytes 32_768

  @s2d_types ~w(hello state join_result roster active_speaker chat_posted
                meeting_ended error log pong)

  @d2s_types ~w(join leave ping)

  @type decode_error ::
          {:unknown_frame_type, byte()}
          | {:control_too_large, pos_integer()}
          | {:audio_too_large, pos_integer()}
          | {:audio_odd_bytes, pos_integer()}
          | {:invalid_json, String.t()}
          | {:unknown_control_type, String.t()}
          | :empty_frame

  @doc "The one wire version this daemon speaks. A `hello` declaring anything else is refused."
  @spec protocol_version() :: 1
  def protocol_version, do: @protocol_version

  @doc "Every control `\"type\"` legal in the given direction (`:s2d` = sidecar → daemon)."
  @spec known_types(:s2d | :d2s) :: [String.t()]
  def known_types(:s2d), do: @s2d_types
  def known_types(:d2s), do: @d2s_types

  @doc "Maximum control-frame payload in bytes."
  @spec max_control_bytes() :: pos_integer()
  def max_control_bytes, do: @max_control_bytes

  @doc "Maximum audio-frame payload in bytes."
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  @doc """
  Encodes a control message into a full frame. Raises on a non-map (a caller
  that lost track of what it is sending must not reach the wire).
  """
  @spec encode_control(map()) :: binary()
  def encode_control(msg) when is_map(msg), do: <<@control_type, Jason.encode!(msg)::binary>>

  @doc """
  Decodes one frame into `{:control, map()}` or `{:audio, binary()}`.

  Every failure is typed: the caller tears the sidecar down and reports the
  reason rather than guessing at the bytes.
  """
  @spec decode(binary()) :: {:control, map()} | {:audio, binary()} | {:error, decode_error()}
  def decode(<<>>), do: {:error, :empty_frame}

  def decode(<<@control_type, payload::binary>>) do
    if byte_size(payload) > @max_control_bytes do
      {:error, {:control_too_large, byte_size(payload)}}
    else
      decode_control_payload(payload)
    end
  end

  def decode(<<@audio_type, payload::binary>>) do
    case validate_audio(payload) do
      :ok -> {:audio, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(<<type, _rest::binary>>), do: {:error, {:unknown_frame_type, type}}

  @doc """
  Decodes a control frame, raising `ArgumentError` on any decode error. For
  fixture round-tripping and tests; the runtime path uses `decode/1`.
  """
  @spec decode_control!(binary()) :: map()
  def decode_control!(frame) when is_binary(frame) do
    case decode(frame) do
      {:control, msg} -> msg
      {:audio, _pcm} -> raise ArgumentError, "expected a control frame, got audio"
      {:error, reason} -> raise ArgumentError, "control frame rejected: #{inspect(reason)}"
    end
  end

  @doc "Checks an audio payload against the size and sample-alignment caps."
  @spec validate_audio(binary()) :: :ok | {:error, decode_error()}
  def validate_audio(payload) when is_binary(payload) do
    size = byte_size(payload)

    cond do
      size > @max_audio_bytes -> {:error, {:audio_too_large, size}}
      rem(size, 2) != 0 -> {:error, {:audio_odd_bytes, size}}
      true -> :ok
    end
  end

  defp decode_control_payload(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type} = msg} when is_binary(type) -> known_control(type, msg)
      {:ok, %{}} -> {:error, {:invalid_json, ~s(control frame has no "type" string)}}
      {:ok, _other} -> {:error, {:invalid_json, "control frame is not a JSON object"}}
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp known_control(type, msg) do
    if type in @s2d_types or type in @d2s_types do
      {:control, msg}
    else
      {:error, {:unknown_control_type, type}}
    end
  end
end
