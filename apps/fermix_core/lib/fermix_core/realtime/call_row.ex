defmodule FermixCore.Realtime.CallRow do
  @moduledoc """
  The one chat row a Live call in the chat leaves when it ends (M56 §4.2, D4),
  rendered from the call's record as the memory database holds it, so the row
  written as the gist settles and the row a boot writes for a daemon that died
  first are the same row: one read path, whatever the record holds.

  The text is the daemon's sentence, "Voice call, 6 minutes", then on its own
  paragraph the gist; or, with no gist (it failed, or the daemon died before
  it was made), the task list, one task a line, its state and its summary; or
  nothing more when the call had neither. The `metadata.call` it carries is
  `Companion.Protocol.validate_call_metadata/1`'s `ended` shape: the call's
  UUID and engine, its length, its settled voice cost (absent when unknown)
  and that cost's accounting, and what became of its gist.

  Pure: the record in, `{call, text}` out.
  """

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
