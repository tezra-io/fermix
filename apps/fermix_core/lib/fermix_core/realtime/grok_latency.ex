defmodule FermixCore.Realtime.GrokLatency do
  @moduledoc """
  How long the owner of a Grok call waited (M70 §09): from the end of their
  speech to the first audio Grok generated for it, and to the first of it the
  client reported playing.

  The two are kept apart, and apart from a task's own time (its
  `delegation_stop` duration): a slow provider, a slow client and a slow
  backend are different findings, and one number would hide which. Only the
  first reply after each turn counts; a reply that speech did not start (a
  continuation after a result) waits on a task, not on Grok.

  Pure: the session owns the clock. Samples are bounded, and what reaches
  `call_stop` is a count, a median and a maximum, never a timeline.
  """

  @max_samples 256

  @type t :: %__MODULE__{
          turns: non_neg_integer(),
          speech_end_ms: integer() | nil,
          awaiting_play_ms: integer() | nil,
          generation: [non_neg_integer()],
          audible: [non_neg_integer()]
        }

  defstruct turns: 0, speech_end_ms: nil, awaiting_play_ms: nil, generation: [], audible: []

  @doc "A call with no turn yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The owner stopped speaking at `now_ms`: one turn, waiting for its reply."
  @spec speech_ended(t(), integer()) :: t()
  def speech_ended(%__MODULE__{} = latency, now_ms) when is_integer(now_ms),
    do: %{latency | turns: latency.turns + 1, speech_end_ms: now_ms, awaiting_play_ms: nil}

  @doc """
  A response Fermix asked for started: it answers a task's result, so the
  owner's last turn is no longer waiting on it.
  """
  @spec continuation_started(t()) :: t()
  def continuation_started(%__MODULE__{} = latency), do: %{latency | speech_end_ms: nil}

  @doc "Audio went to the client at `now_ms`: the first after a turn is its reply."
  @spec audio_forwarded(t(), integer()) :: t()
  def audio_forwarded(%__MODULE__{speech_end_ms: ended} = latency, now_ms)
      when is_integer(ended) and is_integer(now_ms) do
    %{
      latency
      | generation: sample(latency.generation, now_ms - ended),
        speech_end_ms: nil,
        awaiting_play_ms: ended
    }
  end

  def audio_forwarded(%__MODULE__{} = latency, _now_ms), do: latency

  @doc "The client reported playing some of the reply at `now_ms`."
  @spec audio_played(t(), integer()) :: t()
  def audio_played(%__MODULE__{awaiting_play_ms: ended} = latency, now_ms)
      when is_integer(ended) and is_integer(now_ms),
      do: %{latency | audible: sample(latency.audible, now_ms - ended), awaiting_play_ms: nil}

  def audio_played(%__MODULE__{} = latency, _now_ms), do: latency

  @doc """
  The call's `call_stop` measurements: `user_turns`, and a median and a
  maximum for each latency that has a sample. A latency with none is absent:
  unknown is not zero.
  """
  @spec measurements(t()) :: %{atom() => non_neg_integer()}
  def measurements(%__MODULE__{} = latency) do
    %{user_turns: latency.turns}
    |> Map.merge(summary(:generation_latency_ms, latency.generation))
    |> Map.merge(summary(:audible_latency_ms, latency.audible))
  end

  defp sample(samples, ms), do: Enum.take([max(0, ms) | samples], @max_samples)

  defp summary(_name, []), do: %{}

  defp summary(name, samples) do
    sorted = Enum.sort(samples)

    %{
      :"#{name}_median" => Enum.at(sorted, div(length(sorted), 2)),
      :"#{name}_max" => List.last(sorted)
    }
  end
end
