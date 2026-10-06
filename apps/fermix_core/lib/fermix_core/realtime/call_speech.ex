defmodule FermixCore.Realtime.CallSpeech do
  @moduledoc """
  What was said on a Live call, for the whole call (M56 §4.2, §4.4).

  `LiveTranscript` keeps the newest 128 fragments, tens of seconds, for the
  request a hand-off sends. A typed chat turn that asks what was said on the
  call (`voice_call_context`), and the gist a call leaves, need the whole call,
  so the session keeps this buffer beside it: every transcript delta, verbatim,
  joined into speaker runs in the order they arrived, rendered as the hand-off
  request is (`user: ...`, `assistant: ...`, one run a line).

  It lives in the session's memory only and is never written. A call is bounded
  by its max duration, and the buffer by 32 KB: past it the oldest text gives
  way behind the cut marker `LiveText.tail/2` uses, a byte at a time and never
  inside a character, so every run it keeps still names its speaker.
  """

  alias FermixCore.Realtime.LiveText

  @max_bytes 32_768
  @marker_bytes byte_size(LiveText.cut_marker())

  @type speaker :: :user | :assistant

  @typedoc """
  `runs` oldest first, each `{speaker, text}`; `bytes` the rendered size of the
  runs, the marker apart; `cut?` once older text was dropped.
  """
  @type t :: %__MODULE__{
          runs: :queue.queue({speaker(), String.t()}),
          bytes: non_neg_integer(),
          cut?: boolean()
        }

  defstruct runs: :queue.new(), bytes: 0, cut?: false

  @doc "A call that has said nothing yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether nothing has been said on the call."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{runs: runs}), do: :queue.is_empty(runs)

  @doc "The bound on what `text/1` renders, the marker included."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Append one verbatim transcript delta: to the newest run when its speaker
  spoke last, as a new run otherwise. An empty delta changes nothing.
  """
  @spec append(t(), speaker(), String.t()) :: t()
  def append(%__MODULE__{} = speech, speaker, delta)
      when speaker in [:user, :assistant] and is_binary(delta) do
    if delta == "", do: speech, else: speech |> add(speaker, delta) |> bound(@max_bytes)
  end

  @doc "Everything held, speaker labelled, behind the marker when older text was cut."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = speech), do: render(speech)

  @doc """
  The newest `max_bytes` of what was said, cut from the front the way the
  buffer itself is: a reader's view, the buffer unchanged.
  """
  @spec text(t(), pos_integer()) :: String.t()
  def text(%__MODULE__{} = speech, max_bytes)
      when is_integer(max_bytes) and max_bytes > @marker_bytes do
    speech |> bound(max_bytes) |> render()
  end

  defp add(%__MODULE__{} = speech, speaker, delta) do
    case :queue.peek_r(speech.runs) do
      {:value, {^speaker, text}} ->
        runs = :queue.in({speaker, text <> delta}, :queue.drop_r(speech.runs))
        %{speech | runs: runs, bytes: speech.bytes + byte_size(delta)}

      _other_speaker_or_empty ->
        separator = if :queue.is_empty(speech.runs), do: 0, else: 1
        runs = :queue.in({speaker, delta}, speech.runs)
        %{speech | runs: runs, bytes: speech.bytes + separator + run_bytes({speaker, delta})}
    end
  end

  # The marker's room is always kept, so a cut never pushes the render past
  # the bound. Bounded: each pass drops a run or ends.
  defp bound(%__MODULE__{} = speech, max_bytes) do
    overflow = speech.bytes - (max_bytes - @marker_bytes)

    if overflow <= 0, do: speech, else: drop_oldest(speech, overflow, max_bytes)
  end

  defp drop_oldest(speech, overflow, max_bytes) do
    {{:value, {speaker, text} = oldest}, rest} = :queue.out(speech.runs)

    if overflow < byte_size(text) or :queue.is_empty(rest) do
      kept = trim_front(text, overflow)
      runs = :queue.in_r({speaker, kept}, rest)

      %{
        speech
        | runs: runs,
          bytes: speech.bytes - (byte_size(text) - byte_size(kept)),
          cut?: true
      }
    else
      dropped = %{speech | runs: rest, bytes: speech.bytes - run_bytes(oldest) - 1, cut?: true}
      bound(dropped, max_bytes)
    end
  end

  # At least `count` bytes off the front, then the rest of a character a cut
  # landed inside.
  defp trim_front(text, count) when count >= byte_size(text), do: ""

  defp trim_front(text, count),
    do: drop_partial_codepoint(binary_part(text, count, byte_size(text) - count))

  defp drop_partial_codepoint(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_codepoint(rest)

  defp drop_partial_codepoint(text), do: text

  defp render(%__MODULE__{runs: runs, cut?: cut?}) do
    lines = runs |> :queue.to_list() |> Enum.map_join("\n", &run_line/1)
    if cut?, do: LiveText.cut_marker() <> lines, else: lines
  end

  defp run_line({speaker, text}), do: label(speaker) <> text
  defp run_bytes({speaker, text}), do: byte_size(label(speaker)) + byte_size(text)
  defp label(speaker), do: Atom.to_string(speaker) <> ": "
end
