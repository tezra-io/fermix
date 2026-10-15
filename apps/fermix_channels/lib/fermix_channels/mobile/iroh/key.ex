defmodule FermixChannels.Mobile.Iroh.Key do
  @moduledoc """
  The daemon's iroh secret key: `<home>/mobile/iroh_key`, 32 raw bytes, mode
  `0600` (M62 §2). Its Ed25519 public key is the endpoint id a phone dials, so it
  never changes on its own.

  `ensure/1` creates it once, when the rail first starts beside an existing
  gateway identity, by writing a temporary file and renaming it into place, so
  the key is either whole or absent. A key of the wrong size, type or mode is
  refused, never replaced: replacing it would silently cut off every paired
  phone, which dials the old endpoint id. The key leaves this file only for the
  helper, which reads it from the path; the daemon logs only the endpoint id.
  """

  @filename "iroh_key"
  @file_mode 0o600
  @dir_mode 0o700
  @max_stale_temps 32

  @doc "The key's path under a Fermix home."
  @spec path(Path.t()) :: Path.t()
  def path(root) when is_binary(root) and root != "",
    do: Path.join([root, "mobile", @filename])

  @doc """
  Loads the key, creating it first if the home has none. Returns the path the
  helper reads and the endpoint id it must report.
  """
  @spec ensure(Path.t()) :: {:ok, %{path: Path.t(), endpoint_id: String.t()}} | {:error, term()}
  def ensure(root) when is_binary(root) and root != "" do
    key_path = path(root)

    with :ok <- validate_dir(Path.dirname(key_path)),
         {:ok, secret} <- load_or_create(key_path) do
      {:ok, %{path: key_path, endpoint_id: endpoint_id(secret)}}
    end
  end

  @doc "The endpoint id of a secret key: its Ed25519 public key, lowercase hex."
  @spec endpoint_id(<<_::256>>) :: String.t()
  def endpoint_id(<<_::256>> = secret) do
    {public, ^secret} = :crypto.generate_key(:eddsa, :ed25519, secret)
    Base.encode16(public, case: :lower)
  end

  defp load_or_create(key_path) do
    case File.lstat(key_path) do
      {:ok, %{type: :regular, mode: mode}} -> load(key_path, Bitwise.band(mode, 0o777))
      {:ok, %{type: type}} -> {:error, {:iroh_key_unsafe_type, key_path, type}}
      {:error, :enoent} -> create(key_path)
      {:error, reason} -> {:error, {:iroh_key_unreadable, key_path, reason}}
    end
  end

  defp load(key_path, @file_mode) do
    case File.read(key_path) do
      {:ok, <<_::256>> = secret} -> {:ok, secret}
      {:ok, other} -> {:error, {:iroh_key_invalid, key_path, {:size, byte_size(other)}}}
      {:error, reason} -> {:error, {:iroh_key_unreadable, key_path, reason}}
    end
  end

  defp load(key_path, mode), do: {:error, {:iroh_key_invalid, key_path, {:mode, mode}}}

  defp create(key_path) do
    secret = :crypto.strong_rand_bytes(32)
    temp = "#{key_path}.tmp.#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- remove_stale_temps(key_path),
         :ok <- File.write(temp, secret, [:binary, :exclusive]),
         :ok <- File.chmod(temp, @file_mode),
         :ok <- File.rename(temp, key_path) do
      {:ok, secret}
    else
      {:error, reason} -> {:error, {:iroh_key_write_failed, key_path, reason, remove(temp)}}
    end
  end

  # A crash between writing and renaming leaves a temporary file, never a
  # partial key; the next creation removes it.
  defp remove_stale_temps(key_path) do
    case Path.wildcard("#{key_path}.tmp.*") do
      stale when length(stale) <= @max_stale_temps ->
        Enum.reduce_while(stale, :ok, &remove_stale_temp/2)

      stale ->
        {:error, {:too_many_stale_temps, length(stale)}}
    end
  end

  defp remove_stale_temp(temp, :ok) do
    case remove(temp) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:stale_temp_unremovable, temp, reason}}}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_dir(dir) do
    case File.lstat(dir) do
      {:ok, %{type: :directory, mode: mode}} -> dir_mode(dir, Bitwise.band(mode, 0o777))
      {:ok, %{type: type}} -> {:error, {:iroh_key_unsafe_type, dir, type}}
      {:error, reason} -> {:error, {:iroh_key_dir_unusable, dir, reason}}
    end
  end

  defp dir_mode(_dir, @dir_mode), do: :ok
  defp dir_mode(dir, mode), do: {:error, {:iroh_key_dir_unusable, dir, {:mode, mode}}}
end
