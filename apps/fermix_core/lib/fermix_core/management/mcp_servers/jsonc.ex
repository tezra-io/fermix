defmodule FermixCore.Management.McpServers.Jsonc do
  @moduledoc """
  JSON with comments, as VS Code reads its own settings files, its `mcp.json`
  among them: `//` and `/* */` comments, and a comma before a closing brace or
  bracket. `to_json/1` is the one place that turns such a file into JSON for
  the JSON parser (`ImportSources`), and only for a source whose app accepts
  it.

  It reads the text once, byte by byte, and keeps everything inside a string
  as it is (a `//` in a URL included), so it never changes a value. Outside
  strings a line comment goes up to its line's end, which stays; a block
  comment becomes one space; a trailing comma, with only space and comments
  before the bracket that closes it, goes. Anything else that is not JSON is
  left for the parser to refuse, except a block comment that never closes,
  which is refused here. The text is a settings file already bounded by its
  read, and the result is never longer than it.
  """

  @blank ~c" \t\r\n"
  @closers ~c"}]"

  @doc "The JSON the text means, or `{:error, :unclosed_comment}`."
  @spec to_json(binary()) :: {:ok, binary()} | {:error, :unclosed_comment}
  def to_json(text) when is_binary(text), do: scan(text, text, 0, [], false)

  # `run` is the text from the start of the stretch being kept and `len` how
  # many of its bytes are kept so far, so a stretch is copied as one slice;
  # `acc` holds the slices kept, reversed; `comma?` is a comma read and not yet
  # written, written once the next token shows it is not a trailing one.
  defp scan(<<>>, run, len, acc, comma?),
    do: {:ok, finish(settle(kept(acc, run, len), comma?, nil))}

  defp scan(<<"//", rest::binary>>, run, len, acc, comma?),
    do: line_comment(rest, kept(acc, run, len), comma?)

  defp scan(<<"/*", rest::binary>>, run, len, acc, comma?),
    do: block_comment(rest, [" " | kept(acc, run, len)], comma?)

  defp scan(<<char, rest::binary>>, run, len, acc, comma?) when char in @blank,
    do: scan(rest, run, len + 1, acc, comma?)

  defp scan(<<?,, rest::binary>>, run, len, acc, comma?),
    do: scan(rest, rest, 0, settle(kept(acc, run, len), comma?, ?,), true)

  defp scan(<<char, _rest::binary>> = text, run, len, acc, true),
    do: scan(text, text, 0, settle(kept(acc, run, len), true, char), false)

  defp scan(<<?", rest::binary>>, run, len, acc, false), do: string(rest, run, len + 1, acc)

  defp scan(<<_char, rest::binary>>, run, len, acc, false),
    do: scan(rest, run, len + 1, acc, false)

  # A string that never closes is kept as it is, for the parser to refuse.
  defp string(<<?\\, _escaped, rest::binary>>, run, len, acc), do: string(rest, run, len + 2, acc)
  defp string(<<?", rest::binary>>, run, len, acc), do: scan(rest, run, len + 1, acc, false)
  defp string(<<_char, rest::binary>>, run, len, acc), do: string(rest, run, len + 1, acc)
  defp string(<<>>, run, len, acc), do: {:ok, finish(kept(acc, run, len))}

  defp line_comment(<<?\n, _rest::binary>> = text, acc, comma?),
    do: scan(text, text, 0, acc, comma?)

  defp line_comment(<<_char, rest::binary>>, acc, comma?), do: line_comment(rest, acc, comma?)
  defp line_comment(<<>>, acc, comma?), do: scan(<<>>, <<>>, 0, acc, comma?)

  defp block_comment(<<"*/", rest::binary>>, acc, comma?), do: scan(rest, rest, 0, acc, comma?)
  defp block_comment(<<_char, rest::binary>>, acc, comma?), do: block_comment(rest, acc, comma?)
  defp block_comment(<<>>, _acc, _comma?), do: {:error, :unclosed_comment}

  defp kept(acc, _run, 0), do: acc
  defp kept(acc, run, len), do: [binary_part(run, 0, len) | acc]

  # A comma held back is written unless the token after it closes its object
  # or array.
  defp settle(acc, false, _next), do: acc
  defp settle(acc, true, next) when next in @closers, do: acc
  defp settle(acc, true, _next), do: ["," | acc]

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
