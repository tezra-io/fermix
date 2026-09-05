defmodule FermixCore.Providers.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ModelCatalog

  describe "providers/0" do
    test "lists the catalog providers in fallback order" do
      assert ModelCatalog.providers() == [
               :openai_codex,
               :openai,
               :anthropic,
               :xai,
               :openrouter,
               :mistral,
               :ollama
             ]
    end
  end

  describe "models_for/1" do
    test "returns at least one model for each known provider" do
      for provider <- ModelCatalog.providers() do
        models = ModelCatalog.models_for(provider)
        assert is_list(models) and models != []

        Enum.each(models, fn entry ->
          assert %ModelCatalog.Entry{id: id, label: label, context_window: context_window} = entry
          assert is_binary(id) and id != ""
          assert is_binary(label) and label != ""
          assert is_integer(context_window) and context_window > 0
        end)
      end
    end

    test "raises for unknown provider" do
      assert_raise FunctionClauseError, fn ->
        apply(ModelCatalog, :models_for, [:gemini])
      end
    end
  end

  describe "default_model_for/1" do
    test "returns the first model id in the per-provider list" do
      for provider <- ModelCatalog.providers() do
        [%ModelCatalog.Entry{id: first_id} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.default_model_for(provider) == first_id
      end
    end

    test "OpenAI and Codex default to gpt-6-astra (frontier generation)" do
      assert ModelCatalog.default_model_for(:openai) == "gpt-6-astra"
      assert ModelCatalog.default_model_for(:openai_codex) == "gpt-6-astra"
    end

    test "xAI defaults to grok-4.6 (head = newest generation)" do
      assert ModelCatalog.default_model_for(:xai) == "grok-4.6"
    end

    test "the xAI list is ordered newest generation first" do
      ids = Enum.map(ModelCatalog.models_for(:xai), & &1.id)

      assert ids == [
               "grok-4.6",
               "grok-4.5",
               "grok-4.3",
               "grok-4.20-0309-reasoning",
               "grok-4.20-0309-non-reasoning",
               "grok-code-fast-1"
             ]
    end
  end

  describe "context_window_for/2" do
    test "returns cataloged context windows for known models" do
      # Direct-API entries carry the published window; the Codex column carries
      # the cache's max_context_window (the ceiling that path stretches to).
      assert ModelCatalog.context_window_for(:openai, "gpt-5.5") == 1_050_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.4-mini") == 400_000
      # 5.5/5.4-mini are 272k on Codex, NOT the 400k this catalog used to
      # claim: 0.85 * 400_000 = 340_000 deferred compaction past the real
      # window, so a long turn hit the provider limit before compacting.
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.5") == 272_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.4") == 272_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.4-mini") == 272_000
      # The current generation stretches to 872k on Codex.
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-6-astra") == 872_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.6-sol") == 872_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.6-terra") == 872_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.6-luna") == 872_000
      # Astra's direct-API entry is a derived compaction budget, not its real
      # 1,050,000 window: 0.85 * 320_000 = 272_000, exactly the input-token
      # boundary above which OpenAI reprices the full request at 2x/1.5x.
      assert ModelCatalog.context_window_for(:openai, "gpt-6-astra") == 320_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.6-sol") == 272_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.6-terra") == 272_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.6-luna") == 272_000
      # Anthropic 4.6+ ships 1M by default at standard pricing; only Haiku is 200k.
      assert ModelCatalog.context_window_for(:anthropic, "claude-sonnet-4-6") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-fable-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-fable-5-1") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-opus-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-opus-4-8") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-haiku-4-5") == 200_000
      # xAI: Grok 4.6 = 500k, Grok 4.5 = 500k, Grok 4.3 = 1M, Grok 4.20 = 1M.
      # A newer generation is not a bigger window here — 4.6/4.5 are half of 4.3.
      assert ModelCatalog.context_window_for(:xai, "grok-4.6") == 500_000
      assert ModelCatalog.context_window_for(:xai, "grok-4.5") == 500_000
      assert ModelCatalog.context_window_for(:xai, "grok-4.3") == 1_000_000
      assert ModelCatalog.context_window_for(:xai, "grok-4.20-0309-reasoning") == 1_000_000
      assert ModelCatalog.context_window_for(:xai, "grok-4.20-0309-non-reasoning") == 1_000_000
      assert ModelCatalog.context_window_for(:xai, "grok-code-fast-1") == 256_000
    end

    test "returns a safe default and emits telemetry for unknown models" do
      telemetry_id = "model-catalog-unknown-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_id,
        [:fermix, :model_catalog, :unknown_model],
        fn event, measurements, metadata, test_pid ->
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      assert ModelCatalog.context_window_for(:openai, "custom-frontier") == 100_000

      assert_receive {:telemetry, [:fermix, :model_catalog, :unknown_model], %{count: 1},
                      %{provider: :openai, model: "custom-frontier"}}
    end

    test "returns the same safe default for direct-adapter providers outside the catalog" do
      telemetry_id = "model-catalog-direct-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_id,
        [:fermix, :model_catalog, :unknown_model],
        fn event, measurements, metadata, test_pid ->
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      assert ModelCatalog.context_window_for(:mock, "mock-model") == 100_000

      assert_receive {:telemetry, [:fermix, :model_catalog, :unknown_model], %{count: 1},
                      %{provider: :mock, model: "mock-model"}}
    end
  end

  describe "max_output_tokens_for/2" do
    test "returns cataloged output ceilings for Anthropic models" do
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-sonnet-4-6") == 64_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-fable-5") == 64_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-fable-5-1") == 128_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-opus-5") == 128_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-opus-4-8") == 128_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-haiku-4-5") == 64_000
    end

    test "falls back to the conservative default for unknown Anthropic models" do
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-custom") == 8_192
    end

    test "is Anthropic-only — other providers raise rather than return a default" do
      # Dynamic dispatch so the type checker doesn't flag the deliberately
      # off-contract provider at compile time; the fail-loud behavior is what we assert.
      assert_raise FunctionClauseError, fn ->
        apply(ModelCatalog, :max_output_tokens_for, [:openai, "gpt-5.5"])
      end
    end
  end

  describe "reasoning_effort?/2" do
    test "flags the xAI models that reject the reasoning.effort field" do
      assert ModelCatalog.reasoning_effort?(:xai, "grok-4.6")
      assert ModelCatalog.reasoning_effort?(:xai, "grok-4.5")
      assert ModelCatalog.reasoning_effort?(:xai, "grok-4.3")
      refute ModelCatalog.reasoning_effort?(:xai, "grok-4.20-0309-reasoning")
      refute ModelCatalog.reasoning_effort?(:xai, "grok-4.20-0309-non-reasoning")
      refute ModelCatalog.reasoning_effort?(:xai, "grok-code-fast-1")
    end

    test "defaults to true for unknown models and non-xAI providers" do
      assert ModelCatalog.reasoning_effort?(:xai, "grok-future-unlisted")
      assert ModelCatalog.reasoning_effort?(:anthropic, "claude-opus-4-8")
    end
  end

  describe "vision?/2" do
    test "vision-capable catalog models return true" do
      assert ModelCatalog.vision?(:openai_codex, "gpt-5.5")
      assert ModelCatalog.vision?(:openai, "gpt-5.5")
      assert ModelCatalog.vision?(:anthropic, "claude-opus-4-8")
      assert ModelCatalog.vision?(:xai, "grok-4.3")
    end

    test "text-only local models are flagged false (capability gate fails loud)" do
      refute ModelCatalog.vision?(:ollama, "qwen3:32b")
      refute ModelCatalog.vision?(:ollama, "gpt-oss:20b")
      refute ModelCatalog.vision?(:ollama, "llama3.3:70b")
    end

    test "defaults to true for unknown models and non-catalog providers" do
      assert ModelCatalog.vision?(:openai, "gpt-future-unlisted")
      assert ModelCatalog.vision?(:mock, "mock")
    end
  end

  describe "model_effort_ceiling/2, effort_levels_for/2, clamp_effort/3" do
    test "older OpenAI models cap at :xhigh; the current generation is uncapped" do
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-5.5") == :xhigh
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-5.4") == :xhigh
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-5.4-mini") == :xhigh
      assert ModelCatalog.model_effort_ceiling(:openai_codex, "gpt-5.5") == :xhigh
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-6-astra") == nil
      assert ModelCatalog.model_effort_ceiling(:openai_codex, "gpt-6-astra") == nil
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-5.6-sol") == nil
      assert ModelCatalog.model_effort_ceiling(:openai_codex, "gpt-5.6-sol") == nil
      # xhigh is a Grok 4.6 capability: 4.6 is uncapped, every older Grok tops
      # out at :high.
      assert ModelCatalog.model_effort_ceiling(:xai, "grok-4.6") == nil
      assert ModelCatalog.model_effort_ceiling(:xai, "grok-4.5") == :high
      assert ModelCatalog.model_effort_ceiling(:xai, "grok-4.3") == :high
      assert ModelCatalog.model_effort_ceiling(:xai, "grok-code-fast-1") == :high
      assert ModelCatalog.model_effort_ceiling(:openai, "unknown-model") == nil
    end

    test "effort_levels_for/2 drops levels above the model's ceiling" do
      assert ModelCatalog.effort_levels_for(:openai, "gpt-5.5") ==
               [:none, :low, :medium, :high, :xhigh]

      refute :max in ModelCatalog.effort_levels_for(:openai, "gpt-5.5")
      assert :max in ModelCatalog.effort_levels_for(:openai, "gpt-6-astra")
      assert :max in ModelCatalog.effort_levels_for(:openai_codex, "gpt-6-astra")
      assert :max in ModelCatalog.effort_levels_for(:openai, "gpt-5.6-sol")
      assert :max in ModelCatalog.effort_levels_for(:openai_codex, "gpt-5.6-sol")
    end

    test "clamp_effort/3 caps to the model ceiling, then the provider ceiling" do
      # gpt-5.5 caps :max down to its :xhigh model ceiling; the current
      # generation keeps :max.
      assert ModelCatalog.clamp_effort(:openai, "gpt-5.5", :max) == :xhigh
      assert ModelCatalog.clamp_effort(:openai_codex, "gpt-5.5", :max) == :xhigh
      assert ModelCatalog.clamp_effort(:openai_codex, "gpt-6-astra", :max) == :max
      assert ModelCatalog.clamp_effort(:openai, "gpt-5.6-sol", :max) == :max
      # grok-4.6 reaches xhigh, the xai provider ceiling; an older Grok caps at
      # its own :high, which is what xAI would have downgraded :xhigh to anyway.
      assert ModelCatalog.clamp_effort(:xai, "grok-4.6", :xhigh) == :xhigh
      assert ModelCatalog.clamp_effort(:xai, "grok-4.6", :max) == :xhigh
      assert ModelCatalog.clamp_effort(:xai, "grok-4.5", :xhigh) == :high
      assert ModelCatalog.clamp_effort(:xai, "grok-4.5", :max) == :high
      # unknown model: provider-level clamp only.
      assert ModelCatalog.clamp_effort(:openai, "unknown-model", :max) == :max
    end
  end

  describe "known_model?/2" do
    test "matches catalog entries and rejects unknowns" do
      for provider <- ModelCatalog.providers() do
        [%ModelCatalog.Entry{id: first_id} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.known_model?(provider, first_id)
      end

      refute ModelCatalog.known_model?(:openai, "definitely-not-a-real-model")
    end

    test "claude-fable-5 is cataloged without changing the Anthropic default" do
      assert ModelCatalog.known_model?(:anthropic, "claude-fable-5")
      assert ModelCatalog.default_model_for(:anthropic) == "claude-sonnet-4-6"
    end

    test "claude-fable-5-1 is cataloged without changing the Anthropic default" do
      assert ModelCatalog.known_model?(:anthropic, "claude-fable-5-1")
      assert ModelCatalog.default_model_for(:anthropic) == "claude-sonnet-4-6"
    end
  end

  describe "provider_for_model/1" do
    test "resolves a provider-unique slug" do
      assert ModelCatalog.provider_for_model("claude-opus-4-8") == :anthropic
      assert ModelCatalog.provider_for_model("grok-4.3") == :xai
    end

    test "a slug shared across catalogs resolves to the first provider in catalog order" do
      # gpt-5.5 is in both :openai_codex and :openai; providers/0 lists codex first.
      assert ModelCatalog.provider_for_model("gpt-5.5") == :openai_codex
      assert ModelCatalog.provider_for_model("gpt-6-astra") == :openai_codex
    end

    test "the Codex and direct-OpenAI lists carry the same slugs" do
      # RoutingOverrides.validate_pairing/3 raises at config-parse time when a
      # slug the catalog knows under one provider is pinned to the other, so a
      # model added to only one of these two lists turns a legitimate
      # provider/model pin into a hard boot crash. Whole-surface invariant: a
      # model added later either joins both lists or fails here.
      codex = ModelCatalog.models_for(:openai_codex) |> MapSet.new(& &1.id)
      direct = ModelCatalog.models_for(:openai) |> MapSet.new(& &1.id)

      assert codex == direct
    end

    test "an unknown slug is nil" do
      assert ModelCatalog.provider_for_model("definitely-not-a-real-model") == nil
    end
  end
end
