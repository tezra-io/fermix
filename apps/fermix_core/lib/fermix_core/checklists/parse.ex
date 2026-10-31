defmodule FermixCore.Checklists.Parse do
  @moduledoc """
  A list written as markdown, back into rows (MILESTONE_85 §05): what a
  `replace` op carries. Pure, and the inverse of `Checklists.Render`: render
  then parse is the identity on rows, which a property test holds.

  A row is `## [n] Name` for a section, `- [ ] [n] words` or `- [x] [n] words`
  for an item (`*` for `-` too), and the indented lines under an item are its
  note. `[n]` is optional: a line without one is a new row. A list's header
  line and its data line, as a read wrote them, are skipped, as are blank
  lines. What Render adds to the owner's words is undone: a leading backslash
  is dropped, and a row framed as written after outside content comes back
  with its words unquoted and `stamped: true`.

  A leading `[n]` of ASCII digits is always the row's handle, whatever space
  follows it, since Render escapes words that begin with one. Anything else is
  refused with its line number, so a list is never read as something it does
  not say: a line that is not a row, a heading of any level but `## `, an
  indented item or heading (a list does not nest), a note with no item above
  it, a note under a section, a malformed frame, or a second list's header.
  """

  alias FermixCore.Checklists.Render

  @item ~r/\A[-*] \[([ xX])\]\s*(.*)\z/su
  @section ~r/\A## \s*(.*)\z/su
  @handle ~r/\A\[([0-9]+)\]\s*(.*)\z/su
  @header ~r/\A(?:# )?List ".*\(ck_[0-9a-z]{10}\)/u

  @typedoc "One row as markdown carries it: `n` is nil on a line without a number."
  @type row :: %{
          n: pos_integer() | nil,
          kind: :item | :section,
          text: String.t(),
          note: String.t() | nil,
          done: boolean(),
          stamped: boolean()
        }

  @typedoc "Why a line was refused."
  @type reason ::
          :not_a_row
          | :heading_level
          | :nested
          | :note_without_item
          | :note_on_section
          | :bad_frame
          | :second_list

  @doc "The rows `text` writes, in order, or the first line it cannot read."
  @spec rows(String.t()) :: {:ok, [row()]} | {:error, {:line, pos_integer(), reason()}}
  def rows(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &read_line/2)
    |> finish()
  end

  defp finish({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp finish({:error, _reason} = error), do: error

  defp read_line({line, number}, {:ok, rows}) do
    case line(String.trim_trailing(line), rows) do
      {:ok, rows} -> {:cont, {:ok, rows}}
      {:error, reason} -> {:halt, {:error, {:line, number, reason}}}
    end
  end

  defp line("", rows), do: {:ok, rows}

  defp line(<<first::utf8, _rest::binary>> = line, rows) when first in [?\s, ?\t] do
    content = String.trim(line)
    if Render.row_like?(content), do: {:error, :nested}, else: note(content, rows)
  end

  defp line(line, rows) do
    cond do
      line in Render.data_lines() -> {:ok, rows}
      Regex.match?(@header, line) -> header(rows)
      captures = Regex.run(@item, line) -> item(captures, rows)
      captures = Regex.run(@section, line) -> section(captures, rows)
      String.starts_with?(line, "#") -> {:error, :heading_level}
      true -> {:error, :not_a_row}
    end
  end

  # A header is skipped at the top; after a row it would be a second list.
  defp header([]), do: {:ok, []}
  defp header(_rows), do: {:error, :second_list}

  defp item([_line, box, rest], rows) do
    with {:ok, n, words} <- handle(rest),
         {:ok, text, stamped} <- words(words) do
      row = %{n: n, kind: :item, text: text, note: nil, done: box != " ", stamped: stamped}
      {:ok, [row | rows]}
    end
  end

  defp section([_line, rest], rows) do
    with {:ok, n, words} <- handle(rest),
         {:ok, text, stamped} <- words(words) do
      {:ok,
       [%{n: n, kind: :section, text: text, note: nil, done: false, stamped: stamped} | rows]}
    end
  end

  defp handle(rest) do
    case Regex.run(@handle, rest) do
      [_rest, n, words] -> {:ok, String.to_integer(n), words}
      nil -> {:ok, nil, rest}
    end
  end

  defp note(_line, []), do: {:error, :note_without_item}
  defp note(_line, [%{kind: :section} | _rows]), do: {:error, :note_on_section}

  defp note(line, [row | rows]) do
    with {:ok, piece, framed} <- note_piece(line) do
      note = if row.note, do: row.note <> "\n" <> piece, else: piece
      {:ok, [%{row | note: note, stamped: row.stamped or framed} | rows]}
    end
  end

  defp note_piece(line) do
    frame = Render.frame() <> " "

    cond do
      String.starts_with?(line, frame) -> unquote_words(String.replace_prefix(line, frame, ""))
      String.starts_with?(line, "\\") -> {:ok, String.replace_prefix(line, "\\", ""), false}
      true -> {:ok, line, false}
    end
  end

  defp words(words), do: note_piece(words)

  defp unquote_words(quoted) do
    case Jason.decode(quoted) do
      {:ok, text} when is_binary(text) -> {:ok, text, true}
      _not_one_string -> {:error, :bad_frame}
    end
  end
end
