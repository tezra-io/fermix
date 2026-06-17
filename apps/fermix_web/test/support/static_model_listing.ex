defmodule FermixWebWeb.TestSupport.StaticModelListing do
  @moduledoc """
  Test-env default for the SetupLive model-listing seam: no provider is
  live, so panes render the static catalog and never reach the network
  (hermetic-test rule — same family as `SecretWriterStub`). Tests that
  exercise the live UI swap in their own stub via
  `Application.put_env(:fermix_web, :model_listing_impl, ...)`.
  """

  @spec live?(atom()) :: boolean()
  def live?(_provider), do: false

  @spec live_models(atom(), keyword()) :: {:error, String.t()}
  def live_models(provider, _opts) do
    raise "StaticModelListing.live_models/2 called for #{inspect(provider)} — live?/1 is false"
  end
end
