defmodule FermixCore.PhoneCalls.PromptText do
  @moduledoc """
  The one rule for a line of outside text in a phone call, wherever the call
  carries it (M94 §7, §11). Despite the name, it is not only for prompts: it
  is the rule for every text that came from outside Fermix (a brief's values,
  what was said on the call, an excerpt of it, the extraction's own words)
  whether it goes into a model's prompt (the voice brief, a backend turn's
  window, the extraction's input) or into the call's record (the outcome's
  facts, its evidence and its uncertainty note, `Outcome.Record`). A view
  that shows such text should make it one line by this rule too, rather than
  by a rule of its own.

  `line/1` makes such text one line that cannot reorder itself or forge
  structure: every format character (Unicode category Cf, which holds every
  bidirectional control) is dropped; every run of whitespace, control
  characters (C0, DEL, C1, NEL among them) and line or paragraph separators
  (U+2028, U+2029) becomes one space; `<|`, which spells a model's control
  token, is broken up; and the `<` before the untrusted-content frame's tag,
  in any case, is dropped, so the text can never open or close a frame it is
  placed in. Nothing else changes: the words, their order and their
  punctuation stay as they were. A byte bound on such a line is the shared
  cut, `FermixCore.Text.truncate_utf8/2`.
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
end
