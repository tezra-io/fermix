defmodule FermixTestSupport.HostRuntimeStub do
  @moduledoc """
  Deny-by-default host-runtime probe stub, the test-env default for
  `config :fermix_core, :runtime_probe_host` (set in `config/test.exs` —
  never delete that default). It guarantees `mix test` can never resolve a
  host runtime or spawn a real `--version` process: an mcp plugin only
  becomes probe-:ready in a test that explicitly stubs the probe via the
  `:find_executable` / `:version_fetch` opts. Same family as the SafeRm /
  SecretWriterStub rules: tests must never touch host state.
  """

  @behaviour FermixCore.Plugins.Dist.RuntimeProbe.Host

  @impl true
  def find_executable(_command), do: nil

  @impl true
  def version_output(_command, _opts \\ []), do: {:error, :host_runtime_stubbed_out}
end
