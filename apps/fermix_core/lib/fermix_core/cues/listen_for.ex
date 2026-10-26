defmodule FermixCore.Cues.ListenFor do
  @moduledoc """
  A watcher's words to listen for (M60_CUE_INTAKE_AT_SCALE.md §3.1): which
  items reach its filter at all, never which pass. Pure: validating a list,
  compiling it into a matcher, preparing an item's searchable text once, and
  matching that text against any number of matchers.

  **The text searched** is the item's string values, never its keys (its title,
  subject and type, then every string inside its data), each split at
  whitespace (an ASCII space, U+3000, and the CJK full stop and comma). A piece
  shaped like an identifier is left out: an address (`scheme://…`), a DID
  (`did:…`), a dotted name of three or more parts (`app.bsky.feed.post`), or a
  piece with neither a letter nor a digit. So a Japanese post that carries a
  link is still read, minus the link, and "RTX 5090" keeps its number. At most
  64 KiB of text is read.

  **Normalizing**: Unicode NFKD, combining marks removed only after a Latin,
  Greek or Cyrillic letter (where they are accents; Japanese dakuten stay),
  then lowercase. Words and text go through the same function.

  **Matching**: text splits into tokens at anything that is not a letter or a
  digit, and where a script written without spaces (Han, Hiragana, Katakana,
  Thai) meets another ("AI芯片" is `ai`, `芯片`). A word matches when its tokens
  appear in order as whole tokens of the text, so `ai` matches "AI" and not
  "said". A word in a script written without spaces matches as a substring of
  the normalized text. There are no wildcards, patterns or options.
  """

  @max_words 200
  @max_word_chars 64
  @max_text_bytes 65_536

  @no_space_scripts ~r/[\p{Han}\p{Hiragana}\p{Katakana}\p{Thai}]/u
  @token ~r/[\p{Han}]+|[\p{Hiragana}]+|[\p{Katakana}\x{30FC}]+|[\p{Thai}]+|[^\W_\p{Han}\p{Hiragana}\p{Katakana}\p{Thai}]+/u
  @accent ~r/(?<=[\p{Latin}\p{Greek}\p{Cyrillic}])\p{Mn}+/u
  @piece_split ~r/[\s\x{3000}\x{3001}\x{3002}]+/u
  @address ~r/^[a-z][a-z0-9+.\-]*:\/\//i
  @did ~r/^did:/i
  @dotted_name ~r/^[a-z0-9\-]+(\.[a-z0-9\-]+){2,}$/i
  @letter_or_digit ~r/[\p{L}\p{N}]/u
  @control ~r/[\x00-\x1F\x7F]/

  @typedoc "A compiled list: phrases by their first token, and the substring words."
  @type matcher :: %{
          phrases: %{optional(String.t()) => [[String.t()]]},
          substrings: :binary.cp() | nil
        }

  @typedoc "An item's searchable text, prepared once for every watcher of its source."
  @type prepared :: %{text: String.t(), tokens: [String.t()]}

  @doc "The most words a watcher listens for, and the longest one."
  @spec limits() :: %{words: pos_integer(), chars: pos_integer()}
  def limits, do: %{words: @max_words, chars: @max_word_chars}

  @doc """
  Validates a watcher's words: trimmed, one line each, 1 to 64 characters, each
  with a letter or a digit, deduplicated by their normalized form (the first
  spelling kept), and 1 to 200 of them. Refused with a sentence for the owner.
  """
  @spec validate(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate(words) when is_list(words) do
    with {:ok, cleaned} <- clean(words) do
      count(dedupe(cleaned))
    end
  end

  def validate(_words), do: {:error, "Give the words to listen for as a list."}

  @doc "Compiles validated words into a matcher."
  @spec compile([String.t()]) :: matcher()
  def compile(words) when is_list(words) do
    normalized = Enum.map(words, &normalize/1)
    {substrings, spaced} = Enum.split_with(normalized, &Regex.match?(@no_space_scripts, &1))

    %{
      phrases:
        spaced
        |> Enum.map(&tokens/1)
        |> Enum.reject(&(&1 == []))
        |> Enum.group_by(&hd/1, &tl/1),
      substrings: if(substrings == [], do: nil, else: :binary.compile_pattern(substrings))
    }
  end

  @doc "An item's searchable text (`Cues.Item` or any map with `title`, `subject`, `type`, `data`)."
  @spec prepare(map()) :: prepared()
  def prepare(item) when is_map(item) do
    text =
      [Map.get(item, :title), Map.get(item, :subject), Map.get(item, :type), Map.get(item, :data)]
      |> strings([])
      |> Enum.reverse()
      |> take_bytes(@max_text_bytes, [])
      |> Enum.flat_map(&Regex.split(@piece_split, &1, trim: true))
      |> Enum.reject(&identifier?/1)
      |> Enum.join(" ")
      |> normalize()

    %{text: text, tokens: tokens(text)}
  end

  @doc "Whether any of the matcher's words is in the prepared text."
  @spec match?(matcher(), prepared()) :: boolean()
  def match?(%{phrases: phrases, substrings: substrings}, %{text: text, tokens: tokens}) do
    substring?(substrings, text) or phrase?(tokens, phrases)
  end

  @doc "Normalizes text the way words and items are compared."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.normalize(:nfkd)
    |> then(&Regex.replace(@accent, &1, ""))
    |> String.downcase()
  end

  # --- validation -------------------------------------------------------------------

  defp clean(words) do
    Enum.reduce_while(words, {:ok, []}, fn word, {:ok, acc} ->
      case clean_word(word) do
        {:ok, cleaned} -> {:cont, {:ok, [cleaned | acc]}}
        {:error, sentence} -> {:halt, {:error, sentence}}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp clean_word(word) when is_binary(word) do
    word = String.trim(word)

    cond do
      word == "" ->
        {:error, "A word to listen for cannot be empty."}

      String.length(word) > @max_word_chars ->
        {:error, "Each word to listen for is at most #{@max_word_chars} characters: #{word}"}

      Regex.match?(@control, word) ->
        {:error, "Each word to listen for takes a single line."}

      not content?(word) ->
        {:error, "A word to listen for needs a letter or a digit: #{word}"}

      true ->
        {:ok, word}
    end
  end

  defp clean_word(_word), do: {:error, "Each word to listen for is text."}

  defp content?(word) do
    normalized = normalize(word)
    Regex.match?(@no_space_scripts, normalized) or tokens(normalized) != []
  end

  defp dedupe(words), do: Enum.uniq_by(words, &normalize/1)

  defp count([]), do: {:error, "A watcher listens for at least one word."}

  defp count(words) when length(words) > @max_words,
    do: {:error, "A watcher listens for at most #{@max_words} words or short phrases."}

  defp count(words), do: {:ok, words}

  # --- text -------------------------------------------------------------------------

  # Every string value, never a key, depth first and in order (reversed).
  defp strings(value, acc) when is_binary(value), do: [value | acc]
  defp strings(values, acc) when is_list(values), do: Enum.reduce(values, acc, &strings/2)

  defp strings(%{} = map, acc) when not is_struct(map),
    do: map |> Map.values() |> strings(acc)

  defp strings(_other, acc), do: acc

  defp take_bytes([], _left, acc), do: Enum.reverse(acc)
  defp take_bytes(_values, left, acc) when left <= 0, do: Enum.reverse(acc)

  defp take_bytes([value | rest], left, acc) when byte_size(value) <= left,
    do: take_bytes(rest, left - byte_size(value), [value | acc])

  defp take_bytes([value | _rest], left, acc) do
    [whole | _cut] = value |> binary_part(0, left) |> String.chunk(:valid)
    Enum.reverse([whole | acc])
  end

  defp identifier?(piece) do
    Regex.match?(@address, piece) or Regex.match?(@did, piece) or
      Regex.match?(@dotted_name, piece) or not Regex.match?(@letter_or_digit, piece)
  end

  # --- matching -----------------------------------------------------------------------

  defp tokens(text), do: @token |> Regex.scan(text) |> List.flatten()

  defp substring?(nil, _text), do: false
  defp substring?(pattern, text), do: :binary.match(text, pattern) != :nomatch

  defp phrase?([], _phrases), do: false

  defp phrase?([token | rest], phrases) do
    case Map.fetch(phrases, token) do
      {:ok, tails} -> Enum.any?(tails, &prefix?(&1, rest)) or phrase?(rest, phrases)
      :error -> phrase?(rest, phrases)
    end
  end

  defp prefix?([], _tokens), do: true
  defp prefix?([word | words], [word | tokens]), do: prefix?(words, tokens)
  defp prefix?(_words, _tokens), do: false
end
