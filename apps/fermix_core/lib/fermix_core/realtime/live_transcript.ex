defmodule FermixCore.Realtime.LiveTranscript do
  @moduledoc """
  The rolling, timestamped transcript of one Live call.

  Live's delegation event carries an id and an offset — no task text. The only
  description of what the operator actually asked for is this buffer, so it is
  what a delegation's request is built from.

  Fragments are stored VERBATIM. Live's transcript deltas already carry their
  own spacing, so trimming a fragment or inserting a separator corrupts the
  sentence the backend is about to act on ("book the room" becomes "booktheroom"
  or "book  the  room"). Speaker, `start_ms` and `end_ms` are kept because user
  and assistant speech overlap and a delegation is scoped by time, not by turn.

  The buffer is bounded to the most recent 128 fragments: a call runs for
  minutes and a delegation only ever reads a recent window, so an unbounded
  buffer would grow for nothing.
  """

  @max_fragments 128

  # A delegation is created a moment AFTER the speech that caused it, and the
  # transcript delta for that speech may still be in flight. A user fragment
  # that ended within this much of the delegation offset is the sentence being
  # delegated; nothing at all within it means the request has no context yet.

  @type speaker :: :user | :assistant

  @type fragment :: %{
          speaker: speaker(),
          delta: String.t(),
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer()
        }

  @type t :: %__MODULE__{fragments: [fragment()]}

  defstruct fragments: []

  @doc "An empty transcript."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Append one verbatim transcript delta. Newest fragments win the bound."
  @spec append(t(), speaker(), String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def append(%__MODULE__{} = transcript, speaker, delta, start_ms, end_ms)
      when speaker in [:user, :assistant] and is_binary(delta) and
             is_integer(start_ms) and start_ms >= 0 and
             is_integer(end_ms) and end_ms >= 0 do
    fragment = %{speaker: speaker, delta: delta, start_ms: start_ms, end_ms: end_ms}
    %{transcript | fragments: Enum.take([fragment | transcript.fragments], @max_fragments)}
  end

  @doc "The fragments held right now, oldest first."
  @spec fragments(t()) :: [fragment()]
  def fragments(%__MODULE__{fragments: fragments}), do: Enum.reverse(fragments)

  @doc """
  Speaker-labelled text for everything that ended inside
  `[offset_ms - window_ms, ∞)`, ordered by `start_ms`.

  Consecutive fragments from the same speaker are concatenated verbatim into one
  line, so the backend reads sentences rather than syllables.
  """
  @spec context_since(t(), non_neg_integer(), pos_integer()) :: String.t()
  def context_since(%__MODULE__{} = transcript, offset_ms, window_ms)
      when is_integer(offset_ms) and offset_ms >= 0 and is_integer(window_ms) and window_ms > 0 do
    transcript
    |> fragments()
    |> Enum.filter(&(&1.end_ms >= offset_ms - window_ms))
    |> Enum.sort_by(& &1.start_ms)
    |> Enum.chunk_by(& &1.speaker)
    |> Enum.map_join("\n", &format_run/1)
  end

  @doc "When the operator last stopped speaking, or `nil` if they never did."
  @spec latest_user_end_ms(t()) :: non_neg_integer() | nil
  def latest_user_end_ms(%__MODULE__{fragments: fragments}) do
    fragments
    |> Enum.filter(&(&1.speaker == :user))
    |> Enum.map(& &1.end_ms)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  True when the operator's speech reaches the delegation: some user fragment
  ends inside the `window_ms` before `offset_ms` — the same window the request
  is built from, so a delegation that has context to read is one that can be
  submitted. Live raises a delegation seconds after the sentence that asked for
  it (observed live: a task delegated a few seconds after the operator stopped
  speaking, which a two-second lookback refused as "did not catch that"), so
  the lookback is the request window, not a guess about model latency.

  A delegation with no user speech behind it has nothing to act on, and guessing
  a consequential operation from a partial sentence is exactly what this gate
  exists to prevent.
  """
  @spec sufficient?(t(), non_neg_integer(), pos_integer()) :: boolean()
  def sufficient?(%__MODULE__{} = transcript, offset_ms, window_ms)
      when is_integer(offset_ms) and offset_ms >= 0 and is_integer(window_ms) and window_ms > 0 do
    case latest_user_end_ms(transcript) do
      nil -> false
      end_ms -> end_ms >= offset_ms - window_ms
    end
  end

  defp format_run([%{speaker: speaker} | _rest] = run) do
    Atom.to_string(speaker) <> ": " <> Enum.map_join(run, & &1.delta)
  end
end
