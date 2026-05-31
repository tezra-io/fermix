defmodule FermixCore.Setup.SecretKeyBase do
  @moduledoc """
  Resolves the Phoenix `secret_key_base` that signs session cookies.

  The daemon restarts itself (service `KeepAlive`, and the setup UI's restart
  button), so the signing key must be stable across restarts. A per-boot key
  would invalidate the in-flight setup session cookie mid-flow and lock the
  browser out with a 403. We persist a generated key under `FERMIX_HOME`
  (mode `0600`) so it survives restarts.
  """

  # 48 random bytes Base64-encode to 64 characters, satisfying Phoenix's
  # minimum 64-byte `secret_key_base` requirement.
  @random_bytes 48
  @min_length 64

  @doc """
  Returns the persisted secret key base under `home`, generating and
  persisting one on first call. Raises on any I/O failure or a corrupt file.
  """
  @spec read_or_create!(Path.t()) :: String.t()
  def read_or_create!(home) when is_binary(home) do
    path = Path.join(home, "secret_key_base")

    case File.read(path) do
      {:ok, contents} -> verified!(String.trim(contents), path)
      {:error, :enoent} -> create!(home, path)
      {:error, reason} -> raise "could not read #{path}: #{inspect(reason)}"
    end
  end

  defp create!(home, path) do
    key = Base.encode64(:crypto.strong_rand_bytes(@random_bytes))
    File.mkdir_p!(home)
    File.write!(path, key)
    File.chmod!(path, 0o600)
    key
  end

  defp verified!(key, _path) when byte_size(key) >= @min_length, do: key

  defp verified!(_key, path),
    do: raise("#{path} is too short to sign sessions; delete it to regenerate")
end
