defmodule FermixCore.Accessories.Frame do
  @moduledoc """
  One frame of the accessory link (`priv/accessory/PROTOCOL.md`, *Framing*):
  a 16-byte little-endian header (magic `"FX"`, framing version, type, flags,
  reserved, stream, seq, length), at most 4,096 payload bytes, and a CRC-32
  (IEEE, as `:erlang.crc32/1`) over header and payload, written little-endian.

  `check/2` holds a frame to its type's rules and to the direction it travels;
  the parser runs it on every frame it receives, and `encode/1` refuses to
  write a frame no peer may send. Pure.
  """

  import Bitwise

  @magic "FX"
  @framing_version 1
  @header_bytes 16
  @crc_bytes 4
  @max_payload 4_096
  @mic_bytes 960
  @max_speaker_bytes 3_840
  @max_message 8_192
  @start 0x01
  @end_flag 0x02
  @urgent 0x04

  @codes %{control: 1, mic: 2, speaker: 3, diagnostics: 4}
  @types Map.new(@codes, fn {type, code} -> {code, type} end)
  # The frame types each end sends: the host's parser reads the accessory's,
  # and the firmware's reads the host's.
  @sent_by %{accessory: [:control, :mic, :diagnostics], host: [:control, :speaker]}

  defstruct type: :control, flags: 0, stream: 0, seq: 0, payload: <<>>

  @type frame_type :: :control | :mic | :speaker | :diagnostics
  @type sender :: :host | :accessory
  @type t :: %__MODULE__{
          type: frame_type(),
          flags: 0..7,
          stream: 0..65_535,
          seq: 0..4_294_967_295,
          payload: binary()
        }
  @type fault :: :wrong_direction | :bad_flags | :bad_stream | :bad_length

  @doc "The framing version every frame carries, fixed for this transport."
  @spec framing_version() :: pos_integer()
  def framing_version, do: @framing_version

  @doc "The payload cap of one frame."
  @spec max_payload() :: pos_integer()
  def max_payload, do: @max_payload

  @doc "The header's size."
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc "The largest frame on the wire: header, cap and CRC."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @header_bytes + @max_payload + @crc_bytes

  @doc "The frame type a header's type byte names, or `:error` for one outside the set."
  @spec type(byte()) :: {:ok, frame_type()} | :error
  def type(code) when is_integer(code), do: Map.fetch(@types, code)

  @doc "Whether this sender may send this frame type."
  @spec sent_by?(frame_type(), sender()) :: boolean()
  def sent_by?(type, sender), do: type in Map.fetch!(@sent_by, sender)

  @doc "The wire bytes of a frame. Raises `ArgumentError` for a frame no peer may send."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = frame) do
    case structure(frame) do
      :ok ->
        encode_valid(frame)

      {:error, reason} ->
        raise ArgumentError, "invalid accessory frame (#{reason}): #{inspect(frame, limit: 8)}"
    end
  end

  defp encode_valid(%__MODULE__{} = frame) do
    body =
      <<@magic::binary, @framing_version, Map.fetch!(@codes, frame.type), frame.flags, 0,
        frame.stream::16-little, frame.seq::32-little, byte_size(frame.payload)::32-little,
        frame.payload::binary>>

    <<body::binary, :erlang.crc32(body)::32-little>>
  end

  @doc """
  The rules a frame of its type must keep, travelling from `sender`, in the
  contract's order: `wrong_direction`, `bad_flags`, `bad_stream`, `bad_length`.
  """
  @spec check(t(), sender()) :: :ok | {:error, fault()}
  def check(%__MODULE__{type: type} = frame, sender) when sender in [:host, :accessory] do
    if sent_by?(type, sender), do: type_rules(frame), else: {:error, :wrong_direction}
  end

  defp structure(%__MODULE__{type: type, flags: flags, stream: stream, seq: seq})
       when not is_map_key(@codes, type) or flags not in 0..7 or stream not in 0..65_535 or
              seq not in 0..4_294_967_295,
       do: {:error, :bad_header}

  defp structure(%__MODULE__{payload: payload}) when byte_size(payload) > @max_payload,
    do: {:error, :over_cap}

  defp structure(%__MODULE__{} = frame), do: type_rules(frame)

  defp type_rules(%__MODULE__{type: :control, payload: payload}),
    do: if(payload == <<>>, do: {:error, :bad_length}, else: :ok)

  defp type_rules(%__MODULE__{flags: flags}) when flags != 0, do: {:error, :bad_flags}

  defp type_rules(%__MODULE__{type: :diagnostics, stream: stream}) when stream != 0,
    do: {:error, :bad_stream}

  defp type_rules(%__MODULE__{type: :diagnostics, payload: payload}),
    do: if(payload == <<>>, do: {:error, :bad_length}, else: :ok)

  defp type_rules(%__MODULE__{stream: 0}), do: {:error, :bad_stream}

  defp type_rules(%__MODULE__{type: :mic, payload: payload}),
    do: if(byte_size(payload) == @mic_bytes, do: :ok, else: {:error, :bad_length})

  defp type_rules(%__MODULE__{type: :speaker, payload: payload}) do
    size = byte_size(payload)
    if size in 2..@max_speaker_bytes//2, do: :ok, else: {:error, :bad_length}
  end

  @doc """
  One control payload, at most the 8,192-byte message cap, as the frames that
  carry it: `{flags, chunk}` with `START` on the first, `END` on the last
  (both on a payload that fits one frame), and `URGENT` on each when asked.
  """
  @spec control_fragments(binary(), urgent: boolean()) :: [{0..7, binary()}]
  def control_fragments(payload, urgent: urgent?)
      when is_binary(payload) and payload != <<>> and byte_size(payload) <= @max_message and
             is_boolean(urgent?) do
    chunks = chunk(payload, [])
    last = length(chunks) - 1
    urgent = if urgent?, do: @urgent, else: 0

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, i} -> {fragment_flags(i, last) ||| urgent, chunk} end)
  end

  defp fragment_flags(0, 0), do: @start ||| @end_flag
  defp fragment_flags(0, _last), do: @start
  defp fragment_flags(last, last), do: @end_flag
  defp fragment_flags(_middle, _last), do: 0

  defp chunk(<<chunk::binary-size(@max_payload), rest::binary>>, acc) when rest != <<>>,
    do: chunk(rest, [chunk | acc])

  defp chunk(rest, acc), do: Enum.reverse([rest | acc])
end
