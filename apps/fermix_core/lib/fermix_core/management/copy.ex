defmodule FermixCore.Management.Copy do
  @moduledoc """
  The rules every daemon-owned sentence on the management wire obeys
  (M34 native setup §7.7, §7.8 step 4).

  Row labels, footers, choice options, section titles, remediation titles and
  bodies, refusal sentences, restart reasons and the readiness actions are all
  written here in Elixir and rendered verbatim by two front-ends. Neither door
  can correct them, so the rules live beside the strings rather than in a
  reviewer's head, and `copy_test.exs` walks the live producers rather than a
  hand-listed sample.

  The rules, and what each one is for:

    * `:em_dash` — an em or en dash. The product's copy uses a full stop or a
      colon, and a dash reads as a different voice inside one window.
    * `:exclamation` — an exclamation mark. Setup copy states facts.
    * `:mix_task` — a Mix task name (`mix fermix.setup`). An installed operator
      has no `mix`, so naming one is advice they cannot follow.
    * `:version_number` — a dotted version. Copy that names a version is stale
      the moment the next one ships; prose only, because a model or voice name
      is a catalog identity this daemon reflects rather than copy it wrote.
    * `:wire_token` — a bare `snake_case` or `UPPER_SNAKE` identifier outside
      backticks. A configuration key, an internal atom or an environment
      variable rendered as prose reads as a typo to everyone who has not read
      the source; backtick it and it is a literal the operator can type.
    * `:sentence_case` — a capitalised word that neither starts a sentence, nor
      is an initialism, nor is a proper noun. Prose only: a label, a section
      title and a choice option are names, not sentences.

  `:prose` runs every rule; `:name` runs the four that apply to a name. A
  proper noun the daemon interpolates rather than writes (a plugin's display
  name, an account label) is passed in as `names` at the call site, because the
  rule set cannot know it and a list of every vendor on earth would rot.
  """

  alias FermixCore.Providers.Descriptor

  @type kind :: :prose | :name
  @type violation :: {atom(), String.t()}

  @em_dashes ["—", "–"]
  @backticked ~r/`[^`]*`/
  @mix_task ~r/\bmix\s+[a-z][a-z0-9_]*\.[a-z]/
  @version ~r/\bv?\d+\.\d+(?:\.\d+)?\b/
  @wire_token ~r/\b(?:[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b/
  @capitalised ~r/\b[A-Z][a-z]+\b/
  # A sentence starts at the beginning of the string and after a terminator or
  # a colon, which is how this copy introduces a command or a list.
  @sentence_break ~r/(?<=[.?:])\s+/

  # The hand-maintained half, and the only one. Every entry is asserted used by
  # a live string, so a name that leaves the copy leaves this list in the same
  # change. Provider labels are derived below rather than repeated here.
  @proper_nouns [
    "Fermix Computer Use",
    "Claude Code",
    "New York",
    "Los Angeles",
    "Sao Paulo",
    "Fermix",
    "Mac",
    "Doctor",
    "Claude",
    "Codex",
    "Grok",
    "Realtime",
    "Providers",
    "Channels",
    "Telegram",
    "WhatsApp",
    "Discord",
    "Slack",
    "Signal",
    "Google Meet",
    "Zoom",
    "Personality"
  ]

  @doc """
  Every rule this contract enforces, ordered, so a gate can name them.
  """
  @spec rules() :: [atom()]
  def rules, do: [:em_dash, :exclamation, :mix_task, :version_number, :wire_token, :sentence_case]

  @doc """
  The proper nouns and proper phrases the sentence-case rule accepts.

  Provider labels are read from the descriptor registry, so a provider added in
  Elixir needs no entry here; the rest is the hand-maintained list this module
  documents.
  """
  @spec proper_nouns() :: [String.t()]
  def proper_nouns do
    (@proper_nouns ++ descriptor_names())
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end

  @doc """
  Every rule `text` breaks, as `{rule, the offending fragment}`.

  `names` carries proper nouns this string interpolates rather than writes, so
  a plugin's display name inside a daemon sentence is data rather than a
  capitalisation defect.
  """
  @spec violations(String.t(), kind(), [String.t()]) :: [violation()]
  def violations(text, kind, names \\ [])
      when is_binary(text) and kind in [:prose, :name] and is_list(names) do
    literal = Regex.replace(@backticked, text, "``")

    Enum.concat([
      dash_violations(text),
      bang_violations(text),
      pattern_violations(@mix_task, literal, :mix_task),
      prose_only(kind, fn -> pattern_violations(@version, literal, :version_number) end),
      token_violations(literal),
      prose_only(kind, fn -> case_violations(literal, names) end)
    ])
  end

  defp prose_only(:prose, run), do: run.()
  defp prose_only(:name, _run), do: []

  defp dash_violations(text) do
    for dash <- @em_dashes, String.contains?(text, dash), do: {:em_dash, dash}
  end

  defp bang_violations(text) do
    if String.contains?(text, "!"), do: [{:exclamation, "!"}], else: []
  end

  defp pattern_violations(pattern, text, rule) do
    pattern |> Regex.scan(text) |> Enum.map(fn [match | _rest] -> {rule, match} end)
  end

  defp token_violations(text), do: pattern_violations(@wire_token, text, :wire_token)

  defp case_violations(text, names) do
    stripped = strip_names(text, proper_nouns() ++ names)

    stripped
    |> String.split(@sentence_break)
    |> Enum.flat_map(&offending_words/1)
  end

  # The first word of a sentence is capitalised by construction, so only what
  # follows it can be a defect.
  defp offending_words(sentence) do
    case String.split(sentence, ~r/\s+/, parts: 2) do
      [_first] -> []
      [_first, rest] -> @capitalised |> Regex.scan(rest) |> Enum.map(&{:sentence_case, hd(&1)})
    end
  end

  # Longest first, so "Fermix Computer Use" is removed before "Fermix" can
  # leave "Computer Use" behind as two unexplained capitals.
  defp strip_names(text, names) do
    names
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce(text, &String.replace(&2, &1, "-"))
  end

  defp descriptor_names do
    Descriptor.all()
    |> Enum.flat_map(&String.split(&1.label, ~r/[\s()]+/, trim: true))
    |> Enum.filter(&Regex.match?(~r/^[A-Z]/, &1))
  end
end
