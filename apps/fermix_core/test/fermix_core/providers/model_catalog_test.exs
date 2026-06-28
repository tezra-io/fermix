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
  end

  describe "context_window_for/2" do
    test "returns cataloged context windows for known models" do
      # OpenAI direct API serves the full window; Codex (OAuth) caps the same model at 400k.
      assert ModelCatalog.context_window_for(:openai, "gpt-5.5") == 1_050_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.4-mini") == 400_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.5") == 400_000
      # Anthropic 4.6+ ships 1M by default at standard pricing; only Haiku is 200k.
      assert ModelCatalog.context_window_for(:anthropic, "claude-sonnet-4-6") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-fable-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-opus-4-8") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-haiku-4-5") == 200_000
      # xAI: Grok 4.3 = 1M, Grok 4.20 = 256k.
      assert ModelCatalog.context_window_for(:xai, "grok-4.3") == 1_000_000
      assert ModelCatalog.context_window_for(:xai, "grok-4.20-0309-reasoning") == 256_000
    end

    test "returns a safe default and emits telemetry for unknown models" do
      telemetry_id = "model-catalog-unknown-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_id,
        [:fermix, :model_catalog, :unknown_model],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
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
          send(test_pid, {:telemetry, event, measurements, metadata})
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
  end

  describe "provider_for_model/1" do
    test "resolves a provider-unique slug" do
      assert ModelCatalog.provider_for_model("claude-opus-4-8") == :anthropic
      assert ModelCatalog.provider_for_model("grok-4.3") == :xai
    end

    test "a slug shared across catalogs resolves to the first provider in catalog order" do
      # gpt-5.5 is in both :openai_codex and :openai; providers/0 lists codex first.
      assert ModelCatalog.provider_for_model("gpt-5.5") == :openai_codex
    end

    test "an unknown slug is nil" do
      assert ModelCatalog.provider_for_model("definitely-not-a-real-model") == nil
    end
  end
end
