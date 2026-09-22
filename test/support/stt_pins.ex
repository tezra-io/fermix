defmodule FermixTestSupport.SttPins do
  @moduledoc """
  Pin tables for the on-device speech sidecar.

  `FermixCore.Transcription.Local.SidecarInstaller` pins a release per host
  target, so whether on-device speech is offered depends on the machine a test
  runs on. A test that crosses that gate names the machine it means through the
  `releases:` seam instead of inheriting the CI host's answer: this table for a
  machine the build has a sidecar for, and `%{}` for one it has none for.
  """

  alias FermixCore.Transcription.Local.SidecarInstaller

  @doc "A table pinning a release for this host's target. Its URL is never fetched."
  @spec for_this_host() :: %{String.t() => %{url: String.t(), sha256: String.t()}}
  def for_this_host do
    {:ok, target} = SidecarInstaller.target()

    %{
      target => %{
        url: "https://example.invalid/fermix-stt-" <> target,
        sha256: String.duplicate("0", 64)
      }
    }
  end
end
