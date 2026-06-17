defmodule Fermix.CLI.Upgrade.Swapper do
  @moduledoc """
  Disk-side of the upgrade flow.

  Downloads the new binary + signature + certificate to a staging
  directory, asks the cosign verifier to confirm them, snapshots the
  current binary into a one-shot recovery slot
  (`~/.fermix/.previous`), then atomically renames the staged binary
  into the installed path. Rollback is a single `rename(2)` from the
  recovery slot back over the installed path, never a multi-version
  history.
  """

  alias Fermix.CLI.Upgrade.Cosign
  alias FermixCore.Net.StreamDownload

  @type staged :: %{
          blob_path: Path.t(),
          sig_path: Path.t(),
          cert_path: Path.t(),
          staging_dir: Path.t()
        }

  @spec stage_artifact(map(), keyword()) :: {:ok, staged()} | {:error, term()}
  def stage_artifact(artifact, opts \\ []) do
    staging_dir = Keyword.get(opts, :staging_dir, default_staging_dir())
    req_options = Keyword.get(opts, :req_options, [])

    File.mkdir_p!(staging_dir)
    blob_path = Path.join(staging_dir, "fermix.upgrade.tmp")
    sig_path = Path.join(staging_dir, "fermix.upgrade.sig")
    cert_path = Path.join(staging_dir, "fermix.upgrade.pem")

    with :ok <- StreamDownload.download(artifact.url, blob_path, req_options),
         :ok <- StreamDownload.download(artifact.sig_url, sig_path, req_options),
         :ok <- StreamDownload.download(artifact.cert_url, cert_path, req_options),
         :ok <- StreamDownload.check_sha256(blob_path, artifact.sha256) do
      File.chmod!(blob_path, 0o755)

      {:ok,
       %{
         blob_path: blob_path,
         sig_path: sig_path,
         cert_path: cert_path,
         staging_dir: staging_dir
       }}
    end
  end

  @spec verify(staged(), keyword()) :: :ok | {:error, term()}
  def verify(staged, opts \\ []) do
    Cosign.verify(staged.blob_path, staged.sig_path, staged.cert_path, opts)
  end

  @spec swap(staged(), Path.t(), keyword()) ::
          {:ok, %{installed_path: Path.t(), previous_path: Path.t()}} | {:error, term()}
  def swap(staged, installed_path, opts \\ []) do
    previous_path = Keyword.get(opts, :previous_path, default_previous_path())
    File.mkdir_p!(Path.dirname(previous_path))

    with :ok <- snapshot_previous(installed_path, previous_path),
         :ok <- File.rename(staged.blob_path, installed_path) do
      cleanup_staging(staged)
      {:ok, %{installed_path: installed_path, previous_path: previous_path}}
    end
  end

  @spec rollback(Path.t(), Path.t()) :: :ok | {:error, term()}
  def rollback(previous_path, installed_path) do
    case File.exists?(previous_path) do
      true -> File.rename(previous_path, installed_path)
      false -> {:error, {:no_recovery_slot, previous_path}}
    end
  end

  @spec default_staging_dir() :: Path.t()
  def default_staging_dir do
    Path.join(default_fermix_home(), "upgrade.staging")
  end

  @spec default_previous_path() :: Path.t()
  def default_previous_path do
    Path.join(default_fermix_home(), ".previous")
  end

  defp default_fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end

  defp snapshot_previous(installed_path, previous_path) do
    case File.cp(installed_path, previous_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:snapshot_failed, reason}}
    end
  end

  defp cleanup_staging(%{sig_path: sig, cert_path: cert, staging_dir: dir}) do
    _ = File.rm(sig)
    _ = File.rm(cert)
    _ = File.rmdir(dir)
    :ok
  end
end
