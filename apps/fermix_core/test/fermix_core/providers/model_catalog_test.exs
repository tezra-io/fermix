defmodule FermixCore.Providers.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ModelCatalog

  describe "providers/0" do
    test "lists the three M4.10 providers" do
      assert ModelCatalog.providers() == [:openai, :openai_codex, :anthropic]
    end
  end

  describe "models_for/1" do
    test "returns at least one model for each known provider" do
      for provider <- ModelCatalog.providers() do
        models = ModelCatalog.models_for(provider)
        assert is_list(models) and models != []

        Enum.each(models, fn entry ->
          assert {id, label} = entry
          assert is_binary(id) and id != ""
          assert is_binary(label) and label != ""
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
        [{first_id, _label} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.default_model_for(provider) == first_id
      end
    end
  end

  describe "known_model?/2" do
    test "matches catalog entries and rejects unknowns" do
      for provider <- ModelCatalog.providers() do
        [{first_id, _} | _] = ModelCatalog.models_for(provider)
        assert ModelCatalog.known_model?(provider, first_id)
      end

      refute ModelCatalog.known_model?(:openai, "definitely-not-a-real-model")
    end
  end
end
