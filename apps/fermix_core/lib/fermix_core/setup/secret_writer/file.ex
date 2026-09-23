defmodule FermixCore.Setup.SecretWriter.File do
  @moduledoc """
  The file store: one file per secret under `<FERMIX_HOME>/secrets/`, the
  directory `0700` and every file `0600`, so only the account that owns the
  home can read them. It is the declared alternative to the OS keyring for a
  machine whose keyring cannot be used — a locked login keyring, a server with
  none — and it is selected only by `[fermix_core] secret_store = "file"`,
  never by a failed keyring write.

  What it does not do: encrypt at rest. `~/.fermix/auth.json` holds OAuth
  tokens under the same permissions, so this is the posture that home already
  has; the operator chose it knowingly, and `fermix doctor` names it.

  A file is written closed to everyone else before it holds a byte: created
  empty with the exclusive flag, chmod'ed to `0600`, then filled, then renamed
  over the final name, so a crash leaves either the old secret or the new one.
  """

  @behaviour FermixCore.Setup.SecretWriter

  import Bitwise
  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @directory "secrets"
  @group_or_other 0o077

  @impl true
  def available?(opts \\ []), do: File.dir?(home(opts))

  @impl true
  def probe(opts \\ []) do
    directory = directory(opts)

    cond do
      not File.dir?(home(opts)) ->
        %{
          store: :file,
          state: :unavailable,
          sentence:
            "the Fermix home #{home(opts)} does not exist, so #{directory} cannot hold secrets"
        }

      File.exists?(directory) and not File.dir?(directory) ->
        %{
          store: :file,
          state: :unavailable,
          sentence: "#{directory} exists and is not a directory, so it cannot hold secrets"
        }

      true ->
        %{
          store: :file,
          state: :available,
          sentence: "secrets are files under #{directory}, readable only by this account"
        }
    end
  end

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    directory = directory(opts)
    final = Path.join(directory, file_name(key))
    staging = Path.join(directory, ".#{file_name(key)}.#{System.unique_integer([:positive])}")

    with :ok <- ensure_directory(directory),
         :ok <- write_closed(staging, value),
         :ok <- File.rename(staging, final) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:file_store, reason}}
    end
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key) do
    path = Path.join(directory(opts), file_name(key))

    with {:ok, %File.Stat{mode: mode}} <- stat(path),
         :ok <- private?(path, mode),
         {:ok, value} <- File.read(path) do
      case value do
        "" -> {:error, :missing_secret}
        value -> {:ok, value}
      end
    end
  end

  # Removing an absent file succeeds: the postcondition already holds.
  @impl true
  def delete(key, opts \\ []) when is_secret_key(key) do
    case File.rm(Path.join(directory(opts), file_name(key))) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file_store, reason}}
    end
  end

  # A skill's shell command reads the file itself, the way `secret-tool
  # lookup` is run for the keyring store; the value never rides in argv.
  @impl true
  def command_source(key, opts \\ []) when is_secret_key(key) do
    %{
      source: :command,
      command: System.find_executable("cat") || "cat",
      args: [Path.join(directory(opts), file_name(key))],
      timeout_ms: 3_000
    }
  end

  @doc "Where this home keeps its secret files."
  @spec directory(keyword()) :: Path.t()
  def directory(opts \\ []) when is_list(opts), do: Path.join(home(opts), @directory)

  @doc "Every secret file the store holds, by the name `config.toml` knows it as."
  @spec stored(keyword()) :: [String.t()]
  def stored(opts \\ []) when is_list(opts) do
    case File.ls(directory(opts)) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "list", path: directory(opts)
    end
  end

  # `external_env:<NAME>` keeps its family prefix; the colon becomes a dot so
  # the name is a plain file name on every filesystem a home can live on.
  defp file_name(key), do: key |> SecretWriter.item_name() |> String.replace(":", ".")

  defp home(opts), do: Keyword.get(opts, :home) || ConfigStore.fermix_home()

  defp ensure_directory(directory) do
    with :ok <- File.mkdir_p(directory) do
      File.chmod(directory, 0o700)
    end
  end

  defp write_closed(path, value) do
    with {:ok, device} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(device, value) do
      File.close(device)
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :missing_secret}
      {:error, reason} -> {:error, {:file_store, reason}}
    end
  end

  # A secret file someone loosened is refused, not read: the store's promise
  # is that only this account can read it, and reading anyway would keep a
  # channel running on a token another account can now copy.
  defp private?(path, mode) do
    if (mode &&& @group_or_other) == 0 do
      :ok
    else
      {:error, {:file_store, {:readable_by_others, path}}}
    end
  end
end
