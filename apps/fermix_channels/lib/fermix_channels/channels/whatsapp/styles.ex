defmodule FermixChannels.Channels.WhatsApp.Styles do
  @moduledoc """
  Renders model-authored Markdown into WhatsApp's own inline styles.

  WhatsApp styles text natively but with its own spelling, so Markdown leaks raw
  syntax: `**bold**` arrives as literal asterisks around a *doubled* marker and
  `[label](url)` as literal brackets. This is the dialect
  CHANNEL_LONGFORM_PRESENTATION §3.1 assigns to WhatsApp; the splitter measures
  chunks through `rendered_length/1` so the fill condition sees what WhatsApp
  will actually receive.

  | Markdown | WhatsApp |
  |---|---|
  | `**bold**` | `*bold*` |
  | `*italic*`, `_italic_` | `_italic_` |
  | `~~strike~~` | `~strike~` |
  | `` `code` `` | ```` ```code``` ```` (WhatsApp's only monospace form) |
  | ```` ``` ```` fences | unchanged — already WhatsApp's monospace block |
  | `[label](url)` | `label: url` |
  | `# heading` .. `###### heading` | `*heading*` (one bold line) |
  | `- item`, `* item` | `• item` (indent kept) |
  | `> quote` | plain `> `-prefixed line |
  | pipe table | monospace fence (WhatsApp renders no tables) |

  There is no link markup on WhatsApp — the client auto-links a bare URL — so a
  Markdown link becomes its label followed by the URL, which keeps the URL
  clickable and byte-exact instead of hiding it behind text the reader cannot
  reach. Blockquotes have no native form either; the `>` prefix stays as plain
  text because dropping it would lose the fact that the line is a quotation.

  Fenced blocks pass through verbatim, markers and body alike. Emphasis follows
  the shared walker's flanking discipline, so `snake_case`, `2 * 3 * 4` and bare
  URLs full of underscores survive untouched.
  """

  alias FermixChannels.Outbound.Dialect

  @doc """
  Renders `text` in WhatsApp's inline styles.
  """
  @spec render(String.t()) :: String.t()
  def render(text) when is_binary(text), do: Dialect.render(text, spec())

  @doc """
  Length of the *rendered* form of `text`, in graphemes.

  What the outbound splitter measures a candidate chunk with, so the fill
  condition is computed against the text WhatsApp receives rather than the
  Markdown the model wrote.
  """
  @spec rendered_length(String.t()) :: non_neg_integer()
  def rendered_length(text) when is_binary(text), do: text |> render() |> String.length()

  defp spec do
    %{
      bold: {"*", "*"},
      italic: {"_", "_"},
      strike: {"~", "~"},
      code_span: {"```", "```"},
      link: &link/2,
      heading: &heading/1,
      heading_blank_after: false,
      bullet: "• ",
      code_block: &Function.identity/1,
      table: &table/1
    }
  end

  defp link(label, url), do: label <> ": " <> url

  defp heading(""), do: ""
  defp heading(text), do: "*" <> text <> "*"

  defp table(rows), do: ["```"] ++ Dialect.align_rows(rows) ++ ["```"]
end
