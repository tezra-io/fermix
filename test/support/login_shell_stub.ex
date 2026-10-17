defmodule FermixTestSupport.LoginShellStub do
  @moduledoc """
  The test-env reading of the owner's login shell `PATH`
  (`config :fermix_core, :mcp_login_shell`, set in `config/test.exs`): the
  suite's own `PATH`, so a server the suite starts finds what the suite finds
  and no test runs a real login shell with its rc files.
  """

  @behaviour FermixCore.Capabilities.MCP.LoginPath

  @impl true
  def read, do: {:ok, System.get_env("PATH", "")}
end
