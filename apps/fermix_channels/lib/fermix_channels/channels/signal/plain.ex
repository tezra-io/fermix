defmodule FermixChannels.Channels.Signal.Plain do
  @moduledoc """
  Strips model-authored Markdown down to clean plain text for Signal.

  `signal-cli send -m <text>` transmits an unstyled message body, so every
  Markdown marker Fermix leaves in place is punctuation the reader has to read
  around: `**bold**`, `[label](url)`, `### Heading`. This is the plain dialect
  CHANNEL_LONGFORM_PRESENTATION §3.1 assigns to Signal — decoration removed,
  content and URLs preserved byte-for-byte.

  | Markdown | Signal |
  |---|---|
  | `**bold**`, `*italic*`, `_italic_`, `~~strike~~` | marker removed, text kept |
  | `` `code` `` | backticks removed, text kept |
  | `[label](url)` | `label: url` |
  | `# heading` .. `###### heading` | the bare line, blank line after it |
  | `- item`, `* item` | `• item` (indent kept) |
  | ```` ``` ```` fenced block | fence markers dropped, body indented verbatim |
  | `> quote` | plain `> `-prefixed line |
  | pipe table | aligned rows, indented like a code block |

  A fenced block's body is emitted exactly as written, only shifted right, so
  code stays copy-pasteable — indentation is the one plain-text device that
  survives a client with no monospace. Emphasis follows the shared walker's
  flanking discipline, so `snake_case`, `2 * 3 * 4` and bare URLs full of
  underscores survive untouched, and a link's URL always reaches the reader
  intact (MILESTONE_31 §9.5).

  ## Style ranges are deferred

  signal-cli can carry real bold/italic spans as `--text-style START:LENGTH:STYLE`
  ranges, but emitting them needs a renderer that returns `{plain_text, ranges}`
  measured in the code units signal-cli counts — a different shape from this
  string-to-string rewriter — and a `send_message/4` client contract that
  accepts them, so v1 ships plain text only and styling is a follow-up.
  """

  alias FermixChannels.Outbound.Dialect

  @indent "    "

  @doc """
  Renders `text` as plain text with the Markdown decoration removed.
  """
  @spec render(String.t()) :: String.t()
  def render(text) when is_binary(text), do: Dialect.render(text, spec())

  @doc """
  Length of the *rendered* form of `text`, in graphemes.

  What the outbound splitter measures a candidate chunk with, so the readability
  ceiling is computed against the text the reader sees rather than the Markdown
  the model wrote.
  """
  @spec rendered_length(String.t()) :: non_neg_integer()
  def rendered_length(text) when is_binary(text), do: text |> render() |> String.length()

  defp spec do
    %{
      bold: {"", ""},
      italic: {"", ""},
      strike: {"", ""},
      code_span: {"", ""},
      link: &link/2,
      heading: &Function.identity/1,
      heading_blank_after: true,
      bullet: "• ",
      code_block: &code_block/1,
      table: &table/1
    }
  end

  defp link(label, url), do: label <> ": " <> url

  # The block arrives with its opening fence and, unless the model left it
  # unterminated, its closing fence. Both are markup; the body is content.
  defp code_block([_open | rest]) do
    rest
    |> drop_closing_fence()
    |> Enum.map(&(@indent <> &1))
  end

  defp drop_closing_fence([]), do: []

  defp drop_closing_fence(lines) do
    if lines |> List.last() |> fence?(), do: Enum.drop(lines, -1), else: lines
  end

  defp fence?(line), do: line |> String.trim_leading() |> String.starts_with?("```")

  defp table(rows), do: rows |> Dialect.align_rows() |> Enum.map(&(@indent <> &1))
end
