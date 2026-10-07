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
               :venice,
               :ollama
             ]
    end
  end

  describe "models_for/1" do
    test "returns at least one model for each provider that ships a catalog" do
      for provider <- ModelCatalog.providers(), provider != :openai_codex do
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

    # OpenAI Codex signs in with ChatGPT, and the account's models come live
    # from /v1/models (M57 §6.2).
    test "openai_codex ships none" do
      assert ModelCatalog.models_for(:openai_codex) == []
    end

    test "raises for unknown provider" do
      assert_raise FunctionClauseError, fn ->
        apply(ModelCatalog, :models_for, [:gemini])
      end
    end
  end

  describe "default_model_for/1" do
    test "returns the first model id in the per-provider list" do
      for provider <- ModelCatalog.providers(), provider != :openai_codex do
        [%ModelCatalog.Entry{id: first_id} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.default_model_for(provider) == first_id
      end
    end

    test "a provider with no shipped catalog has no default, and no slug is guessed" do
      assert ModelCatalog.default_model_for(:openai_codex) == ""
      assert ModelCatalog.effective_model(:openai_codex, []) == ""
      assert ModelCatalog.effective_model(:openai_codex, default_model: "") == ""

      assert ModelCatalog.effective_model(:openai_codex, default_model: "gpt-6.1-sol") ==
               "gpt-6.1-sol"
    end

    # The plan route serves the public API's models, so a listed slug takes the
    # openai catalog's window; a slug neither knows takes the unknown-model one.
    test "an openai_codex slug takes the openai catalog's window" do
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-6.1-sol") ==
               ModelCatalog.context_window_for(:openai, "gpt-6.1-sol")

      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.5") ==
               ModelCatalog.context_window_for(:openai, "gpt-5.5")

      assert ModelCatalog.context_window_for(:openai_codex, "gpt-plan-unlisted",
               unknown_model_telemetry: false
             ) == 100_000
    end

    test "the openai catalog's facts never make an openai_codex slug a known model" do
      refute ModelCatalog.known_model?(:openai_codex, "gpt-5.5")
    end

    test "OpenAI defaults to gpt-6-astra (frontier generation)" do
      assert ModelCatalog.default_model_for(:openai) == "gpt-6-astra"
    end

    test "xAI defaults to grok-4.7 (head = newest generation)" do
      assert ModelCatalog.default_model_for(:xai) == "grok-4.7"
    end

    test "GPT-6.1 Sol and GPT-6 Luna follow Astra on OpenAI, and GPT-6 Sol is gone" do
      assert ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna" | _rest] =
               Enum.map(ModelCatalog.models_for(:openai), & &1.id)

      refute ModelCatalog.known_model?(:openai, "gpt-6-sol")
    end

    test "Claude Opus 5.5 is offered without moving the Anthropic default" do
      ids = Enum.map(ModelCatalog.models_for(:anthropic), & &1.id)

      assert "claude-opus-5-5" in ids
      assert ModelCatalog.default_model_for(:anthropic) == "claude-sonnet-4-6"
    end

    test "Claude Sonnet 5.5 is offered without moving the Anthropic default" do
      ids = Enum.map(ModelCatalog.models_for(:anthropic), & &1.id)

      assert "claude-sonnet-5-5" in ids
      assert ModelCatalog.default_model_for(:anthropic) == "claude-sonnet-4-6"
    end

    test "Mistral Large 4 is offered without moving the Mistral default" do
      ids = Enum.map(ModelCatalog.models_for(:mistral), & &1.id)

      assert ids == [
               "mistral-large-latest",
               "mistral-large-4-0",
               "mistral-medium-latest",
               "mistral-small-latest"
             ]

      assert ModelCatalog.default_model_for(:mistral) == "mistral-large-latest"
      assert ModelCatalog.context_window_for(:mistral, "mistral-large-4-0") == 524_288
    end

    test "the xAI list is ordered newest generation first" do
      ids = Enum.map(ModelCatalog.models_for(:xai), & &1.id)

      assert ids == [
               "grok-4.7",
               "grok-4.6",
               "grok-4.5",
               "grok-4.3",
               "grok-4.20-0309-reasoning",
               "grok-4.20-0309-non-reasoning",
               "grok-code-fast-1"
             ]
    end
  end

  describe "effective_model/2" do
    test "the block's default_model wins when it names one" do
      assert ModelCatalog.effective_model(:openai, default_model: "gpt-5.4-mini") ==
               "gpt-5.4-mini"
    end

    # A fresh sign-in has chosen nothing yet, and every surface still has to
    # name the model the daemon will call.
    test "an absent or blank default_model is the catalog default, for every provider" do
      for provider <- ModelCatalog.providers() do
        expected = ModelCatalog.default_model_for(provider)

        assert ModelCatalog.effective_model(provider, []) == expected
        assert ModelCatalog.effective_model(provider, default_model: nil) == expected
        assert ModelCatalog.effective_model(provider, default_model: "") == expected
      end
    end
  end

  describe "context_window_for/2" do
    test "returns cataloged context windows for known models" do
      # Direct-API entries carry the published window.
      assert ModelCatalog.context_window_for(:openai, "gpt-5.5") == 1_050_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.4-mini") == 400_000
      # Astra's direct-API entry is a derived compaction budget, not its real
      # 1,050,000 window: 0.85 * 320_000 = 272_000, exactly the input-token
      # boundary above which OpenAI reprices the full request at 2x/1.5x.
      assert ModelCatalog.context_window_for(:openai, "gpt-6-astra") == 320_000
      assert ModelCatalog.context_window_for(:openai, "gpt-6.1-sol") == 320_000
      assert ModelCatalog.context_window_for(:openai, "gpt-6-luna") == 320_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.6-sol") == 272_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.6-terra") == 272_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.6-luna") == 272_000
      # Anthropic 4.6+ ships 1M by default at standard pricing; only Haiku is 200k.
      assert ModelCatalog.context_window_for(:anthropic, "claude-sonnet-4-6") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-sonnet-5-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-fable-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-fable-5-1") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-opus-5-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-opus-5") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-opus-4-8") == 1_000_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-haiku-4-5") == 200_000
      # xAI: Grok 4.7 = 500k, Grok 4.6 = 500k, Grok 4.5 = 500k, Grok 4.3 = 1M, Grok 4.20 = 1M.
      # A newer generation is not a bigger window here — 4.6/4.5 are half of 4.3.
      assert ModelCatalog.context_window_for(:xai, "grok-4.7") == 500_000
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
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-sonnet-5-5") == 128_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-fable-5") == 64_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-fable-5-1") == 128_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-opus-5-5") == 128_000
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
      assert ModelCatalog.reasoning_effort?(:xai, "grok-4.7")
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
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-6-astra") == nil
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-6.1-sol") == nil
      assert ModelCatalog.model_effort_ceiling(:openai, "gpt-5.6-sol") == nil
      # OpenAI Codex serves the public API's models: their caps are openai's.
      assert ModelCatalog.model_effort_ceiling(:openai_codex, "gpt-5.5") == :xhigh
      assert ModelCatalog.model_effort_ceiling(:openai_codex, "gpt-6.1-sol") == nil
      # xhigh arrived with Grok 4.6: 4.6+ is uncapped, every older Grok tops
      # out at :high.
      assert ModelCatalog.model_effort_ceiling(:xai, "grok-4.7") == nil
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
      assert :max in ModelCatalog.effort_levels_for(:openai, "gpt-6.1-sol")
      assert :max in ModelCatalog.effort_levels_for(:openai, "gpt-5.6-sol")
      assert :max in ModelCatalog.effort_levels_for(:openai_codex, "gpt-6-astra")
    end

    test "clamp_effort/3 caps to the model ceiling, then the provider ceiling" do
      # gpt-5.5 caps :max down to its :xhigh model ceiling; the current
      # generation keeps :max.
      assert ModelCatalog.clamp_effort(:openai, "gpt-5.5", :max) == :xhigh
      assert ModelCatalog.clamp_effort(:openai, "gpt-6-astra", :max) == :max
      assert ModelCatalog.clamp_effort(:openai, "gpt-5.6-sol", :max) == :max
      # grok-4.6 reaches xhigh, the xai provider ceiling; an older Grok caps at
      # its own :high, which is what xAI would have downgraded :xhigh to anyway.
      assert ModelCatalog.clamp_effort(:xai, "grok-4.7", :xhigh) == :xhigh
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
      for provider <- ModelCatalog.providers(), provider != :openai_codex do
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

  # M49 §3.3: the curated Venice list is every-model-is-private, the head is the
  # default, and the tier rides in the label because the label is the one model
  # field both setup doors draw.
  describe "the Venice catalog" do
    test "defaults to grok-4-7 and lists family-then-newest after it" do
      assert ModelCatalog.default_model_for(:venice) == "grok-4-7"

      assert Enum.map(ModelCatalog.models_for(:venice), & &1.id) == [
               "grok-4-7",
               "deepseek-v4-1-flash",
               "z-ai-glm-5-3-flash",
               "z-ai-glm-5-3",
               "grok-4-6",
               "e2ee-kimi-k3-p",
               "kimi-k3",
               "kimi-k2-6",
               "minimax-m3-preview"
             ]
    end

    test "every label carries its privacy tier, and the enclave model says TEE not E2EE" do
      labels = Map.new(ModelCatalog.models_for(:venice), &{&1.id, &1.label})

      for {id, label} <- labels do
        assert String.contains?(label, " · Private"), "#{id} does not publish its privacy tier"
      end

      assert labels["e2ee-kimi-k3-p"] == "Kimi K3 · Private (TEE)"
      refute Enum.any?(Map.values(labels), &String.contains?(&1, "E2EE"))
    end

    test "only the single-image model is text-only, and windows are the listed ones" do
      by_id = Map.new(ModelCatalog.models_for(:venice), &{&1.id, &1})

      refute ModelCatalog.vision?(:venice, "z-ai-glm-5-3")
      assert ModelCatalog.vision?(:venice, "grok-4-7")
      assert ModelCatalog.vision?(:venice, "grok-4-6")
      assert ModelCatalog.vision?(:venice, "e2ee-kimi-k3-p")

      assert by_id["grok-4-7"].context_window == 500_000
      assert by_id["grok-4-6"].context_window == 500_000
      assert by_id["z-ai-glm-5-3-flash"].context_window == 1_048_576
      assert by_id["kimi-k2-6"].context_window == 256_000
      assert by_id["minimax-m3-preview"].context_window == 524_288
    end

    # Grok is the one curated Venice line the engine also calls directly, so its
    # entries compact at the xAI list's windows.
    test "the Grok entries take the xAI list's windows" do
      by_id = Map.new(ModelCatalog.models_for(:venice), &{&1.id, &1})

      assert by_id["grok-4-7"].context_window == ModelCatalog.context_window_for(:xai, "grok-4.7")
      assert by_id["grok-4-6"].context_window == ModelCatalog.context_window_for(:xai, "grok-4.6")
    end

    # Venice takes the server default rather than a partial effort range (the
    # descriptor's `effort?: false`), so no entry may carry a per-model cap.
    test "no Venice entry declares a reasoning-effort ceiling" do
      for entry <- ModelCatalog.models_for(:venice) do
        assert ModelCatalog.model_effort_ceiling(:venice, entry.id) == nil
      end
    end
  end

  # M12 §3.1: the curated OpenRouter list mirrors the vendor catalogs' current
  # generation, so every entry names a model its vendor's own list carries and
  # compacts at that entry's window, deliberate deviations included.
  describe "the OpenRouter catalog" do
    test "suggests each vendor line's current generation beside the entries it kept" do
      assert Enum.map(ModelCatalog.models_for(:openrouter), & &1.id) == [
               "anthropic/claude-sonnet-4.6",
               "anthropic/claude-sonnet-5.5",
               "anthropic/claude-fable-5.1",
               "anthropic/claude-fable-5",
               "anthropic/claude-opus-5.5",
               "anthropic/claude-opus-4.8",
               "openai/gpt-6-astra",
               "openai/gpt-6.1-sol",
               "openai/gpt-6-luna",
               "openai/gpt-5.5",
               "x-ai/grok-4.7",
               "x-ai/grok-4.3"
             ]

      refute ModelCatalog.known_model?(:openrouter, "openai/gpt-6-sol")
    end

    test "defaults to the Anthropic default" do
      assert ModelCatalog.default_model_for(:openrouter) == "anthropic/claude-sonnet-4.6"

      assert vendor_model(ModelCatalog.default_model_for(:openrouter)) ==
               {:anthropic, ModelCatalog.default_model_for(:anthropic)}
    end

    test "every entry is a model its vendor's list carries, at that entry's window" do
      for %{id: id, context_window: window} <- ModelCatalog.models_for(:openrouter) do
        {vendor, vendor_id} = vendor_model(id)

        assert ModelCatalog.known_model?(vendor, vendor_id), "#{id} has no #{vendor} entry"
        assert window == ModelCatalog.context_window_for(vendor, vendor_id), id
      end
    end
  end

  # OpenRouter prefixes every vendor and writes Anthropic's dashes as dots.
  defp vendor_model("anthropic/" <> model), do: {:anthropic, String.replace(model, ".", "-")}
  defp vendor_model("openai/" <> model), do: {:openai, model}
  defp vendor_model("x-ai/" <> model), do: {:xai, model}

  describe "provider_for_model/1" do
    test "resolves a provider-unique slug" do
      assert ModelCatalog.provider_for_model("claude-opus-4-8") == :anthropic
      assert ModelCatalog.provider_for_model("grok-4.3") == :xai
    end

    # OpenAI Codex ships no catalog, so an OpenAI slug is owned by the API-key
    # provider alone.
    test "an OpenAI slug resolves to the API-key provider" do
      assert ModelCatalog.provider_for_model("gpt-5.5") == :openai
      assert ModelCatalog.provider_for_model("gpt-6-astra") == :openai
    end

    test "an unknown slug is nil" do
      assert ModelCatalog.provider_for_model("definitely-not-a-real-model") == nil
    end
  end

  describe "context_window_for/3 with unknown_model_telemetry: false" do
    test "answers the default for an unknown model without emitting" do
      test_pid = self()
      handler_id = "catalog-quiet-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :model_catalog, :unknown_model],
        fn event, measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert ModelCatalog.context_window_for(:mock, "no-such-model",
               unknown_model_telemetry: false
             ) == ModelCatalog.context_window_for(:mock, "no-such-model")

      # exactly one event: from the default-emitting call, none from the quiet one
      assert_receive {:telemetry, [:fermix, :model_catalog, :unknown_model], _, _}
      refute_receive {:telemetry, [:fermix, :model_catalog, :unknown_model], _, _}
    end
  end
end
