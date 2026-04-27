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

    with :ok <- download(artifact.url, blob_path, req_options),
         :ok <- download(artifact.sig_url, sig_path, req_options),
         :ok <- download(artifact.cert_url, cert_path, req_options),
         :ok <- check_sha256(blob_path, artifact.sha256) do
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

  defp download(url, path, req_options) do
    case Req.get(url, [raw: true, into: File.stream!(path)] ++ req_options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_status, status, url}}
      {:error, reason} -> {:error, {:download_failed, reason, url}}
    end
  end

  defp check_sha256(path, expected_hex) do
    actual = path |> File.stream!([], 64 * 1024) |> hash_stream() |> Base.encode16(case: :lower)

    if actual == String.downcase(expected_hex) do
      :ok
    else
      {:error, {:sha256_mismatch, expected: expected_hex, actual: actual}}
    end
  end

  defp hash_stream(stream) do
    Enum.reduce(stream, :crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
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
