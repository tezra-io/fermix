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
  @type entry :: {id :: String.t(), label :: String.t(), context_window :: pos_integer()}

  @unknown_model_default_ctx 100_000

  @openai [
    {"gpt-5.5", "GPT-5.5 (default, recommended)", 1_050_000},
    {"gpt-5.4", "GPT-5.4", 1_050_000},
    {"gpt-5.4-mini", "GPT-5.4 mini", 400_000}
  ]

  @openai_codex [
    {"gpt-5.5", "GPT-5.5 (default, latest)", 400_000},
    {"gpt-5.4", "GPT-5.4", 400_000},
    {"gpt-5.4-mini", "GPT-5.4 mini (faster, cheaper)", 400_000}
  ]

  @anthropic [
    {"claude-sonnet-4-6", "Claude Sonnet 4.6 (recommended)", 1_000_000},
    {"claude-opus-4-7", "Claude Opus 4.7 (best quality)", 1_000_000},
    {"claude-haiku-4-5", "Claude Haiku 4.5 (fastest)", 200_000}
  ]

  @spec providers() :: [provider()]
  def providers, do: [:openai, :openai_codex, :anthropic]

  @spec models_for(provider()) :: [entry()]
  def models_for(:openai), do: @openai
  def models_for(:openai_codex), do: @openai_codex
  def models_for(:anthropic), do: @anthropic

  @spec default_model_for(provider()) :: String.t()
  def default_model_for(provider) do
    [{id, _label, _ctx} | _] = models_for(provider)
    id
  end

  @spec known_model?(provider(), String.t()) :: boolean()
  def known_model?(provider, id) when is_binary(id) do
    Enum.any?(models_for(provider), fn {model_id, _label, _ctx} -> model_id == id end)
  end

  @spec context_window_for(atom(), String.t()) :: pos_integer()
  def context_window_for(provider, model_id) when is_binary(model_id) do
    provider
    |> models_for_context_window()
    |> Enum.find(fn {id, _label, _ctx} -> id == model_id end)
    |> case do
      {_id, _label, ctx} when is_integer(ctx) and ctx > 0 ->
        ctx

      nil ->
        emit_unknown_model(provider, model_id)
        @unknown_model_default_ctx
    end
  end

  defp models_for_context_window(provider)
       when provider in [:openai, :openai_codex, :anthropic] do
    models_for(provider)
  end

  defp models_for_context_window(_provider), do: []

  defp emit_unknown_model(provider, model_id) do
    :telemetry.execute(
      [:fermix, :model_catalog, :unknown_model],
      %{count: 1},
      %{provider: provider, model: model_id}
    )
  end
end
