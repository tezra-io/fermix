defmodule FermixChannels.Channels.Slack.Mrkdwn do
  @moduledoc """
  Renders model-authored Markdown into Slack's `mrkdwn` dialect.

  Slack does not read Markdown. Left alone, `**bold**` arrives as literal
  asterisks and `[label](url)` as literal brackets — the raw-syntax leak
  CHANNEL_LONGFORM_PRESENTATION §3.1 assigns this dialect to close. The
  transform runs on every outbound text send, and the splitter measures chunks
  through `rendered_length/1` so the fill condition sees the text Slack will
  actually receive.

  | Markdown | mrkdwn |
  |---|---|
  | `**bold**` | `*bold*` |
  | `*italic*`, `_italic_` | `_italic_` |
  | `~~strike~~` | `~strike~` |
  | `[label](url)` | `<url\\|label>` |
  | `# heading` .. `###### heading` | `*heading*` (one bold line) |
  | `- item`, `* item` | `• item` (indent kept) |
  | `` `code` ``, ```` ``` ```` fences | unchanged — mrkdwn shares the syntax |
  | `> quote` | unchanged — mrkdwn's own blockquote |
  | pipe table | monospace fence (Slack renders no tables) |

  Fenced blocks are handed through verbatim, markers and body alike: their
  contents are never walked, so a `*` or `_` inside code cannot be re-marked.

  Emphasis follows the flanking discipline of the shared walker, so
  `snake_case`, `2 * 3 * 4` and bare URLs full of underscores survive untouched.

  ## Not escaped

  Slack asks senders to escape `&`, `<` and `>` in message text. This renderer
  deliberately does not: `>` is the blockquote marker mrkdwn reads at line start
  and `<…|…>` is the link form emitted above, so escaping the three characters
  correctly means teaching the walker which occurrences are markup and which are
  prose. That is a separate change with its own golden set, and half-escaping is
  worse than not escaping — a stray `&gt;` in prose is a visible defect where a
  bare `<` in prose is, at worst, an unwanted auto-link.
  """

  alias FermixChannels.Outbound.Dialect

  @doc """
  Renders `text` as Slack mrkdwn.
  """
  @spec render(String.t()) :: String.t()
  def render(text) when is_binary(text), do: Dialect.render(text, spec())

  @doc """
  Length of the *rendered* form of `text`, in graphemes.

  What the outbound splitter measures a candidate chunk with, so the fill
  condition is computed against the text Slack receives rather than the Markdown
  the model wrote.
  """
  @spec rendered_length(String.t()) :: non_neg_integer()
  def rendered_length(text) when is_binary(text), do: text |> render() |> String.length()

  defp spec do
    %{
      bold: {"*", "*"},
      italic: {"_", "_"},
      strike: {"~", "~"},
      code_span: {"`", "`"},
      link: &link/2,
      heading: &heading/1,
      heading_blank_after: false,
      bullet: "• ",
      code_block: &Function.identity/1,
      table: &table/1
    }
  end

  defp link(label, url), do: "<" <> url <> "|" <> label <> ">"

  defp heading(""), do: ""
  defp heading(text), do: "*" <> text <> "*"

  defp table(rows), do: ["```"] ++ Dialect.align_rows(rows) ++ ["```"]
end
