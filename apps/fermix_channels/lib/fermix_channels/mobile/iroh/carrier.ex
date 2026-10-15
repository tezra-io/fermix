defmodule FermixChannels.Mobile.Iroh.Carrier do
  @moduledoc """
  The iroh carrier's frames: what a phone and the daemon exchange on an iroh
  stream, and so on a bridge connection after its preamble (mobile
  `PROTOCOL.md`, *The iroh carrier*).

  A frame is a 4-byte big-endian length of what follows, then a type byte and
  its payload: the meetbot sidecar's framing, so the carrier reads it with
  Erlang's `{:packet, 4}` and its `packet_size` bound refuses an oversized frame
  before allocating it. This module sees a frame without its length.

  - `01` a message: one whole Noise message, 1 to 65,535 bytes.
  - `02` a close: a 2-byte big-endian close code and its reason, UTF-8, at most
    123 bytes.

  Pure.
  """

  @message 1
  @close 2
  @max_message_bytes 65_535
  @max_reason_bytes 123

  @doc "The largest frame after its length: a type byte and a whole Noise message."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: 1 + @max_message_bytes

  @doc "A message frame, without its length (the socket's `{:packet, 4}` adds it)."
  @spec message(binary()) :: iodata()
  def message(payload)
      when is_binary(payload) and byte_size(payload) in 1..@max_message_bytes,
      do: [@message, payload]

  @doc """
  A close frame, without its length. A reason longer than 123 bytes is cut at a
  character boundary.
  """
  @spec close(0..65_535, String.t()) :: iodata()
  def close(code, reason) when code in 0..65_535 and is_binary(reason),
    do: [@close, <<code::16-big>>, truncate(reason)]

  @doc "Reads one frame the socket delivered without its length."
  @spec decode(binary()) ::
          {:message, binary()} | {:close, 0..65_535, String.t()} | {:error, term()}
  def decode(<<@message, payload::binary>>)
      when byte_size(payload) in 1..@max_message_bytes,
      do: {:message, payload}

  def decode(<<@close, code::16-big, reason::binary>>)
      when byte_size(reason) <= @max_reason_bytes do
    if String.valid?(reason), do: {:close, code, reason}, else: {:error, :invalid_close_reason}
  end

  def decode(<<type, _rest::binary>>) when type in [@message, @close],
    do: {:error, :invalid_frame_length}

  def decode(<<_type, _rest::binary>>), do: {:error, :unknown_frame_type}
  def decode(<<>>), do: {:error, :empty_frame}

  defp truncate(reason) when byte_size(reason) <= @max_reason_bytes, do: reason

  defp truncate(reason) do
    reason
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme
      if byte_size(next) <= @max_reason_bytes, do: {:cont, next}, else: {:halt, acc}
    end)
  end
end
