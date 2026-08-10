defmodule FermixCore.Tools.SnippetSanitizer do
  @moduledoc """
  Plain text out of a short provider-supplied display string (MILESTONE_31
  §10.2).

  Search providers decorate titles, descriptions, and labels with highlight
  markup (`<strong>`) and HTML entities. None of it may reach the model as
  markup: a tool result is untrusted content, and rendering provider tags is
  how injected markup earns authority it never had.

  This is deliberately not `Tools.HtmlText`, which renders a whole fetched
  *document* into markdown-light text (headings, links, lists). A place name is
  not a document; running a document renderer over a 40-character label would
  reformat it. Three ordered transforms, nothing else:

    1. drop tags, replacing each with a space so `Quiet<br/>coffee` does not
       fuse into one word;
    2. decode character references — once, over the tag-stripped text, so
       `&lt;b&gt;` stays visible text rather than being promoted into a tag and
       then silently stripped. The decoded text is data, and every tool result
       stays inside the existing `<untrusted_tool_result>` framing;
    3. collapse whitespace runs and trim.

  An unknown entity is left exactly as written. Dropping it would delete
  content the provider sent, and a snippet reading `100 deg` where the source
  said `100 &fakeentity; deg` is a quieter lie than the raw entity.

  M31 adopts this in the place adapter only; retrofitting the existing
  `web_search` backends is a separate cleanup (§10.2).
  """

  # Both bounds of a tag must be present — a bare `<` in "open 8 < 9 hours" is
  # text, not markup.
  @tag ~r/<[^>]*>/
  @entity ~r/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/
  @whitespace ~r/\s+/u

  # The references search snippets actually carry. Anything else is left as
  # written rather than guessed at.
  @named_entities %{
    "amp" => "&",
    "apos" => "'",
    "bull" => "•",
    "deg" => "°",
    "gt" => ">",
    "hellip" => "…",
    "ldquo" => "“",
    "lsquo" => "‘",
    "lt" => "<",
    "mdash" => "—",
    "middot" => "·",
    "nbsp" => " ",
    "ndash" => "–",
    "quot" => "\"",
    "rdquo" => "”",
    "rsquo" => "’"
  }

  @doc """
  Sanitizes one short display string.

  Binary in, binary out. A non-binary raises: callers parse provider payloads
  and must type-check there, where a wrong type is reportable as a parser
  change rather than coerced into text here.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(text) when is_binary(text) do
    text
    |> strip_tags()
    |> decode_entities()
    |> collapse_whitespace()
  end

  defp strip_tags(text), do: Regex.replace(@tag, text, " ")

  defp decode_entities(text), do: Regex.replace(@entity, text, &decode_entity/2)

  defp decode_entity(matched, "#x" <> hex), do: codepoint(matched, hex, 16)
  defp decode_entity(matched, "#X" <> hex), do: codepoint(matched, hex, 16)
  defp decode_entity(matched, "#" <> digits), do: codepoint(matched, digits, 10)
  defp decode_entity(matched, name), do: Map.get(@named_entities, name, matched)

  defp codepoint(matched, digits, base) do
    case Integer.parse(digits, base) do
      {value, ""} -> encode_codepoint(matched, value)
      _other -> matched
    end
  end

  # Surrogates and out-of-range values are not encodable — `<<0xD800::utf8>>`
  # raises — so the reference stays as written instead of crashing the parse.
  defp encode_codepoint(_matched, value) when value in 1..0xD7FF or value in 0xE000..0x10FFFF,
    do: <<value::utf8>>

  defp encode_codepoint(matched, _value), do: matched

  defp collapse_whitespace(text) do
    @whitespace
    |> Regex.replace(text, " ")
    |> String.trim()
  end
end
