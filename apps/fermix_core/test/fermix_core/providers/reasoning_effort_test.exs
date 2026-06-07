defmodule FermixCore.Providers.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ReasoningEffort

  describe "levels/0 and valid?/1" do
    test "canonical vocabulary is none/low/medium/high/xhigh/max (no minimal, no auto)" do
      assert ReasoningEffort.levels() == [:none, :low, :medium, :high, :xhigh, :max]
    end

    test "valid?/1 accepts canonical atoms and rejects everything else" do
      for level <- [:none, :low, :medium, :high, :xhigh, :max] do
        assert ReasoningEffort.valid?(level)
      end

      refute ReasoningEffort.valid?(:minimal)
      refute ReasoningEffort.valid?(:auto)
      refute ReasoningEffort.valid?(:bogus)
      refute ReasoningEffort.valid?("high")
      refute ReasoningEffort.valid?(nil)
    end
  end

  describe "parse/1" do
    test "casts canonical atoms and case-insensitive strings" do
      assert ReasoningEffort.parse(:high) == {:ok, :high}
      assert ReasoningEffort.parse("high") == {:ok, :high}
      assert ReasoningEffort.parse("  XHIGH ") == {:ok, :xhigh}
    end

    test "rejects removed/unknown values" do
      assert ReasoningEffort.parse("minimal") == :error
      assert ReasoningEffort.parse("auto") == :error
      assert ReasoningEffort.parse("absurd") == :error
      assert ReasoningEffort.parse(123) == :error
    end
  end

  describe "levels_for/1 and supported?/2" do
    test "per-provider vocabularies" do
      assert ReasoningEffort.levels_for(:openai) == [:none, :low, :medium, :high, :xhigh]
      assert ReasoningEffort.levels_for(:openai_codex) == [:none, :low, :medium, :high, :xhigh]
      assert ReasoningEffort.levels_for(:anthropic) == [:low, :medium, :high, :xhigh, :max]
      assert ReasoningEffort.levels_for(:xai) == [:none, :low, :medium, :high]
      assert ReasoningEffort.levels_for(:unknown) == []
    end

    test "supported?/2" do
      assert ReasoningEffort.supported?(:xhigh, :openai)
      refute ReasoningEffort.supported?(:max, :openai)
      assert ReasoningEffort.supported?(:max, :anthropic)
      refute ReasoningEffort.supported?(:none, :anthropic)
      assert ReasoningEffort.supported?(:none, :xai)
      refute ReasoningEffort.supported?(:xhigh, :xai)
    end

    test "xai clamps above-ceiling levels to high" do
      assert ReasoningEffort.to_provider(:xhigh, :xai) == {:ok, "high"}
      assert ReasoningEffort.to_provider(:max, :xai) == {:ok, "high"}
      assert ReasoningEffort.to_provider(:none, :xai) == :omit
    end
  end

  describe "to_provider/2" do
    test "none omits the field for OpenAI-family" do
      assert ReasoningEffort.to_provider(:none, :openai) == :omit
      assert ReasoningEffort.to_provider(:none, :openai_codex) == :omit
    end

    test "supported levels map to their verbatim wire string" do
      assert ReasoningEffort.to_provider(:high, :openai) == {:ok, "high"}
      assert ReasoningEffort.to_provider(:xhigh, :openai) == {:ok, "xhigh"}
      assert ReasoningEffort.to_provider(:max, :anthropic) == {:ok, "max"}
      assert ReasoningEffort.to_provider(:xhigh, :anthropic) == {:ok, "xhigh"}
      assert ReasoningEffort.to_provider(:low, :anthropic) == {:ok, "low"}
    end

    test "a level above the provider's ceiling clamps to that ceiling" do
      assert ReasoningEffort.to_provider(:max, :openai) == {:ok, "xhigh"}
      assert ReasoningEffort.to_provider(:max, :openai_codex) == {:ok, "xhigh"}
    end

    test "a level below the provider's floor is unsupported (reject loud upstream)" do
      assert ReasoningEffort.to_provider(:none, :anthropic) ==
               {:error, {:unsupported, :none, :anthropic}}
    end

    test "a non-canonical level is unsupported regardless of provider" do
      assert ReasoningEffort.to_provider(:auto, :anthropic) ==
               {:error, {:unsupported, :auto, :anthropic}}
    end
  end
end
