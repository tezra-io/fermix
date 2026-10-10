defmodule FermixCore.Providers.ModelCatalog do
  @moduledoc """
  Static per-provider model lists for the setup wizard.

  Each model is one `Entry` record carrying everything Fermix needs to know
  about it: the slug, the wizard label, the context window, and the two
  provider-specific capability fields. One record per model is the whole point
  — these capability flags used to live in separate per-slug tables that drift
  silently when a model is added; co-locating them makes that drift impossible.

  The first entry in each list is the wizard default for that provider.
  Catalog updates ship in code, not config — see
  `docs/MILESTONE_4_10_CODEX_PARITY.md` §4.7. The wizard offers a
  free-form `Custom...` escape hatch for models not in the catalog;
  typos are caught by the doctor probe at boot/wizard finalize.
  """

  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog.Entry
  alias FermixCore.Providers.ReasoningEffort

  @type provider ::
          :openai
          | :openai_codex
          | :anthropic
          | :xai
          | :openrouter
          | :ollama
          | :mistral
          | :venice
  @type entry :: Entry.t()

  @unknown_model_default_ctx 100_000
  @default_max_output_tokens 8_192

  # OpenAI Codex ships no catalog (M57 §6.2): it signs in with ChatGPT, the
  # models a signed-in account may call come live from `GET /v1/models`
  # (`ModelListing`), they differ by plan and workspace, and that list is a
  # catalog rather than an entitlement check. Shipping a default here would name
  # a slug the account may not have, so the provider has none until one is
  # chosen (`Setup.LiveModel.ensure/2` picks the first listed one after a
  # sign-in), and the route refuses until then. A slug it runs with takes the
  # unknown-model rule (`context_window_for/3`).
  @openai_codex []

  # The OpenAI API models. `context_window` is the compaction denominator
  # (`context_tokens / context_window >= compaction.threshold`, default 0.85 —
  # see `TurnRunner`), NOT a declared capability, so it is not a straight copy
  # of a published number. astra = frontier (default); GPT-6.1 sol and GPT-6
  # luna = the generation's cheaper frontier/fast pair; the gpt-5.6
  # sol/terra/luna = frontier/balanced/fast of the prior generation.
  #
  # Windows: the published window from
  # developers.openai.com/api/docs/models/<id> for gpt-5.5, gpt-5.4 and
  # gpt-5.4-mini only. The other six are deliberate deviations, because every
  # current model reprices a request above 272k INPUT tokens at 2x input/cache
  # and 1.5x output "for the full request" — a cliff rather than a ramp, so one
  # token over doubles the bill for everything before it:
  #
  #   * astra, GPT-6.1 sol and GPT-6 luna, 320_000 is NOT their real 1,050,000
  #     window (6.1 sol takes the calibration of the GPT-6 sol it replaced).
  #     0.85 * 320_000 = 272_000 puts compaction exactly on that
  #     boundary, so the standard-priced tier is used in full. Do not
  #     "correct" it upward.
  #
  #   * sol/terra/luna 272_000 predate that calibration and are NOT their
  #     published windows, which are also 1,050,000. They sit below the cliff
  #     rather than on it, giving up 40,800 tokens of standard-priced context
  #     that astra reclaims. Safe, just not tuned — align them at 320_000 if
  #     that headroom is worth having.
  #
  # The calibration couples to the DEFAULT threshold: raising
  # `compaction.threshold` above 0.85 walks astra off the cliff, lowering it
  # only compacts earlier. And the gate is one turn late by construction —
  # `context_tokens` is the prior turn's REAL provider-reported peak
  # (`TurnRunner` :107, :865), not an estimate, so a turn that grows sharply on
  # a large tool result can cross 272k and be billed at 2x once before the next
  # preflight compaction trims it. Zero margin means nothing absorbs that lag.
  #
  # `max` reasoning effort is a current-generation capability (the GPT-6 and
  # GPT-5.6 models), so those leave `max_reasoning_effort` unset (provider
  # ceiling = `:max`) while gpt-5.5/gpt-5.4/gpt-5.4-mini cap at `:xhigh`. An
  # over-reaching config self-heals down to the model's ceiling at route
  # resolution (see `clamp_effort/3`), it does not 400 at the provider. Astra's
  # Codex-only `ultra` level (maximum reasoning plus automatic task delegation)
  # is a Codex-harness mode rather than a `reasoning.effort` wire value, so it
  # is deliberately absent from `ReasoningEffort`.
  @openai [
    %Entry{
      id: "gpt-6-astra",
      label: "GPT-6 Astra (default, recommended)",
      context_window: 320_000
    },
    %Entry{id: "gpt-6.1-sol", label: "GPT-6.1 Sol", context_window: 320_000},
    %Entry{id: "gpt-6-luna", label: "GPT-6 Luna (fast, cheaper)", context_window: 320_000},
    %Entry{id: "gpt-5.6-sol", label: "GPT-5.6 Sol", context_window: 272_000},
    %Entry{id: "gpt-5.6-terra", label: "GPT-5.6 Terra (balanced)", context_window: 272_000},
    %Entry{id: "gpt-5.6-luna", label: "GPT-5.6 Luna (fast, cheaper)", context_window: 272_000},
    %Entry{
      id: "gpt-5.5",
      label: "GPT-5.5",
      context_window: 1_050_000,
      max_reasoning_effort: :xhigh
    },
    %Entry{
      id: "gpt-5.4",
      label: "GPT-5.4",
      context_window: 1_050_000,
      max_reasoning_effort: :xhigh
    },
    %Entry{
      id: "gpt-5.4-mini",
      label: "GPT-5.4 mini",
      context_window: 400_000,
      max_reasoning_effort: :xhigh
    }
  ]

  # Context windows are the API defaults the adapter actually gets (it does not
  # send the `context-1m` beta header, design doc §8). The 4.6+ generation
  # (Opus 5.5, Opus 5, Fable 5.1, Fable 5, Opus 4.8, Sonnet 5.5, Sonnet 4.6) and
  # Haiku 5.5 take 1M tokens; Haiku 4.5 takes 200k.
  #
  # `compaction_ceiling` is where those 1M models compact, whatever the
  # threshold: `compact_at_tokens/3` takes the lower of threshold * window and
  # the ceiling. No price cliff sets 200_000 for the 4.6+ generation (1M is
  # standard-priced): a call costs what it carries, and at 0.85 of 1M a
  # conversation carried up to 850k tokens. A chat turn that arrives after the
  # prompt cache expired re-writes all of it at 1.25x input, and every step of a
  # cron run re-reads it. Haiku 5.5's 100_000 IS a cliff: above 100,000 prompt
  # tokens (cache reads and writes included) its input and output are billed
  # at 5x, so it compacts there; the gate is one turn late by construction (see
  # the OpenAI note above), so one turn can cross it before compaction runs.
  # Haiku 4.5's real window is 200k, so it compacts at the threshold of it.
  # Do not "correct" a ceiling upward.
  #
  # max_output_tokens are the per-model output ceilings Anthropic requires on
  # every request (Hermes reference values — verify against current Anthropic
  # docs before the SSE follow-up raises the adapter's non-streaming cap above
  # them). Fable 5.1 is a Covered Model: an organization on zero data retention
  # gets a 400 on every request until Anthropic authorizes it, which is an
  # account setting rather than a request-shape defect. Opus 5.5 shares Fable
  # 5.1's request rules (thinking always on, no forced tool_choice); the
  # adapter's "opus-5" substring already sends that shape. Sonnet 5.5 400s on
  # disabled thinking, forced tool_choice and sampling params; its "sonnet-5"
  # substring sends adaptive thinking and no sampling params, and the adapter
  # never sends tool_choice.
  @anthropic [
    %Entry{
      id: "claude-sonnet-4-6",
      label: "Claude Sonnet 4.6 (recommended)",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 64_000
    },
    %Entry{
      id: "claude-sonnet-5-5",
      label: "Claude Sonnet 5.5",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 128_000
    },
    %Entry{
      id: "claude-fable-5-1",
      label: "Claude Fable 5.1",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 128_000
    },
    %Entry{
      id: "claude-fable-5",
      label: "Claude Fable 5",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 64_000
    },
    %Entry{
      id: "claude-opus-5-5",
      label: "Claude Opus 5.5 (best quality)",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 128_000
    },
    %Entry{
      id: "claude-opus-5",
      label: "Claude Opus 5",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 128_000
    },
    %Entry{
      id: "claude-opus-4-8",
      label: "Claude Opus 4.8",
      context_window: 1_000_000,
      compaction_ceiling: 200_000,
      max_output_tokens: 128_000
    },
    %Entry{
      id: "claude-haiku-5-5",
      label: "Claude Haiku 5.5 (fastest)",
      context_window: 1_000_000,
      compaction_ceiling: 100_000,
      max_output_tokens: 128_000
    },
    %Entry{
      id: "claude-haiku-4-5",
      label: "Claude Haiku 4.5",
      context_window: 200_000,
      max_output_tokens: 64_000
    }
  ]

  # xAI model names are volatile (design doc §8) — stale ids fail in the
  # doctor probe, not the first user turn. Ordered newest generation first,
  # larger window breaking ties within a generation, so the head is always the
  # current frontier model (= the wizard default).
  #
  # Windows re-verified against docs.x.ai/developers/models/<id> (2026-08-12):
  # Grok 4.6 = 500k, Grok 4.5 = 500k, Grok 4.3 = 1M, Grok 4.20 = 1M,
  # code-fast = 256k. The 4.5 and 4.20 figures corrected long-stale values here
  # (they read 1M and 256k respectively) — a window that overstates the real one
  # defers compaction past the provider's limit. Grok 4.7 = 500k
  # (docs.x.ai/developers/grok-4-7, 2026-09-22).
  #
  # `reasoning_effort?: false` marks the models that reject `reasoning.effort`
  # (design doc §6.2) — re-verify against current xAI docs when adding models.
  #
  # `xhigh` arrived with Grok 4.6, so 4.6+ leaves `max_reasoning_effort` unset
  # (provider ceiling = `:xhigh`) while every older Grok caps at `:high` — the
  # same shape as the gpt-5.6-vs-gpt-5.5 split above. xAI itself treats an
  # `xhigh` request to an older model as `high` rather than rejecting it, so the
  # cap is about not *offering* a level that would silently do nothing, not
  # about avoiding a 400.
  @xai [
    %Entry{id: "grok-4.7", label: "Grok 4.7 (recommended, latest)", context_window: 500_000},
    %Entry{id: "grok-4.6", label: "Grok 4.6", context_window: 500_000},
    %Entry{
      id: "grok-4.5",
      label: "Grok 4.5",
      context_window: 500_000,
      max_reasoning_effort: :high
    },
    %Entry{
      id: "grok-4.3",
      label: "Grok 4.3",
      context_window: 1_000_000,
      max_reasoning_effort: :high
    },
    %Entry{
      id: "grok-4.20-0309-reasoning",
      label: "Grok 4.20 reasoning",
      context_window: 1_000_000,
      reasoning_effort?: false,
      max_reasoning_effort: :high
    },
    %Entry{
      id: "grok-4.20-0309-non-reasoning",
      label: "Grok 4.20 non-reasoning",
      context_window: 1_000_000,
      reasoning_effort?: false,
      max_reasoning_effort: :high
    },
    %Entry{
      id: "grok-code-fast-1",
      label: "Grok Code Fast (cheap, coding)",
      context_window: 256_000,
      reasoning_effort?: false,
      max_reasoning_effort: :high
    }
  ]

  # OpenRouter ids are vendor-prefixed and use dots where Anthropic-direct
  # uses dashes; windows mirror the per-vendor catalogs above (M12 §3.1,
  # [verify] ids/introduction dates at release time — wrong ids fail in the
  # doctor probe, not the first turn). 2026-introduced models only — the
  # web pane's live upstream catalog offers everything else newest-first,
  # so this curated list stays current-generation.
  #
  # A vendor line's newer models sit beside its older entries, which stay
  # because a person may have configured them, in the vendor list's own order;
  # the head follows the Anthropic default. The Claude entries take
  # @anthropic's 200_000 compaction ceiling. The GPT-6 entries take @openai's
  # 320_000 calibration, not the listed 1,050,000: OpenRouter bills them at the
  # same 2x/1.5x above 272k input tokens (its listing's pricing override, read
  # 2026-10-03).
  @openrouter [
    %Entry{
      id: "anthropic/claude-sonnet-4.6",
      label: "Claude Sonnet 4.6 via OpenRouter (default)",
      context_window: 1_000_000,
      compaction_ceiling: 200_000
    },
    %Entry{
      id: "anthropic/claude-sonnet-5.5",
      label: "Claude Sonnet 5.5 via OpenRouter",
      context_window: 1_000_000,
      compaction_ceiling: 200_000
    },
    %Entry{
      id: "anthropic/claude-fable-5.1",
      label: "Claude Fable 5.1 via OpenRouter",
      context_window: 1_000_000,
      compaction_ceiling: 200_000
    },
    %Entry{
      id: "anthropic/claude-fable-5",
      label: "Claude Fable 5 via OpenRouter",
      context_window: 1_000_000,
      compaction_ceiling: 200_000
    },
    %Entry{
      id: "anthropic/claude-opus-5.5",
      label: "Claude Opus 5.5 via OpenRouter",
      context_window: 1_000_000,
      compaction_ceiling: 200_000
    },
    %Entry{
      id: "anthropic/claude-opus-4.8",
      label: "Claude Opus 4.8 via OpenRouter",
      context_window: 1_000_000,
      compaction_ceiling: 200_000
    },
    %Entry{
      id: "openai/gpt-6-astra",
      label: "GPT-6 Astra via OpenRouter",
      context_window: 320_000
    },
    %Entry{
      id: "openai/gpt-6.1-sol",
      label: "GPT-6.1 Sol via OpenRouter",
      context_window: 320_000
    },
    %Entry{id: "openai/gpt-6-luna", label: "GPT-6 Luna via OpenRouter", context_window: 320_000},
    %Entry{id: "openai/gpt-5.5", label: "GPT-5.5 via OpenRouter", context_window: 1_050_000},
    %Entry{id: "x-ai/grok-4.7", label: "Grok 4.7 via OpenRouter", context_window: 500_000},
    %Entry{id: "x-ai/grok-4.3", label: "Grok 4.3 via OpenRouter", context_window: 1_000_000}
  ]

  # Mistral ships rolling `-latest` aliases that always resolve to the current
  # build of each tier, so the slugs stay correct without catalog churn (a
  # stale id would fail in the doctor probe, not the first turn). All three
  # serve a 128k context window ([verify] against docs.mistral.ai/models when
  # adding tiers); `reasoning_effort` is omitted (see the descriptor entry).
  #
  # Mistral Large 4 is the one pinned id: a public preview from 2026-10-06 that
  # no `-latest` alias names yet, listed by `GET /v1/models` as
  # `mistral-large-4-0`. Mistral announces a 1M window, but the window its API
  # serves is listed at 524,288 tokens, and `context_window` is the compaction
  # denominator, so it takes the served figure. It does not move the default.
  @mistral [
    %Entry{
      id: "mistral-large-latest",
      label: "Mistral Large (recommended)",
      context_window: 128_000
    },
    %Entry{
      id: "mistral-large-4-0",
      label: "Mistral Large 4 (preview)",
      context_window: 524_288
    },
    %Entry{id: "mistral-medium-latest", label: "Mistral Medium", context_window: 128_000},
    %Entry{
      id: "mistral-small-latest",
      label: "Mistral Small (fast, cheap)",
      context_window: 128_000
    }
  ]

  # Venice publishes a privacy tier per model, and the label is the one model
  # field both setup doors draw — so the tier rides in the label (M49 §3.3).
  # Every curated entry is `private`: the prompt is processed on hardware Venice
  # contracts and is not retained. `(TEE)` marks an enclave model and never says
  # "E2EE" — called by a plain client, an `e2ee-*` id runs in the enclave while
  # Venice's own edge still sees plaintext. The live listing offers the
  # `anonymized` tier too; this curated list does not.
  #
  # From the listing of 2026-09-19, all tool-calling; Grok 4.7 from the listing
  # of 2026-10-03, where it took the `most_intelligent` tag from Grok 4.6, which
  # stays for the people who chose it. The head is the default: the private
  # model Venice itself tags `most_intelligent`. The rest follow the live
  # listing's own order — by family, then newest first — so one ordering rule
  # explains both surfaces. Windows are the listed `context_length`, which for
  # the Grok entries is also @xai's ([verify] on every addition: an overstated
  # window defers compaction past the provider's real limit). `reasoning_effort`
  # is omitted for every Venice model (see the descriptor entry), so no entry
  # caps it. `vision?: false` marks the one model that takes no images, so an
  # image turn routed to it fails loud at the capability gate (M14) instead of
  # 400-ing downstream.
  @venice [
    %Entry{id: "grok-4-7", label: "Grok 4.7 · Private", context_window: 500_000},
    %Entry{
      id: "deepseek-v4-1-flash",
      label: "DeepSeek V4.1 Flash · Private",
      context_window: 1_000_000
    },
    %Entry{id: "z-ai-glm-5-3-flash", label: "GLM 5.3 Flash · Private", context_window: 1_048_576},
    %Entry{
      id: "z-ai-glm-5-3",
      label: "GLM 5.3 · Private",
      context_window: 1_000_000,
      vision?: false
    },
    %Entry{id: "grok-4-6", label: "Grok 4.6 · Private", context_window: 500_000},
    %Entry{id: "e2ee-kimi-k3-p", label: "Kimi K3 · Private (TEE)", context_window: 1_000_000},
    %Entry{id: "kimi-k3", label: "Kimi K3 · Private", context_window: 1_000_000},
    %Entry{id: "kimi-k2-6", label: "Kimi K2.6 · Private", context_window: 256_000},
    %Entry{
      id: "minimax-m3-preview",
      label: "MiniMax M3 Preview · Private",
      context_window: 524_288
    }
  ]

  # Ollama windows are model CAPABILITY; the local server may serve far
  # less (default num_ctx is small) and truncates silently — the doctor
  # probe checks the served num_ctx against these (M12 §3.2, [verify]
  # ids/windows against ollama.com/library tool-capable tags).
  # These catalog entries are text-only models — vision needs a separate tag
  # (llava / llama3.2-vision), so they carry `vision?: false`: an image turn
  # routed to one fails loud at the capability gate (M14) instead of 400-ing
  # downstream. Vision-capable local models added later set `vision?: true`.
  @ollama [
    %Entry{
      id: "qwen3:32b",
      label: "Qwen3 32B (default; tools)",
      context_window: 128_000,
      vision?: false
    },
    %Entry{
      id: "gpt-oss:20b",
      label: "GPT-OSS 20B (tools)",
      context_window: 128_000,
      vision?: false
    },
    %Entry{
      id: "llama3.3:70b",
      label: "Llama 3.3 70B (tools)",
      context_window: 128_000,
      vision?: false
    }
  ]

  # The canonical ordered provider list lives in the Descriptor registry
  # (order = fallback order + auto-promotion tie-break); the catalog
  # delegates so the two can never drift.
  @spec providers() :: [provider()]
  def providers, do: Descriptor.ids()

  @spec models_for(provider()) :: [entry()]
  def models_for(:openai_codex), do: @openai_codex
  def models_for(:openai), do: @openai
  def models_for(:anthropic), do: @anthropic
  def models_for(:xai), do: @xai
  def models_for(:openrouter), do: @openrouter
  def models_for(:mistral), do: @mistral
  def models_for(:venice), do: @venice
  def models_for(:ollama), do: @ollama

  @doc """
  The catalog's default model for `provider`: its first entry. A provider whose
  models are discovered rather than shipped (`openai_codex`) has no default and
  answers `""`, the "no model chosen yet" value the management protocol already
  carries; its route refuses that value rather than guess a slug.
  """
  @spec default_model_for(provider()) :: String.t()
  def default_model_for(provider) do
    case models_for(provider) do
      [%Entry{id: id} | _rest] -> id
      [] -> ""
    end
  end

  @doc """
  The model a provider runs with: the `default_model` its config block names,
  or the catalog default while it names none. The one resolver behind the
  setup row, the settings Model row, the overview, Doctor's probe and the
  route, so a provider that has just been signed in shows the model it will
  call, and every surface names the same one. A provider with no shipped
  catalog (`openai_codex`) answers `""` until a model is chosen.
  """
  @spec effective_model(provider(), keyword()) :: String.t()
  def effective_model(provider, block) when is_list(block) do
    case Keyword.get(block, :default_model) do
      model when is_binary(model) and model != "" -> model
      _absent -> default_model_for(provider)
    end
  end

  @spec known_model?(provider(), String.t()) :: boolean()
  def known_model?(provider, id) when is_binary(id) do
    Enum.any?(models_for(provider), &(&1.id == id))
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

  @doc """
  The model's context window in tokens, or the catalog default for a model
  it does not know. An unknown model emits `[:fermix, :model_catalog,
  :unknown_model]` once per call; a caller that resolves the window on every
  loop run passes `unknown_model_telemetry: false` so a long-lived
  uncatalogued route does not emit on every turn.
  """
  @spec context_window_for(atom(), String.t(), [{:unknown_model_telemetry, boolean()}]) ::
          pos_integer()
  def context_window_for(provider, model_id, opts \\ [])
      when is_binary(model_id) and is_list(opts) do
    case find_entry(provider, model_id) do
      %Entry{context_window: ctx} when is_integer(ctx) and ctx > 0 ->
        ctx

      nil ->
        if Keyword.get(opts, :unknown_model_telemetry, true),
          do: emit_unknown_model(provider, model_id)

        @unknown_model_default_ctx
    end
  end

  @doc """
  The model's compaction ceiling (`Entry.compaction_ceiling`), or `nil` for a
  model without one, an unknown model included.
  """
  @spec compaction_ceiling_for(atom(), String.t()) :: pos_integer() | nil
  def compaction_ceiling_for(provider, model_id) when is_binary(model_id) do
    case find_entry(provider, model_id) do
      %Entry{compaction_ceiling: ceiling} -> ceiling
      nil -> nil
    end
  end

  @doc """
  The prompt size, in tokens, at which a conversation compacts: `threshold`
  of `window`, never above `ceiling`. The one rule for the trigger between
  turns, the budget inside a turn, and what Doctor reports.
  """
  @spec compact_at_tokens(pos_integer(), pos_integer() | nil, number()) :: pos_integer()
  def compact_at_tokens(window, nil, threshold)
      when is_integer(window) and window > 0 and is_number(threshold) and threshold > 0,
      do: trunc(threshold * window)

  def compact_at_tokens(window, ceiling, threshold)
      when is_integer(ceiling) and ceiling > 0,
      do: min(compact_at_tokens(window, nil, threshold), ceiling)

  @doc "`compact_at_tokens/3` for a catalog model."
  @spec compact_at_tokens_for(atom(), String.t(), number()) :: pos_integer()
  def compact_at_tokens_for(provider, model_id, threshold) when is_binary(model_id) do
    compact_at_tokens(
      context_window_for(provider, model_id),
      compaction_ceiling_for(provider, model_id),
      threshold
    )
  end

  @doc """
  The context a conversation on this model is kept within: its window, or its
  compaction ceiling when that is lower. Compaction aims at half of it.
  """
  @spec context_budget_for(atom(), String.t()) :: pos_integer()
  def context_budget_for(provider, model_id) when is_binary(model_id) do
    window = context_window_for(provider, model_id)

    case compaction_ceiling_for(provider, model_id) do
      nil -> window
      ceiling -> min(window, ceiling)
    end
  end

  # Anthropic-only by design: it is the one provider whose API requires an
  # explicit `max_tokens` on every request (the only caller is
  # `Anthropic.Messages`). Asking for any other provider is a bug — fail loud
  # (FunctionClauseError) rather than return a misleading default.
  @spec max_output_tokens_for(:anthropic, String.t()) :: pos_integer()
  def max_output_tokens_for(:anthropic, model_id) when is_binary(model_id) do
    case find_entry(:anthropic, model_id) do
      %Entry{max_output_tokens: tokens} when is_integer(tokens) and tokens > 0 -> tokens
      _absent -> @default_max_output_tokens
    end
  end

  @doc """
  Whether `model_id` accepts the `reasoning.effort` request field. xAI-only in
  practice — the xAI Responses adapter is the sole caller; unknown ids and every
  non-xAI provider default to `true` (they never gate on it).
  """
  @spec reasoning_effort?(provider(), String.t()) :: boolean()
  def reasoning_effort?(provider, model_id) when is_binary(model_id) do
    case find_entry(provider, model_id) do
      %Entry{reasoning_effort?: value} -> value
      nil -> true
    end
  end

  @doc """
  The highest reasoning-effort level `model_id` accepts when it is lower than
  its provider's ceiling, or `nil` when the model has no per-model cap (unknown
  models and every uncapped model). Two families cap today: the older OpenAI
  models (gpt-5.5 / gpt-5.4 / gpt-5.4-mini), because `max` is a
  current-generation capability (GPT-6 Astra and the GPT-5.6 models), and every
  xAI model except Grok 4.6, because `xhigh` is a 4.6 capability.
  """
  @spec model_effort_ceiling(atom(), String.t()) :: ReasoningEffort.level() | nil
  def model_effort_ceiling(provider, model_id) when is_binary(model_id) do
    case find_entry(provider, model_id) do
      %Entry{max_reasoning_effort: ceiling} -> ceiling
      nil -> nil
    end
  end

  @doc """
  The reasoning-effort levels a setup surface should offer for `model_id`: the
  provider's vocabulary narrowed to the model's ceiling. Setup panes call this
  instead of `ReasoningEffort.levels_for/1` so an older model never lists an
  effort it would reject.
  """
  @spec effort_levels_for(atom(), String.t()) :: [ReasoningEffort.level()]
  def effort_levels_for(provider, model_id) when is_binary(model_id) do
    ReasoningEffort.levels_for(provider, model_effort_ceiling(provider, model_id))
  end

  @doc """
  Clamps `level` into `model_id`'s effective effort range: the provider's
  floor/ceiling first (`ReasoningEffort.clamp/2`), then down to the model's own
  cap. Used to overlay a routing-level effort onto a concrete route without
  sending an effort the model rejects.
  """
  @spec clamp_effort(atom(), String.t(), ReasoningEffort.level()) :: ReasoningEffort.level()
  def clamp_effort(provider, model_id, level) when is_binary(model_id) do
    level
    |> ReasoningEffort.clamp(provider)
    |> ReasoningEffort.cap(model_effort_ceiling(provider, model_id))
  end

  @doc """
  Whether `model_id` accepts image (vision) input. Defaults to `true`; only
  models known to be text-only carry `vision?: false`. Unknown ids and
  non-catalog providers (e.g. the `:mock` test adapter, or a free-form custom
  model) default to `true` — permissive, with the downstream provider 400 as
  the documented model-dependent edge.
  """
  @spec vision?(provider(), String.t()) :: boolean()
  def vision?(provider, model_id) when is_binary(model_id) do
    case find_entry(provider, model_id) do
      %Entry{vision?: value} -> value
      nil -> true
    end
  end

  # Quiet lookup — no unknown_model telemetry. Callers that need that signal
  # use context_window_for/2, which wraps this and emits on a miss. Returns nil
  # for providers outside the catalog (e.g. direct-adapter `:mock`) so callers
  # degrade to their default instead of raising on models_for/1.
  # OpenAI Codex lists the signed-in account's models live, and its plan route
  # serves the public API's models, so a slug's window and effort ceiling are
  # the `openai` catalog's. Only per-model facts read through here: the model
  # list and `known_model?/2` stay the live listing's.
  defp find_entry(:openai_codex, model_id), do: find_entry(:openai, model_id)

  defp find_entry(provider, model_id) do
    if provider in Descriptor.ids() do
      Enum.find(models_for(provider), &(&1.id == model_id))
    else
      nil
    end
  end

  defp emit_unknown_model(provider, model_id) do
    :telemetry.execute(
      [:fermix, :model_catalog, :unknown_model],
      %{count: 1},
      %{provider: provider, model: model_id}
    )
  end
end
