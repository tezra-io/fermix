defmodule Fermix.CLI.Upgrade.Cosign do
  @moduledoc """
  Shells out to `cosign verify-blob` to validate a downloaded binary
  against the signature + certificate published in the release
  manifest.

  Keyless OIDC verification — the cert and signature come from the
  release pipeline (see `.github/workflows/release.yml`). We pin the
  certificate identity to the *specific* release workflow tag matching
  the manifest's selected version (audit F-13), and the issuer to the
  GitHub Actions OIDC token issuer, so a cert minted for a different
  version or repo cannot pass.
  """

  @issuer "https://token.actions.githubusercontent.com"
  @identity_prefix "https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v"
  @default_timeout_ms 60_000

  @spec verify(Path.t(), Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def verify(blob_path, sig_path, cert_path, opts \\ []) do
    cosign = Keyword.get(opts, :cosign_path) || System.find_executable("cosign")

    with :ok <- require_cosign(cosign),
         :ok <- require_existing(blob_path, :missing_blob),
         :ok <- require_existing(sig_path, :missing_signature),
         :ok <- require_existing(cert_path, :missing_certificate),
         {:ok, identity_regex} <- identity_regex(opts) do
      run(cosign, blob_path, sig_path, cert_path, identity_regex, opts)
    end
  end

  defp require_cosign(nil), do: {:error, :cosign_not_installed}
  defp require_cosign(_path), do: :ok

  defp require_existing(path, missing_tag) do
    if File.exists?(path), do: :ok, else: {:error, {missing_tag, path}}
  end

  defp identity_regex(opts) do
    case Keyword.get(opts, :identity_regex) do
      override when is_binary(override) and override != "" ->
        {:ok, override}

      _ ->
        case Keyword.fetch(opts, :version) do
          {:ok, version} when is_binary(version) and version != "" ->
            {:ok, "^" <> @identity_prefix <> Regex.escape(version) <> "$"}

          _ ->
            {:error, :missing_version}
        end
    end
  end

  defp run(cosign, blob_path, sig_path, cert_path, identity_regex, opts) do
    issuer = Keyword.get(opts, :issuer, @issuer)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

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

    run_with_timeout(cosign, args, timeout_ms)
  end

  defp run_with_timeout(cosign, args, timeout_ms) do
    task = Task.async(fn -> System.cmd(cosign, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:cosign_failed, code, String.trim(out)}}
      nil -> {:error, {:cosign_timeout, timeout_ms}}
    end
  end
end
