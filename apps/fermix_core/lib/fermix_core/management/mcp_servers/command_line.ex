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

  `tokens/2` reads a line Fermix reads but never runs as one command, such as a
  pasted `claude mcp add` line, by the same rules with one difference: a `$` a
  shell would expand (unquoted, or inside double quotes) is kept as written
  rather than refused, and each word says whether it holds one, so the caller
  decides what such a word means.
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
    with {:ok, words} <- read(line, home, :refuse),
         :ok <- no_assignment(words) do
      [command | args] = words
      {:ok, {command, args}}
    end
  end

  @doc """
  The words of `line`, each with whether it holds a `$` a shell would expand,
  which is kept as written; every other refusal is `split/2`'s, naming
  `command_line`, and a leading `~` is `home` as there.
  """
  @spec tokens(String.t(), Path.t()) :: {:ok, [{String.t(), boolean()}]} | {:error, refusal()}
  def tokens(line, home) when is_binary(line) and is_binary(home) do
    with {:ok, words} <- read(line, home, :keep) do
      {:ok, Enum.map(words, &token/1)}
    end
  end

  @doc "The refusal of a line that needs a shell to mean what it says."
  @spec shell_sentence() :: String.t()
  def shell_sentence,
    do:
      "Fermix runs the command itself, not through a shell, so it cannot hold a pipe, " <>
        "a redirection, a list or a dollar sign. Quote a character the program needs."

  # `dollars` is `:refuse` for a command that runs, `:keep` for `tokens/2`.
  defp read(line, home, dollars) do
    with {:ok, words} <- words(String.to_charlist(line), [], nil, :blank, dollars),
         {:ok, words} <- at_home(words, home),
         :ok <- bounded(words) do
      {:ok, words}
    end
  end

  defp token({:dollar, word}), do: {word, true}
  defp token(word), do: {word, false}

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

  defp home_word(word, {:ok, acc}, home) do
    case at_home_word(word, home) do
      {:ok, expanded} -> {:cont, {:ok, [expanded | acc]}}
      {:error, _refusal} = error -> {:halt, error}
    end
  end

  defp at_home_word({:dollar, word}, home) do
    with {:ok, expanded} <- at_home_word(word, home), do: {:ok, {:dollar, expanded}}
  end

  defp at_home_word({:home, word}, home), do: expand_home(word, home, "command_line")
  defp at_home_word(word, _home), do: {:ok, word}

  @doc "The line `split/2` reads as exactly these words."
  @spec join([String.t()]) :: String.t()
  def join(words) when is_list(words), do: Enum.map_join(words, " ", &quote_word/1)

  defp quote_word(word) do
    if Regex.match?(@safe_word, word),
      do: word,
      else: "'" <> String.replace(word, "'", ~S('\'')) <> "'"
  end

  # `current` is the word being read, reversed, or nil between words; `mode` is
  # `:blank`, `:word`, `:single` or `:double`; `dollars` says what a `$` a shell
  # would expand does: `:refuse` refuses the line, `:keep` keeps it and marks
  # its word for `tokens/2`.
  defp words([], acc, current, mode, _dollars) when mode in [:blank, :word],
    do: {:ok, Enum.reverse(push(acc, current))}

  defp words([], _acc, _current, _mode, _dollars),
    do: refuse("A quotation mark is not closed.")

  defp words([char | rest], acc, current, :single, dollars),
    do: single(char, rest, acc, current, dollars)

  defp words([char | rest], acc, current, :double, dollars),
    do: double(char, rest, acc, current, dollars)

  defp words([char | rest], acc, current, _mode, dollars),
    do: bare(char, rest, acc, current, dollars)

  defp bare(char, rest, acc, current, dollars) when char in [?\s, ?\t],
    do: words(rest, push(acc, current), nil, :blank, dollars)

  defp bare(char, _rest, _acc, _current, _dollars) when char in [?\n, ?\r],
    do: refuse("A command is one line.")

  defp bare(?', rest, acc, current, dollars),
    do: words(rest, acc, started(current), :single, dollars)

  defp bare(?", rest, acc, current, dollars),
    do: words(rest, acc, started(current), :double, dollars)

  defp bare(?\\, [], _acc, _current, _dollars),
    do: refuse("A command cannot end with a backslash.")

  defp bare(?\\, [next | rest], acc, current, dollars),
    do: words(rest, acc, [next | started(current)], :word, dollars)

  # A `~` that starts a word is marked for `at_home/2`, unless a quote before
  # the word's first `/` quotes it.
  defp bare(?~, rest, acc, nil, dollars) do
    prefix = Enum.take_while(rest, &(&1 not in [?/, ?\s, ?\t]))

    if Enum.any?(prefix, &(&1 in @quoting)),
      do: words(rest, acc, [?~], :word, dollars),
      else: words(rest, acc, [?~, :home], :word, dollars)
  end

  defp bare(?$, rest, acc, current, :keep),
    do: words(rest, acc, [?$, :dollar | started(current)], :word, :keep)

  defp bare(char, _rest, _acc, _current, _dollars) when char in @operators,
    do: refuse(shell_sentence())

  defp bare(char, rest, acc, current, dollars),
    do: words(rest, acc, [char | started(current)], :word, dollars)

  defp started(nil), do: []
  defp started(current), do: current

  defp single(?', rest, acc, current, dollars), do: words(rest, acc, current, :word, dollars)

  defp single(char, rest, acc, current, dollars),
    do: words(rest, acc, [char | current], :single, dollars)

  defp double(?", rest, acc, current, dollars), do: words(rest, acc, current, :word, dollars)

  defp double(?\\, [next | rest], acc, current, dollars) when next in [?", ?\\, ?$, ?`],
    do: words(rest, acc, [next | current], :double, dollars)

  defp double(?$, rest, acc, current, :keep),
    do: words(rest, acc, [?$, :dollar | current], :double, :keep)

  defp double(char, _rest, _acc, _current, _dollars) when char in [?$, ?`],
    do: refuse(shell_sentence())

  defp double(char, rest, acc, current, dollars),
    do: words(rest, acc, [char | current], :double, dollars)

  defp push(acc, nil), do: acc

  # A word that holds a kept `$` comes back marked, around what it is otherwise.
  defp push(acc, current) do
    chars = Enum.reverse(current)
    word = word(Enum.reject(chars, &(&1 == :dollar)))
    if :dollar in chars, do: [{:dollar, word} | acc], else: [word | acc]
  end

  defp word([:home | chars]), do: {:home, List.to_string(chars)}
  defp word(chars), do: List.to_string(chars)

  defp bounded([]), do: refuse("A local server needs the command that starts it.")

  defp bounded(words) when length(words) > @max_words,
    do: refuse("A command has at most 128 words.")

  defp bounded(_words), do: :ok

  defp no_assignment([command | _args]) do
    if Regex.match?(@assignment, command),
      do: refuse("A variable goes in a row of its own, not in front of the command."),
      else: :ok
  end

  defp refuse(sentence), do: refuse("command_line", sentence)
  defp refuse(field, sentence), do: {:error, {:invalid_params, field, sentence}}
end
