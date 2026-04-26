defmodule FermixCore.Prompt.InjectionScan do
  @moduledoc """
  Narrow prompt-injection scanner for file-backed prompt parts.
  """

  @patterns [
    ignore_previous_instructions: ~r/ignore\s+previous\s+instructions/i,
    ignore_all_prior: ~r/ignore\s+all\s+prior/i,
    you_are_now: ~r/you\s+are\s+now/i,
    disregard_above: ~r/disregard\s+above/i,
    chatml_system: ~r/<\|system\|>/i,
    chatml_start: ~r/<\|im_start\|>/i,
    chatml_end: ~r/<\|im_end\|>/i,
    invisible_unicode: ~r/[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{202E}]/u,
    html_comment: ~r/<!--.*?-->/s,
    script_tag: ~r/<script\b[^>]*>.*?<\/script>/is
  ]

  @type scan_result :: {:ok, String.t()} | {:suspect, String.t(), [atom()]}

  @spec scan(String.t()) :: scan_result()
  def scan(content) when is_binary(content) do
    matches =
      @patterns
      |> Enum.filter(fn {_name, pattern} -> Regex.match?(pattern, content) end)
      |> Enum.map(fn {name, _pattern} -> name end)

    case matches do
      [] -> {:ok, content}
      _matches -> {:suspect, content, matches}
    end
  end
end
