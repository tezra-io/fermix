defmodule FermixCore.Providers.OpenAI.ResponsesSharedTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.OpenAI.ResponsesShared

  describe "valid_reasoning_efforts/0" do
    test "returns the canonical hermes-agent compatible enum" do
      assert ResponsesShared.valid_reasoning_efforts() ==
               [:none, :minimal, :low, :medium, :high, :xhigh]
    end
  end

  describe "maybe_reasoning_field/1" do
    test "returns nil for nil, :none, and \"none\" — caller omits the body field" do
      assert ResponsesShared.maybe_reasoning_field(nil) == nil
      assert ResponsesShared.maybe_reasoning_field(:none) == nil
      assert ResponsesShared.maybe_reasoning_field("none") == nil
    end

    test "returns %{effort: <string>} for each valid level (atom)" do
      for level <- [:minimal, :low, :medium, :high, :xhigh] do
        assert ResponsesShared.maybe_reasoning_field(level) == %{effort: Atom.to_string(level)}
      end
    end

    test "returns %{effort: <string>} for each valid level (string)" do
      for level <- ["minimal", "low", "medium", "high", "xhigh"] do
        assert ResponsesShared.maybe_reasoning_field(level) == %{effort: level}
      end
    end

    test "raises ArgumentError on an unknown atom level" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: :weird/, fn ->
        ResponsesShared.maybe_reasoning_field(:weird)
      end
    end

    test "raises ArgumentError on an unknown string level" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: \"absurd\"/, fn ->
        ResponsesShared.maybe_reasoning_field("absurd")
      end
    end

    test "raises ArgumentError on a non-atom non-string value" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: 7/, fn ->
        ResponsesShared.maybe_reasoning_field(7)
      end
    end
  end
end
