defmodule FermixCore.PhoneCalls.Transcript do
  @moduledoc """
  A phone call's transcript as the prompt and the outcome read it (M94 §7,
  §11).

  An entry is one transcript fragment exactly as the sideband delivered it
  (`OpenAILive.Events`' `{:transcript, ...}`), in arrival order: `:remote` is
  the called party (`session.input_transcript.delta`), `:assistant` is the
  voice model (`session.output_transcript.delta`). A fragment is not a
  complete turn and carries its own spacing, so `turns/1` joins consecutive
  fragments of one speaker exactly as they came, into one turn with the first
  fragment's start and the last one's end. Arrival order is not speech order:
  two turns can overlap in time, which only their offsets show.

  A turn's words are its runs of letters and digits, lowercased. Two readers
  use the turns. `window/2` renders them for a backend turn, newest last,
  inside the untrusted-content frame (`Capabilities.UntrustedContent`), each
  turn one line by `PromptText.line/1`, so no fragment can forge a line or a
  speaker label. `locate/2` and `occurrences/2` find where words were said,
  for the outcome check: a quote is said at a position when its words are the
  turn's words from there on, so punctuation, spacing and case never decide a
  match, and the words always do. `said/4` gives back what the turn itself
  said there, from the quote's first word to its last, one line: never the
  quote's own characters.
  """

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.PhoneCalls.PromptText

  @source "phone_call_transcript"
  @cut_marker "(earlier speech cut for length)"
  @speakers [:remote, :assistant]
  @labels %{remote: "recipient", assistant: "assistant"}
  @word ~r/[\p{L}\p{N}]+/u

  @type speaker :: :remote | :assistant
  @type entry :: %{
          required(:speaker) => speaker(),
          required(:text) => String.t(),
          required(:start_ms) => integer() | nil,
          required(:end_ms) => integer() | nil
        }
  @type turn :: %{
          index: non_neg_integer(),
          speaker: speaker(),
          text: String.t(),
          start_ms: integer() | nil,
          end_ms: integer() | nil,
          words: [String.t()],
          spans: [{non_neg_integer(), pos_integer()}]
        }
  @typedoc "Where a quote was said: a turn's index and the index of its first word there."
  @type position :: {non_neg_integer(), non_neg_integer()}
  @type found :: %{
          remote: position() | nil,
          assistant: position() | nil,
          any: position() | nil
        }

  @doc """
  The entries as turns: consecutive fragments of one speaker joined exactly.
  Raises on an entry of another shape: the worker builds them, so a bad one
  is a bug.
  """
  @spec turns([entry()]) :: [turn()]
  def turns(entries) when is_list(entries) do
    entries
    |> Enum.map(&checked!/1)
    |> Enum.chunk_by(& &1.speaker)
    |> Enum.with_index()
    |> Enum.map(&turn/1)
  end

  @doc "Whether any turn is the called party's, with words in it."
  @spec remote_speech?([turn()]) :: boolean()
  def remote_speech?(turns) when is_list(turns),
    do: Enum.any?(turns, &(&1.speaker == :remote and &1.words != []))

  @doc "`text`'s words: its runs of letters and digits, lowercased."
  @spec words(String.t()) :: [String.t()]
  def words(text) when is_binary(text) do
    @word |> Regex.scan(text) |> Enum.map(fn [word] -> String.downcase(word) end)
  end

  @doc """
  The turns as lines, oldest first: `[12.4s] recipient: words`, with the
  turn's start in seconds from the call's first event (`?` when unknown) and
  its text made one line by `PromptText.line/1`.
  """
  @spec lines([turn()]) :: [String.t()]
  def lines(turns) when is_list(turns), do: Enum.map(turns, &line/1)

  @doc """
  The newest lines that fit in `max_bytes`, inside the untrusted-content
  frame. Earlier lines give way whole, behind a marker: the end of a call is
  where it is settled.
  """
  @spec window([entry()], pos_integer()) :: String.t()
  def window(entries, max_bytes)
      when is_list(entries) and is_integer(max_bytes) and max_bytes > 0 do
    frame_bytes = byte_size(UntrustedContent.frame(@source, ""))
    budget = max(max_bytes - frame_bytes - byte_size(@cut_marker) - 1, 0)

    entries
    |> turns()
    |> lines()
    |> newest_within(budget)
    |> Enum.join("\n")
    |> then(&UntrustedContent.frame(@source, &1))
  end

  @doc """
  The newest lines within `budget` bytes joined by newlines, and whether any
  was cut. Earlier lines give way whole, behind `cut_marker/0`.
  """
  @spec newest_lines([String.t()], non_neg_integer()) :: {String.t(), boolean()}
  def newest_lines(lines, budget) when is_list(lines) and is_integer(budget) and budget >= 0 do
    kept = newest_within(lines, budget)
    {Enum.join(kept, "\n"), kept != lines}
  end

  @doc "The marker that stands for lines cut from the front."
  @spec cut_marker() :: String.t()
  def cut_marker, do: @cut_marker

  @doc """
  Every place `quote` was said, in transcript order, each with its speaker.
  A quote with no letters or digits is said nowhere.
  """
  @spec occurrences(String.t(), [turn()]) :: [{speaker(), position()}]
  def occurrences(quote, turns) when is_binary(quote) and is_list(turns) do
    case words(quote) do
      [] -> []
      needle -> Enum.flat_map(turns, &hits(&1, needle))
    end
  end

  @doc """
  Where `quote` was said: the latest position in a `:remote` turn, in an
  `:assistant` turn and in any turn, each `nil` when it was not said there.
  """
  @spec locate(String.t(), [turn()]) :: found()
  def locate(quote, turns) when is_binary(quote) and is_list(turns) do
    hits = occurrences(quote, turns)

    %{
      remote: hits |> Enum.filter(&(elem(&1, 0) == :remote)) |> max_position(),
      assistant: hits |> Enum.filter(&(elem(&1, 0) == :assistant)) |> max_position(),
      any: max_position(hits)
    }
  end

  @doc "Where in `turn` `quote` was said: its latest word position there, or `nil`."
  @spec within(String.t(), turn()) :: non_neg_integer() | nil
  def within(quote, %{words: _words} = turn) when is_binary(quote) do
    case occurrences(quote, [turn]) do
      [] -> nil
      hits -> hits |> Enum.map(fn {_speaker, {_turn, word}} -> word end) |> Enum.max()
    end
  end

  @doc """
  What `turn` itself said at `position`: its own text from the first of
  `quote`'s words to the last, and `extra` words after when it has them, one
  line by `PromptText.line/1`.
  """
  @spec said(turn(), position(), String.t(), non_neg_integer()) :: String.t()
  def said(%{index: index, spans: spans, text: text}, {index, word}, quote, extra \\ 0)
      when is_binary(quote) and is_integer(extra) and extra >= 0 do
    last = min(word + length(words(quote)) + extra, length(spans)) - 1
    {first_at, _length} = Enum.at(spans, word)
    {last_at, last_length} = Enum.at(spans, last)
    text |> binary_part(first_at, last_at + last_length - first_at) |> PromptText.line()
  end

  # -- turns ------------------------------------------------------------------

  defp checked!(%{speaker: speaker, text: text, start_ms: start_ms, end_ms: end_ms} = entry)
       when speaker in @speakers and is_binary(text) and
              (is_integer(start_ms) or is_nil(start_ms)) and
              (is_integer(end_ms) or is_nil(end_ms)) do
    if String.valid?(text),
      do: entry,
      else: raise(ArgumentError, "a phone call transcript entry's text is not UTF-8")
  end

  defp checked!(entry),
    do: raise(ArgumentError, "not a phone call transcript entry: #{inspect(entry, limit: 5)}")

  defp turn({[first | _] = fragments, index}) do
    text = Enum.map_join(fragments, & &1.text)
    spans = @word |> Regex.scan(text, return: :index) |> Enum.map(fn [span] -> span end)

    %{
      index: index,
      speaker: first.speaker,
      text: text,
      start_ms: first.start_ms,
      end_ms: List.last(fragments).end_ms,
      words: Enum.map(spans, fn {at, size} -> String.downcase(binary_part(text, at, size)) end),
      spans: spans
    }
  end

  defp line(turn),
    do:
      "[#{seconds(turn.start_ms)}] #{Map.fetch!(@labels, turn.speaker)}: #{PromptText.line(turn.text)}"

  defp seconds(nil), do: "?"
  defp seconds(ms) when ms < 0, do: "?"
  defp seconds(ms), do: "#{div(ms, 1000)}.#{div(rem(ms, 1000), 100)}s"

  defp newest_within(lines, budget) do
    {kept, _used} =
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn line, {kept, used} ->
        next = used + byte_size(line) + 1
        if next <= budget, do: {:cont, {[line | kept], next}}, else: {:halt, {kept, used}}
      end)

    if length(kept) == length(lines), do: kept, else: [@cut_marker | kept]
  end

  # -- locating quotes ----------------------------------------------------------

  defp hits(%{words: words, speaker: speaker, index: index}, needle),
    do: words |> starts(needle, 0, []) |> Enum.reverse() |> Enum.map(&{speaker, {index, &1}})

  # Every word position from which `needle` is the turn's words.
  defp starts([], _needle, _at, found), do: found

  defp starts([_word | rest] = words, needle, at, found) do
    found = if prefix?(needle, words), do: [at | found], else: found
    starts(rest, needle, at + 1, found)
  end

  defp prefix?([], _words), do: true
  defp prefix?([word | needle], [word | words]), do: prefix?(needle, words)
  defp prefix?(_needle, _words), do: false

  defp max_position([]), do: nil
  defp max_position(hits), do: hits |> Enum.map(&elem(&1, 1)) |> Enum.max()
end
