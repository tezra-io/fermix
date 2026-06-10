defmodule FermixCore.Plugins.Dist.Verifier.Cosign do
  @moduledoc """
  Production `Verifier`: keyless cosign verify-blob, pinning the certificate
  identity to the `fermix-plugins` release workflow at the artifact's own tag
  (`<name>/v<version>`), and the issuer to the GitHub Actions OIDC issuer.

  A cert minted for a different plugin, a different version, or a different
  repo's workflow cannot pass. The shelling-out itself is reused from the
  binary-upgrade `Cosign` module (which already accepts an `identity_regex`
  override); this module only computes the plugin-specific identity.
  """

  @behaviour FermixCore.Plugins.Dist.Verifier

  alias Fermix.CLI.Upgrade.Cosign

  @identity_prefix "https://github.com/tezra-io/fermix-plugins/.github/workflows/release-plugin.yml@refs/tags/"

  @impl true
  def verify(blob, sig, cert, opts)
      when is_binary(blob) and is_binary(sig) and is_binary(cert) and is_list(opts) do
    with {:ok, identity_regex} <- resolve_identity(opts) do
      Cosign.verify(blob, sig, cert, Keyword.put(opts, :identity_regex, identity_regex))
    end
  end

  defp resolve_identity(opts) do
    case Keyword.get(opts, :artifact, :plugin) do
      :plugin -> identity_regex(opts)
      other -> {:error, {:unknown_artifact_kind, other}}
    end
  end

  @doc """
  The pinned certificate-identity regexp for a plugin release, anchored so only
  the exact `<name>/v<version>` workflow ref matches. Public for testing the
  pinning without a `cosign` binary.
  """
  @spec identity_regex(keyword()) :: {:ok, String.t()} | {:error, term()}
  def identity_regex(opts) do
    with {:ok, name} <- fetch_nonempty(opts, :name),
         {:ok, version} <- fetch_nonempty(opts, :version) do
      # Escape the WHOLE identity (not just the tag) and anchor both ends, so
      # the regexp form is an exact-string match — the dots in `.github` and
      # `release-plugin.yml` cannot act as wildcards.
      {:ok, "^" <> Regex.escape(@identity_prefix <> "#{name}/v#{version}") <> "$"}
    end
  end

  defp fetch_nonempty(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_verifier_opt, key}}
    end
  end
end
