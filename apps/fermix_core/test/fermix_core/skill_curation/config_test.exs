defmodule FermixCore.SkillCuration.ConfigTest do
  # Pure module: no processes, no I/O, no global state — readers take an explicit
  # config so nothing touches Application env.
  use ExUnit.Case, async: true

  alias FermixCore.SkillCuration.Config, as: SkillCurationConfig

  describe "normalize/1" do
    test "nil and empty input normalize to an empty keyword" do
      assert SkillCurationConfig.normalize(nil) == []
      assert SkillCurationConfig.normalize(%{}) == []
      assert SkillCurationConfig.normalize([]) == []
    end

    test "accepts enabled as string or atom key" do
      assert SkillCurationConfig.normalize(%{"enabled" => false}) == [enabled: false]
      assert SkillCurationConfig.normalize(%{enabled: true}) == [enabled: true]
      assert SkillCurationConfig.normalize(enabled: false) == [enabled: false]
    end

    test "rejects a non-boolean enabled and names the key + value" do
      assert_raise ArgumentError, ~r/skill_curation\.enabled "true"/, fn ->
        SkillCurationConfig.normalize(enabled: "true")
      end
    end
  end

  describe "config_keys/0" do
    test "the allowlist is exactly the section's key surface" do
      keys = SkillCurationConfig.config_keys()

      assert Enum.sort(keys) == [:enabled]
      assert length(keys) == length(Enum.uniq(keys))
    end
  end

  describe "enabled?/1" do
    test "defaults to true when the key is absent" do
      assert SkillCurationConfig.enabled?([]) == true
    end

    test "reads an explicit value" do
      assert SkillCurationConfig.enabled?(enabled: false) == false
      assert SkillCurationConfig.enabled?(enabled: true) == true
    end
  end
end
