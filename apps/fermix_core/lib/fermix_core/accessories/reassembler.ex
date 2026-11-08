defmodule FermixCore.Accessories.Reassembler do
  @moduledoc """
  Control frames back into control messages (`priv/accessory/PROTOCOL.md`,
  *Reassembly*). A message travels as one `START | END` frame, or as a `START`
  frame, frames with neither flag and an `END` frame, contiguous among the
  sender's control frames. Control frames must arrive in sequence, a message
  stays on one stream, and none passes 8,192 bytes; any break is a fault
  that drops the open message and the expected sequence number, so the next
  control frame starts afresh. A control frame with seq 0 always starts a new
  sequence (a sender that opened the link again), with no fault. Pure.
  """

  import Bitwise

  alias FermixCore.Accessories.Frame

  @start 0x01
  @end_flag 0x02
  @max_message 8_192
  @seq_modulus 4_294_967_296

  defstruct open: nil, last_seq: nil

  @type fault :: :control_seq_gap | :fragment_sequence | :fragment_stream | :control_too_large
  @type t :: %__MODULE__{
          open: {0..65_535, [binary()], non_neg_integer()} | nil,
          last_seq: non_neg_integer() | nil
        }
  @type result ::
          {:more, t()} | {:message, 0..65_535, binary(), t()} | {:fault, fault(), t()}

  @doc "An empty reassembler: a new link, or after a HELLO."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The control message cap."
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message

  @doc """
  Takes the next control frame: more to come, a whole message with its
  stream, or a fault. A frame with seq 0 starts a new sequence: a sender that
  opened the link again numbers its control frames from 0, so any partial
  message and the expected seq are dropped with no fault, and the frame is
  read as the first of the new sequence.
  """
  @spec feed(t(), Frame.t()) :: result()
  def feed(%__MODULE__{}, %Frame{type: :control, seq: 0} = frame),
    do: fragment(%__MODULE__{last_seq: 0}, frame)

  def feed(%__MODULE__{} = reassembler, %Frame{type: :control, seq: seq} = frame) do
    if in_sequence?(reassembler, seq),
      do: fragment(%{reassembler | last_seq: seq}, frame),
      else: fault(:control_seq_gap)
  end

  defp in_sequence?(%__MODULE__{last_seq: nil}, _seq), do: true
  defp in_sequence?(%__MODULE__{last_seq: last}, seq), do: seq == rem(last + 1, @seq_modulus)

  defp fragment(%__MODULE__{open: nil} = reassembler, %Frame{flags: flags} = frame)
       when band(flags, @start ||| @end_flag) == (@start ||| @end_flag),
       do: {:message, frame.stream, frame.payload, reassembler}

  defp fragment(%__MODULE__{open: nil} = reassembler, %Frame{flags: flags} = frame)
       when band(flags, @start) != 0,
       do:
         {:more, %{reassembler | open: {frame.stream, [frame.payload], byte_size(frame.payload)}}}

  defp fragment(%__MODULE__{open: nil}, _frame), do: fault(:fragment_sequence)

  defp fragment(_open, %Frame{flags: flags}) when band(flags, @start) != 0,
    do: fault(:fragment_sequence)

  defp fragment(%__MODULE__{open: {stream, _parts, _size}}, %Frame{stream: other})
       when other != stream,
       do: fault(:fragment_stream)

  defp fragment(%__MODULE__{open: {_stream, _parts, size}}, %Frame{payload: payload})
       when size + byte_size(payload) > @max_message,
       do: fault(:control_too_large)

  defp fragment(%__MODULE__{open: {stream, parts, size}} = reassembler, %Frame{} = frame) do
    parts = [frame.payload | parts]

    if band(frame.flags, @end_flag) != 0,
      do:
        {:message, stream, parts |> Enum.reverse() |> IO.iodata_to_binary(),
         %{reassembler | open: nil}},
      else: {:more, %{reassembler | open: {stream, parts, size + byte_size(frame.payload)}}}
  end

  defp fault(reason), do: {:fault, reason, new()}
end
