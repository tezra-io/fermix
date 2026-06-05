defmodule FermixCore.Providers.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ModelCatalog

  describe "providers/0" do
    test "lists the four providers" do
      assert ModelCatalog.providers() == [:openai, :openai_codex, :anthropic, :xai]
    end
  end

  describe "models_for/1" do
    test "returns at least one model for each known provider" do
      for provider <- ModelCatalog.providers() do
        models = ModelCatalog.models_for(provider)
        assert is_list(models) and models != []

        Enum.each(models, fn entry ->
          assert {id, label, context_window} = entry
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
        [{first_id, _label, _ctx} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.default_model_for(provider) == first_id
      end
    end
  end

  describe "context_window_for/2" do
    test "returns cataloged context windows for known models" do
      assert ModelCatalog.context_window_for(:openai, "gpt-5.5") == 1_050_000
      assert ModelCatalog.context_window_for(:openai, "gpt-5.4-mini") == 400_000
      assert ModelCatalog.context_window_for(:openai_codex, "gpt-5.5") == 400_000
      # Anthropic windows are the no-beta defaults; 1M needs the context-1m
      # beta header the adapter deliberately does not send (design doc §8).
      assert ModelCatalog.context_window_for(:anthropic, "claude-sonnet-4-6") == 200_000
      assert ModelCatalog.context_window_for(:anthropic, "claude-haiku-4-5") == 200_000
      assert ModelCatalog.context_window_for(:xai, "grok-4.3") == 1_000_000
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
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-opus-4-7") == 128_000
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-haiku-4-5") == 64_000
    end

    test "returns the conservative default for unknown models and providers" do
      assert ModelCatalog.max_output_tokens_for(:anthropic, "claude-custom") == 8_192
      assert ModelCatalog.max_output_tokens_for(:openai, "gpt-5.5") == 8_192
    end
  end

  describe "known_model?/2" do
    test "matches catalog entries and rejects unknowns" do
      for provider <- ModelCatalog.providers() do
        [{first_id, _, _ctx} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.known_model?(provider, first_id)
      end

      refute ModelCatalog.known_model?(:openai, "definitely-not-a-real-model")
    end
  end
end
