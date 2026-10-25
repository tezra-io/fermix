defmodule FermixWebWeb.TestSupport.UnreachableAnthropicLogin do
  @moduledoc """
  The `:anthropic_login_impl` a web test gets when it chose none.

  The real `FermixCore.Auth.AnthropicLogin` reads Claude Code's own login: the
  login Keychain item through `security` and `~/.claude/.credentials.json`. A
  test that reached it would read the person's real credential on their Mac.
  Every function here raises instead, so such a test fails by name; a test that
  renders the Claude Code import picks a stub of its own.
  """

  @spec store_setup_token(String.t(), keyword()) :: no_return()
  def store_setup_token(_token, _opts \\ []), do: unreachable(:store_setup_token)

  @spec import_claude_code(keyword()) :: no_return()
  def import_claude_code(_opts \\ []), do: unreachable(:import_claude_code)

  @spec claude_code_present?(keyword()) :: no_return()
  def claude_code_present?(_opts \\ []), do: unreachable(:claude_code_present?)

  defp unreachable(function) do
    raise "a test reached AnthropicLogin.#{function} with no stub chosen, which would read " <>
            "the real Claude Code login; set :anthropic_login_impl to a stub for this test"
  end
end
