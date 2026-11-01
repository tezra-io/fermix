defmodule FermixCore.Home.Archive.ConfigText do
  @moduledoc """
  Reads and rewrites string values in a restored `config.toml` line by line,
  touching nothing else.

  `ConfigStore` writes the file by rendering its normalized snapshot, which
  drops comments and every key it does not own, and always under the running
  home. A restore needs the opposite: the file exactly as it was, with only the
  values that named the old home moved to the new one. So this module works on
  the text: one `key = value` per line (the shape `ConfigStore` reads and
  writes), section headers, comments, and basic (`"…"`) and literal (`'…'`)
  strings, including the strings inside an array. A value is rewritten only
  when it is the old root or begins with the old root followed by `/`; keys and
  comments are never rewritten. A file with a multi-line string, which
  `ConfigStore` cannot read either, is refused rather than guessed at.
  """

  alias FermixCore.Setup.SecretWriter

  @type rewritten :: [String.t()]

  @doc """
  Rewrites every string value beginning with `old_root` so it begins with
  `new_root`, answering the new text and the dotted key of each value it
  rewrote, in file order (a key repeats once per rewritten array element).
  """
  @spec rebase(String.t(), Path.t(), Path.t()) ::
          {:ok, String.t(), rewritten()} | {:error, :multiline_string}
  def rebase(contents, root, root) when is_binary(contents) and is_binary(root),
    do: {:ok, contents, []}

  def rebase(contents, old_root, new_root)
      when is_binary(contents) and is_binary(old_root) and old_root != "" and
             is_binary(new_root) and new_root != "" do
    if String.contains?(contents, [~s("""), "'''"]) do
      {:error, :multiline_string}
    else
      {lines, {_section, _key, keys}} =
        contents
        |> String.split("\n")
        |> Enum.map_reduce({"", "", []}, &rebase_line(&1, &2, old_root, new_root))

      {:ok, Enum.join(lines, "\n"), Enum.reverse(keys)}
    end
  end

  @doc """
  How many values in the file are references to secrets held in the OS
  keyring (`SecretWriter.store_of_sentinel/1`), which never travel with a home.
  """
  @spec keyring_references(String.t()) :: non_neg_integer()
  def keyring_references(contents) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.flat_map(&value_tokens/1)
    |> Enum.count(fn token -> SecretWriter.store_of_sentinel(token.value) == {:ok, :keyring} end)
  end

  @doc """
  Where the file keeps a reference to a secret held in the OS keyring: each
  `{section, key}` whose value is `@keyring`, in file order, `section` as its
  header names it (`put/4` takes it back).
  """
  @spec keyring_keys(String.t()) :: [{String.t(), String.t()}]
  def keyring_keys(contents) when is_binary(contents), do: sentinel_keys(contents, :keyring)

  @doc """
  Where the file keeps a reference to a secret held in its file store: each
  `{section, key}` whose value is `@file`, in file order, as `keyring_keys/1`.
  """
  @spec file_keys(String.t()) :: [{String.t(), String.t()}]
  def file_keys(contents) when is_binary(contents), do: sentinel_keys(contents, :file)

  defp sentinel_keys(contents, store) do
    {_section, keys} =
      contents
      |> String.split("\n")
      |> Enum.reduce({"", []}, fn line, {section, keys} ->
        case header(line) do
          {:ok, name} -> {name, keys}
          :none -> {section, sentinel_key(line, section, store) ++ keys}
        end
      end)

    Enum.reverse(keys)
  end

  defp sentinel_key(line, section, store) do
    with key when is_binary(key) <- key_of(line),
         true <-
           Enum.any?(
             value_tokens(line),
             &(SecretWriter.store_of_sentinel(&1.value) == {:ok, store})
           ) do
      [{section, key}]
    else
      _other -> []
    end
  end

  @doc """
  The raw TOML text `key` holds in `[section]` (the value after `=`, its comment
  dropped, trimmed), or `:absent` when the file does not set it there.
  """
  @spec value(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :absent
  def value(contents, section, key)
      when is_binary(contents) and is_binary(section) and is_binary(key) do
    case find_entry(String.split(contents, "\n"), section, key) do
      {_index, line} -> {:ok, raw_value(line)}
      nil -> :absent
    end
  end

  @doc """
  Sets `key` in `[section]` to the TOML text `raw`: in place when the file sets
  it (its comment kept), on the line after the section header when the section
  exists, and in a new section at the end otherwise. Nothing else changes.
  """
  @spec put(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def put(contents, section, key, raw)
      when is_binary(contents) and is_binary(section) and section != "" and is_binary(key) and
             key != "" and is_binary(raw) do
    lines = String.split(contents, "\n")

    case {find_entry(lines, section, key), find_header(lines, section)} do
      {{index, line}, _header} -> List.replace_at(lines, index, replace_value(line, raw))
      {nil, index} when is_integer(index) -> List.insert_at(lines, index + 1, "#{key} = #{raw}")
      {nil, nil} -> append_section(lines, section, key, raw)
    end
    |> Enum.join("\n")
  end

  @doc """
  The tables of the file named `table` or beneath it (`table.<name>…`), each
  as its header line and every line after it up to the next header, in file
  order.
  """
  @spec tables(String.t(), String.t()) :: [String.t()]
  def tables(contents, table)
      when is_binary(contents) and is_binary(table) and table != "" do
    contents
    |> String.split("\n")
    |> blocks()
    |> Enum.filter(fn {name, _lines} -> under_table?(name, table) end)
    |> Enum.map(fn {_name, lines} -> Enum.join(lines, "\n") end)
  end

  @doc "The file without the tables `tables/2` answers for `table`; every other line kept."
  @spec drop_tables(String.t(), String.t()) :: String.t()
  def drop_tables(contents, table)
      when is_binary(contents) and is_binary(table) and table != "" do
    contents
    |> String.split("\n")
    |> blocks()
    |> Enum.reject(fn {name, _lines} -> under_table?(name, table) end)
    |> Enum.flat_map(fn {_name, lines} -> lines end)
    |> Enum.join("\n")
  end

  # The file's lines grouped by the table each belongs to: the lines before the
  # first header belong to the root table, named "".
  defp blocks(lines) do
    lines
    |> Enum.chunk_while(
      {"", []},
      fn line, {name, acc} ->
        case header(line) do
          {:ok, next} -> {:cont, {name, Enum.reverse(acc)}, {next, [line]}}
          :none -> {:cont, {name, [line | acc]}}
        end
      end,
      fn {name, acc} -> {:cont, {name, Enum.reverse(acc)}, nil} end
    )
    |> Enum.reject(&match?({"", []}, &1))
  end

  defp under_table?(name, table), do: name == table or String.starts_with?(name, table <> ".")

  @doc "The string a raw TOML basic or literal string value holds, or `:error`."
  @spec string(String.t()) :: {:ok, String.t()} | :error
  def string(raw) when is_binary(raw) do
    case tokens(raw) do
      [%{start: 0, length: length, value: value}] when length == byte_size(raw) -> {:ok, value}
      _other -> :error
    end
  end

  @doc """
  The dotted keys whose string values are absolute paths outside `root`, once
  each, in file order: settings a move to another host may leave pointing at
  nothing.
  """
  @spec paths_outside(String.t(), Path.t()) :: [String.t()]
  def paths_outside(contents, root) when is_binary(contents) and is_binary(root) do
    {_section, _key, keys} =
      contents
      |> String.split("\n")
      |> Enum.reduce({"", "", []}, &outside_line(&1, &2, root))

    keys |> Enum.reverse() |> Enum.uniq()
  end

  defp outside_line(line, {section, last_key, keys}, root) do
    case header(line) do
      {:ok, name} ->
        {name, "", keys}

      :none ->
        key = key_of(line) || last_key
        foreign = line |> value_tokens() |> Enum.filter(&foreign_path?(&1.value, root))
        {section, key, add_keys(keys, section, key, foreign)}
    end
  end

  defp foreign_path?(value, root),
    do: String.starts_with?(value, "/") and not under?(value, root)

  # Each line with the section it sits in and the key it sets (`:header` for a
  # section header, nil for a line that sets nothing).
  defp located(lines) do
    {located, _section} =
      lines
      |> Enum.with_index()
      |> Enum.map_reduce("", fn {line, index}, section ->
        case header(line) do
          {:ok, name} -> {{index, name, :header, line}, name}
          :none -> {{index, section, key_of(line), line}, section}
        end
      end)

    located
  end

  defp find_entry(lines, section, key) do
    Enum.find_value(located(lines), fn
      {index, ^section, ^key, line} -> {index, line}
      _other -> nil
    end)
  end

  defp find_header(lines, section) do
    Enum.find_value(located(lines), fn
      {index, ^section, :header, _line} -> index
      _other -> nil
    end)
  end

  defp raw_value(line) do
    from = byte_size(key_text(line)) + 1
    to = comment_at(line) || byte_size(line)
    line |> binary_part(from, to - from) |> String.trim()
  end

  defp replace_value(line, raw) do
    comment =
      case comment_at(line) do
        nil -> ""
        at -> " " <> binary_part(line, at, byte_size(line) - at)
      end

    String.trim_trailing(key_text(line)) <> " = " <> raw <> comment
  end

  # A file that ends in a newline keeps it after the new section.
  defp append_section(lines, section, key, raw) do
    added = ["", "[#{section}]", "#{key} = #{raw}"]

    case List.last(lines) do
      "" -> Enum.drop(lines, -1) ++ added ++ [""]
      _last -> lines ++ added
    end
  end

  defp rebase_line(line, {section, last_key, keys}, old_root, new_root) do
    case header(line) do
      {:ok, name} ->
        {line, {name, "", keys}}

      :none ->
        key = key_of(line) || last_key
        tokens = line |> value_tokens() |> Enum.filter(&under?(&1.value, old_root))

        {rewrite(line, tokens, old_root, new_root),
         {section, key, add_keys(keys, section, key, tokens)}}
    end
  end

  defp header(line) do
    case Regex.run(~r/\A\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?\z/, line) do
      [_match, name | _comment] -> {:ok, name}
      nil -> :none
    end
  end

  defp key_of(line) do
    case key_text(line) do
      nil -> nil
      key -> key |> String.trim() |> String.trim("\"") |> String.trim("'")
    end
  end

  defp add_keys(keys, section, key, tokens) do
    dotted = if section == "", do: key, else: section <> "." <> key
    Enum.reduce(tokens, keys, fn _token, acc -> [dotted | acc] end)
  end

  defp under?(value, root), do: value == root or String.starts_with?(value, root <> "/")

  # The string tokens after the line's first `=` outside a string, stopping at
  # a comment. A line with no `=` (an array continuing from the line above) is
  # all value.
  defp value_tokens(line) do
    from =
      case key_text(line) do
        nil -> 0
        key -> byte_size(key) + 1
      end

    line |> tokens() |> Enum.filter(&(&1.start >= from))
  end

  # The text before the line's first `=` outside a string, or nil.
  defp key_text(line) do
    tokens = tokens(line)

    case :binary.matches(line, "=") |> Enum.find(fn {at, 1} -> outside?(at, tokens) end) do
      {at, 1} -> binary_part(line, 0, at)
      nil -> nil
    end
  end

  defp outside?(at, tokens),
    do: not Enum.any?(tokens, &(at >= &1.start and at < &1.start + &1.length))

  defp tokens(line) do
    line
    |> scan()
    |> Enum.take_while(fn {start, _length} -> binary_part(line, start, 1) != "#" end)
    |> Enum.map(&token(line, &1))
  end

  # Where the line's comment starts, outside any string, or nil.
  defp comment_at(line) do
    Enum.find_value(scan(line), fn {start, _length} ->
      if binary_part(line, start, 1) == "#", do: start
    end)
  end

  defp scan(line) do
    ~r/"(?:[^"\\]|\\.)*"|'[^']*'|#/
    |> Regex.scan(line, return: :index)
    |> Enum.map(fn [{start, length}] -> {start, length} end)
  end

  defp token(line, {start, length}) do
    raw = binary_part(line, start, length)
    inner = binary_part(raw, 1, length - 2)

    case raw do
      "\"" <> _rest -> %{start: start, length: length, kind: :basic, value: unescape(inner)}
      "'" <> _rest -> %{start: start, length: length, kind: :literal, value: inner}
    end
  end

  defp rewrite(line, [], _old_root, _new_root), do: line

  defp rewrite(line, tokens, old_root, new_root) do
    {parts, cursor} =
      Enum.reduce(tokens, {[], 0}, fn token, {parts, cursor} ->
        value =
          new_root <>
            binary_part(
              token.value,
              byte_size(old_root),
              byte_size(token.value) - byte_size(old_root)
            )

        before = binary_part(line, cursor, token.start - cursor)
        {[encode(value, token.kind), before | parts], token.start + token.length}
      end)

    [binary_part(line, cursor, byte_size(line) - cursor) | parts]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp encode(value, :literal) do
    if String.contains?(value, "'") or Regex.match?(~r/[\x00-\x1f\x7f]/, value),
      do: encode(value, :basic),
      else: "'" <> value <> "'"
  end

  defp encode(value, :basic) do
    escaped =
      Regex.replace(~r/[\\"\x00-\x1f\x7f]/, value, fn
        "\\" -> "\\\\"
        "\"" -> "\\\""
        <<char>> -> "\\u" <> String.pad_leading(Integer.to_string(char, 16), 4, "0")
      end)

    "\"" <> escaped <> "\""
  end

  defp unescape(raw) do
    Regex.replace(~r/\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)/u, raw, fn _match, escape ->
      unescape_one(escape)
    end)
  end

  defp unescape_one("u" <> hex), do: <<String.to_integer(hex, 16)::utf8>>
  defp unescape_one("U" <> hex), do: <<String.to_integer(hex, 16)::utf8>>
  defp unescape_one("b"), do: "\b"
  defp unescape_one("t"), do: "\t"
  defp unescape_one("n"), do: "\n"
  defp unescape_one("f"), do: "\f"
  defp unescape_one("r"), do: "\r"
  defp unescape_one("e"), do: "\e"
  defp unescape_one(other), do: other
end
