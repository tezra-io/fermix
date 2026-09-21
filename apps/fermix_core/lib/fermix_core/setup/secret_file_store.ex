defmodule FermixCore.Setup.SecretWriter.FileStore do
  @moduledoc """
  A private-file secret store, used only where the owner has said to.

  This is never chosen for someone. It is reached when a request carries the
  owner's consent, and the choice it records is reversible: a successful
  keyring write moves the value back and deletes the copy here.

  One file per secret rather than one file for all of them. A write then never
  rewrites a value it is not changing, so a crash cannot lose an unrelated
  credential; a delete and a migration are one rename or unlink each; the
  permission check is per file, so one widened file refuses one secret instead
  of all of them; and it keeps the keyring's per-item addressing, so sentinel
  resolution is the same shape in both stores.

  The directory is `0700` and every file `0600`, and both are checked on every
  read and every write. A wider mode is refused loudly and never repaired: it
  is evidence about the machine, not a formatting error, and quietly narrowing
  it would destroy the only sign that something else had been there.
  """

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @directory "secrets"
  @directory_mode 0o700
  @file_mode 0o600

  @impl true
  def available?(opts \\ []) when is_list(opts), do: is_binary(home(opts))

  @doc "Where this store keeps its files, for a caller that must report it."
  @spec directory(keyword()) :: String.t()
  def directory(opts \\ []) when is_list(opts), do: Path.join(home(opts), @directory)

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    with {:ok, dir} <- ensure_directory(opts),
         path = Path.join(dir, filename(key, opts)),
         :ok <- check_mode(path, @file_mode) do
      write_atomically(path, value)
    end
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key) do
    with {:ok, dir} <- readable_directory(opts),
         path = Path.join(dir, filename(key, opts)),
         :ok <- check_mode(path, @file_mode) do
      read_value(path)
    end
  end

  @doc """
  Removes the file behind `key`. Succeeds when there is none, because the
  postcondition — this machine no longer stores that credential — holds.
  """
  @impl true
  def delete(key, opts \\ []) when is_secret_key(key) do
    with {:ok, dir} <- readable_directory(opts) do
      dir
      |> Path.join(filename(key, opts))
      |> File.rm()
      |> case do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:file_store_failed, reason}}
      end
    end
  end

  @doc """
  The item name of every secret stored here, as the keyring spells it. This is
  what the migration back reads, so it never has to guess which keys moved.
  """
  @spec stored_keys(keyword()) :: [String.t()]
  def stored_keys(opts \\ []) when is_list(opts) do
    # A machine that never used this store has no directory, and that is the
    # commonest case rather than an error: nothing is stored here.
    with {:ok, dir} <- readable_directory(opts),
         {:ok, names} <- File.ls(dir) do
      Enum.flat_map(names, &decode_filename/1)
    else
      _nothing_stored -> []
    end
  end

  @impl true
  def command_source(key, opts \\ []) when is_secret_key(key) do
    %{source: :file, path: Path.join(directory(opts), filename(key, opts))}
  end

  # The name never lands in a path as itself: an item name carries `:` and a
  # profile prefix, and encoding it makes the filename injective and incapable
  # of naming anything outside this directory.
  defp filename(key, opts) do
    Base.url_encode64(scoped_name(key, opts), padding: false)
  end

  defp decode_filename(name) do
    case Base.url_decode64(name, padding: false) do
      {:ok, decoded} -> [strip_prefix(decoded)]
      :error -> []
    end
  end

  defp strip_prefix(name) do
    case String.split(name, "\0", parts: 2) do
      [_prefix, item] -> item
      [item] -> item
    end
  end

  defp scoped_name(key, opts) do
    SecretWriter.scoped_prefix(opts) <> "\0" <> SecretWriter.item_name(key)
  end

  # An existing directory is checked, never chmodded back: narrowing it here
  # would erase the evidence that it had been widened, which is the one thing
  # a caller needs to be told.
  defp ensure_directory(opts) do
    dir = directory(opts)

    case File.dir?(dir) do
      true -> readable_directory(opts)
      false -> create_directory(dir)
    end
  end

  defp create_directory(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @directory_mode) do
      {:ok, dir}
    else
      {:error, reason} -> {:error, {:file_store_failed, reason}}
    end
  end

  defp readable_directory(opts) do
    dir = directory(opts)

    case check_mode(dir, @directory_mode) do
      :ok -> {:ok, dir}
      error -> error
    end
  end

  # An absent path is not a refusal: nothing is stored there yet, and the
  # caller's own missing-secret answer is the truthful one.
  defp check_mode(path, allowed) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> compare_mode(path, Bitwise.band(mode, 0o777), allowed)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file_store_failed, reason}}
    end
  end

  defp compare_mode(_path, mode, allowed) when mode == allowed, do: :ok

  defp compare_mode(path, mode, allowed) do
    case Bitwise.band(mode, Bitwise.bnot(allowed)) do
      0 -> :ok
      _wider -> {:error, {:insecure_permissions, path, mode}}
    end
  end

  defp write_atomically(path, value) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- write_private(temporary, value),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:file_store_failed, reason}}
    end
  end

  # The mode is set before the value lands: a file created 0644 and narrowed
  # afterwards is readable for as long as that takes.
  defp write_private(path, value) do
    with {:ok, handle} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        IO.binwrite(handle, value)
      after
        File.close(handle)
      end
      |> case do
        :ok -> File.chmod(path, @file_mode)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_value(path) do
    case File.read(path) do
      {:ok, ""} -> {:error, :missing_secret}
      {:ok, value} -> {:ok, value}
      {:error, :enoent} -> {:error, :missing_secret}
      {:error, reason} -> {:error, {:file_store_failed, reason}}
    end
  end

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
end
