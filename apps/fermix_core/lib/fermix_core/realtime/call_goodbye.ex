defmodule FermixCore.Realtime.CallGoodbye do
  @moduledoc """
  Whether what the owner said ends a task-engine voice call (M96 §5): one
  rule for Grok Voice and GPT-Live alike, from every endpoint.

  A call ends on a goodbye when the owner's whole turn was an English goodbye
  (`goodbye?/2`) and the voice's reply to it has played out, so the voice's own
  goodbye is heard in full. Each engine feeds four signals, in milliseconds on
  one timeline of its own, and acts on what they answer:

    * `owner_words/3`: words of the owner's, with when they were spoken.
    * `reply_started/2`: the voice began a reply at `at_ms`. Every word spoken
      before it since the reply before is the turn it answers.
    * `reply_played_out/1`: the reply has been heard to its end.
    * `interrupted/1`: the reply was cut short (a barge-in, the client's
      `interrupt`); the turn it answered no longer ends the call.

  Words are grouped by when they were spoken, never by when their transcript
  arrived: a transcript that lands after the reply began still joins the turn
  that reply answers, and the reply's own echo of "Bye!" (spoken after it
  began) can neither end the call nor keep it open. When the answered turn's
  last words arrive after its reply already played out, `owner_words/3` ends
  the call then: whichever comes last ends it.

  Bounded: a goodbye counts only when its reply started within
  `@reply_window_ms` of its last word; the turn in progress and the answered
  turn are all that is held, each at most `@max_fragments` pieces and
  `@max_turn_bytes`, and a turn that outgrows that is held as too long to be a
  goodbye. Pure: the engines own the clocks, the timers and the end.
  """

  # A goodbye has at most this many words, fillers left out.
  @max_words 8
  # Text longer than this is not a goodbye, whatever it says.
  @max_text_bytes 256
  # A goodbye counts only when the voice began its reply within this long of
  # the goodbye's last word.
  @reply_window_ms 10_000
  # What one turn holds: transcript fragments and their bytes. Past either, the
  # turn is too long to be a goodbye and is held only as such.
  @max_fragments 32
  @max_turn_bytes 512

  @fillers ~w(um uh erm hmm)
  @lead_ins [
    ~w(okay),
    ~w(ok),
    ~w(alright),
    ~w(all right),
    ~w(thanks),
    ~w(thank you),
    ~w(thank you so much),
    ~w(cool),
    ~w(great),
    ~w(perfect),
    ~w(sounds good),
    ~w(cheers),
    ~w(thats all),
    ~w(thats it),
    ~w(all done)
  ]
  @closings [
    ~w(bye),
    ~w(bye bye),
    ~w(goodbye),
    ~w(good bye),
    ~w(bye for now),
    ~w(see you later),
    ~w(see ya),
    ~w(talk to you later),
    ~w(catch you later),
    ~w(take care),
    ~w(good night),
    ~w(goodnight),
    ~w(gotta go),
    ~w(got to go),
    ~w(hang up),
    ~w(end the call)
  ]
  # Often the first half of "see you at five" when the owner pauses, so only
  # after a lead-in or before a tail.
  @guarded_closings [~w(see you), ~w(talk later)]
  @tails [~w(then), ~w(now), ~w(for now), ~w(thanks), ~w(thank you), ~w(fermix)]

  @typep fragment :: {non_neg_integer(), String.t()}
  @typep spill :: {non_neg_integer(), non_neg_integer()} | nil
  @typep turn :: %{fragments: [fragment()], spill: spill()}
  @typep answered :: %{
           fragments: [fragment()],
           spill: spill(),
           from_ms: non_neg_integer(),
           reply_at: non_neg_integer(),
           played_out?: boolean()
         }

  @type t :: %__MODULE__{
          tails: [[String.t()]],
          turn: turn(),
          reply_at: non_neg_integer() | nil,
          answered: answered() | nil
        }

  @enforce_keys [:tails]
  defstruct tails: [], turn: %{fragments: [], spill: nil}, reply_at: nil, answered: nil

  @doc """
  A call with nothing said yet. `assistant_name` is the configured name the
  owner may add to a goodbye ("bye, Nova"), or `nil`.
  """
  @spec new(String.t() | nil) :: t()
  def new(assistant_name) when is_binary(assistant_name) or is_nil(assistant_name),
    do: %__MODULE__{tails: tails(assistant_name)}

  @doc """
  Words of the owner's, spoken at `start_ms`. Fragments of one turn are
  joined verbatim in the order they were spoken, as a transcript's deltas are,
  so a caller passing whole utterances ends each with a space. `:end` when they
  complete a goodbye whose reply has already played out.
  """
  @spec owner_words(t(), String.t(), non_neg_integer()) :: {:end | :cont, t()}
  def owner_words(%__MODULE__{} = goodbye, text, start_ms)
      when is_binary(text) and is_integer(start_ms) and start_ms >= 0 do
    cond do
      late_for_answered?(goodbye, start_ms) -> late_words(goodbye, text, start_ms)
      before_last_reply?(goodbye, start_ms) -> {:cont, goodbye}
      true -> {:cont, %{goodbye | turn: add(goodbye.turn, start_ms, text)}}
    end
  end

  @doc """
  The voice began a reply at `at_ms`. What the owner said before it since the
  last reply began is the turn it answers; what they said from `at_ms` on
  starts the next one. The turn an earlier reply answered is forgotten.
  """
  @spec reply_started(t(), non_neg_integer()) :: t()
  def reply_started(%__MODULE__{} = goodbye, at_ms) when is_integer(at_ms) and at_ms >= 0 do
    at_ms = max(at_ms, goodbye.reply_at || at_ms)
    {before, rest} = split(goodbye.turn, at_ms)

    answered =
      Map.merge(before, %{from_ms: goodbye.reply_at || 0, reply_at: at_ms, played_out?: false})

    %{goodbye | turn: rest, reply_at: at_ms, answered: answered}
  end

  @doc "The reply was cut short: the turn it answered no longer ends the call."
  @spec interrupted(t()) :: t()
  def interrupted(%__MODULE__{} = goodbye), do: %{goodbye | answered: nil}

  @doc """
  The reply has played to its end. `:end` when the turn it answered is a
  goodbye; otherwise the reply is remembered as played, for a late transcript.
  """
  @spec reply_played_out(t()) :: {:end | :cont, t()}
  def reply_played_out(%__MODULE__{answered: nil} = goodbye), do: {:cont, goodbye}

  def reply_played_out(%__MODULE__{answered: answered} = goodbye) do
    if goodbye_turn?(answered, goodbye.tails),
      do: {:end, goodbye},
      else: {:cont, %{goodbye | answered: %{answered | played_out?: true}}}
  end

  @doc """
  Whether `text` is a whole English goodbye: at most #{@max_words} words, fillers
  left out, that are exactly any lead-ins ("okay", "thanks"), one closing
  ("bye", "talk to you later") and any tails ("then", "thanks", the
  assistant's name). "Tell Sam bye" and "see you at five" are not.

  Normalised first: lowercase, apostrophes dropped (`that's` is `thats`), every
  other mark that is not a letter or a digit, hyphens included, a space.
  """
  @spec goodbye?(String.t(), String.t() | nil) :: boolean()
  def goodbye?(text, assistant_name)
      when is_binary(text) and (is_binary(assistant_name) or is_nil(assistant_name)),
      do: shaped?(text, tails(assistant_name))

  ## The turns

  defp late_for_answered?(%{answered: nil}, _start_ms), do: false

  defp late_for_answered?(%{answered: answered}, start_ms),
    do: start_ms >= answered.from_ms and start_ms < answered.reply_at

  # Spoken before the last reply began, and not into the turn it answers: an
  # older turn's, or one an interruption forgot.
  defp before_last_reply?(%{reply_at: nil}, _start_ms), do: false
  defp before_last_reply?(%{reply_at: reply_at}, start_ms), do: start_ms < reply_at

  defp late_words(goodbye, text, start_ms) do
    answered = Map.merge(goodbye.answered, add(goodbye.answered, start_ms, text))
    goodbye = %{goodbye | answered: answered}

    if answered.played_out? and goodbye_turn?(answered, goodbye.tails),
      do: {:end, goodbye},
      else: {:cont, goodbye}
  end

  defp goodbye_turn?(%{spill: nil, fragments: [_ | _] = fragments, reply_at: reply_at}, tails) do
    last_ms = fragments |> Enum.map(&elem(&1, 0)) |> Enum.max()
    reply_at - last_ms <= @reply_window_ms and shaped?(joined(fragments), tails)
  end

  defp goodbye_turn?(_answered, _tails), do: false

  defp joined(fragments),
    do: fragments |> Enum.reverse() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join(&elem(&1, 1))

  # Newest first. A fragment past the bounds is not kept: only when it was
  # spoken, so the turn it belongs to is known to be too long.
  defp add(%{fragments: fragments, spill: spill}, start_ms, text) do
    bytes = fragments |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum()

    if length(fragments) < @max_fragments and bytes + byte_size(text) <= @max_turn_bytes,
      do: %{fragments: [{start_ms, text} | fragments], spill: spill},
      else: %{fragments: fragments, spill: widen(spill, start_ms)}
  end

  defp widen(nil, start_ms), do: {start_ms, start_ms}
  defp widen({from, to}, start_ms), do: {min(from, start_ms), max(to, start_ms)}

  defp split(%{fragments: fragments, spill: spill}, at_ms) do
    {before, rest} = Enum.split_with(fragments, fn {start_ms, _text} -> start_ms < at_ms end)

    {%{fragments: before, spill: spill_before(spill, at_ms)},
     %{fragments: rest, spill: spill_from(spill, at_ms)}}
  end

  defp spill_before({from, to}, at_ms) when from < at_ms, do: {from, min(to, at_ms - 1)}
  defp spill_before(_spill, _at_ms), do: nil

  defp spill_from({from, to}, at_ms) when to >= at_ms, do: {max(from, at_ms), to}
  defp spill_from(_spill, _at_ms), do: nil

  ## The phrase rule

  defp shaped?(text, tails) when byte_size(text) <= @max_text_bytes do
    words = words(text)
    length(words) in 1..@max_words and closed?(words, false, tails)
  end

  defp shaped?(_text, _tails), do: false

  defp words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/['’‘]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @fillers))
  end

  # Any lead-ins, then one closing, then any tails. Each step takes at least
  # one word of at most eight, so the walk is bounded.
  defp closed?(words, led?, tails) do
    closing?(words, led?, tails) or
      Enum.any?(@lead_ins, fn lead -> after_phrase?(words, lead, &closed?(&1, true, tails)) end)
  end

  defp closing?(words, led?, tails) do
    Enum.any?(@closings, &after_phrase?(words, &1, fn rest -> tails?(rest, tails) end)) or
      Enum.any?(
        @guarded_closings,
        &after_phrase?(words, &1, fn rest -> guarded?(rest, led?, tails) end)
      )
  end

  defp guarded?([], led?, _tails), do: led?
  defp guarded?(rest, _led?, tails), do: tails?(rest, tails)

  defp tails?([], _tails), do: true

  defp tails?(words, tails),
    do: Enum.any?(tails, fn tail -> after_phrase?(words, tail, &tails?(&1, tails)) end)

  defp after_phrase?(words, phrase, then) do
    case Enum.split(words, length(phrase)) do
      {^phrase, rest} -> then.(rest)
      _other -> false
    end
  end

  defp tails(nil), do: @tails

  defp tails(name) do
    case words(name) do
      [] -> @tails
      name_words -> [name_words | @tails]
    end
  end
end
