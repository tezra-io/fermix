defmodule FermixCore.Setup.SecretWriter.Migration do
  @moduledoc """
  The way back from the file store to the keyring.

  A keyring write already deletes the file copy it supersedes, but that only
  happens when the owner saves a secret — and saving means retyping a value no
  client can read back out of the file store. An owner who unlocks their
  keyring an hour later would otherwise have no way home but to retype every
  key, so this moves them all.

  Nothing is deleted on trust. Each value is written to the keyring and read
  back from it before its file copy goes, because a write the keyring accepted
  and cannot produce would otherwise lose the secret. A refusal leaves every
  file where it was and the recorded choice unchanged, so a failed migration
  puts the owner exactly where they started and the operation can simply be
  run again.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.SecretWriter.FileStore

  @type report :: %{moved: [atom()], store: :keyring | :file}

  @doc """
  Moves every file-stored secret into the keyring.

  `unlock: true` carries the owner's request to answer the system prompt, on
  the same bound a save uses.
  """
  @spec to_keyring(keyword()) :: {:ok, report()} | {:error, term()}
  def to_keyring(opts \\ []) when is_list(opts) do
    case FileStore.stored_keys(opts) do
      [] -> finish([], opts)
      names -> move_all(names, opts)
    end
  end

  defp move_all(names, opts) do
    case Enum.reduce_while(names, {:ok, []}, &move_one(&1, &2, opts)) do
      {:ok, moved} -> finish(Enum.reverse(moved), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # What moved is named by its registry key, not by the environment name the
  # store files it under: the caller is told which SECRET moved, and where a
  # store keeps it is that store's business.
  defp move_one(name, {:ok, moved}, opts) do
    with {:ok, key} <- key_for(name),
         :ok <- move(name, opts) do
      {:cont, {:ok, [key | moved]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # Read, write, read back, and only then delete. The order is the whole of
  # the safety here: at every point between the first read and the delete,
  # at least one store holds a value that answers.
  defp move(name, opts) do
    with {:ok, key} <- key_for(name),
         {:ok, value} <- FileStore.get(key, opts),
         :ok <- write(key, value, opts),
         :ok <- verify(key, value, name, opts) do
      FileStore.delete(key, opts)
    end
  end

  defp write(key, value, opts) do
    put = Keyword.get(opts, :put, &SecretWriter.put/3)
    put.(key, value, keyring_opts(opts))
  end

  # `store: :keyring` is set rather than inherited: this operation exists to
  # write to the keyring, and an opts list carrying the home's current choice
  # would otherwise send every value straight back where it came from.
  defp keyring_opts(opts) do
    opts
    |> Keyword.put(:store, :keyring)
    |> Keyword.put(:unlock, Keyword.get(opts, :unlock, false))
  end

  defp verify(key, value, name, opts) do
    case SecretWriter.get(key, keyring_opts(opts)) do
      {:ok, ^value} -> :ok
      _unreadable -> {:error, {:verify_failed, name}}
    end
  end

  # An item name the registry does not know is one this engine cannot address,
  # so it is reported rather than skipped: a migration that quietly left a file
  # behind would report a move that did not finish.
  defp key_for(name) do
    case Enum.find(SecretPaths.all(), &(&1.env == name)) do
      %{key: key} -> {:ok, key}
      nil -> {:error, {:unknown_secret, name}}
    end
  end

  defp finish(moved, opts) do
    case ConfigStore.put_secret_store(home(opts), :keyring) do
      :ok -> {:ok, %{moved: moved, store: :keyring}}
      {:error, reason} -> {:error, {:choice_not_recorded, reason}}
    end
  end

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
end
