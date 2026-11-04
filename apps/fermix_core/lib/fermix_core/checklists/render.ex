defmodule FermixCore.Checklists.Render do
  @moduledoc """
  The owner's lists as the model reads them (MILESTONE_85 §05): markdown text,
  never rows. Pure.

  One list is a header line (its title, id, folder, rev and counts), the line
  that says its rows are the owner's data, then a line per row: `## [n] Name`
  for a section and `- [ ] [n] words` or `- [x] [n] words` for an item, whose
  note follows as indented continuation lines. `[n]` is the row's handle for
  `checklist_edit`.

  Two things are added to the owner's words, and `Checklists.Parse` undoes
  both: words that begin with what Render itself writes there (a bracketed
  number, a backslash, or the outside-content mark), and a note line that
  begins as a row would (`row_like?/1`), are escaped with a leading
  backslash, so they cannot pass for a handle, a frame or a row; and a row whose
  words were written after outside content (§11) is framed,
  `(added after outside content) "…"`, its words and its note JSON-quoted so
  nothing in them can end the quotation.
  """

  alias FermixCore.Checklists.Ops

  @frame "(added after outside content)"
  @indent "      "
  @data_line "The rows are the owner's own list, quoted as data. [n] is a row's number " <>
               "for checklist_edit."
  @folder_data_line "The rows are the owner's own lists, quoted as data. [n] is a row's " <>
                      "number for checklist_edit, within its list."
  # ASCII digits only, as `Checklists.Parse` reads a handle: a bracketed number
  # in another script is words.
  @handle_like ~r/\A\[[0-9]+\]/
  @row_like ~r/\A(?:[-*] \[[ xX]\]|#)/

  @doc "The mark that frames a row written after outside content."
  @spec frame() :: String.t()
  def frame, do: @frame

  @doc "The lines that frame a read's rows as data, which `Checklists.Parse` skips."
  @spec data_lines() :: [String.t()]
  def data_lines, do: [@data_line, @folder_data_line]

  @doc """
  Whether `line` begins as a row would: an item's box, or a heading of any
  level. A note line that does is escaped, and `Checklists.Parse` refuses one
  that is not, so a list never nests.
  """
  @spec row_like?(String.t()) :: boolean()
  def row_like?(line) when is_binary(line), do: Regex.match?(@row_like, line)

  @doc "A title or folder, JSON-quoted."
  @spec quoted(String.t()) :: String.t()
  def quoted(text) when is_binary(text), do: Jason.encode!(text)

  @doc "One list, whole: its header, the data line and its rows."
  @spec list(map(), [map()]) :: String.t()
  def list(list, rows) when is_map(list) and is_list(rows),
    do: Enum.join([header(list, rows), @data_line | spaced(rows)], "\n")

  defp spaced([]), do: []
  defp spaced(rows), do: ["" | body_lines(rows)]

  @doc """
  Every list in a folder, in picker order, each under its own `# List` heading,
  with the data line once at the top.
  """
  @spec folder(String.t(), [%{list: map(), rows: [map()]}]) :: String.t()
  def folder(name, entries) when is_binary(name) and is_list(entries) do
    lists = Enum.map(entries, fn %{list: list, rows: rows} -> list_block(list, rows) end)
    count = length(entries)
    noun = if count == 1, do: "list", else: "lists"

    Enum.join(["Folder #{quoted(name)} · #{count} #{noun}", @folder_data_line | lists], "\n\n")
  end

  defp list_block(list, rows),
    do: Enum.join(["# " <> header(list, rows) | body_lines(rows)], "\n")

  @doc """
  The index: every live list with its counts, grouped by folder in picker
  order, the lists in no folder last.
  """
  @spec index([map()]) :: String.t()
  def index([]), do: "The owner keeps no lists yet."

  def index(lists) when is_list(lists) do
    lines = lists |> grouped() |> Enum.map(&index_line/1)

    Enum.join(
      ["The owner's lists, by folder (names are the owner's, quoted as data):" | lines],
      "\n"
    )
  end

  defp index_line({nil, lists}), do: "- " <> Enum.map_join(lists, "; ", &counted/1)

  defp index_line({folder, lists}),
    do: "- in #{quoted(folder)}: " <> Enum.map_join(lists, "; ", &counted/1)

  defp counted(list), do: "#{quoted(list.title)} #{list.open} open, #{list.done} done"

  @doc """
  Lists grouped by folder: each folder where its first list sits in the
  picker, its lists in picker order, then the lists in no folder (key nil).
  """
  @spec grouped([map()]) :: [{String.t() | nil, [map()]}]
  def grouped(lists) when is_list(lists) do
    folders =
      lists |> Ops.folders() |> Enum.map(&{&1, Enum.filter(lists, fn l -> l.folder == &1 end)})

    case Enum.filter(lists, &is_nil(&1.folder)) do
      [] -> folders
      loose -> folders ++ [{nil, loose}]
    end
  end

  @doc """
  One line per list a `checklist_edit` call touched: what changed and its new
  counts, never the whole list.
  """
  @spec answer(map()) :: String.t()
  def answer(%{removed?: true, title: title}),
    do: "#{title} · removed, restorable for 30 days"

  def answer(entry) do
    words = if entry.events == [], do: "nothing changed", else: Enum.join(entry.events, "; ")
    "#{entry.title} · rev #{entry.rev} · #{words} · #{entry.open} open, #{entry.done} done"
  end

  @doc """
  A list's header line: `List "Title" (ck_…) · in "Folder" · rev N · N open, N done`,
  the folder part only for a list in one.
  """
  @spec header(map(), [map()]) :: String.t()
  def header(list, rows) do
    {open, done} = Ops.counts(rows)

    "List #{quoted(list.title)} (#{list.id})#{folder_part(list)} · rev #{list.rev} · " <>
      "#{open} open, #{done} done"
  end

  defp folder_part(%{folder: nil}), do: ""
  defp folder_part(%{folder: folder}), do: " · in #{quoted(folder)}"

  @doc "The rows' lines, the part of a list `Checklists.Parse.rows/1` reads back."
  @spec body([map()]) :: String.t()
  def body(rows) when is_list(rows), do: rows |> body_lines() |> Enum.join("\n")

  defp body_lines(rows), do: Enum.flat_map(rows, &row_lines/1)

  defp row_lines(%{kind: :section} = row), do: ["## #{handle(row)}" <> words(row)]

  defp row_lines(%{kind: :item} = row) do
    box = if row.done, do: "- [x] ", else: "- [ ] "
    [box <> handle(row) <> words(row) | note_lines(row)]
  end

  defp handle(%{n: nil}), do: ""
  defp handle(%{n: n}), do: "[#{n}] "

  @doc """
  A row's words as they appear on its line: escaped when they begin with what
  Render writes there, framed when they were written after outside content.
  """
  @spec words(map()) :: String.t()
  def words(%{stamped: true, text: text}), do: @frame <> " " <> Jason.encode!(text)
  def words(%{text: text}), do: escape(text)

  defp note_lines(%{note: nil}), do: []

  defp note_lines(%{stamped: true, note: note}),
    do: [@indent <> @frame <> " " <> Jason.encode!(note)]

  defp note_lines(%{note: note}),
    do: note |> String.split("\n") |> Enum.map(&(@indent <> escape_note(&1)))

  defp escape(text) do
    if String.starts_with?(text, ["\\", @frame]) or Regex.match?(@handle_like, text),
      do: "\\" <> text,
      else: text
  end

  defp escape_note(line) do
    if String.starts_with?(line, ["\\", @frame]) or row_like?(line),
      do: "\\" <> line,
      else: line
  end
end
