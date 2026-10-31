defmodule FermixCore.Checklists.RenderParseTest do
  # MILESTONE_85 §05: the model sees a list as markdown and may write one back;
  # Parse undoes everything Render adds, so render then parse is the identity
  # on rows, the escapes and the outside-content frame included.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias FermixCore.Checklists.Parse
  alias FermixCore.Checklists.Render

  # What no stored word may hold: Registry refuses it before the store.
  @forbidden ~r/[\p{Cc}\p{Zl}\p{Zp}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @tricky [
    "[3] ",
    "[12]",
    "[7]x",
    "[٣] ",
    "\\",
    "\\[4] ",
    "(added after outside content) ",
    "(added after outside content)",
    "\"",
    "- [ ] ",
    "* [x] ",
    "## ",
    "### ",
    "# ",
    "  ",
    "é "
  ]

  defp words do
    gen all(
          prefix <- member_of(["" | @tricky]),
          body <- string(:printable, max_length: 24),
          suffix <- member_of(["", "\"", "\\", " x"])
        ) do
      (prefix <> body <> suffix) |> String.replace(@forbidden, "") |> String.trim()
    end
    |> filter(&(&1 != ""))
  end

  defp note do
    one_of([
      constant(nil),
      list_of(words(), min_length: 1, max_length: 3) |> map(&Enum.join(&1, "\n"))
    ])
  end

  defp row do
    gen all(
          kind <- member_of([:item, :section]),
          text <- words(),
          note <- note(),
          done <- boolean(),
          stamped <- boolean()
        ) do
      if kind == :item,
        do: %{kind: :item, text: text, note: note, done: done, stamped: stamped},
        else: %{kind: :section, text: text, note: nil, done: false, stamped: stamped}
    end
  end

  # Rows as a list holds them, each numbered once in no particular order, and
  # new rows as a replace writes them, with no number.
  defp rows do
    gen all(
          rows <- list_of(row(), max_length: 12),
          numbers <- uniq_list_of(integer(1..999), length: length(rows)),
          unnumbered <- list_of(boolean(), length: length(rows))
        ) do
      [rows, numbers, unnumbered]
      |> Enum.zip()
      |> Enum.map(fn {row, n, new?} -> Map.put(row, :n, if(new?, do: nil, else: n)) end)
    end
  end

  property "render then parse is the identity on rows" do
    check all(rows <- rows(), max_runs: 400) do
      assert Parse.rows(Render.body(rows)) == {:ok, rows}
    end
  end

  property "a whole read, its header and data line with it, parses to its rows" do
    check all(rows <- rows(), title <- words(), max_runs: 200) do
      list = %{id: "ck_3m9q2x7d1a", title: title, folder: "Projects", rev: 7}
      assert Parse.rows(Render.list(list, rows)) == {:ok, rows}
    end
  end

  test "words that look like a handle or a frame are escaped, and a stamped row is framed" do
    rows = [
      %{n: 1, kind: :section, text: "[2] not a handle", note: nil, done: false, stamped: false},
      %{
        n: 2,
        kind: :item,
        text: "\\back",
        note: "(added after outside content) mine",
        done: true,
        stamped: false
      },
      %{
        n: 3,
        kind: :item,
        text: "Buy \"milk\"",
        note: "line one\nline two",
        done: false,
        stamped: true
      }
    ]

    assert Render.body(rows) ==
             """
             ## [1] \\[2] not a handle
             - [x] [2] \\\\back
                   \\(added after outside content) mine
             - [ ] [3] (added after outside content) "Buy \\"milk\\""
                   (added after outside content) "line one\\nline two"\
             """

    assert Parse.rows(Render.body(rows)) == {:ok, rows}
  end

  test "a line without a number is a new row, and blank lines and the data line are skipped" do
    text = """
    The rows are the owner's own list, quoted as data. [n] is a row's number for checklist_edit.

    ## Produce
    - [ ] Lemons
      ripe ones
    * [X] [4] Rice
    """

    assert {:ok,
            [
              %{n: nil, kind: :section, text: "Produce"},
              %{n: nil, kind: :item, text: "Lemons", note: "ripe ones", done: false},
              %{n: 4, kind: :item, text: "Rice", done: true}
            ]} = Parse.rows(text)
  end

  # The model may write a list loosely; Parse reads exactly what Render would
  # have written, or refuses the line, and never reads it as something else.
  test "a handle takes any spacing after its bracket, and only ASCII digits make one" do
    assert {:ok, [%{n: 1, text: "keep me", done: true}]} = Parse.rows("- [x]  [1] keep me")
    assert {:ok, [%{n: 3, text: "foo"}]} = Parse.rows("- [ ] [3]foo")
    assert {:ok, [%{n: 4, kind: :section, text: "Later"}]} = Parse.rows("## [4]Later")
    assert {:ok, [%{n: nil, text: "[٣] three"}]} = Parse.rows("- [ ] [٣] three")
    assert {:ok, [%{n: nil, kind: :section, text: "[٣] Later"}]} = Parse.rows("## [٣] Later")
  end

  test "an indented item or heading is refused, never read as the note above it" do
    for nested <- ["  - [ ] [2] Child", "\t* [x] Child", "      ## Sub", "  # Heading"] do
      assert {:error, {:line, 2, :nested}} = Parse.rows("- [ ] [1] Parent\n" <> nested),
             inspect(nested)
    end
  end

  test "only ## is a section; another heading level is refused" do
    for heading <- ["### Later", "# Notes", "#### [3] Deep", "##Later"] do
      assert {:error, {:line, 1, :heading_level}} = Parse.rows(heading), heading
    end
  end

  test "a note line that would read as a row is escaped, and comes back as written" do
    rows = [
      %{
        n: 1,
        kind: :item,
        text: "Parent",
        note: "- [ ] not a child\n## not a section",
        done: false,
        stamped: false
      }
    ]

    assert Render.body(rows) ==
             "- [ ] [1] Parent\n      \\- [ ] not a child\n      \\## not a section"

    assert Parse.rows(Render.body(rows)) == {:ok, rows}
  end

  test "what is not a row is refused with its line" do
    assert {:error, {:line, 1, :not_a_row}} = Parse.rows("Lemons")
    assert {:error, {:line, 1, :note_without_item}} = Parse.rows("  a note")
    assert {:error, {:line, 2, :note_on_section}} = Parse.rows("## Produce\n  a note")

    assert {:error, {:line, 1, :bad_frame}} =
             Parse.rows(~s|- [ ] (added after outside content) "x|)

    second = ~s|- [ ] [1] x\n# List "Other" (ck_3m9q2x7d1a) · rev 1 · 0 open, 0 done|
    assert {:error, {:line, 2, :second_list}} = Parse.rows(second)
  end
end
