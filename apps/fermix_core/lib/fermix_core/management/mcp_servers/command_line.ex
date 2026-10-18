defmodule FermixCore.Management.McpServers.CommandLine do
  @moduledoc """
  The command line an owner types for a local MCP server, and back (M74 §5).

  `split/2` reads it the way a POSIX shell reads one simple command, word by
  word: blanks separate words, single quotes keep everything up to the next
  one, double quotes keep everything up to the next unescaped one with `\\`
  escaping `"`, `\\`, `$` and a backquote inside them, and `\\` outside quotes
  keeps the next character. The program is started with these words as its
  arguments, never through a shell, so a line that needs a shell to mean what
  it says is refused rather than run as something else: a pipe, a redirection,
  a list, a substitution, `$`, and a leading `NAME=value`.

  One expansion is made, the one a shell makes of a path the owner types: a
  `~` that starts a word, unquoted up to the word's first `/`, alone or before
  that `/`, is the home folder the daemon gives the program (`expand_home/3`,
  which the form's working folder goes through too). A quoted `~` stays as it
  is, and `~name`, another account's home, is refused. Nothing else is
  expanded.

  `join/1` writes the words back as a line that `split/2` reads as the same
  words, quoting only a word that needs it, so the row shows the command that
  runs, a home folder written out.
  """

  @max_words 128
  # Characters a shell gives a meaning to outside quotes, so a line that has one
  # unquoted would mean something else here.
  @operators ~c"|&;<>()`$"
  # A `~` may not lead a bare word: `split/2` would read it as the home folder.
  @safe_word ~r{\A[A-Za-z0-9_@%+=:,./^-][A-Za-z0-9_@%+=:,./~^-]*\z}
  @assignment ~r/\A[A-Za-z_][A-Za-z0-9_]*=/
  # Characters that quote what follows them: one of these before a word's first
  # `/` quotes its `~`, which a shell then leaves as it is.
  @quoting ~c"'\"\\"
  @max_named_chars 64

  @type refusal :: {:invalid_params, String.t(), String.t()}

  @doc """
  The program and its arguments, `home` written in for a leading `~`, or a
  refusal naming `command_line`.
  """
  @spec split(String.t(), Path.t()) :: {:ok, {String.t(), [String.t()]}} | {:error, refusal()}
  def split(line, home) when is_binary(line) and is_binary(home) do
    with {:ok, words} <- words(String.to_charlist(line), [], nil, :blank),
         {:ok, words} <- at_home(words, home),
         :ok <- bounded(words),
         :ok <- no_assignment(words) do
      [command | args] = words
      {:ok, {command, args}}
    end
  end

  @doc """
  `path` with a leading `~` read as a shell reads it: `~` alone or before a
  `/` is `home`, and `~name`, another account's home, is refused naming
  `field`. A path that does not start with `~` is as it was.
  """
  @spec expand_home(String.t(), Path.t(), String.t()) :: {:ok, String.t()} | {:error, refusal()}
  def expand_home("~" <> rest = path, home, field) when is_binary(home) and is_binary(field) do
    case rest do
      "" -> {:ok, home}
      "/" <> _path -> {:ok, home <> rest}
      _name -> refuse(field, "Write the full path in place of #{named(path)}.")
    end
  end

  def expand_home(path, home, field)
      when is_binary(path) and is_binary(home) and is_binary(field),
      do: {:ok, path}

  # The `~name` the owner wrote, up to the first `/`, bounded so a sentence
  # stays a sentence.
  defp named(path),
    do: path |> String.split("/", parts: 2) |> hd() |> String.slice(0, @max_named_chars)

  defp at_home(words, home) do
    with {:ok, reversed} <- Enum.reduce_while(words, {:ok, []}, &home_word(&1, &2, home)) do
      {:ok, Enum.reverse(reversed)}
    end
  end

  defp home_word({:home, word}, {:ok, acc}, home) do
    case expand_home(word, home, "command_line") do
      {:ok, path} -> {:cont, {:ok, [path | acc]}}
      {:error, _refusal} = error -> {:halt, error}
    end
  end

  defp home_word(word, {:ok, acc}, _home), do: {:cont, {:ok, [word | acc]}}

  @doc "The line `split/2` reads as exactly these words."
  @spec join([String.t()]) :: String.t()
  def join(words) when is_list(words), do: Enum.map_join(words, " ", &quote_word/1)

  defp quote_word(word) do
    if Regex.match?(@safe_word, word),
      do: word,
      else: "'" <> String.replace(word, "'", ~S('\'')) <> "'"
  end

  # `current` is the word being read, reversed, or nil between words; `mode` is
  # `:blank`, `:word`, `:single` or `:double`.
  defp words([], acc, current, mode) when mode in [:blank, :word],
    do: {:ok, Enum.reverse(push(acc, current))}

  defp words([], _acc, _current, _mode),
    do: refuse("A quotation mark is not closed.")

  defp words([char | rest], acc, current, :single), do: single(char, rest, acc, current)
  defp words([char | rest], acc, current, :double), do: double(char, rest, acc, current)
  defp words([char | rest], acc, current, _mode), do: bare(char, rest, acc, current)

  defp bare(char, rest, acc, current) when char in [?\s, ?\t],
    do: words(rest, push(acc, current), nil, :blank)

  defp bare(char, _rest, _acc, _current) when char in [?\n, ?\r],
    do: refuse("A command is one line.")

  defp bare(?', rest, acc, current), do: words(rest, acc, started(current), :single)
  defp bare(?", rest, acc, current), do: words(rest, acc, started(current), :double)
  defp bare(?\\, [], _acc, _current), do: refuse("A command cannot end with a backslash.")

  defp bare(?\\, [next | rest], acc, current),
    do: words(rest, acc, [next | started(current)], :word)

  # A `~` that starts a word is marked for `at_home/2`, unless a quote before
  # the word's first `/` quotes it.
  defp bare(?~, rest, acc, nil) do
    prefix = Enum.take_while(rest, &(&1 not in [?/, ?\s, ?\t]))

    if Enum.any?(prefix, &(&1 in @quoting)),
      do: words(rest, acc, [?~], :word),
      else: words(rest, acc, [?~, :home], :word)
  end

  defp bare(char, _rest, _acc, _current) when char in @operators,
    do: refuse(operator_sentence())

  defp bare(char, rest, acc, current), do: words(rest, acc, [char | started(current)], :word)

  defp started(nil), do: []
  defp started(current), do: current

  defp single(?', rest, acc, current), do: words(rest, acc, current, :word)
  defp single(char, rest, acc, current), do: words(rest, acc, [char | current], :single)

  defp double(?", rest, acc, current), do: words(rest, acc, current, :word)

  defp double(?\\, [next | rest], acc, current) when next in [?", ?\\, ?$, ?`],
    do: words(rest, acc, [next | current], :double)

  defp double(char, _rest, _acc, _current) when char in [?$, ?`],
    do: refuse(operator_sentence())

  defp double(char, rest, acc, current), do: words(rest, acc, [char | current], :double)

  defp push(acc, nil), do: acc

  defp push(acc, current) do
    case Enum.reverse(current) do
      [:home | word] -> [{:home, List.to_string(word)} | acc]
      word -> [List.to_string(word) | acc]
    end
  end

  defp bounded([]), do: refuse("A local server needs the command that starts it.")

  defp bounded(words) when length(words) > @max_words,
    do: refuse("A command has at most 128 words.")

  defp bounded(_words), do: :ok

  defp no_assignment([command | _args]) do
    if Regex.match?(@assignment, command),
      do: refuse("A variable goes in a row of its own, not in front of the command."),
      else: :ok
  end

  defp operator_sentence,
    do:
      "Fermix runs the command itself, not through a shell, so it cannot hold a pipe, " <>
        "a redirection, a list or a dollar sign. Quote a character the program needs."

  defp refuse(sentence), do: refuse("command_line", sentence)
  defp refuse(field, sentence), do: {:error, {:invalid_params, field, sentence}}
end
