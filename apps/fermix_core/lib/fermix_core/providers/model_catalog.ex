defmodule FermixCore.Providers.ModelCatalog do
  @moduledoc """
  Static per-provider model lists for the setup wizard.

  The first entry in each list is the wizard default for that provider.
  Catalog updates ship in code, not config — see
  `docs/MILESTONE_4_10_CODEX_PARITY.md` §4.7. The wizard offers a
  free-form `Custom...` escape hatch for models not in the catalog;
  typos are caught by the doctor probe at boot/wizard finalize.
  """

  @type provider :: :openai | :openai_codex | :anthropic
  @type entry :: {id :: String.t(), label :: String.t()}

  @openai [
    {"gpt-5.5", "GPT-5.5 (default, recommended)"},
    {"gpt-5.4", "GPT-5.4"},
    {"gpt-5.4-mini", "GPT-5.4 mini"}
  ]

  @openai_codex [
    {"gpt-5.5", "GPT-5.5 (default, latest)"},
    {"gpt-5.4", "GPT-5.4"},
    {"gpt-5.4-mini", "GPT-5.4 mini (faster, cheaper)"}
  ]

  @anthropic [
    {"claude-sonnet-4-6", "Claude Sonnet 4.6 (recommended)"},
    {"claude-opus-4-7", "Claude Opus 4.7 (best quality)"},
    {"claude-haiku-4-5", "Claude Haiku 4.5 (fastest)"}
  ]

  @spec providers() :: [provider()]
  def providers, do: [:openai, :openai_codex, :anthropic]

  @spec models_for(provider()) :: [entry()]
  def models_for(:openai), do: @openai
  def models_for(:openai_codex), do: @openai_codex
  def models_for(:anthropic), do: @anthropic

  @spec default_model_for(provider()) :: String.t()
  def default_model_for(provider) do
    [{id, _label} | _] = models_for(provider)
    id
  end

  @spec known_model?(provider(), String.t()) :: boolean()
  def known_model?(provider, id) when is_binary(id) do
    Enum.any?(models_for(provider), fn {model_id, _label} -> model_id == id end)
  end
end
