defmodule FermixCore.PhoneCalls.Call.LastWords do
  @moduledoc """
  The last words a call's transcript holds, kept as the evidence of a call
  whose outcome was not read (M94 §09: an extraction that failed or was
  abandoned, an engine stop, a transcript at its bound). The transcript dies
  with the worker, so these lines are what tells the owner whether anything
  was agreed.

  Each speaker's closing turn, one line each, in the order they were said:
  the turn's own last words, from a word boundary, as many as fit in the
  ledger's excerpt bound (`Outcome.Record.bounds/0`). The slice is
  `Transcript.said/4`'s, so it is what the turn itself said, one line; the
  report is then fitted to the ledger's bounds by `Outcome.fit_report/1`, the
  one path every outcome's evidence takes. Pure.
  """

  alias FermixCore.PhoneCalls.Outcome.Record
  alias FermixCore.PhoneCalls.Transcript

  @labels %{remote: "recipient", assistant: "assistant"}

  @doc "The closing line of each speaker, oldest first, as report evidence."
  @spec evidence([Transcript.entry()]) :: [%{speaker: String.t(), text: String.t()}]
  def evidence(entries) when is_list(entries) do
    %{excerpt_bytes: bytes} = Record.bounds()
    turns = Transcript.turns(entries)

    [:remote, :assistant]
    |> Enum.map(fn speaker -> last_turn(turns, speaker) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.index)
    |> Enum.map(&%{speaker: Map.fetch!(@labels, &1.speaker), text: closing(&1, bytes)})
  end

  # The speaker's last turn that said any word.
  defp last_turn(turns, speaker) do
    turns
    |> Enum.filter(&(&1.speaker == speaker and &1.words != []))
    |> List.last()
  end

  # The turn's last words that fit in `bytes`: from the earliest word whose
  # run to the turn's last word fits, or the last word alone, which the fit
  # then cuts.
  defp closing(%{index: index, spans: spans} = turn, bytes) do
    {last_at, last_size} = List.last(spans)
    stop = last_at + last_size
    count = length(spans)

    first =
      spans
      |> Enum.with_index()
      |> Enum.find_value(count - 1, fn {{at, _size}, word} -> if stop - at <= bytes, do: word end)

    Transcript.said(turn, {index, first}, "", count - first)
  end
end
