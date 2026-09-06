defmodule FermixCore.Setup.TestHomeIsolationTest do
  use ExUnit.Case, async: true

  # The suite boots the whole umbrella before a single test runs: config
  # providers hydrate `config.toml`, `SkillRegistry` loads the installed plugin
  # store, `ensure_workspace/0` creates directories. With `FERMIX_HOME` unset
  # every one of those reads the OPERATOR's `~/.fermix` — host state the suite
  # neither controls nor restores, and the reason a machine with an installed
  # `remote_mcp` plugin cannot run `mix test` at all (boot dies inside the
  # provenance gate). `config/test.exs` pins a suite-owned home when the caller
  # supplied none, so a plain `mix test` boots exactly like the documented
  # `FERMIX_HOME=$(mktemp -d) mix test`.
  #
  # Captured at LOAD time — every test file is compiled before any test runs,
  # so this is the value the boot ran under and not whatever one of the ~55
  # tests that rewrite this variable happens to have left in it.
  @boot_home System.get_env("FERMIX_HOME")

  test "the suite boots against a FERMIX_HOME the suite owns" do
    assert is_binary(@boot_home) and @boot_home != "",
           "FERMIX_HOME is unset for the suite: boot read the operator's real ~/.fermix"
  end

  test "the suite's FERMIX_HOME is never the operator's real home" do
    operator_home = Path.expand(Path.join(System.user_home!(), ".fermix"))

    refute Path.expand(@boot_home || "") == operator_home,
           "FERMIX_HOME points at the operator's real home (#{operator_home})"
  end
end
