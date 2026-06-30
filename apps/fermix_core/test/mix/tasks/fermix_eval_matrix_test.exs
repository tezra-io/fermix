defmodule Mix.Tasks.Fermix.Eval.MatrixTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Descriptor
  alias Mix.Tasks.Fermix.Eval.Matrix

  describe "matrix/0" do
    test "enumerates every provider in Descriptor order" do
      providers = Matrix.matrix()
      assert Enum.map(providers, & &1.id) == Descriptor.ids()
      # Order is load-bearing (fallback order): codex first, ollama last.
      assert hd(providers).id == :openai_codex
      assert List.last(providers).id == :ollama
    end

    test "each provider lists models with the catalog default first" do
      for provider <- Matrix.matrix() do
        assert provider.models != [], "#{provider.id} has no models"
        assert provider.default_model == hd(provider.models).id
      end
    end

    test "carries the descriptor auth/effort metadata, not a hand-copied list" do
      by_id = Map.new(Matrix.matrix(), &{&1.id, &1})

      assert by_id[:openai].auth_modes == [:api_key]
      assert by_id[:anthropic].auth_modes == [:api_key, :oauth]
      assert by_id[:ollama].auth_modes == [:none]

      # effort? gates reasoning_effort: true for openai/codex/anthropic/xai,
      # false for openrouter/mistral/ollama.
      assert by_id[:anthropic].effort
      assert by_id[:xai].effort
      refute by_id[:openrouter].effort
      refute by_id[:mistral].effort
      refute by_id[:ollama].effort
    end

    test "model slugs come straight from ModelCatalog (regression: no abbreviated xAI slug)" do
      xai = Enum.find(Matrix.matrix(), &(&1.id == :xai))
      slugs = Enum.map(xai.models, & &1.id)
      # The authoritative slug is the dated form; the abbreviated form an
      # earlier eval-design draft used must never appear.
      assert "grok-4.20-0309-reasoning" in slugs
      refute "grok-4.20-reasoning" in slugs
    end

    test "per-model capability flags ride along for the sweep" do
      xai = Enum.find(Matrix.matrix(), &(&1.id == :xai))
      reasoning = Enum.find(xai.models, &(&1.id == "grok-4.20-0309-reasoning"))
      # xAI reasoning variants reject reasoning.effort — the sweep must know.
      refute reasoning.reasoning_effort

      anthropic = Enum.find(Matrix.matrix(), &(&1.id == :anthropic))
      opus = Enum.find(anthropic.models, &(&1.id == "claude-opus-4-8"))
      assert opus.reasoning_effort
      assert opus.context_window == 1_000_000
    end

    test "the structure is JSON-encodable (the sweep consumes it over stdout)" do
      json = Jason.encode!(%{providers: Matrix.matrix()})
      decoded = Jason.decode!(json)
      assert length(decoded["providers"]) == length(Descriptor.ids())
      first = hd(decoded["providers"])
      assert is_binary(first["default_model"])
      assert is_list(first["models"])
    end
  end
end
