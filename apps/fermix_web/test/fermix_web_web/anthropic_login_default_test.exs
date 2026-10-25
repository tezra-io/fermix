defmodule FermixWebWeb.AnthropicLoginDefaultTest do
  # Reads the suite's app env, which sync modules may set and restore.
  use ExUnit.Case, async: false

  alias FermixWebWeb.TestSupport.UnreachableAnthropicLogin

  # Three setup cases once read the person's real Claude Code login on every
  # run, because their module cleared this key and the page fell back to the
  # real AnthropicLogin. The suite's default raises instead.
  test "a web test that chose no Claude Code stub raises instead of reading the real login" do
    assert Application.fetch_env!(:fermix_web, :anthropic_login_impl) ==
             UnreachableAnthropicLogin

    for read <- [
          &UnreachableAnthropicLogin.claude_code_present?/0,
          &UnreachableAnthropicLogin.import_claude_code/0
        ] do
      assert_raise RuntimeError, ~r/no stub chosen/, read
    end
  end
end
