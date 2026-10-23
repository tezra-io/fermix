defmodule FermixCore.OpenLoops.ConfigTest do
  # Pure module: no processes, no I/O, no global state. Readers take an explicit
  # config so nothing touches Application env.
  use ExUnit.Case, async: true

  alias FermixCore.OpenLoops.Config, as: OpenLoopsConfig

  describe "normalize/1" do
    test "nil and empty input normalize to an empty keyword" do
      assert OpenLoopsConfig.normalize(nil) == []
      assert OpenLoopsConfig.normalize(%{}) == []
      assert OpenLoopsConfig.normalize([]) == []
    end

    test "accepts enabled as string or atom key" do
      assert OpenLoopsConfig.normalize(%{"enabled" => true}) == [enabled: true]
      assert OpenLoopsConfig.normalize(%{enabled: false}) == [enabled: false]
      assert OpenLoopsConfig.normalize(enabled: true) == [enabled: true]
    end

    test "rejects a non-boolean enabled and names the key and value" do
      assert_raise ArgumentError, ~r/open_loops\.enabled "true"/, fn ->
        OpenLoopsConfig.normalize(enabled: "true")
      end

      assert_raise ArgumentError, ~r/open_loops\.enabled 1/, fn ->
        OpenLoopsConfig.normalize(%{"enabled" => 1})
      end
    end
  end

  describe "config_keys/0" do
    test "the allowlist is exactly the section's key surface" do
      keys = OpenLoopsConfig.config_keys()

      assert Enum.sort(keys) == [:enabled]
      assert length(keys) == length(Enum.uniq(keys))
    end
  end

  describe "enabled?/1" do
    test "defaults to false when the key is absent" do
      assert OpenLoopsConfig.enabled?([]) == false
    end

    test "reads an explicit value" do
      assert OpenLoopsConfig.enabled?(enabled: true) == true
      assert OpenLoopsConfig.enabled?(enabled: false) == false
    end
  end
end
