defmodule FermixCore.Providers.ModelCatalog do
  @moduledoc """
  Static per-provider model lists for the setup wizard.

  The first entry in each list is the wizard default for that provider.
  Catalog updates ship in code, not config — see
  `docs/MILESTONE_4_10_CODEX_PARITY.md` §4.7. The wizard offers a
  free-form `Custom...` escape hatch for models not in the catalog;
  typos are caught by the doctor probe at boot/wizard finalize.
  """

  alias FermixCore.Providers.Descriptor

  @type provider :: :openai | :openai_codex | :anthropic | :xai | :openrouter | :ollama
  @type entry :: {id :: String.t(), label :: String.t(), context_window :: pos_integer()}

  @unknown_model_default_ctx 100_000

  # Same models, two access routes with different effective windows: the Codex
  # (ChatGPT subscription / OAuth) path caps the shared models at 400k, while the
  # OpenAI direct API (api key) serves the full window. Keyed per provider so the
  # window follows the auth path automatically (see models_for/1).
  @openai_codex [
    {"gpt-5.5", "GPT-5.5 (default, latest)", 400_000},
    {"gpt-5.4", "GPT-5.4", 400_000},
    {"gpt-5.4-mini", "GPT-5.4 mini (faster, cheaper)", 400_000}
  ]

  @openai [
    {"gpt-5.5", "GPT-5.5 (default, recommended)", 1_050_000},
    {"gpt-5.4", "GPT-5.4", 1_050_000},
    {"gpt-5.4-mini", "GPT-5.4 mini", 400_000}
  ]

  # Context windows are the API defaults the adapter actually gets (it does not
  # send the `context-1m` beta header, design doc §8) — compaction thresholds key
  # off these. The 4.6+ generation (Opus 4.8, Sonnet 4.6) ships the full 1M
  # window by default at standard pricing; only Haiku 4.5 is 200k. (Older
  # Sonnet 4/4.5 still need the beta for 1M, but they are not in this catalog.)
  @anthropic [
    {"claude-sonnet-4-6", "Claude Sonnet 4.6 (recommended)", 1_000_000},
    {"claude-fable-5", "Claude Fable 5", 1_000_000},
    {"claude-opus-4-8", "Claude Opus 4.8 (best quality)", 1_000_000},
    {"claude-haiku-4-5", "Claude Haiku 4.5 (fastest)", 200_000}
  ]

  # Anthropic requires `max_tokens` on every request; these are the
  # per-model output ceilings (Hermes reference values — verify against
  # current Anthropic docs before the SSE follow-up raises the adapter's
  # non-streaming cap above them).
  @anthropic_max_output %{
    "claude-sonnet-4-6" => 64_000,
    "claude-fable-5" => 64_000,
    "claude-opus-4-8" => 128_000,
    "claude-haiku-4-5" => 64_000
  }
  @default_max_output_tokens 8_192

  # xAI model names are volatile (design doc §8) — stale ids fail in the
  # doctor probe, not the first user turn. Windows from current xAI docs:
  # Grok 4.3 = 1M, Grok 4.20 = 256k (same window as Grok 4), code-fast = 256k.
  @xai [
    {"grok-4.3", "Grok 4.3 (recommended)", 1_000_000},
    {"grok-4.20-0309-reasoning", "Grok 4.20 reasoning", 256_000},
    {"grok-4.20-0309-non-reasoning", "Grok 4.20 non-reasoning", 256_000},
    {"grok-code-fast-1", "Grok Code Fast (cheap, coding)", 256_000}
  ]

  # The canonical ordered provider list lives in the Descriptor registry
  # (order = fallback order + auto-promotion tie-break); the catalog
  # delegates so the two can never drift.
  @spec providers() :: [provider()]
  def providers, do: Descriptor.ids()

  # OpenRouter ids are vendor-prefixed and use dots where Anthropic-direct
  # uses dashes; windows mirror the per-vendor catalogs above (M12 §3.1,
  # [verify] ids/introduction dates at release time — wrong ids fail in the
  # doctor probe, not the first turn). 2026-introduced models only — the
  # web pane's live upstream catalog offers everything else newest-first,
  # so this curated list stays current-generation.
  @openrouter [
    {"anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6 via OpenRouter (default)", 1_000_000},
    {"anthropic/claude-fable-5", "Claude Fable 5 via OpenRouter", 1_000_000},
    {"anthropic/claude-opus-4.8", "Claude Opus 4.8 via OpenRouter", 1_000_000},
    {"openai/gpt-5.5", "GPT-5.5 via OpenRouter", 1_050_000},
    {"x-ai/grok-4.3", "Grok 4.3 via OpenRouter", 1_000_000}
  ]

  # Ollama windows are model CAPABILITY; the local server may serve far
  # less (default num_ctx is small) and truncates silently — the doctor
  # probe checks the served num_ctx against these (M12 §3.2, [verify]
  # ids/windows against ollama.com/library tool-capable tags).
  @ollama [
    {"qwen3:32b", "Qwen3 32B (default; tools)", 128_000},
    {"gpt-oss:20b", "GPT-OSS 20B (tools)", 128_000},
    {"llama3.3:70b", "Llama 3.3 70B (tools)", 128_000}
  ]

  @spec models_for(provider()) :: [entry()]
  def models_for(:openai_codex), do: @openai_codex
  def models_for(:openai), do: @openai
  def models_for(:anthropic), do: @anthropic
  def models_for(:xai), do: @xai
  def models_for(:openrouter), do: @openrouter
  def models_for(:ollama), do: @ollama

  @spec default_model_for(provider()) :: String.t()
  def default_model_for(provider) do
    [{id, _label, _ctx} | _] = models_for(provider)
    id
  end

  @spec known_model?(provider(), String.t()) :: boolean()
  def known_model?(provider, id) when is_binary(id) do
    Enum.any?(models_for(provider), fn {model_id, _label, _ctx} -> model_id == id end)
  end

  @doc """
  The first catalog provider whose model list contains `id`, or `nil` if none
  do. Catalog order (`providers/0`) breaks ties for a slug shared across
  providers (an OpenAI/Codex model resolves to the earlier entry); callers that
  know the active provider should prefer it before falling back here.
  """
  @spec provider_for_model(String.t()) :: provider() | nil
  def provider_for_model(id) when is_binary(id) do
    Enum.find(providers(), fn provider -> known_model?(provider, id) end)
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

  # Anthropic-only by design: it is the one provider whose API requires an
  # explicit `max_tokens` on every request (the only caller is
  # `Anthropic.Messages`). Asking for any other provider is a bug — fail loud
  # (FunctionClauseError) rather than return a misleading default.
  @spec max_output_tokens_for(:anthropic, String.t()) :: pos_integer()
  def max_output_tokens_for(:anthropic, model_id) when is_binary(model_id) do
    Map.get(@anthropic_max_output, model_id, @default_max_output_tokens)
  end

  defp models_for_context_window(provider) do
    if provider in Descriptor.ids(), do: models_for(provider), else: []
  end

  defp emit_unknown_model(provider, model_id) do
    :telemetry.execute(
      [:fermix, :model_catalog, :unknown_model],
      %{count: 1},
      %{provider: provider, model: model_id}
    )
  end
end
