defmodule FermixCore.PhoneCalls.PromptText do
  @moduledoc """
  The one rule for text from outside Fermix that a phone call's prompts or its
  record carry (M94 §7, §11): a brief's values, what was said on the call, an
  excerpt of it, and the extraction's own words.

  `line/1` makes such text one line that cannot reorder itself or forge
  structure: every format character (Unicode category Cf, which holds every
  bidirectional control) is dropped; every run of whitespace, control
  characters (C0, DEL, C1, NEL among them) and line or paragraph separators
  (U+2028, U+2029) becomes one space; `<|`, which spells a model's control
  token, is broken up; and the `<` before the untrusted-content frame's tag,
  in any case, is dropped, so the text can never open or close a frame it is
  placed in. Nothing else
  changes: the words, their order and their punctuation stay as they were.
  """

  @format ~r/\p{Cf}/u
  @breaks ~r/[\s\p{Cc}\x{2028}\x{2029}]+/u
  @frame_tag ~r/<\s*(\/?\s*untrusted_tool_result)/iu

  @doc "`text` as one line (see the module doc)."
  @spec line(String.t()) :: String.t()
  def line(text) when is_binary(text) do
    text
    |> String.replace(@format, "")
    |> String.replace(@breaks, " ")
    |> String.replace("<|", "< |")
    |> String.replace(@frame_tag, "\\1")
    |> String.trim()
  end

  @doc """
  `text` at most `max` bytes, cut at a character boundary, never inside one.
  """
  @spec cut(String.t(), non_neg_integer()) :: String.t()
  def cut(text, max) when is_binary(text) and is_integer(max) and max >= 0 do
    if byte_size(text) <= max, do: text, else: prefix(text, max)
  end

  defp prefix(text, size) when size <= 0, do: binary_part(text, 0, 0)

  defp prefix(text, size) do
    candidate = binary_part(text, 0, size)
    if String.valid?(candidate), do: candidate, else: prefix(text, size - 1)
  end
end
