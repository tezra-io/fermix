defmodule Fermix.CLI.Upgrade.Cosign do
  @moduledoc """
  Shells out to `cosign verify-blob` to validate a downloaded binary
  against the signature + certificate published in the release
  manifest.

  Keyless OIDC verification — the cert and signature come from the
  release pipeline (see `.github/workflows/release.yml`). We pin the
  certificate identity to the release workflow file and the issuer
  to the GitHub Actions OIDC token issuer so a forged cert minted
  against a different repo can't pass.
  """

  @issuer "https://token.actions.githubusercontent.com"
  @identity_regex ~r{^https://github\.com/tezra-io/fermix/\.github/workflows/release\.yml@refs/tags/v[\d.]+$}

  @spec verify(Path.t(), Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def verify(blob_path, sig_path, cert_path, opts \\ []) do
    cosign = Keyword.get(opts, :cosign_path) || System.find_executable("cosign")

    cond do
      is_nil(cosign) ->
        {:error, :cosign_not_installed}

      not File.exists?(blob_path) ->
        {:error, {:missing_blob, blob_path}}

      not File.exists?(sig_path) ->
        {:error, {:missing_signature, sig_path}}

      not File.exists?(cert_path) ->
        {:error, {:missing_certificate, cert_path}}

      true ->
        run(cosign, blob_path, sig_path, cert_path, opts)
    end
  end

  defp run(cosign, blob_path, sig_path, cert_path, opts) do
    identity_regex = Keyword.get(opts, :identity_regex, Regex.source(@identity_regex))
    issuer = Keyword.get(opts, :issuer, @issuer)

    args = [
      "verify-blob",
      "--certificate",
      cert_path,
      "--signature",
      sig_path,
      "--certificate-identity-regexp",
      identity_regex,
      "--certificate-oidc-issuer",
      issuer,
      blob_path
    ]

    case System.cmd(cosign, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:cosign_failed, code, String.trim(out)}}
    end
  end
end
