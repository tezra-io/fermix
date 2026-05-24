defmodule FermixCore.Providers.OpenAI.ResponsesSharedTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.OpenAI.ResponsesShared

  describe "maybe_reasoning_field/2" do
    test "returns nil for nil, :none, and \"none\" — caller omits the body field" do
      assert ResponsesShared.maybe_reasoning_field(nil, :openai) == nil
      assert ResponsesShared.maybe_reasoning_field(:none, :openai) == nil
      assert ResponsesShared.maybe_reasoning_field("none", :openai) == nil
    end

    test "returns %{effort: <string>} for each supported level (atom and string)" do
      for level <- [:low, :medium, :high, :xhigh] do
        assert ResponsesShared.maybe_reasoning_field(level, :openai) ==
                 %{effort: Atom.to_string(level)}

        assert ResponsesShared.maybe_reasoning_field(Atom.to_string(level), :openai) ==
                 %{effort: Atom.to_string(level)}
      end
    end

    test "clamps a level above the provider ceiling (:max -> xhigh on OpenAI-family)" do
      assert ResponsesShared.maybe_reasoning_field(:max, :openai) == %{effort: "xhigh"}
      assert ResponsesShared.maybe_reasoning_field(:max, :openai_codex) == %{effort: "xhigh"}
    end

    test "raises ArgumentError on a removed level (minimal)" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: :minimal/, fn ->
        ResponsesShared.maybe_reasoning_field(:minimal, :openai)
      end
    end

    test "raises ArgumentError on an unknown string level" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: \"absurd\"/, fn ->
        ResponsesShared.maybe_reasoning_field("absurd", :openai)
      end
    end

    test "raises ArgumentError on a non-atom non-string value" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: 7/, fn ->
        ResponsesShared.maybe_reasoning_field(7, :openai)
      end
    end
  end
end
