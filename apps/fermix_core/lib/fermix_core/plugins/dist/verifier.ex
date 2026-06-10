defmodule FermixCore.Plugins.Dist.Verifier do
  @moduledoc """
  Behaviour for verifying a plugin artifact's cosign signature.

  The seam exists so install tests can assert the integrity gate WITHOUT a
  `cosign` binary on the host — and so the stub can **default-deny**, making it
  impossible for a test to pass the gate by accident (green-because-stubbed).
  The production implementation is `Verifier.Cosign`, pinning the certificate
  identity to the `fermix-plugins` release workflow at the artifact's own tag.
  """

  @doc """
  Verify `blob` against its detached `sig` + `cert`. `opts` carries the plugin
  `:name` and `:version` (used to pin the cosign certificate identity).
  Returns `:ok` or `{:error, reason}`.
  """
  @callback verify(blob :: Path.t(), sig :: Path.t(), cert :: Path.t(), opts :: keyword()) ::
              :ok | {:error, term()}
end
