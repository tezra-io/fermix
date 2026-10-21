defmodule FermixTestSupport.HostFactsStub do
  @moduledoc false
  # The host facts the suite's boot reads (`config :fermix_core,
  # :host_facts_reader` in `config/test.exs`). The install, the OS and the
  # architecture are the run's own, from `BootProfile` and `BuildInfo`; what
  # `HostFacts` itself would read from the machine is fixed: macOS 26.1, Ubuntu
  # 24.04 LTS, and no Linux desktop app, so no test reads this machine's
  # SystemVersion.plist, os-release or Flatpak exports.
  @behaviour FermixCore.HostFacts

  alias FermixCore.HostFacts

  @impl true
  def read(host, architecture) do
    HostFacts.read(host, architecture,
      plutil: &plutil/1,
      os_release: fn -> {:ok, ~s(NAME="Ubuntu"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n)} end,
      flatpak_exports: []
    )
  end

  defp plutil(["-extract", "ProductName" | _rest]), do: {:ok, "macOS\n"}
  defp plutil(["-extract", "ProductVersion" | _rest]), do: {:ok, "26.1\n"}
end
