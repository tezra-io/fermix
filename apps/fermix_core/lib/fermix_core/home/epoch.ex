defmodule FermixCore.Home.Epoch do
  @moduledoc """
  The primary epoch of a Fermix home: `<home>/mobile/primary_epoch`, one
  positive decimal integer and a newline.

  It counts how many times this home has become the primary engine: 1 from the
  home's first boot as the primary, one more on every move to another host and
  on every restore from a snapshot (M75 D14). The phone identity carries it,
  both handshakes announce it, and a client keeps the highest epoch it has seen
  and refuses a lower one by name, so a retired copy of the home can never pass
  as the primary again.

  Absent is a state, not a default: only a home that has never booted as the
  primary has no file. `initialise/1`, at a primary boot and before the phone
  subtree starts, is the one writer of the first epoch, for a new home and for
  a home from before the epoch existed alike, logged once.
  `FermixChannels.Mobile.Identity` never writes one. Nothing else invents an
  epoch, and `bump/1` on an absent epoch is an error: a move or a restore needs
  a number to count from.
  """

  require Logger

  @dir "mobile"
  @filename "primary_epoch"
  @max_epoch 1_000_000_000
  @file_mode 0o600
  @dir_mode 0o700

  @type epoch :: pos_integer()
  @type error ::
          {:invalid_epoch, Path.t(), String.t()}
          | {:epoch_overflow, Path.t()}
          | {:file, Path.t(), File.posix()}

  @doc "Where the epoch lives under `root`."
  @spec path(Path.t()) :: Path.t()
  def path(root) when is_binary(root) and root != "",
    do: Path.join([root, @dir, @filename])

  @doc "The largest epoch the file may hold."
  @spec max_epoch() :: epoch()
  def max_epoch, do: @max_epoch

  @doc """
  The epoch under `root`: `:absent` when the file does not exist, an error when
  it holds anything but one integer in range.
  """
  @spec read(Path.t()) :: {:ok, epoch()} | :absent | {:error, error()}
  def read(root) when is_binary(root) and root != "" do
    file = path(root)

    case File.read(file) do
      {:ok, contents} -> parse(contents, file)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc """
  Writes `epoch` under `root`: a sibling temp file renamed into place, mode
  `0600`, under a `mobile/` directory created `0700` when it did not exist. An
  existing `mobile/` keeps its mode.
  """
  @spec write(Path.t(), epoch()) :: :ok | {:error, error()}
  def write(root, epoch)
      when is_binary(root) and root != "" and is_integer(epoch) and epoch >= 1 and
             epoch <= @max_epoch do
    file = path(root)
    tmp = file <> ".tmp"

    with :ok <- ensure_dir(Path.dirname(file)),
         :ok <- file_op(File.write(tmp, Integer.to_string(epoch) <> "\n"), tmp),
         :ok <- discard_on_error(file_op(File.chmod(tmp, @file_mode), tmp), tmp),
         :ok <- discard_on_error(file_op(File.rename(tmp, file), file), tmp) do
      :ok
    end
  end

  @doc """
  The epoch a primary boot runs at: the one on disk, or 1 written now for a
  home that has none (its first boot as the primary, or a home from before the
  epoch existed), logged once. An invalid file is an error for the boot to
  refuse by name.
  """
  @spec initialise(Path.t()) :: {:ok, :present | :created, epoch()} | {:error, error()}
  def initialise(root) when is_binary(root) and root != "" do
    case read(root) do
      {:ok, epoch} -> {:ok, :present, epoch}
      :absent -> create_first(root)
      {:error, _reason} = error -> error
    end
  end

  @doc "The one sentence a boot refusal over the epoch is reported with."
  @spec error_sentence(error()) :: String.t()
  def error_sentence({:invalid_epoch, file, excerpt}) do
    "The primary epoch at #{file} is not one positive integer (#{excerpt}); " <>
      "restore this home from an archive or write the last epoch it ran at."
  end

  def error_sentence({:epoch_overflow, file}),
    do: "The primary epoch at #{file} cannot go any higher."

  def error_sentence({:file, file, reason}),
    do: "Cannot read or write the primary epoch at #{file}: #{inspect(reason)}."

  @doc "Reads the epoch under `root` and writes it plus one."
  @spec bump(Path.t()) :: {:ok, epoch()} | {:error, error() | :absent}
  def bump(root) when is_binary(root) and root != "" do
    with {:ok, epoch} <- present(read(root)),
         :ok <- in_range(epoch + 1, root),
         :ok <- write(root, epoch + 1) do
      {:ok, epoch + 1}
    end
  end

  defp create_first(root) do
    with :ok <- write(root, 1) do
      Logger.info("primary epoch initialised at 1 for a home without one: #{path(root)}")
      {:ok, :created, 1}
    end
  end

  defp present(:absent), do: {:error, :absent}
  defp present(other), do: other

  defp in_range(epoch, _root) when epoch <= @max_epoch, do: :ok
  defp in_range(_epoch, root), do: {:error, {:epoch_overflow, path(root)}}

  defp parse(contents, file) do
    with [digits] <- Regex.run(~r/\A([1-9][0-9]{0,9})\n\z/, contents, capture: :all_but_first),
         epoch when epoch <= @max_epoch <- String.to_integer(digits) do
      {:ok, epoch}
    else
      _other -> {:error, {:invalid_epoch, file, excerpt(contents)}}
    end
  end

  defp excerpt(contents),
    do: contents |> binary_part(0, min(byte_size(contents), 32)) |> inspect()

  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}

  # A temp file the rename never consumed is removed so a failed write leaves
  # the directory as it found it; the original error is what the caller sees.
  defp discard_on_error(:ok, _tmp), do: :ok

  defp discard_on_error({:error, _reason} = error, tmp) do
    case File.rm(tmp) do
      :ok -> error
      {:error, :enoent} -> error
      {:error, rm_reason} -> {:error, {:file, tmp, rm_reason}}
    end
  end
end
