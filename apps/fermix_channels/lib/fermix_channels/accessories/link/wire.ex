defmodule FermixChannels.Accessories.Link.Wire do
  @moduledoc """
  The host's sending side of one accessory link (`priv/accessory/PROTOCOL.md`,
  *Framing*, *Sequence numbers*): a control message as the frames that carry
  it, and a speaker PCM frame, each numbered by its type's own counter. The
  counters start at `0` when the host opens the port and are never reset by
  a HELLO, so they belong to the port's lifetime, not the attach's. Pure.
  """

  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.Frame

  @seq_modulus 4_294_967_296
  @max_speaker_bytes 3_840

  defstruct control: 0, speaker: 0

  @type t :: %__MODULE__{control: non_neg_integer(), speaker: non_neg_integer()}

  @doc "Counters for a port just opened."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A control message's wire bytes, `URGENT` on every frame when asked, and the
  counters after them. A message `Control.encode/2` refuses comes back as its
  error: it is the host's own bug, never sent.
  """
  @spec control(t(), Control.message(), boolean()) ::
          {:ok, iodata(), t()} | {:error, Control.error()}
  def control(%__MODULE__{} = wire, %{type: _type} = message, urgent?) when is_boolean(urgent?) do
    with {:ok, json} <- Control.encode(:host, message) do
      stream = Control.stream(message)

      {frames, wire} =
        json
        |> Frame.control_fragments(urgent: urgent?)
        |> Enum.map_reduce(wire, fn {flags, chunk}, acc ->
          frame = %Frame{
            type: :control,
            flags: flags,
            stream: stream,
            seq: acc.control,
            payload: chunk
          }

          {Frame.encode(frame), %{acc | control: next(acc.control)}}
        end)

      {:ok, frames, wire}
    end
  end

  @doc "One speaker PCM frame on a call's stream: even, 2 to 3,840 bytes."
  @spec speaker(t(), 1..65_535, binary()) :: {:ok, binary(), t()} | {:error, :bad_speaker_frame}
  def speaker(%__MODULE__{} = wire, stream, pcm)
      when stream in 1..65_535 and is_binary(pcm) and byte_size(pcm) in 2..@max_speaker_bytes//2 do
    frame = %Frame{type: :speaker, stream: stream, seq: wire.speaker, payload: pcm}
    {:ok, Frame.encode(frame), %{wire | speaker: next(wire.speaker)}}
  end

  def speaker(%__MODULE__{}, _stream, _pcm), do: {:error, :bad_speaker_frame}

  defp next(seq), do: rem(seq + 1, @seq_modulus)
end
