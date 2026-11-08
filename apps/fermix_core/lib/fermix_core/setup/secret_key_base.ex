defmodule FermixCore.Setup.SecretKeyBase do
  @moduledoc """
  Resolves the Phoenix `secret_key_base` that signs session cookies.

  The daemon restarts itself (service `KeepAlive`, and the setup UI's restart
  button), so the signing key must be stable across restarts. A per-boot key
  would invalidate the in-flight setup session cookie mid-flow and lock the
  browser out with a 403. We persist a generated key under `FERMIX_HOME`
  (mode `0600`) so it survives restarts.

  Only a boot that serves the web listener resolves it
  (`FermixCore.BootProfile.prepare/2`), so a verb that serves nothing,
  `fermix --version` among them, writes no home.
  """

  # 48 random bytes Base64-encode to 64 characters, satisfying Phoenix's
  # minimum 64-byte `secret_key_base` requirement.
  @random_bytes 48
  @min_length 64

  @doc """
  The key the web listener signs with: `SECRET_KEY_BASE` where the operator
  set it, else the one persisted under `home` (`read_or_create!/1`).
  """
  @spec resolve!(Path.t()) :: String.t()
  def resolve!(home) when is_binary(home) do
    case System.get_env("SECRET_KEY_BASE") do
      nil -> read_or_create!(home)
      key -> key
    end
  end

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
