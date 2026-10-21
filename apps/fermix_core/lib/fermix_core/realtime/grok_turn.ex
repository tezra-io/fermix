defmodule FermixCore.Realtime.GrokTurn do
  @moduledoc """
  Where a Grok call's turns stand, and the one arbiter of `response.create`
  (M70 §05).

  Grok runs server VAD: the owner's speech starts and ends responses by
  itself, and a response may carry calls to `fermix_task`. A task's output
  can come back while the owner is speaking, while a reply is still playing,
  or after Grok has already answered something else, so continuing after a
  result is a decision, and exactly one place makes it:

    * **Every call is answered once.** Call ids are remembered for the whole
      call (`@max_remembered_calls`): a repeated event is a duplicate, never a
      second task. Past the bound the call cannot keep that promise and ends
      (`{:exhausted, _}`), rather than forget an id. A response may carry at
      most `@max_calls_per_response` calls; the rest are refused.
    * **A response's outputs go back together.** Its continuation is owed only
      once the response is done and every call it carried has its output, so
      the model never answers with half its results (xAI's parallel-call
      rule).
    * **One answer per result.** A continuation is due only when nothing
      stands in its way: no response in progress, the owner not speaking, no
      VAD response about to start for speech that just ended, and the
      assistant's audio drained on the client. A response Grok starts on its
      own while one is owed hears the outputs too, so it consumes the
      obligation; Fermix never starts a second answer for the same result
      (the M50 race). A requested continuation the provider never started is
      owed again at most `@max_continuation_attempts` times.
    * **An interrupted response stays interrupted.** Its later audio is
      dropped (`fence/2`), and a call it carries is refused rather than run.

  Pure: the session owns the clock, the timers and the wire.
  """

  @max_calls_per_response 8
  @max_remembered_calls 1_024
  @max_continuation_attempts 2
  # Interrupted responses are only read while their tail is in flight.
  @max_fenced 64

  @type t :: %__MODULE__{
          user_speaking?: boolean(),
          vad_pending?: boolean(),
          active: MapSet.t(String.t()),
          responses: %{String.t() => %{calls: MapSet.t(), answered: MapSet.t(), done?: boolean()}},
          seen: MapSet.t(String.t()),
          fenced: [String.t()],
          owed?: boolean(),
          requested: String.t() | nil,
          attempts: non_neg_integer(),
          next_id: pos_integer()
        }

  defstruct user_speaking?: false,
            vad_pending?: false,
            active: MapSet.new(),
            responses: %{},
            seen: MapSet.new(),
            fenced: [],
            # A continuation is owed for results no response has heard yet.
            owed?: false,
            # The continuation asked for and not yet started, by its id.
            requested: nil,
            attempts: 0,
            next_id: 1

  @doc "A call with no turn taken yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Server VAD heard the owner start speaking."
  @spec speech_started(t()) :: t()
  def speech_started(%__MODULE__{} = turn),
    do: %{turn | user_speaking?: true, vad_pending?: false}

  @doc """
  Server VAD heard the owner stop. Its own response for that speech is about
  to start, so no continuation is due until it does or the grace is over.
  """
  @spec speech_stopped(t()) :: t()
  def speech_stopped(%__MODULE__{} = turn),
    do: %{turn | user_speaking?: false, vad_pending?: true}

  @doc "The speech that ended started no response of its own in time."
  @spec vad_grace_over(t()) :: t()
  def vad_grace_over(%__MODULE__{} = turn), do: %{turn | vad_pending?: false}

  @doc """
  A response started. Fermix's own continuation names itself in `metadata`
  (`fermix_continuation`); any other response, Grok's own after speech, hears
  the outputs already given and consumes what was owed.
  """
  @spec response_created(t(), String.t(), map() | nil) :: t()
  def response_created(%__MODULE__{} = turn, response_id, metadata)
      when is_binary(response_id) and (is_map(metadata) or is_nil(metadata)) do
    %{
      turn
      | active: MapSet.put(turn.active, response_id),
        responses: Map.put_new(turn.responses, response_id, response()),
        vad_pending?: false
    }
    |> started(continuation_id(metadata))
  end

  @doc "A response ended; its continuation is owed once its calls are answered."
  @spec response_done(t(), String.t()) :: t()
  def response_done(%__MODULE__{} = turn, response_id) when is_binary(response_id) do
    responses = Map.update(turn.responses, response_id, done(response()), &done/1)
    settle(%{turn | active: MapSet.delete(turn.active, response_id), responses: responses})
  end

  @doc """
  A response carried a call. `:ok` when it is new and is to be run;
  `:duplicate` for an id already seen; `:too_many` when its response already
  carries the most it may (the call still needs its refusal as output);
  `:exhausted` when the call can remember no more ids.
  """
  @spec function_call(t(), String.t(), String.t()) ::
          {:ok | :duplicate | :too_many | :exhausted, t()}
  def function_call(%__MODULE__{} = turn, response_id, call_id)
      when is_binary(response_id) and is_binary(call_id) do
    cond do
      MapSet.member?(turn.seen, call_id) -> {:duplicate, turn}
      MapSet.size(turn.seen) >= @max_remembered_calls -> {:exhausted, turn}
      true -> remember(turn, response_id, call_id)
    end
  end

  @doc "A call's one output was sent."
  @spec answered(t(), String.t()) :: t()
  def answered(%__MODULE__{} = turn, call_id) when is_binary(call_id) do
    case Enum.find(turn.responses, fn {_id, r} -> MapSet.member?(r.calls, call_id) end) do
      {response_id, response} ->
        answered = MapSet.put(response.answered, call_id)

        settle(%{
          turn
          | responses: Map.put(turn.responses, response_id, %{response | answered: answered})
        })

      nil ->
        turn
    end
  end

  @doc """
  Whether Fermix should ask for the continuation now: one is owed, no response
  is in progress or about to start, the owner is not speaking, and the
  client has played everything it was sent (`drained?`).
  """
  @spec due?(t(), boolean()) :: boolean()
  def due?(%__MODULE__{} = turn, drained?) when is_boolean(drained?) do
    turn.owed? and is_nil(turn.requested) and MapSet.size(turn.active) == 0 and
      not turn.user_speaking? and not turn.vad_pending? and drained?
  end

  @doc "The continuation is being asked for: its id rides as `response.metadata`."
  @spec request(t()) :: {String.t(), t()}
  def request(%__MODULE__{owed?: true, requested: nil} = turn) do
    id = "c" <> Integer.to_string(turn.next_id)

    {id,
     %{turn | owed?: false, requested: id, attempts: turn.attempts + 1, next_id: turn.next_id + 1}}
  end

  @doc """
  The requested continuation never started: refused by the provider, or not
  seen in time. Owed again while attempts remain; `:gave_up` after that, the
  results still on the task frames and in the chat.
  """
  @spec request_failed(t()) :: {:retry | :gave_up | :none, t()}
  def request_failed(%__MODULE__{requested: id} = turn) when is_binary(id) do
    if turn.attempts < @max_continuation_attempts,
      do: {:retry, %{turn | owed?: true, requested: nil}},
      else: {:gave_up, %{turn | requested: nil, attempts: 0}}
  end

  def request_failed(%__MODULE__{} = turn), do: {:none, turn}

  @doc "The requested continuation's id, while one is outstanding."
  @spec requested(t()) :: String.t() | nil
  def requested(%__MODULE__{requested: id}), do: id

  @doc "Responses in progress that are not interrupted, for an explicit interrupt to cancel."
  @spec cancellable(t()) :: [String.t()]
  def cancellable(%__MODULE__{} = turn),
    do: turn.active |> MapSet.to_list() |> Enum.reject(&fenced?(turn, &1))

  @doc "Interrupts a response: its later audio is dropped and its calls refused."
  @spec fence(t(), String.t()) :: t()
  def fence(%__MODULE__{} = turn, response_id) when is_binary(response_id) do
    if fenced?(turn, response_id),
      do: turn,
      else: %{turn | fenced: Enum.take([response_id | turn.fenced], @max_fenced)}
  end

  @doc "Whether a response was interrupted."
  @spec fenced?(t(), String.t()) :: boolean()
  def fenced?(%__MODULE__{fenced: fenced}, response_id) when is_binary(response_id),
    do: response_id in fenced

  @doc "Every response in progress, interrupted or not."
  @spec active(t()) :: [String.t()]
  def active(%__MODULE__{active: active}), do: MapSet.to_list(active)

  defp remember(turn, response_id, call_id) do
    response = Map.get(turn.responses, response_id, response())
    over? = MapSet.size(response.calls) >= @max_calls_per_response
    response = %{response | calls: MapSet.put(response.calls, call_id)}

    turn = %{
      turn
      | seen: MapSet.put(turn.seen, call_id),
        responses: Map.put(turn.responses, response_id, response)
    }

    {if(over?, do: :too_many, else: :ok), turn}
  end

  # Fermix's own continuation is fulfilled, and what was owed since it was
  # asked for stays owed. Any other response hears every output already given,
  # so it consumes both what was owed and what was asked for: a requested
  # continuation that still starts is a second answer the provider chose, not
  # one Fermix asks for again.
  defp started(%{requested: id} = turn, id) when is_binary(id),
    do: %{turn | requested: nil, attempts: 0}

  defp started(turn, _other), do: %{turn | owed?: false, requested: nil, attempts: 0}

  # A done response whose every call is answered is finished: it owes a
  # continuation when it carried any call at all.
  defp settle(turn) do
    finished =
      for {id, %{done?: true} = r} <- turn.responses, MapSet.subset?(r.calls, r.answered), do: id

    owed? = Enum.any?(finished, &(MapSet.size(turn.responses[&1].calls) > 0))
    %{turn | responses: Map.drop(turn.responses, finished), owed?: turn.owed? or owed?}
  end

  defp continuation_id(%{"fermix_continuation" => id}) when is_binary(id), do: id
  defp continuation_id(_metadata), do: nil

  defp response, do: %{calls: MapSet.new(), answered: MapSet.new(), done?: false}
  defp done(response), do: %{response | done?: true}
end
