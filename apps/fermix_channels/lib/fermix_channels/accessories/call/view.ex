defmodule FermixChannels.Accessories.Call.View do
  @moduledoc """
  What the Mac shows of an accessory's call (M91 E3; `priv/management/
  PROTOCOL.md`, *Accessories*, the call): the engine, model and voice the call
  started with, its voice state, who muted it, its newest transcript lines,
  its tasks and its usage. The call's own process folds every engine frame it
  already reads into this view and hands it to its link, whose status the
  Mac's long poll reads, so the Mac observes the call without a second
  microphone, speaker or provider session. Nothing of it is persisted. Pure.

  Bounded: at most 6 lines of at most 400 characters (a longer line keeps its
  end), and the 8 newest tasks with summaries of at most 240.
  """

  @max_lines 6
  @max_line_chars 400
  @max_tasks 8
  @max_summary_chars 240
  @call_states ~w(connecting listening thinking speaking muted reconnecting)
  @task_statuses %{
    "pending" => "running",
    "running" => "running",
    "completed" => "completed",
    "failed" => "failed",
    "cancelled" => "cancelled"
  }

  @type line :: %{speaker: :user | :assistant, text: String.t(), final?: boolean()}
  @type task :: %{
          task: String.t(),
          revision: pos_integer(),
          status: String.t(),
          summary: String.t() | nil,
          in_chat?: boolean()
        }
  @type usage :: %{
          cost_cents: number() | nil,
          voice_seconds: number() | nil,
          accounting: String.t() | nil
        }
  @type t :: %{
          state: String.t() | nil,
          muted_by: :mac | :accessory | nil,
          engine: String.t(),
          model: String.t(),
          voice: String.t(),
          call_uuid: String.t() | nil,
          conversation: String.t() | nil,
          started_at: DateTime.t() | nil,
          transcript: [line()],
          tasks: [task()],
          usage: usage() | nil
        }

  @doc "A call's view before anything happened on it, from the config it started with."
  @spec new(%{engine: String.t(), model: String.t(), voice: String.t()}) :: t()
  def new(%{engine: engine, model: model, voice: voice}) do
    %{
      state: nil,
      muted_by: nil,
      engine: engine,
      model: model,
      voice: voice,
      call_uuid: nil,
      conversation: nil,
      started_at: nil,
      transcript: [],
      tasks: [],
      usage: nil
    }
  end

  @doc "The call was admitted at `at`."
  @spec admitted(t(), DateTime.t()) :: t()
  def admitted(view, %DateTime{} = at), do: %{view | started_at: at}

  @doc "Who muted the call, or nil when it is not muted."
  @spec muted(t(), :mac | :accessory | nil) :: t()
  def muted(view, by) when by in [:mac, :accessory, nil], do: %{view | muted_by: by}

  @doc "The robot's task events, which OpenAI Realtime's tool batches become (D21)."
  @spec task_events(t(), [map()]) :: t()
  def task_events(view, events) when is_list(events) do
    Enum.reduce(events, view, fn event, acc ->
      put_task(acc, event.task, event.revision, event.status, nil, event.in_chat)
    end)
  end

  @doc "One engine frame the call reads; every other frame leaves the view as it was."
  @spec engine(t(), map()) :: t()
  def engine(view, %{type: "state", state: state}) when state in @call_states,
    do: %{view | state: state}

  def engine(view, %{type: "call_ready"} = ready) do
    %{
      view
      | call_uuid: string(Map.get(ready, :call_uuid)),
        conversation: conversation(Map.get(ready, :conversation))
    }
  end

  def engine(view, %{type: "transcript_delta", text: text}) when is_binary(text),
    do: view |> close_lines() |> add_line(:user, text, true)

  def engine(view, %{type: "assistant_text_delta", text: text}) when is_binary(text),
    do: append(view, :assistant, text)

  def engine(view, %{type: "assistant_text_done", text: text}) when is_binary(text),
    do: finish(view, :assistant, text)

  def engine(view, %{type: "caption", speaker: speaker, delta: delta})
      when speaker in ["user", "assistant"] and is_binary(delta),
      do: append(view, String.to_existing_atom(speaker), delta)

  def engine(view, %{type: "task", detached: true}), do: view

  def engine(view, %{type: "task", delegation_id: id, revision: revision, status: status} = frame)
      when is_binary(id) and is_integer(revision) and is_map_key(@task_statuses, status) do
    put_task(
      view,
      id,
      revision,
      Map.fetch!(@task_statuses, status),
      summary(Map.get(frame, :summary)),
      Map.get(frame, :server_seq) != nil
    )
  end

  def engine(view, %{type: "usage"} = usage), do: %{view | usage: usage(view.usage, usage)}
  def engine(view, _frame), do: view

  # -- the transcript ---------------------------------------------------------------

  # The speaker's open line takes the delta; another speaker's, or a final one,
  # starts a new line and closes the one before it.
  defp append(view, speaker, delta) do
    case List.last(view.transcript) do
      %{speaker: ^speaker, final?: false} = line ->
        replace_last(view, %{line | text: tail(line.text <> delta)})

      _other ->
        view |> close_lines() |> add_line(speaker, delta, false)
    end
  end

  defp finish(view, speaker, text) do
    case List.last(view.transcript) do
      %{speaker: ^speaker, final?: false} = line ->
        replace_last(view, %{line | text: tail(text), final?: true})

      _other ->
        view |> close_lines() |> add_line(speaker, text, true)
    end
  end

  defp close_lines(view),
    do: %{view | transcript: Enum.map(view.transcript, &%{&1 | final?: true})}

  defp add_line(view, speaker, text, final?) do
    lines = view.transcript ++ [%{speaker: speaker, text: tail(text), final?: final?}]
    %{view | transcript: Enum.take(lines, -@max_lines)}
  end

  defp replace_last(view, line),
    do: %{view | transcript: List.replace_at(view.transcript, -1, line)}

  defp tail(text) do
    if String.length(text) > @max_line_chars,
      do: String.slice(text, -@max_line_chars, @max_line_chars),
      else: text
  end

  # -- tasks -----------------------------------------------------------------------

  # A task keeps its place; a revision older than the one shown changes nothing.
  defp put_task(view, id, revision, status, summary, in_chat?) do
    task = %{task: id, revision: revision, status: status, summary: summary, in_chat?: in_chat?}

    tasks =
      case Enum.find_index(view.tasks, &(&1.task == id)) do
        nil -> Enum.take(view.tasks ++ [task], -@max_tasks)
        index -> List.update_at(view.tasks, index, &newer(&1, task))
      end

    %{view | tasks: tasks}
  end

  defp newer(%{revision: shown} = old, %{revision: given}) when given < shown, do: old
  defp newer(old, new), do: %{new | summary: new.summary || old.summary}

  defp summary(text) when is_binary(text) and text != "",
    do: String.slice(text, 0, @max_summary_chars)

  defp summary(_absent), do: nil

  # -- usage -----------------------------------------------------------------------

  # Unknown is never zero: a field the frame does not carry keeps what an
  # earlier one said.
  defp usage(previous, frame) do
    previous = previous || %{cost_cents: nil, voice_seconds: nil, accounting: nil}

    %{
      cost_cents:
        number(Map.get(frame, :voice_cost_cents, Map.get(frame, :cost_cents))) ||
          previous.cost_cents,
      voice_seconds: number(Map.get(frame, :voice_seconds)) || previous.voice_seconds,
      accounting: accounting(Map.get(frame, :accounting)) || previous.accounting
    }
  end

  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_value), do: nil

  defp accounting(value) when value in ["complete", "incomplete", "running"], do: value
  defp accounting(_value), do: nil

  defp conversation(value) when value in ["chat", "private"], do: value
  defp conversation(_value), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
