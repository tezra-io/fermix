defmodule FermixCore.Realtime.CallRow do
  @moduledoc """
  The chat rows a Live call in the chat writes about itself, rendered in one
  place: the one row it leaves when it ends (M56 §4.2, D4), and the two rows
  of a task that outlives it (§4.6).

  The ended row is rendered from the call's record as the memory database
  holds it, so the row written as the gist settles and the row a boot writes
  for a daemon that died first are the same row: one read path, whatever the
  record holds.

  The text is the daemon's sentence, "Voice call, 6 minutes", then on its own
  paragraph the gist; or, with no gist (it failed, or the daemon died before
  it was made), the task list, one task a line, its state and its summary; or
  nothing more when the call had neither. The `metadata.call` it carries is
  `Companion.Protocol.validate_call_metadata/1`'s `ended` shape: the call's
  UUID and engine, its length, its settled voice cost (absent when unknown)
  and that cost's accounting, and what became of its gist. A task still
  running when the row is written reads "Still running".

  A task handed over to finish into the chat says so in one row
  (`task_running/4`: "Still working on:" and the request on one line, its end
  kept, since the end is the ask), and ends in another (`task_done/4`): a
  completed task's result as the stage 5 split shows it (the part after the
  delimiter, else the whole reply), a failure's sentence, or a fixed sentence
  for a task cancelled, timed out or lost to a restart. Each names the task's
  `metadata.call`, its terminal `state` on the second.

  Pure: the record or the task in, `{call, text}` out.
  """

  alias FermixCore.Realtime.LiveText

  # The bound `LiveText.split/2` takes. No line of it is said after the call,
  # and a reply with no delimiter is the whole text on both sides of the
  # bound, so it changes nothing shown here.
  @split_max_bytes 1_500
  @request_line_max_bytes 400

  @cancelled_text "The task was cancelled."
  @timed_out_text "The task ran past its time limit and was stopped."
  @restarted_text "The task stopped when Fermix restarted."

  @typedoc """
  How a task that outlived its call ended: its reply, its failure's sentence,
  cancelled, past its wall clock, or lost to a daemon restart (a `failed`
  task).
  """
  @type task_end ::
          {:completed, String.t()}
          | {:failed, String.t()}
          | :cancelled
          | :timed_out
          | :restarted

  @doc "The row for a closed record: its `metadata.call` and its text."
  @spec ended(map()) :: {map(), String.t()}
  def ended(%{uuid: uuid, engine: engine, accounting: accounting} = record)
      when is_binary(uuid) and is_binary(engine) and is_binary(accounting) do
    duration_s = duration_s(record.started_at, record.ended_at)

    call =
      %{
        "uuid" => uuid,
        "event" => "ended",
        "engine" => engine,
        "duration_s" => duration_s,
        "accounting" => accounting,
        "gist_status" => record.gist_status
      }
      |> put_cost(record.voice_cost_cents)

    {call, Enum.join([sentence(duration_s) | body(record)], "\n\n")}
  end

  @doc "The row that says a task still runs after its call: its `metadata.call` and its text."
  @spec task_running(String.t(), String.t(), pos_integer(), String.t()) :: {map(), String.t()}
  def task_running(uuid, task_id, revision, request)
      when is_binary(uuid) and is_binary(task_id) and is_integer(revision) and revision >= 1 and
             is_binary(request) do
    line =
      request
      |> LiveText.tail(@request_line_max_bytes)
      |> LiveText.one_line(@request_line_max_bytes)

    {task_call(uuid, "task_running", task_id, revision), "Still working on: " <> line}
  end

  @doc "The row a task that outlived its call ends with: its `metadata.call` and its text."
  @spec task_done(String.t(), String.t(), pos_integer(), task_end()) :: {map(), String.t()}
  def task_done(uuid, task_id, revision, task_end)
      when is_binary(uuid) and is_binary(task_id) and is_integer(revision) and revision >= 1 do
    {state, text} = ended_task(task_end)
    {Map.put(task_call(uuid, "task_done", task_id, revision), "state", state), text}
  end

  defp ended_task({:completed, reply}) when is_binary(reply) do
    case LiveText.split(reply, @split_max_bytes) do
      {_spoken, shown} when is_binary(shown) -> {"completed", shown}
      {spoken, nil} -> {"completed", spoken}
    end
  end

  defp ended_task({:failed, sentence}) when is_binary(sentence), do: {"failed", sentence}
  defp ended_task(:cancelled), do: {"cancelled", @cancelled_text}
  defp ended_task(:timed_out), do: {"timed_out", @timed_out_text}
  defp ended_task(:restarted), do: {"failed", @restarted_text}

  defp task_call(uuid, event, task_id, revision),
    do: %{"uuid" => uuid, "event" => event, "task_id" => task_id, "revision" => revision}

  @doc """
  The daemon's sentence for a call that lasted `seconds`: "under a minute"
  below one, else whole minutes, rounded, "1 minute" singular.
  """
  @spec sentence(non_neg_integer()) :: String.t()
  def sentence(seconds) when is_integer(seconds) and seconds >= 0,
    do: "Voice call, " <> length_words(seconds)

  defp length_words(seconds) when seconds < 60, do: "under a minute"

  defp length_words(seconds) do
    case div(seconds + 30, 60) do
      1 -> "1 minute"
      minutes -> "#{minutes} minutes"
    end
  end

  defp body(%{gist: gist}) when is_binary(gist), do: [gist]
  defp body(%{tasks: []}), do: []
  defp body(%{tasks: tasks}) when is_list(tasks), do: [Enum.map_join(tasks, "\n", &task_line/1)]

  defp task_line(%{"state" => state} = task) do
    case Map.get(task, "summary") do
      summary when is_binary(summary) and summary != "" -> "- #{state_words(state)}: #{summary}"
      _none -> "- #{state_words(state)}"
    end
  end

  defp state_words("detached"), do: "Still running"

  defp state_words(state) when is_binary(state),
    do: state |> String.replace("_", " ") |> String.capitalize()

  defp put_cost(call, nil), do: call
  defp put_cost(call, cents) when is_number(cents), do: Map.put(call, "voice_cost_cents", cents)

  defp duration_s(started_at, ended_at) do
    {:ok, started, _offset} = DateTime.from_iso8601(started_at)
    {:ok, ended, _offset} = DateTime.from_iso8601(ended_at)
    max(0, DateTime.diff(ended, started, :second))
  end
end
