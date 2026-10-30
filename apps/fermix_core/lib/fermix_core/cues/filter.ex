defmodule FermixCore.Cues.Filter do
  @moduledoc """
  One filter call (M60 §8.2). While `[fermix_core.cues] screen_provider`
  names a provider, its decision model screens the item first
  (`Cues.Filter.Decision`), in place of the words to listen for, and only an
  item it lets through reaches the filter model (`Cues.Filter.Llm`); otherwise
  the filter model reads every item the words routed. The setting is read at
  every call, so a change applies to the next one, and both answer in
  `Llm.result()`, so `Cues.Filters` and `Cues.LiveFilters` never ask which ran.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Filter.Decision
  alias FermixCore.Cues.Filter.Llm

  @doc "Decides one claim; see `Llm.decide/2` and `Decision.screen/3` for the opts."
  @spec decide(map(), keyword()) :: Llm.result()
  def decide(claim, opts) when is_map(claim) and is_list(opts) do
    case CuesConfig.screen_provider() do
      nil -> Llm.decide(claim, opts)
      provider -> screened(Decision.screen(claim, provider, opts), claim, opts)
    end
  end

  defp screened(:through, claim, opts), do: Llm.decide(claim, opts)
  defp screened(outcome, _claim, _opts), do: outcome
end
