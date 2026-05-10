defmodule FermixCore.Memory.CompactionConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.CompactionConfig

  describe "normalize/1" do
    test "keeps valid explicit config" do
      assert CompactionConfig.normalize(%{"enabled" => true, "threshold" => 0.85}) == [
               enabled: true,
               threshold: 0.85
             ]

      assert CompactionConfig.normalize(enabled: false, threshold: 0.1) == [
               enabled: false,
               threshold: 0.1
             ]
    end

    test "rejects out-of-range threshold values" do
      assert_raise ArgumentError, ~r/compaction.threshold/, fn ->
        CompactionConfig.normalize(threshold: 0.09)
      end

      assert_raise ArgumentError, ~r/compaction.threshold/, fn ->
        CompactionConfig.normalize(threshold: 1.01)
      end
    end

    test "rejects invalid threshold and enabled types" do
      assert_raise ArgumentError, ~r/compaction.threshold/, fn ->
        CompactionConfig.normalize(threshold: "0.85")
      end

      assert_raise ArgumentError, ~r/compaction.enabled/, fn ->
        CompactionConfig.normalize(enabled: "true")
      end
    end
  end

  describe "accessors" do
    test "apply runtime defaults when values are unset" do
      assert CompactionConfig.enabled?([]) == true
      assert CompactionConfig.threshold([]) == 0.85
    end
  end
end
